package ink

import "core:fmt"
import "core:math"
import "core:strings"

// Flip to true to dump per-step pointer/path/divert info to stderr while
// debugging the evaluator. Off by default — adds significant overhead.
DEBUG_TRACE :: false

// Story: the evaluator. Walks the pointer through the compiled story tree,
// emits content to the output stream, executes control commands, gathers
// choices, and resolves diverts.
//
// Mirrors ink-engine-runtime/Story.cs but is intentionally a vertical slice:
//   - Native function dispatch is stubbed (story_state_error on encounter).
//   - The "snapshot at last newline" rewind that handles glue-across-newline
//     is omitted; we just keep stepping until canContinue is false or the
//     output stream ends in a newline.
//   - Multi-flow, default invisible choices, and most async/profiling are
//     deferred.
//
// This is enough to walk TheIntercept through its global decls, divert into
// the start knot, emit text, and present the first choice list. Subsequent
// passes will fill in expression-evaluation details as they're exercised.

STORY_OUTPUT_STREAM_LIMIT :: 1024 * 1024 // sanity cap on a single Continue

// ---- Public API -----------------------------------------------------------

// Advance the story until the next sensible stopping point: either the
// output stream ends in a newline, or canContinue becomes false (i.e. we
// hit a choice point or end-of-story). Returns true on a clean stop, false
// if an error was recorded mid-step.
story_continue :: proc(s: ^Story_State) -> bool {
	if !story_state_can_continue(s) {
		story_state_error(s, "Can't continue - check can_continue first")
		return false
	}

	s.did_safe_exit = false
	s.saw_lookahead_unsafe_function_after_newline = false
	output_stream_reset(&s.output_stream)

	// Newline lookahead via full state snapshot. When the output ends in a
	// newline AND canContinue, take a deep snapshot of every mutable piece
	// of state. If a subsequent step pushes more visible text past that
	// newline, restore the snapshot — including variables, callstack, eval
	// stack, choices, visit counts, etc. — so the next Continue re-runs the
	// post-newline content cleanly. Mirrors C# StateSnapshot/RestoreStateSnapshot.
	snap: State_Snapshot
	snap_text_len := 0

	take_snap :: proc(s: ^Story_State, snap: ^State_Snapshot, snap_text_len: ^int) {
		snap^ = state_snapshot_take(s)
		txt := output_stream_current_text(&s.output_stream, context.temp_allocator)
		snap_text_len^ = len(txt)
		s.snapshot_at_last_newline_exists = true
	}
	drop_snap :: proc(s: ^Story_State, snap: ^State_Snapshot) {
		state_snapshot_discard(snap)
		s.snapshot_at_last_newline_exists = false
	}
	rewind_snap :: proc(s: ^Story_State, snap: ^State_Snapshot) {
		state_snapshot_restore(s, snap)
		s.snapshot_at_last_newline_exists = false
	}

	step_count := 0
	for {
		step_count += 1
		if step_count > 100_000 {
			when DEBUG_TRACE {
				fmt.eprintln("--- TRACE (last 40 steps before bail) ---")
				for line in s.debug_trace do fmt.eprintln(line)
			}
			story_state_error(s, "story_continue: step count exceeded sanity cap (likely infinite loop in evaluator)")
			return false
		}

		story_step(s)
		if story_state_has_error(s) do return false

		if !output_stream_in_string_evaluation(&s.output_stream) {
			if s.snapshot_at_last_newline_exists {
				txt := output_stream_current_text(&s.output_stream, context.temp_allocator)

				// Did the newline at snap-time still occupy that position? If
				// not, glue ate it — drop the snapshot so we don't roll back
				// over the merged content. (Mirrors C# CalculateNewlineOutputStateChange:
				// NewlineRemoved -> DiscardSnapshot.)
				newline_intact :=
					len(txt) >= snap_text_len &&
					snap_text_len > 0 &&
					txt[snap_text_len - 1] == '\n'
				extended := false
				if newline_intact && len(txt) > snap_text_len {
					for i in snap_text_len ..< len(txt) {
						c := txt[i]
						if c != ' ' && c != '\t' {
							extended = true
							break
						}
					}
				}
				if !newline_intact {
					drop_snap(s, &snap)
				} else if extended || s.saw_lookahead_unsafe_function_after_newline {
					rewind_snap(s, &snap)
					return true
				}
			}

			if output_stream_ends_in_newline(&s.output_stream) {
				if story_state_can_continue(s) {
					if !s.snapshot_at_last_newline_exists {
						take_snap(s, &snap, &snap_text_len)
					}
				} else if s.snapshot_at_last_newline_exists {
					drop_snap(s, &snap)
				}
			}
		}

		if !story_state_can_continue(s) do break
	}

	// If we exit with a snapshot still pending (e.g. canContinue went false
	// before we hit any extension), discard rather than restore — the
	// post-newline state is the real one we want to keep.
	if s.snapshot_at_last_newline_exists do drop_snap(s, &snap)
	return true
}

story_current_text :: proc(s: ^Story_State, allocator := context.allocator) -> string {
	return output_stream_current_text(&s.output_stream, allocator)
}

story_current_tags :: proc(s: ^Story_State, allocator := context.allocator) -> []string {
	return output_stream_current_tags(&s.output_stream, allocator)
}

story_current_choices :: proc(s: ^Story_State) -> []Choice {
	// Like upstream: while we can continue producing text, choices are not
	// yet shown, so callers see an empty list.
	if story_state_can_continue(s) do return nil

	// Side-effecting like C# Story.currentChoices: assign each visible
	// choice its position as `index`. Invisible-default choices are
	// filtered out (and don't get an index, matching dotnet semantics).
	out_idx := 0
	for &c in s.current_choices {
		if c.is_invisible_default do continue
		c.index = out_idx
		out_idx += 1
	}
	return s.current_choices[:]
}

story_choose_choice_index :: proc(s: ^Story_State, choice_idx: int) -> bool {
	if choice_idx < 0 || choice_idx >= len(s.current_choices) {
		story_state_error(s, fmt.tprintf("choice index %d out of range", choice_idx))
		return false
	}
	// The chosen Choice's thread_at_generation captures the callstack at the
	// moment the choice was created; restore it before navigating to the
	// target so saved continuations and temp vars unwind correctly.
	c := &s.current_choices[choice_idx]
	call_stack_set_current_thread(&s.call_stack, &c.thread_at_generation)
	story_choose_path_string(s, c.target_path, increment_turn = true)
	return true
}

// ---- Internal: per-step --------------------------------------------------

@(private)
story_continue_single_step :: proc(s: ^Story_State) -> (output_ends_in_newline: bool) {
	story_step(s)
	// We don't yet implement the snapshot/rewind mechanism C# uses around
	// newlines (so glue can revive a line terminator). For the moment, run
	// each Continue all the way to !canContinue or end. This collapses
	// multi-line turns into a single OUTPUT block (mismatching dotnet's
	// per-newline granularity), but produces correct state at the bail-out.
	return false
}

