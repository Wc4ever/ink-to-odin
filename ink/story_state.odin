package ink

import "core:mem"
import "core:mem/virtual"
import "core:strings"

// Story_State: the entire mutable runtime state of a story playthrough.
//
// Composition (mirrors ink-engine-runtime/StoryState.cs minus multi-flow,
// patches, and observer events):
//   - call_stack       : execution frames + threads + temp variables
//   - variables_state  : globals + defaults + variable-pointer deref
//   - output_stream    : current flow's output buffer
//   - eval_stack       : evaluator's value stack ([Eval_Start..Eval_End])
//   - current_choices  : presented choices for the consumer
//   - visit_counts     : path -> times visited, for `~ x = -> knot` reads
//   - turn_indices     : path -> turn index at last visit
//   - rng state        : story_seed + previous_random
//   - errors, warnings : evaluator-collected
//   - runtime_arena    : owns ^Object allocations made BY the evaluator
//                        (separate from Compiled_Story.arena which owns
//                        the immutable compiled tree)
//
// `compiled_story` is a non-owning back-reference. The Compiled_Story is
// expected to outlive the Story_State.

INK_SAVE_STATE_VERSION :: 10
DEFAULT_FLOW_NAME      :: "DEFAULT_FLOW"

Story_State :: struct {
	compiled_story: ^Compiled_Story,

	// Owns evaluator-produced runtime objects; cleared on reset/load.
	runtime_arena: virtual.Arena,

	// Active flow's data — per-flow state (callstack, output stream, pending
	// choices). Stored as direct fields rather than indirected through a Flow
	// pointer so the call sites that read these can stay unchanged. On
	// story_switch_flow, these fields swap with the matching entry in
	// inactive_flows.
	call_stack:      Call_Stack,
	variables_state: Variable_State,
	output_stream:   Output_Stream,
	current_choices: [dynamic]Choice,

	// Multi-flow storage. Holds the inactive flows ONLY (the active one lives
	// in the fields above). current_flow_name identifies which flow is active.
	// For default single-flow stories, inactive_flows stays empty.
	inactive_flows:    map[string]Flow,
	current_flow_name: string,

	eval_stack: [dynamic]^Object,

	diverted_pointer: Pointer,

	visit_counts:        map[string]int,
	turn_indices:        map[string]int,
	current_turn_index:  int,

	story_seed:      int,
	previous_random: int,
	did_safe_exit:   bool,

	// EXTERNAL function bindings + fallback toggle. When an `is_external`
	// divert fires and no binding is registered for the name, the runtime
	// optionally diverts to a same-named ink knot.
	externals:                            map[string]External_Binding,
	allow_external_function_fallbacks:    bool,

	// Lookahead-safety machinery (mirrors C# Story._sawLookaheadUnsafe...
	// + _stateSnapshotAtLastNewline). story_continue toggles
	// snapshot_at_last_newline_exists when it takes/restores/discards its
	// internal snap; execute_external_call reads it to decide whether an
	// unsafe binding can run now or must defer until snapshot is settled.
	snapshot_at_last_newline_exists:             bool,
	saw_lookahead_unsafe_function_after_newline: bool,

	current_errors:   [dynamic]string,
	current_warnings: [dynamic]string,

	// Debug trace ring buffer — last N steps for diagnostics.
	debug_trace: [dynamic]string,
}

// Choice: presented to game code via story_current_choices. Created by the
// evaluator from a Choice_Point and the surrounding callstack/output state.
//
// thread_at_generation owns a deep-copy of the current thread at the moment
// the choice was created. When the player selects the choice, the runtime
// restores this thread as the active callstack thread, ensuring divert
// targets, temp vars, and saved continuations all unwind from the right
// location even if the story moved on while gathering remaining choices.
Choice :: struct {
	text:                  string,
	index:                 int,
	source_path:           string, // originalChoicePath
	target_path:           string, // pathStringOnChoice
	original_thread_index: int,
	thread_at_generation:  Call_Stack_Thread,
	tags:                  []string,
	is_invisible_default:  bool,
}