@(private)
story_step :: proc(s: ^Story_State) {
	pointer := story_state_current_pointer(s)
	if pointer_is_null(pointer) do return

	when DEBUG_TRACE {
		// Record container path + index + obj kind for the current step.
		obj_at := pointer_resolve(pointer)
		path_str: string
		if pointer.container != nil {
			pp := object_path(pointer.container, story_state_runtime_allocator(s))
			path_str = path_to_string(pp, story_state_runtime_allocator(s))
		}
		kind: string
		if obj_at == nil {
			kind = "nil"
		} else {
			switch v in obj_at.variant {
			case Container:                kind = fmt.tprintf("Container name=%q", v.name)
			case String_Value:             kind = fmt.tprintf("Str %q", v.value)
			case Int_Value:                kind = fmt.tprintf("Int %d", v.value)
			case Float_Value, Bool_Value:  kind = "Num/Bool"
			case Divert_Target_Value:      kind = fmt.tprintf("DivertTarget %s", v.target)
			case Variable_Pointer_Value:   kind = "VarPtr"
			case List_Value:               kind = "List"
			case Control_Command:          kind = fmt.tprintf("Cmd.%v", v)
			case Native_Function_Call:     kind = fmt.tprintf("Native %s", v.name)
			case Divert:                   kind = fmt.tprintf("Divert tgt=%q var=%q cond=%v push=%v type=%v ext=%v", v.target_path, v.variable_divert_name, v.is_conditional, v.pushes_to_stack, v.stack_push_type, v.is_external)
			case Choice_Point:             kind = fmt.tprintf("Choice -> %s", v.path_on_choice)
			case Variable_Reference:       kind = fmt.tprintf("VarRef %s", v.name)
			case Variable_Assignment:      kind = fmt.tprintf("VarAssign %s", v.name)
			case Tag, Glue, Void:          kind = "Tag/Glue/Void"
			}
		}
		line := fmt.aprintf("[%s.%d] %s", path_str, pointer.index, kind, allocator = story_state_runtime_allocator(s))
		append(&s.debug_trace, line)
		if len(s.debug_trace) > 40 {
			ordered_remove(&s.debug_trace, 0)
		}
	}

	// Descend into containers: when current pointer addresses a Container,
	// step into its first child instead. Visit-count each container we enter.
	for {
		obj := pointer_resolve(pointer)
		if obj == nil do break
		container, is_c := obj.variant.(Container)
		if !is_c do break
		visit_container(s, obj, true)
		if len(container.content) == 0 do break
		pointer = pointer_start_of(obj)
	}
	story_state_set_current_pointer(s, pointer)

	current_obj := pointer_resolve(pointer)
	should_add_to_stream := true
	is_logic_or_flow := perform_logic_and_flow_control(s, current_obj, current_obj)
	if pointer_is_null(story_state_current_pointer(s)) do return
	if is_logic_or_flow do should_add_to_stream = false

	if cp, is_cp := current_obj.variant.(Choice_Point); is_cp {
		choice, ok := process_choice(s, cp, current_obj)
		if ok {
			append(&s.current_choices, choice)
		}
		current_obj = nil
		should_add_to_stream = false
	}

	if current_obj != nil {
		if _, is_container := current_obj.variant.(Container); is_container {
			should_add_to_stream = false
		}
	}

	if should_add_to_stream && current_obj != nil {
		// Variable-pointer specialisation: lock down its context.
		if vp, is_vp := current_obj.variant.(Variable_Pointer_Value); is_vp && vp.context_index == -1 {
			ctx_idx := call_stack_context_for_variable_named(&s.call_stack, vp.name)
			specialised := new(Object, story_state_runtime_allocator(s))
			specialised.variant = Variable_Pointer_Value{name = vp.name, context_index = ctx_idx}
			current_obj = specialised
		}

		cur_el := call_stack_current_element(&s.call_stack)
		in_expr := cur_el != nil && cur_el.in_expression_evaluation
		if in_expr {
			eval_stack_push(s, current_obj)
		} else {
			output_stream_push(&s.output_stream, current_obj, &s.call_stack, story_state_runtime_allocator(s))
		}
	}

	next_content(s)

	// Starting a thread happens AFTER the increment so the parent thread's
	// pointer (and the cloned child thread's pointer) sit just past the
	// StartThread instruction. Mirrors C# Story.Step lines 966-971.
	if current_obj != nil {
		if cmd, is_cmd := current_obj.variant.(Control_Command); is_cmd && cmd == .Start_Thread {
			call_stack_push_thread(&s.call_stack)
		}
	}
}

@(private)
perform_logic_and_flow_control :: proc(s: ^Story_State, obj: ^Object, here: ^Object) -> bool {
	if obj == nil do return false

	switch v in obj.variant {
	case Container:
		return false
	case String_Value, Int_Value, Float_Value, Bool_Value, Divert_Target_Value, Variable_Pointer_Value, List_Value, Glue, Tag, Void:
		return false

	case Divert:
		return execute_divert(s, v, here)

	case Control_Command:
		return execute_control_command(s, v)

	case Native_Function_Call:
		return execute_native_function(s, v.name)

	case Variable_Reference:
		return execute_variable_reference(s, v, here)

	case Variable_Assignment:
		return execute_variable_assignment(s, v)

	case Choice_Point:
		// Choice points are processed at the call site of perform_logic_and_flow_control.
		return false
	}
	return false
}

// ---- Diverts --------------------------------------------------------------

@(private)
execute_divert :: proc(s: ^Story_State, d: Divert, here: ^Object) -> bool {
	if d.is_conditional {
		cond := eval_stack_pop(s)
		if !is_truthy(cond) do return true
	}

	if d.is_external {
		return execute_external_call(s, d)
	}

	target_path_string := d.target_path
	if len(d.variable_divert_name) > 0 {
		v := variable_state_get_variable_with_name(&s.variables_state, d.variable_divert_name)
		if v == nil {
			story_state_error(s, fmt.tprintf("divert variable '%s' not found", d.variable_divert_name))
			return true
		}
		dt, is_dt := v.variant.(Divert_Target_Value)
		if !is_dt {
			story_state_error(s, fmt.tprintf("divert variable '%s' is not a divert target", d.variable_divert_name))
			return true
		}
		target_path_string = dt.target
	}

	target_pointer := story_pointer_at_path_string(s, target_path_string, here)
	if pointer_is_null(target_pointer) {
		story_state_error(s, fmt.tprintf("divert target not found: %s", target_path_string))
		return true
	}
	// Mirror C# Divert.targetPointer: for a name-final path (index == -1)
	// the divert lands at the container's first child (index 0), NOT at the
	// container itself. This avoids re-visiting the named container's outer
	// frame when diverting WITHIN it (e.g. `-> arena` from inside `arena`).
	if target_pointer.index == -1 do target_pointer.index = 0

	when DEBUG_TRACE {
		// Show what each divert resolves to.
		t_path: string
		if target_pointer.container != nil {
			tp := object_path(target_pointer.container, story_state_runtime_allocator(s))
			t_path = path_to_string(tp, story_state_runtime_allocator(s))
		}
		dbg := fmt.aprintf("    => DIVERT '%s' resolved to [%s.%d]", target_path_string, t_path, target_pointer.index, allocator = story_state_runtime_allocator(s))
		append(&s.debug_trace, dbg)
		if len(s.debug_trace) > 40 do ordered_remove(&s.debug_trace, 0)
	}

	s.diverted_pointer = target_pointer

	if d.pushes_to_stack {
		call_stack_push(&s.call_stack, d.stack_push_type, output_stream_length_with_pushed = len(s.output_stream.stream))
	}
	return true
}

// ---- Control commands -----------------------------------------------------

@(private)
execute_control_command :: proc(s: ^Story_State, cmd: Control_Command) -> bool {
	switch cmd {
	case .Eval_Start:
		set_in_expression_evaluation(s, true)
	case .Eval_End:
		set_in_expression_evaluation(s, false)

	case .Eval_Output:
		if len(s.eval_stack) > 0 {
			out := eval_stack_pop(s)
			if _, is_void := out.variant.(Void); !is_void {
				txt := value_to_string(out, story_state_runtime_allocator(s))
				str_obj := new(Object, story_state_runtime_allocator(s))
				str_obj.variant = String_Value{value = txt}
				output_stream_push(&s.output_stream, str_obj, &s.call_stack, story_state_runtime_allocator(s))
			}
		}

	case .No_Op:
		// nothing

	case .Duplicate:
		if len(s.eval_stack) > 0 {
			eval_stack_push(s, s.eval_stack[len(s.eval_stack) - 1])
		}

	case .Pop_Evaluated_Value:
		eval_stack_pop(s)

	case .Pop_Function, .Pop_Tunnel:
		expected_type: Push_Pop_Type = .Function if cmd == .Pop_Function else .Tunnel

		// Tunnel-onwards may carry an override target on the eval stack.
		override_target_path: string
		if expected_type == .Tunnel {
			popped := eval_stack_pop(s)
			if popped != nil {
				if dt, is_dt := popped.variant.(Divert_Target_Value); is_dt {
					override_target_path = dt.target
				}
			}
		}

		cur := call_stack_current_element(&s.call_stack)
		if cur == nil || cur.type != expected_type || !call_stack_can_pop(&s.call_stack) {
			story_state_error(s, fmt.tprintf("mismatched %v pop", cmd))
			return true
		}
		call_stack_pop(&s.call_stack)
		if len(override_target_path) > 0 {
			s.diverted_pointer = story_pointer_at_path_string(s, override_target_path)
		}

	case .Begin_String:
		// Push the marker into the output stream and exit expression mode
		// so following content goes to the stream until End_String collects it.
		mark := new(Object, story_state_runtime_allocator(s))
		mark.variant = Control_Command.Begin_String
		output_stream_push(&s.output_stream, mark, &s.call_stack, story_state_runtime_allocator(s))
		set_in_expression_evaluation(s, false)

	case .End_String:
		// Walk back to Begin_String, concatenate intervening string content,
		// pop those entries from the stream, push the assembled string onto
		// the eval stack, and re-enter expression mode.
		begin_idx := -1
		for i := len(s.output_stream.stream) - 1; i >= 0; i -= 1 {
			if c, is_cmd := s.output_stream.stream[i].variant.(Control_Command); is_cmd && c == .Begin_String {
				begin_idx = i
				break
			}
		}
		if begin_idx < 0 {
			story_state_error(s, "End_String without Begin_String")
			return true
		}
		b := strings.builder_make(story_state_runtime_allocator(s))
		for i := begin_idx + 1; i < len(s.output_stream.stream); i += 1 {
			if sv, is_str := s.output_stream.stream[i].variant.(String_Value); is_str {
				strings.write_string(&b, sv.value)
			}
		}
		// Pop everything from begin_idx onward.
		consumed := len(s.output_stream.stream) - begin_idx
		output_stream_pop(&s.output_stream, consumed)

		set_in_expression_evaluation(s, true)
		str_obj := new(Object, story_state_runtime_allocator(s))
		str_obj.variant = String_Value{value = strings.to_string(b)}
		eval_stack_push(s, str_obj)

	case .Begin_Tag, .End_Tag:
		// Both pass straight through to output stream when not in string eval;
		// current_tags computation handles structure.
		mark := new(Object, story_state_runtime_allocator(s))
		mark.variant = cmd
		output_stream_push(&s.output_stream, mark, &s.call_stack, story_state_runtime_allocator(s))

	case .Done:
		// In a child thread, Done returns to the parent (popping the thread).
		// In the mainline, Done flags safe-exit and clears the pointer.
		if call_stack_can_pop_thread(&s.call_stack) {
			call_stack_pop_thread(&s.call_stack)
		} else {
			s.did_safe_exit = true
			story_state_set_current_pointer(s, POINTER_NULL)
		}

	case .End:
		story_force_end(s)

	case .Choice_Count:
		eval_stack_push_int(s, i64(len(s.current_choices)))

	case .Turns:
		eval_stack_push_int(s, i64(s.current_turn_index + 1))

	case .Visit_Index:
		// (current container's visit count) - 1, used by sequence/cycle exprs.
		cur := story_state_current_pointer(s)
		count := story_state_visit_count_at_path_string_for_container(s, cur.container)
		eval_stack_push_int(s, i64(count - 1))

	case .Sequence_Shuffle_Index:
		eval_stack_push_int(s, next_sequence_shuffle_index(s))

	case .List_Range:
		// Pops max, min, target — min/max may be int OR list value.
		// For list bounds, C# uses minItem.Value for min, maxItem.Value for max.
		max_obj := eval_stack_pop(s)
		min_obj := eval_stack_pop(s)
		target_obj := eval_stack_pop(s)
		target, t_ok := list_value_of(target_obj)
		if !t_ok {
			story_state_error(s, "LIST_RANGE expects a list as third arg")
			return true
		}
		alloc := story_state_runtime_allocator(s)
		eval_stack_push(s, new_list_object(ink_list_range(target, list_range_min(min_obj), list_range_max(max_obj), alloc), alloc))

	case .List_From_Int:
		// Pops int, then list-name string. Returns the list def's item with
		// that exact value, wrapped as a single-item list. Empty list if no
		// item matches.
		int_obj := eval_stack_pop(s)
		name_obj := eval_stack_pop(s)
		ai, _, _ := as_number(int_obj)
		list_name: string
		if sv, ok := name_obj.variant.(String_Value); ok do list_name = sv.value
		alloc := story_state_runtime_allocator(s)
		out: Ink_List
		out.items = make(map[List_Item]int, allocator = alloc)
		if def, has := s.compiled_story.list_definitions.by_list[list_name]; has {
			if item_name, found := def.names_by_value[int(ai)]; found {
				out.items[List_Item{origin_name = list_name, item_name = item_name}] = int(ai)
			}
		}
		eval_stack_push(s, new_list_object(out, alloc))

	case .List_Random:
		// Pops a list, picks one item using (storySeed + previousRandom) as
		// .NET Random seed. Output is a single-item list with that pick.
		// Order of iteration must be deterministic and match C# (insertion
		// order in C# Dictionary == sorted by (value, name) for our lists,
		// since the listDef JSON is value-ordered).
		l_obj := eval_stack_pop(s)
		l, ok := list_value_of(l_obj)
		alloc := story_state_runtime_allocator(s)
		out: Ink_List
		out.items = make(map[List_Item]int, allocator = alloc)
		if !ok {
			story_state_error(s, "LIST_RANDOM expects a list")
			return true
		}
		if len(l.items) > 0 {
			rng: Net_Random
			net_random_init(&rng, s.story_seed + s.previous_random)
			next := net_random_next(&rng)
			idx := next % len(l.items)
			sorted := ink_list_sorted_items(l, story_state_runtime_allocator(s))
			pick := sorted[idx]
			out.items[pick] = l.items[pick]
			s.previous_random = next
		}
		eval_stack_push(s, new_list_object(out, alloc))

	case .Turns_Since, .Read_Count:
		// Pop divert target, resolve to container, query visit_counts (READ_COUNT)
		// or turn_indices (TURNS_SINCE). C# returns 0/-1 respectively if the
		// container can't be resolved.
		target_obj := eval_stack_pop(s)
		dt, is_dt := target_obj.variant.(Divert_Target_Value)
		if !is_dt {
			story_state_error(s, fmt.tprintf("%v expected a divert target", cmd))
			return true
		}
		target_pointer := story_pointer_at_path_string(s, dt.target)
		count := 0
		if !pointer_is_null(target_pointer) && target_pointer.container != nil {
			if cmd == .Turns_Since {
				count = story_state_turns_since_for_container(s, target_pointer.container, story_state_runtime_allocator(s))
			} else {
				count = story_state_visit_count_for_container(s, target_pointer.container, story_state_runtime_allocator(s))
			}
		} else {
			count = -1 if cmd == .Turns_Since else 0
		}
		eval_stack_push_int(s, i64(count))

	case .Random:
		// RANDOM(min, max) — inclusive both ends. Seeded by storySeed +
		// previousRandom; previousRandom is set to the .NET Random's nextInt
		// (mirroring upstream so seeded walks stay deterministic).
		max_obj := eval_stack_pop(s)
		min_obj := eval_stack_pop(s)
		max_i, _, _ := as_number(max_obj)
		min_i, _, _ := as_number(min_obj)
		random_range := int(max_i - min_i + 1)
		if random_range <= 0 {
			story_state_error(s, fmt.tprintf("RANDOM(%d, %d): max must be larger than min", min_i, max_i))
			return true
		}
		rng: Net_Random
		net_random_init(&rng, s.story_seed + s.previous_random)
		next := net_random_next(&rng)
		chosen := (next % random_range) + int(min_i)
		eval_stack_push_int(s, i64(chosen))
		s.previous_random = next

	case .Seed_Random:
		seed_obj := eval_stack_pop(s)
		seed_i, _, _ := as_number(seed_obj)
		s.story_seed = int(seed_i)
		s.previous_random = 0
		// SEED_RANDOM is a function; push a void result.
		v := new(Object, story_state_runtime_allocator(s))
		v.variant = Void{}
		eval_stack_push(s, v)

	case .Start_Thread:
		// Marker only — the actual PushThread happens in story_step after
		// the content pointer has incremented past this command.
	}

	return true
}