choice_destroy :: proc(c: ^Choice) {
	delete(c.tags)
	c.tags = nil
	call_stack_thread_destroy(&c.thread_at_generation)
}

// Per-flow execution state. Each flow has its own callstack, output stream,
// and pending choice list — but globals (variables, visit/turn counts) are
// shared across flows on the parent Story_State. Mirrors C# Ink.Runtime.Flow.
//
// At any moment the *active* flow's three pieces live as direct fields on
// Story_State (call_stack, output_stream, current_choices); inactive flows
// are parked in Story_State.inactive_flows under their name.
Flow :: struct {
	call_stack:      Call_Stack,
	output_stream:   Output_Stream,
	current_choices: [dynamic]Choice,
}

flow_destroy :: proc(f: ^Flow) {
	for &c in f.current_choices do choice_destroy(&c)
	delete(f.current_choices)
	output_stream_destroy(&f.output_stream)
	call_stack_destroy(&f.call_stack)
}

// ---- Lifecycle ------------------------------------------------------------

// Initializes a Story_State for the given Compiled_Story. The story state's
// own runtime arena is created here; the call stack starts with one Tunnel
// frame at the start of the story root.
story_state_init :: proc(s: ^Story_State, story: ^Compiled_Story) -> bool {
	if story == nil || story.root == nil do return false

	if err := virtual.arena_init_growing(&s.runtime_arena); err != nil {
		return false
	}

	s.compiled_story = story
	s.diverted_pointer = POINTER_NULL
	s.current_turn_index = -1
	s.story_seed = 0
	s.previous_random = 0
	s.did_safe_exit = false

	call_stack_init(&s.call_stack, story.root)
	variable_state_init(&s.variables_state, &s.call_stack)
	s.variables_state.list_definitions = &story.list_definitions
	s.variables_state.runtime_alloc = story_state_runtime_allocator(s)
	output_stream_init(&s.output_stream)

	s.inactive_flows = make(map[string]Flow)
	s.current_flow_name = DEFAULT_FLOW_NAME

	s.current_choices = make([dynamic]Choice, 0, 0)
	s.eval_stack = make([dynamic]^Object, 0, 0)
	s.visit_counts = make(map[string]int)
	s.turn_indices = make(map[string]int)
	s.current_errors = make([dynamic]string, 0, 0)
	s.current_warnings = make([dynamic]string, 0, 0)
	s.debug_trace = make([dynamic]string, 0, 0)

	// Bootstrap: run the "global decl" knot if present, then snapshot
	// defaults so VariableReferences resolve from the first real Continue.
	story_reset_globals(s)
	return true
}

story_state_destroy :: proc(s: ^Story_State) {
	for &c in s.current_choices do choice_destroy(&c)
	delete(s.current_choices)
	delete(s.eval_stack)
	delete(s.visit_counts)
	delete(s.turn_indices)
	delete(s.current_errors)
	delete(s.current_warnings)
	delete(s.debug_trace)

	output_stream_destroy(&s.output_stream)
	variable_state_destroy(&s.variables_state)
	call_stack_destroy(&s.call_stack)

	for _, &flow in s.inactive_flows do flow_destroy(&flow)
	delete(s.inactive_flows)

	if s.externals != nil do delete(s.externals)

	virtual.arena_destroy(&s.runtime_arena)
	s^ = {}
}

// ---- Flow management -----------------------------------------------------
//
// A Flow is a parallel execution cursor (callstack + output + pending choices)
// over the same compiled story. Globals are shared; only the per-flow state
// is per-flow. Mirrors C# Story.SwitchFlow / SwitchToDefaultFlow / RemoveFlow.

// Returns the active flow's name (defaults to "DEFAULT_FLOW").
story_current_flow_name :: proc(s: ^Story_State) -> string {
	return s.current_flow_name
}