// Mirrors C# Story.NextSequenceShuffleIndex. Pops `numElements` (top) then
// `seqCount` from the eval stack, computes a deterministic shuffle index
// keyed on (sum of container path chars) + loopIndex + storySeed, and
// returns the iteration's pick. Identical to inkle's reference algorithm,
// so seeded sequences produce the same alternative as dotnet.
@(private)
next_sequence_shuffle_index :: proc(s: ^Story_State) -> i64 {
	num_elements_obj := eval_stack_pop(s)
	num_elements := i64(0)
	if v, ok := num_elements_obj.variant.(Int_Value); ok do num_elements = v.value
	if num_elements <= 0 {
		story_state_error(s, "Sequence_Shuffle_Index: expected positive numElements")
		return 0
	}

	seq_count_obj := eval_stack_pop(s)
	seq_count := i64(0)
	if v, ok := seq_count_obj.variant.(Int_Value); ok do seq_count = v.value

	loop_index      := seq_count / num_elements
	iteration_index := seq_count % num_elements

	cur := story_state_current_pointer(s)
	path_hash: int
	if cur.container != nil {
		p := object_path(cur.container, story_state_runtime_allocator(s))
		defer path_destroy(&p, story_state_runtime_allocator(s))
		ps := path_to_string(p, story_state_runtime_allocator(s))
		defer delete(ps, story_state_runtime_allocator(s))
		for i in 0 ..< len(ps) {
			path_hash += int(ps[i])
		}
	}
	random_seed := path_hash + int(loop_index) + s.story_seed

	rng: Net_Random
	net_random_init(&rng, random_seed)

	// Fisher-Yates-style: maintain an unpicked-indices list, draw with the
	// RNG, swap-remove, take the iteration_index'th one. Allocate the temp
	// list in the runtime arena (cheap) — a few ints per shuffle call.
	unpicked := make([dynamic]int, 0, num_elements, story_state_runtime_allocator(s))
	for i in 0 ..< int(num_elements) do append(&unpicked, i)

	for i in 0 ..= int(iteration_index) {
		chosen := net_random_next(&rng) % len(unpicked)
		chosen_index := unpicked[chosen]
		ordered_remove(&unpicked, chosen)
		if i64(i) == iteration_index {
			return i64(chosen_index)
		}
	}
	return 0
}

// ---- Native function dispatch --------------------------------------------
//
// Pops the right number of args from the eval stack, computes, pushes the
// result. Numeric coercion mirrors C#: if either operand is a float the op
// runs in float; otherwise int.

@(private)
execute_native_function :: proc(s: ^Story_State, name: string) -> bool {
	// 1-arg ops first.
	switch name {
	case "!":
		a := eval_stack_pop(s)
		eval_stack_push_bool(s, !is_truthy(a))
		return true
	case "_": // unary negate (note: "L^" decoded already)
		a := eval_stack_pop(s)
		ai, af, is_f := as_number(a)
		if is_f do eval_stack_push_float(s, -af)
		else    do eval_stack_push_int(s, -ai)
		return true
	case "FLOOR":
		a := eval_stack_pop(s)
		_, af, _ := as_number(a)
		eval_stack_push_int(s, i64(af)) // truncates toward zero; for non-neg this is floor
		return true
	case "CEILING":
		a := eval_stack_pop(s)
		_, af, _ := as_number(a)
		c := i64(af)
		if f64(c) < af do c += 1
		eval_stack_push_int(s, c)
		return true
	case "INT":
		a := eval_stack_pop(s)
		ai, af, is_f := as_number(a)
		if is_f do eval_stack_push_int(s, i64(af))
		else    do eval_stack_push_int(s, ai)
		return true
	case "FLOAT":
		a := eval_stack_pop(s)
		ai, af, is_f := as_number(a)
		if is_f do eval_stack_push_float(s, af)
		else    do eval_stack_push_float(s, f64(ai))
		return true
	case "LIST_COUNT":
		a := eval_stack_pop(s)
		l, ok := list_value_of(a)
		if !ok {
			story_state_error(s, "LIST_COUNT expects a list")
			return true
		}
		eval_stack_push_int(s, i64(len(l.items)))
		return true
	case "LIST_VALUE":
		a := eval_stack_pop(s)
		l, ok := list_value_of(a)
		if !ok {
			story_state_error(s, "LIST_VALUE expects a list")
			return true
		}
		eval_stack_push_int(s, i64(ink_list_single_value(l)))
		return true
	case "LIST_MIN":
		a := eval_stack_pop(s)
		l, ok := list_value_of(a)
		if !ok {
			story_state_error(s, "LIST_MIN expects a list")
			return true
		}
		eval_stack_push(s, new_list_object(ink_list_min_as_list(l, story_state_runtime_allocator(s)), story_state_runtime_allocator(s)))
		return true
	case "LIST_MAX":
		a := eval_stack_pop(s)
		l, ok := list_value_of(a)
		if !ok {
			story_state_error(s, "LIST_MAX expects a list")
			return true
		}
		eval_stack_push(s, new_list_object(ink_list_max_as_list(l, story_state_runtime_allocator(s)), story_state_runtime_allocator(s)))
		return true
	case "LIST_ALL":
		a := eval_stack_pop(s)
		l, ok := list_value_of(a)
		if !ok {
			story_state_error(s, "LIST_ALL expects a list")
			return true
		}
		alloc := story_state_runtime_allocator(s)
		eval_stack_push(s, new_list_object(ink_list_all(l, &s.compiled_story.list_definitions, alloc), alloc))
		return true
	case "LIST_INVERT":
		a := eval_stack_pop(s)
		l, ok := list_value_of(a)
		if !ok {
			story_state_error(s, "LIST_INVERT expects a list")
			return true
		}
		alloc := story_state_runtime_allocator(s)
		eval_stack_push(s, new_list_object(ink_list_invert(l, &s.compiled_story.list_definitions, alloc), alloc))
		return true
	}

	// 2-arg ops.
	b := eval_stack_pop(s)
	a := eval_stack_pop(s)
	if a == nil || b == nil {
		story_state_error(s, fmt.tprintf("native '%s' had insufficient args on eval stack", name))
		return true
	}

	// List+int / list-int: shifts each item's value by ±N within its origin's
	// item-by-value space. Items whose target value isn't a defined item are
	// silently dropped. C# rejects int+list (only list+int) — we match.
	if al, a_is_list := list_value_of(a); a_is_list {
		if (name == "+" || name == "-") {
			if _, b_is_int := b.variant.(Int_Value); b_is_int {
				bi64, _, _ := as_number(b)
				delta := int(bi64)
				if name == "-" do delta = -delta
				eval_stack_push(s, new_list_object(ink_list_shift(al, delta, &s.compiled_story.list_definitions, story_state_runtime_allocator(s)), story_state_runtime_allocator(s)))
				return true
			}
		}
	}

	// List-vs-list operations dispatch first; numeric coercion below would
	// silently turn a list into 0 and yield wrong results.
	if al, a_is_list := list_value_of(a); a_is_list {
		if bl, b_is_list := list_value_of(b); b_is_list {
			alloc := story_state_runtime_allocator(s)
			switch name {
			case "+":  eval_stack_push(s, new_list_object(ink_list_union(al, bl, alloc), alloc)); return true
			case "-":  eval_stack_push(s, new_list_object(ink_list_difference(al, bl, alloc), alloc)); return true
			case "^":  eval_stack_push(s, new_list_object(ink_list_intersect(al, bl, alloc), alloc)); return true
			case "?":  eval_stack_push_bool(s, ink_list_contains_all(al, bl)); return true
			case "!?": eval_stack_push_bool(s, !ink_list_contains_all(al, bl)); return true
			case "==": eval_stack_push_bool(s, ink_lists_equal(al, bl)); return true
			case "!=": eval_stack_push_bool(s, !ink_lists_equal(al, bl)); return true
			case ">":  eval_stack_push_bool(s, ink_list_min_value(al) > ink_list_max_value(bl)); return true
			case "<":  eval_stack_push_bool(s, ink_list_max_value(al) < ink_list_min_value(bl)); return true
			case ">=": eval_stack_push_bool(s, ink_list_min_value(al) >= ink_list_min_value(bl) && ink_list_max_value(al) >= ink_list_max_value(bl)); return true
			case "<=": eval_stack_push_bool(s, ink_list_max_value(al) <= ink_list_max_value(bl) && ink_list_min_value(al) <= ink_list_min_value(bl)); return true
			}
		}
	}

	// String-vs-string concatenation and equality.
	if name == "+" || name == "==" || name == "!=" {
		if as, a_str := a.variant.(String_Value); a_str {
			if bs, b_str := b.variant.(String_Value); b_str {
				switch name {
				case "+":
					sum := strings.concatenate({as.value, bs.value}, story_state_runtime_allocator(s))
					sv := new(Object, story_state_runtime_allocator(s))
					sv.variant = String_Value{value = sum}
					eval_stack_push(s, sv)
				case "==":
					eval_stack_push_bool(s, as.value == bs.value)
				case "!=":
					eval_stack_push_bool(s, as.value != bs.value)
				}
				return true
			}
		}
	}

	ai, af, a_is_f := as_number(a)
	bi, bf, b_is_f := as_number(b)
	use_float := a_is_f || b_is_f

	if use_float {
		// Coerce both to float.
		if !a_is_f do af = f64(ai)
		if !b_is_f do bf = f64(bi)
		switch name {
		case "+": eval_stack_push_float(s, af + bf)
		case "-": eval_stack_push_float(s, af - bf)
		case "*": eval_stack_push_float(s, af * bf)
		case "/":
			if bf == 0 {
				story_state_error(s, "division by zero")
				return true
			}
			eval_stack_push_float(s, af / bf)
		case "%":
			// Odin doesn't allow % on floats directly; use math
			eval_stack_push_float(s, af - bf * f64(i64(af / bf)))
		case "POW": eval_stack_push_float(s, math.pow(af, bf))
		case "==": eval_stack_push_bool(s, af == bf)
		case "!=": eval_stack_push_bool(s, af != bf)
		case ">":  eval_stack_push_bool(s, af >  bf)
		case "<":  eval_stack_push_bool(s, af <  bf)
		case ">=": eval_stack_push_bool(s, af >= bf)
		case "<=": eval_stack_push_bool(s, af <= bf)
		case "&&": eval_stack_push_bool(s, af != 0 && bf != 0)
		case "||": eval_stack_push_bool(s, af != 0 || bf != 0)
		case "MIN": eval_stack_push_float(s, min(af, bf))
		case "MAX": eval_stack_push_float(s, max(af, bf))
		case:
			story_state_error(s, fmt.tprintf("native '%s' not yet implemented (float)", name))
		}
		return true
	}

	// Integer / boolean path.
	switch name {
	case "+": eval_stack_push_int(s, ai + bi)
	case "-": eval_stack_push_int(s, ai - bi)
	case "*": eval_stack_push_int(s, ai * bi)
	case "/":
		if bi == 0 {
			story_state_error(s, "division by zero")
			return true
		}
		eval_stack_push_int(s, ai / bi)
	case "%":
		if bi == 0 {
			story_state_error(s, "modulo by zero")
			return true
		}
		eval_stack_push_int(s, ai % bi)
	case "POW":
		exp := bi
		r := i64(1)
		if exp >= 0 do for _ in 0 ..< exp do r *= ai
		eval_stack_push_int(s, r)
	case "==": eval_stack_push_bool(s, ai == bi)
	case "!=": eval_stack_push_bool(s, ai != bi)
	case ">":  eval_stack_push_bool(s, ai >  bi)
	case "<":  eval_stack_push_bool(s, ai <  bi)
	case ">=": eval_stack_push_bool(s, ai >= bi)
	case "<=": eval_stack_push_bool(s, ai <= bi)
	case "&&": eval_stack_push_bool(s, ai != 0 && bi != 0)
	case "||": eval_stack_push_bool(s, ai != 0 || bi != 0)
	case "MIN": eval_stack_push_int(s, min(ai, bi))
	case "MAX": eval_stack_push_int(s, max(ai, bi))
	case:
		story_state_error(s, fmt.tprintf("native '%s' not yet implemented (int)", name))
	}
	return true
}