// Switch the active flow to `name`. If a flow by that name doesn't yet exist,
// it's created with a fresh callstack at the start of the story root.
// No-op if `name` is already active. Globals (variables, visit/turn counts)
// are unaffected — only the per-flow execution cursor swaps.
story_switch_flow :: proc(s: ^Story_State, name: string) {
	if s.current_flow_name == name do return

	// Park the current active flow under its name.
	prev_name := strings.clone(s.current_flow_name, story_state_runtime_allocator(s))
	s.inactive_flows[prev_name] = Flow {
		call_stack      = s.call_stack,
		output_stream   = s.output_stream,
		current_choices = s.current_choices,
	}

	// Pop or freshly create the target flow into the active slot.
	if existing, ok := s.inactive_flows[name]; ok {
		s.call_stack      = existing.call_stack
		s.output_stream   = existing.output_stream
		s.current_choices = existing.current_choices
		delete_key(&s.inactive_flows, name)
		// Variable_State holds &s.call_stack; the address is unchanged so
		// callstack-bound temp lookups continue to resolve into the active flow.
	} else {
		// Fresh flow: same shape as story_state_init does for the initial flow.
		call_stack_init(&s.call_stack, s.compiled_story.root)
		output_stream_init(&s.output_stream)
		s.current_choices = make([dynamic]Choice, 0, 0)
	}

	s.current_flow_name = strings.clone(name, story_state_runtime_allocator(s))
}

story_switch_to_default_flow :: proc(s: ^Story_State) {
	story_switch_flow(s, DEFAULT_FLOW_NAME)
}

// Removes a flow. Cannot remove the active flow or the default flow.
story_remove_flow :: proc(s: ^Story_State, name: string) -> bool {
	if name == DEFAULT_FLOW_NAME do return false
	if name == s.current_flow_name do return false
	flow, found := s.inactive_flows[name]
	if !found do return false
	flow_destroy(&flow)
	delete_key(&s.inactive_flows, name)
	return true
}

// Names of every flow currently in play (active + inactive). Caller owns the
// returned slice (delete it).
story_alive_flow_names :: proc(s: ^Story_State, allocator := context.allocator) -> []string {
	names := make([dynamic]string, 0, len(s.inactive_flows) + 1, allocator)
	append(&names, s.current_flow_name)
	for n in s.inactive_flows do append(&names, n)
	return names[:]
}

// Resets to "fresh story" state. The runtime arena is freed and re-created;
// every evaluator-produced Object becomes invalid. Compiled_Story is unchanged.
story_state_reset :: proc(s: ^Story_State) {
	story := s.compiled_story
	story_state_destroy(s)
	story_state_init(s, story)
}

// Allocator backing evaluator-produced runtime Objects (e.g. results of
// `~ x = 5`, intermediate native-function values, split String_Values).
story_state_runtime_allocator :: proc(s: ^Story_State) -> mem.Allocator {
	return virtual.arena_allocator(&s.runtime_arena)
}

// ---- Pointer accessors ----------------------------------------------------
//
// Same convention as C#: currentPointer is the topmost callstack element's
// pointer; previousPointer is per-thread.

story_state_current_pointer :: proc(s: ^Story_State) -> Pointer {
	el := call_stack_current_element(&s.call_stack)
	if el == nil do return POINTER_NULL
	return el.current_pointer
}

story_state_set_current_pointer :: proc(s: ^Story_State, p: Pointer) {
	el := call_stack_current_element(&s.call_stack)
	if el == nil do return
	el.current_pointer = p
}

story_state_previous_pointer :: proc(s: ^Story_State) -> Pointer {
	t := call_stack_current_thread(&s.call_stack)
	if t == nil do return POINTER_NULL
	return t.previous_pointer
}

story_state_set_previous_pointer :: proc(s: ^Story_State, p: Pointer) {
	t := call_stack_current_thread(&s.call_stack)
	if t == nil do return
	t.previous_pointer = p
}

// canContinue: the runtime can step the pointer if it points somewhere
// meaningful and we have no fatal errors collected.
story_state_can_continue :: proc(s: ^Story_State) -> bool {
	if pointer_is_null(story_state_current_pointer(s)) do return false
	return !story_state_has_error(s)
}

story_state_has_error :: proc(s: ^Story_State) -> bool {
	return len(s.current_errors) > 0
}

story_state_has_warning :: proc(s: ^Story_State) -> bool {
	return len(s.current_warnings) > 0
}

// ---- Visit / turn counts --------------------------------------------------