// LIST_RANGE bounds: int → that int; list → minItem.Value (for min bound)
// or maxItem.Value (for max bound). Mirrors InkList.ListWithSubRange.
@(private)
list_range_min :: proc(o: ^Object) -> int {
	if o == nil do return 0
	if v, ok := o.variant.(Int_Value); ok do return int(v.value)
	if v, ok := o.variant.(Float_Value); ok do return int(v.value)
	if v, ok := o.variant.(List_Value); ok && len(v.value.items) > 0 do return ink_list_min_value(v.value)
	return 0
}

@(private)
list_range_max :: proc(o: ^Object) -> int {
	if o == nil do return max(int)
	if v, ok := o.variant.(Int_Value); ok do return int(v.value)
	if v, ok := o.variant.(Float_Value); ok do return int(v.value)
	if v, ok := o.variant.(List_Value); ok && len(v.value.items) > 0 do return ink_list_max_value(v.value)
	return max(int)
}

@(private)
list_value_of :: proc(o: ^Object) -> (l: Ink_List, ok: bool) {
	if o == nil do return {}, false
	if lv, is_lv := o.variant.(List_Value); is_lv do return lv.value, true
	return {}, false
}

@(private)
as_number :: proc(o: ^Object) -> (i: i64, f: f64, is_float: bool) {
	if o == nil do return 0, 0, false
	switch v in o.variant {
	case Int_Value:   return v.value, 0, false
	case Float_Value: return 0, v.value, true
	case Bool_Value:  return v.value ? 1 : 0, 0, false
	case String_Value, Container, Divert_Target_Value, Variable_Pointer_Value, List_Value, Glue, Tag, Void, Control_Command, Native_Function_Call, Divert, Choice_Point, Variable_Reference, Variable_Assignment:
		return 0, 0, false
	}
	return 0, 0, false
}

@(private)
eval_stack_push_bool :: proc(s: ^Story_State, b: bool) {
	o := new(Object, story_state_runtime_allocator(s))
	o.variant = Bool_Value{value = b}
	eval_stack_push(s, o)
}

@(private)
eval_stack_push_float :: proc(s: ^Story_State, x: f64) {
	o := new(Object, story_state_runtime_allocator(s))
	o.variant = Float_Value{value = x}
	eval_stack_push(s, o)
}

// ---- Variable refs / assigns ---------------------------------------------

@(private)
execute_variable_reference :: proc(s: ^Story_State, vr: Variable_Reference, here: ^Object) -> bool {
	if len(vr.name) > 0 {
		v := variable_state_get_variable_with_name(&s.variables_state, vr.name)
		if v == nil {
			story_state_error(s, fmt.tprintf("variable '%s' not found", vr.name))
			return true
		}
		eval_stack_push(s, v)
		return true
	}

	// Read-count reference. The compiled path may be relative (e.g.
	// ".^.^.^.putmein"); resolve it to the absolute container path first,
	// then look up visit_counts. Mirrors C# VariableReference.containerForCount
	// + state.VisitCountForContainer.
	target := story_pointer_at_path_string(s, vr.path_for_count, here)
	count := 0
	if !pointer_is_null(target) && target.container != nil {
		count = story_state_visit_count_at_path_string_for_container(s, target.container)
	}
	eval_stack_push_int(s, i64(count))
	return true
}

@(private)
execute_variable_assignment :: proc(s: ^Story_State, va: Variable_Assignment) -> bool {
	value := eval_stack_pop(s)
	if value == nil {
		story_state_error(s, fmt.tprintf("variable assignment '%s' had nothing on eval stack", va.name))
		return true
	}
	variable_state_assign(&s.variables_state, va, value, story_state_runtime_allocator(s))
	return true
}

// ---- Choice processing ---------------------------------------------------

@(private)
process_choice :: proc(s: ^Story_State, cp: Choice_Point, here: ^Object) -> (Choice, bool) {
	show := true

	if .Has_Condition in cp.flags {
		cond := eval_stack_pop(s)
		if !is_truthy(cond) do show = false
	}

	choice_only_text: string
	start_text: string
	tags: []string

	if .Has_Choice_Only_Content in cp.flags {
		choice_only_text, tags = pop_choice_string_and_tags(s, tags)
	}
	if .Has_Start_Content in cp.flags {
		start_text, tags = pop_choice_string_and_tags(s, tags)
	}

	if .Once_Only in cp.flags {
		// Resolve the target container and check visit count.
		target_ptr := story_pointer_at_path_string(s, cp.path_on_choice, here)
		if !pointer_is_null(target_ptr) && target_ptr.container != nil {
			cnt := story_state_visit_count_at_path_string_for_container(s, target_ptr.container)
			when DEBUG_TRACE {
				fmt.eprintfln("once-only check: target=%v cnt=%d", cp.path_on_choice, cnt)
			}
			if cnt > 0 do show = false
		}
	}

	if !show do return Choice{}, false

	// Concat start + choice-only into the visible text, trim leading/trailing
	// spaces and tabs (matches C# Trim(' ', '\t')).
	combined := strings.concatenate({start_text, choice_only_text}, story_state_runtime_allocator(s))
	text := strings.trim(combined, " \t")

	// Fork the active thread so we can restore exactly this moment when the
	// player picks this choice. Clones callstack frames + temp variables;
	// the forked copy lives on the Choice until that choice is destroyed.
	forked := call_stack_fork_thread(&s.call_stack)
	thread_idx := forked.thread_index

	// Source path: absolute path to the choice point itself.
	src_path := ""
	if here != nil {
		p := object_path(here, story_state_runtime_allocator(s))
		src_path = path_to_string(p, story_state_runtime_allocator(s))
	}

	// Target path: convert the (possibly relative) cp.path_on_choice into
	// the absolute path of the target container. ChoosePathString needs an
	// absolute path so this conversion happens here at choice creation time
	// (mirroring C# ChoicePoint.pathOnChoice's lazy relative->global rewrite).
	target_path_abs := cp.path_on_choice
	target_ptr := story_pointer_at_path_string(s, cp.path_on_choice, here)
	if !pointer_is_null(target_ptr) && target_ptr.container != nil {
		tp := object_path(target_ptr.container, story_state_runtime_allocator(s))
		target_path_abs = path_to_string(tp, story_state_runtime_allocator(s))
	}

	return Choice{
		text                  = text,
		// upstream's runtime never assigns choice.index — it stays at the
		// default 0 throughout. Used only when reading saved state, where
		// it round-trips. Leave at 0 for byte-equivalent JSON output.
		index                 = 0,
		source_path           = src_path,
		target_path           = target_path_abs,
		original_thread_index = thread_idx,
		thread_at_generation  = forked,
		tags                  = tags,
		is_invisible_default  = .Is_Invisible_Default in cp.flags,
	}, true
}

@(private)
pop_choice_string_and_tags :: proc(s: ^Story_State, existing: []string) -> (string, []string) {
	val := eval_stack_pop(s)
	str_text := ""
	if sv, is_str := val.variant.(String_Value); is_str {
		str_text = sv.value
	}

	// Collect any preceding Tag objects, in the order they were pushed.
	tags := existing
	for len(s.eval_stack) > 0 {
		top := s.eval_stack[len(s.eval_stack) - 1]
		t, is_tag := top.variant.(Tag)
		if !is_tag do break
		eval_stack_pop(s)
		// Insert at the front so we preserve push order.
		new_tags := make([]string, len(tags) + 1, story_state_runtime_allocator(s))
		new_tags[0] = t.text
		for i in 0 ..< len(tags) {
			new_tags[i + 1] = tags[i]
		}
		tags = new_tags
	}
	return str_text, tags
}

// ---- Pointer stepping ----------------------------------------------------

@(private)
next_content :: proc(s: ^Story_State) {
	// previousPointer tracks where we were so visit-count-on-divert can
	// detect what new containers we've entered.
	story_state_set_previous_pointer(s, story_state_current_pointer(s))

	if !pointer_is_null(s.diverted_pointer) {
		story_state_set_current_pointer(s, s.diverted_pointer)
		s.diverted_pointer = POINTER_NULL
		visit_changed_containers_due_to_divert(s)
		if !pointer_is_null(story_state_current_pointer(s)) do return
	}

	if !increment_content_pointer(s) {
		// Out of content. Auto-pop a function; otherwise the story ends.
		if call_stack_can_pop(&s.call_stack, .Function) {
			call_stack_pop(&s.call_stack, .Function)
			cur := call_stack_current_element(&s.call_stack)
			if cur != nil && cur.in_expression_evaluation {
				v := new(Object, story_state_runtime_allocator(s))
				v.variant = Void{}
				eval_stack_push(s, v)
			}
			if !pointer_is_null(story_state_current_pointer(s)) do next_content(s)
		} else if call_stack_can_pop_thread(&s.call_stack) {
			call_stack_pop_thread(&s.call_stack)
			// Recurse: parent's pointer is now at whatever it was when the
			// thread was pushed (typically a divert that "spawned" the thread).
			// Step past it so the parent doesn't re-execute the spawn.
			if !pointer_is_null(story_state_current_pointer(s)) do next_content(s)
		}
	}
}

@(private)
increment_content_pointer :: proc(s: ^Story_State) -> bool {
	cur := call_stack_current_element(&s.call_stack)
	if cur == nil do return false
	pointer := cur.current_pointer
	pointer.index += 1

	for pointer.container != nil {
		c, is_c := pointer.container.variant.(Container)
		if !is_c do break
		if pointer.index < len(c.content) do break

		// Fell off the end of this container; step out into parent's content.
		ancestor := pointer.container.parent
		if ancestor == nil do break
		pa, is_pc := ancestor.variant.(Container)
		if !is_pc do break
		idx := -1
		for child, i in pa.content {
			if child == pointer.container {
				idx = i
				break
			}
		}
		if idx < 0 do break
		pointer = Pointer{container = ancestor, index = idx + 1}
	}

	if pointer.container != nil {
		c, is_c := pointer.container.variant.(Container)
		if is_c && pointer.index >= len(c.content) {
			pointer = POINTER_NULL
		}
	}

	cur.current_pointer = pointer
	return !pointer_is_null(pointer)
}

// After a divert lands us in a new location, walk up the new pointer's
// ancestry. Any container that wasn't in the previous ancestry counts as
// newly-entered and gets a visit. Mirrors C# VisitChangedContainersDueToDivert.
@(private)
visit_changed_containers_due_to_divert :: proc(s: ^Story_State) {
	prev := story_state_previous_pointer(s)
	cur := story_state_current_pointer(s)

	if pointer_is_null(cur) || cur.index == -1 do return

	// Set of containers active before the divert (walk up from prev).
	prev_set := make(map[^Object]bool, 8, story_state_runtime_allocator(s))
	if !pointer_is_null(prev) {
		anchor := pointer_resolve(prev)
		if anchor == nil do anchor = prev.container
		walk := anchor
		for walk != nil {
			if _, is_c := walk.variant.(Container); is_c do prev_set[walk] = true
			walk = walk.parent
		}
	}

	// Walk up from the new position, visiting any containers NOT in prev_set
	// (or that count-at-start-only, since those need a fresh visit on each
	// entry-from-start regardless).
	current_child := pointer_resolve(cur)
	if current_child == nil do return

	parent_container := current_child.parent
	all_children_entered_at_start := true

	for parent_container != nil {
		pc, is_c := parent_container.variant.(Container)
		if !is_c do break

		_, in_prev := prev_set[parent_container]
		if in_prev && !(.Count_Start_Only in pc.flags) do break

		entering_at_start := len(pc.content) > 0 && pc.content[0] == current_child && all_children_entered_at_start
		if !entering_at_start do all_children_entered_at_start = false

		visit_container(s, parent_container, entering_at_start)

		current_child = parent_container
		parent_container = parent_container.parent
	}
}

@(private)
visit_container :: proc(s: ^Story_State, container_obj: ^Object, at_start: bool) {
	c, ok := container_obj.variant.(Container)
	if !ok do return
	if .Count_Start_Only in c.flags && !at_start do return

	when DEBUG_TRACE {
		p := object_path(container_obj, story_state_runtime_allocator(s))
		ps := path_to_string(p, story_state_runtime_allocator(s))
		fmt.eprintfln("visit_container: %v flags=%v at_start=%v", ps, c.flags, at_start)
	}

	if .Visits in c.flags {
		story_state_increment_visit_count_for_container(s, container_obj, story_state_runtime_allocator(s))
	}
	if .Turns in c.flags {
		story_state_record_turn_index_visit_to_container(s, container_obj, story_state_runtime_allocator(s))
	}
}