story_state_visit_count_at_path_string :: proc(s: ^Story_State, path_string: string) -> int {
	if v, ok := s.visit_counts[path_string]; ok do return v
	return 0
}

// Resolve a Container pointer to its path string and read the visit count.
// Skips the .Visits flag check because some callers (Visit_Index control
// command, sequence-shuffle dispatch) consult visit counts unconditionally.
story_state_visit_count_at_path_string_for_container :: proc(s: ^Story_State, container_obj: ^Object) -> int {
	if container_obj == nil do return 0
	p := object_path(container_obj, story_state_runtime_allocator(s))
	defer path_destroy(&p, story_state_runtime_allocator(s))
	key := path_to_string(p, story_state_runtime_allocator(s))
	if v, ok := s.visit_counts[key]; ok do return v
	return 0
}

story_state_visit_count_for_container :: proc(s: ^Story_State, container_obj: ^Object, allocator := context.allocator) -> int {
	c, ok := container_obj.variant.(Container)
	if !ok do return 0
	if .Visits not_in c.flags {
		story_state_error(s, "Read count for unflagged container is undefined")
		return 0
	}
	p := object_path(container_obj, allocator)
	defer path_destroy(&p, allocator)
	key := path_to_string(p, allocator)
	defer delete(key, allocator)
	if v, ok := s.visit_counts[key]; ok do return v
	return 0
}

story_state_increment_visit_count_for_container :: proc(s: ^Story_State, container_obj: ^Object, allocator := context.allocator) {
	if container_obj == nil do return
	p := object_path(container_obj, allocator)
	defer path_destroy(&p, allocator)
	key_temp := path_to_string(p, allocator)
	defer delete(key_temp, allocator)

	// Map keys must outlive the entry. Clone into the runtime arena.
	if existing, found := s.visit_counts[key_temp]; found {
		s.visit_counts[key_temp] = existing + 1
	} else {
		key_owned := path_string_clone_into(key_temp, story_state_runtime_allocator(s))
		s.visit_counts[key_owned] = 1
	}
}

story_state_record_turn_index_visit_to_container :: proc(s: ^Story_State, container_obj: ^Object, allocator := context.allocator) {
	if container_obj == nil do return
	p := object_path(container_obj, allocator)
	defer path_destroy(&p, allocator)
	key_temp := path_to_string(p, allocator)
	defer delete(key_temp, allocator)
	if _, found := s.turn_indices[key_temp]; found {
		s.turn_indices[key_temp] = s.current_turn_index
	} else {
		key_owned := path_string_clone_into(key_temp, story_state_runtime_allocator(s))
		s.turn_indices[key_owned] = s.current_turn_index
	}
}

story_state_turns_since_for_container :: proc(s: ^Story_State, container_obj: ^Object, allocator := context.allocator) -> int {
	c, ok := container_obj.variant.(Container)
	if !ok do return -1
	if .Turns not_in c.flags {
		story_state_error(s, "TURNS_SINCE() for unflagged container is undefined")
	}
	p := object_path(container_obj, allocator)
	defer path_destroy(&p, allocator)
	key := path_to_string(p, allocator)
	defer delete(key, allocator)
	if idx, found := s.turn_indices[key]; found {
		return s.current_turn_index - idx
	}
	return -1
}

// ---- Errors / warnings ----------------------------------------------------

story_state_error :: proc(s: ^Story_State, msg: string) {
	append(&s.current_errors, msg)
}

story_state_warning :: proc(s: ^Story_State, msg: string) {
	append(&s.current_warnings, msg)
}

story_state_reset_errors :: proc(s: ^Story_State) {
	clear(&s.current_errors)
	clear(&s.current_warnings)
}

// ---- Output / output reset ------------------------------------------------

story_state_reset_output :: proc(s: ^Story_State, init_objs: []^Object = nil) {
	output_stream_reset(&s.output_stream, init_objs)
}

// ---- Helpers --------------------------------------------------------------

@(private)
path_string_clone_into :: proc(s: string, allocator: mem.Allocator) -> string {
	bytes := make([]byte, len(s), allocator)
	copy(bytes, transmute([]byte)s)
	return string(bytes)
}