// ---- Path resolution ------------------------------------------------------

// Resolve a path string to a Pointer. Absolute paths walk from the story
// root; relative paths (those that path_parse marks is_relative) walk from
// `from`. Pass `from = nil` (or rely on the path being absolute) for
// from-root resolution.
//
// Pointer index conventions (matching C# Story.PointerAtPath):
//   - Path's last component is a NAME  -> (foundContainer, -1)
//     so Pointer.Resolve returns the container itself; Step's descend
//     loop will then visit it as it walks in.
//   - Path's last component is an INDEX -> (parentContainer, index)
//     a position inside the parent's content list.
@(private)
story_pointer_at_path_string :: proc(s: ^Story_State, path_str: string, from: ^Object = nil) -> Pointer {
	if len(path_str) == 0 do return POINTER_NULL
	p := path_parse(path_str, story_state_runtime_allocator(s))

	last, has_last := path_last_component(p)
	last_is_index := has_last && path_component_is_index(last)

	r: Search_Result
	if p.is_relative && from != nil {
		r = object_resolve_path(from, p)
	} else {
		r = container_content_at_path(s.compiled_story.root, p)
	}
	if r.obj == nil do return POINTER_NULL

	if last_is_index {
		// The last component pointed to an indexed slot. result.obj IS that
		// slot's content; back up to its parent and use the explicit index.
		parent := r.obj.parent
		if parent == nil do return POINTER_NULL
		if _, is_pc := parent.variant.(Container); !is_pc do return POINTER_NULL
		return Pointer{container = parent, index = last.index}
	}

	// Path ended on a name (or path was empty / just "."). result.obj is the
	// named container itself; use index = -1 so Step's descend visits it.
	if _, is_c := r.obj.variant.(Container); is_c {
		return Pointer{container = r.obj, index = -1}
	}
	// Non-container final result with non-index path — fall through to
	// addressing via parent.
	parent := r.obj.parent
	if parent == nil do return POINTER_NULL
	if _, is_pc := parent.variant.(Container); !is_pc do return POINTER_NULL
	for child, i in (&parent.variant.(Container)).content {
		if child == r.obj do return Pointer{container = parent, index = i}
	}
	return POINTER_NULL
}

// ---- Eval stack helpers --------------------------------------------------

@(private)
eval_stack_push :: proc(s: ^Story_State, obj: ^Object) {
	if obj == nil do return
	append(&s.eval_stack, obj)
}

@(private)
eval_stack_pop :: proc(s: ^Story_State) -> ^Object {
	if len(s.eval_stack) == 0 do return nil
	v := s.eval_stack[len(s.eval_stack) - 1]
	resize(&s.eval_stack, len(s.eval_stack) - 1)
	return v
}

@(private)
eval_stack_push_int :: proc(s: ^Story_State, n: i64) {
	o := new(Object, story_state_runtime_allocator(s))
	o.variant = Int_Value{value = n}
	eval_stack_push(s, o)
}

// ---- Choose path / force end ---------------------------------------------

@(private)
story_choose_path_string :: proc(s: ^Story_State, path_str: string, increment_turn: bool) {
	if increment_turn do s.current_turn_index += 1
	for &c in s.current_choices do choice_destroy(&c)
	clear(&s.current_choices)
	target := story_pointer_at_path_string(s, path_str)
	if pointer_is_null(target) {
		story_state_error(s, fmt.tprintf("choose-path target not found: %s", path_str))
		return
	}
	// Convert (container, -1) returned for name-final paths into (container, 0)
	// to match C# SetChosenPath's "if newPointer.index == -1 then 0" rule.
	if target.index == -1 do target.index = 0
	story_state_set_current_pointer(s, target)
	// Don't clear previous_pointer — preserve whatever the (forked) thread
	// recorded so visit-on-divert and serialization see the right context.
	visit_changed_containers_due_to_divert(s)
}

// Run the "global decl" container if the compiled story has one, then snapshot
// the resulting globals as defaults. Mirrors C# Story.ResetGlobals(). Must be
// called once after story_state_init before normal play begins, so that any
// VariableReference to a declared global resolves.
story_reset_globals :: proc(s: ^Story_State) {
	root, root_is_c := s.compiled_story.root.variant.(Container)
	if !root_is_c do return
	if _, has_globals := root.named_only_content["global decl"]; has_globals {
		original := story_state_current_pointer(s)
		story_choose_path_string(s, "global decl", increment_turn = false)
		// Run until done (the global decl container ends with Done).
		step_count := 0
		for story_state_can_continue(s) {
			step_count += 1
			if step_count > 100_000 {
				story_state_error(s, "story_reset_globals: step count exceeded sanity cap")
				break
			}
			story_step(s)
			if story_state_has_error(s) do break
		}
		story_state_set_current_pointer(s, original)
	}
	variable_state_snapshot_default_globals(&s.variables_state)
}

@(private)
story_force_end :: proc(s: ^Story_State) {
	call_stack_reset(&s.call_stack)
	s.diverted_pointer = POINTER_NULL
	story_state_set_current_pointer(s, POINTER_NULL)
}

// ---- Misc helpers --------------------------------------------------------

@(private)
set_in_expression_evaluation :: proc(s: ^Story_State, on: bool) {
	cur := call_stack_current_element(&s.call_stack)
	if cur == nil do return
	cur.in_expression_evaluation = on
}

@(private)
is_truthy :: proc(obj: ^Object) -> bool {
	if obj == nil do return false
	switch v in obj.variant {
	case Int_Value:    return v.value != 0
	case Float_Value:  return v.value != 0
	case Bool_Value:   return v.value
	case String_Value: return len(v.value) > 0
	case List_Value:   return len(v.value.items) > 0
	case Divert_Target_Value:
		// Per upstream, using a divert target as a condition is an error.
		return false
	case Variable_Pointer_Value, Container, Divert, Choice_Point, Variable_Reference, Variable_Assignment, Tag, Glue, Void, Control_Command, Native_Function_Call:
		return false
	}
	return false
}

@(private)
value_to_string :: proc(obj: ^Object, allocator := context.allocator) -> string {
	if obj == nil do return ""
	switch v in obj.variant {
	case Int_Value:    return fmt.aprintf("%d", v.value, allocator = allocator)
	case Float_Value:  return fmt.aprintf("%g", v.value, allocator = allocator)
	case Bool_Value:   return v.value ? "true" : "false"
	case String_Value: return v.value
	case Divert_Target_Value: return v.target
	case List_Value: return ink_list_to_string(v.value, allocator)
	case Variable_Pointer_Value, Container, Divert, Choice_Point, Variable_Reference, Variable_Assignment, Tag, Glue, Void, Control_Command, Native_Function_Call:
		return ""
	}
	return ""
}
