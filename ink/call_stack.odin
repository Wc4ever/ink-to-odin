package ink

// CallStack: nested function/tunnel frames + threads.
//
// Ownership:
//   Call_Stack       owns []Call_Stack_Thread
//   Call_Stack_Thread owns []Call_Stack_Element
//   Call_Stack_Element owns map[string]^Object  (temp variable bindings)
//
// The ^Object values stored in temp_variables are NOT owned by the call stack.
// They reference values from the compiled story arena (for constants) or
// from a separate runtime-value arena (for evaluator-produced values). The
// call stack's destroy procs only delete maps/slices, never the Object refs.
//
// Mirrors ink-engine-runtime/CallStack.cs.

Call_Stack_Element :: struct {
	current_pointer:                       Pointer,
	in_expression_evaluation:              bool,
	type:                                  Push_Pop_Type,
	temporary_variables:                   map[string]^Object,

	// Used when a function is invoked from game-side evaluation: records
	// where the eval stack stood so we can detect a return value.
	evaluation_stack_height_when_pushed:   int,

	// Output-stream index at the moment the function was pushed; used by
	// the runtime to trim whitespace bracketing function output.
	function_start_in_output_stream:       int,
}

Call_Stack_Thread :: struct {
	callstack:        [dynamic]Call_Stack_Element,
	thread_index:     int,
	previous_pointer: Pointer,
}

Call_Stack :: struct {
	threads:        [dynamic]Call_Stack_Thread,
	thread_counter: int,
	start_of_root:  Pointer,
}

// ---- Lifecycle ------------------------------------------------------------

call_stack_init :: proc(s: ^Call_Stack, root_container: ^Object) {
	s.start_of_root = pointer_start_of(root_container)
	s.threads = make([dynamic]Call_Stack_Thread, 0, 1)
	call_stack_reset(s)
}

call_stack_destroy :: proc(s: ^Call_Stack) {
	for &thread in s.threads {
		call_stack_thread_destroy(&thread)
	}
	delete(s.threads)
	s.threads = nil
	s.thread_counter = 0
	s.start_of_root = POINTER_NULL
}

call_stack_thread_destroy :: proc(t: ^Call_Stack_Thread) {
	for &el in t.callstack {
		delete(el.temporary_variables)
		el.temporary_variables = nil
	}
	delete(t.callstack)
	t.callstack = nil
}

// Resets to a single thread with a single Tunnel-typed frame at the start
// of the story root. Mirrors C# CallStack.Reset() — note that the upstream
// Reset preserves threadCounter, so re-init from a non-zero state still
// monotonically increments thread indices when subsequent forks happen.
call_stack_reset :: proc(s: ^Call_Stack) {
	for &thread in s.threads {
		call_stack_thread_destroy(&thread)
	}
	clear(&s.threads)
	// thread_counter intentionally NOT reset — matches upstream behaviour.

	thread := Call_Stack_Thread {
		callstack    = make([dynamic]Call_Stack_Element, 0, 4),
		thread_index = 0,
	}
	append(&thread.callstack, Call_Stack_Element{
		type                = .Tunnel,
		current_pointer     = s.start_of_root,
		temporary_variables = make(map[string]^Object),
	})
	append(&s.threads, thread)
}

// Deep copy: independent threads, elements, and temp-variable maps. ^Object
// values are shared (same convention as C# CallStack(CallStack toCopy)).
call_stack_copy :: proc(src: ^Call_Stack) -> Call_Stack {
	dst := Call_Stack {
		threads        = make([dynamic]Call_Stack_Thread, 0, len(src.threads)),
		thread_counter = src.thread_counter,
		start_of_root  = src.start_of_root,
	}
	for &thread in src.threads {
		append(&dst.threads, call_stack_thread_copy(&thread))
	}
	return dst
}

call_stack_thread_copy :: proc(t: ^Call_Stack_Thread) -> Call_Stack_Thread {
	dst := Call_Stack_Thread {
		callstack        = make([dynamic]Call_Stack_Element, 0, len(t.callstack)),
		thread_index     = t.thread_index,
		previous_pointer = t.previous_pointer,
	}
	for &el in t.callstack {
		copy_el := el
		copy_el.temporary_variables = make(map[string]^Object, len(el.temporary_variables))
		for k, v in el.temporary_variables {
			copy_el.temporary_variables[k] = v
		}
		append(&dst.callstack, copy_el)
	}
	return dst
}

// ---- Accessors ------------------------------------------------------------

// Pointer to the topmost element of the current thread. Caller must not
// trigger a push/pop while holding this pointer (the underlying [dynamic]
// may reallocate).
call_stack_current_element :: proc(s: ^Call_Stack) -> ^Call_Stack_Element {
	t := call_stack_current_thread(s)
	if t == nil || len(t.callstack) == 0 do return nil
	return &t.callstack[len(t.callstack) - 1]
}

// 0-based index of the topmost element in the current thread's callstack.
// (Note: C#'s contextIndex parameters are 1-based; this proc returns the
// 0-based version. Callers that need the C#-shaped value add 1.)
call_stack_current_element_index :: proc(s: ^Call_Stack) -> int {
	t := call_stack_current_thread(s)
	if t == nil do return -1
	return len(t.callstack) - 1
}

call_stack_current_thread :: proc(s: ^Call_Stack) -> ^Call_Stack_Thread {
	if len(s.threads) == 0 do return nil
	return &s.threads[len(s.threads) - 1]
}

call_stack_depth :: proc(s: ^Call_Stack) -> int {
	t := call_stack_current_thread(s)
	if t == nil do return 0
	return len(t.callstack)
}

call_stack_can_pop :: proc(s: ^Call_Stack, expected_type: Maybe(Push_Pop_Type) = nil) -> bool {
	t := call_stack_current_thread(s)
	if t == nil || len(t.callstack) <= 1 do return false
	if expected, ok := expected_type.?; ok {
		return t.callstack[len(t.callstack) - 1].type == expected
	}
	return true
}

call_stack_can_pop_thread :: proc(s: ^Call_Stack) -> bool {
	if len(s.threads) <= 1 do return false
	return !call_stack_element_is_evaluate_from_game(s)
}

call_stack_element_is_evaluate_from_game :: proc(s: ^Call_Stack) -> bool {
	el := call_stack_current_element(s)
	if el == nil do return false
	return el.type == .Function_Evaluation_From_Game
}

call_stack_thread_with_index :: proc(s: ^Call_Stack, index: int) -> ^Call_Stack_Thread {
	for &t in s.threads {
		if t.thread_index == index do return &t
	}
	return nil
}

// ---- Push / pop -----------------------------------------------------------

call_stack_push :: proc(s: ^Call_Stack, type: Push_Pop_Type, external_eval_stack_height: int = 0, output_stream_length_with_pushed: int = 0) {
	t := call_stack_current_thread(s)
	if t == nil do return

	current := t.callstack[len(t.callstack) - 1]
	new_el := Call_Stack_Element {
		type                                = type,
		current_pointer                     = current.current_pointer,
		in_expression_evaluation            = false,
		temporary_variables                 = make(map[string]^Object),
		evaluation_stack_height_when_pushed = external_eval_stack_height,
		function_start_in_output_stream     = output_stream_length_with_pushed,
	}
	append(&t.callstack, new_el)
}

call_stack_pop :: proc(s: ^Call_Stack, expected_type: Maybe(Push_Pop_Type) = nil) -> bool {
	if !call_stack_can_pop(s, expected_type) do return false
	t := call_stack_current_thread(s)
	last := &t.callstack[len(t.callstack) - 1]
	delete(last.temporary_variables)
	pop(&t.callstack)
	return true
}

call_stack_push_thread :: proc(s: ^Call_Stack) {
	cur := call_stack_current_thread(s)
	if cur == nil do return
	new_thread := call_stack_thread_copy(cur)
	s.thread_counter += 1
	new_thread.thread_index = s.thread_counter
	append(&s.threads, new_thread)
}

call_stack_fork_thread :: proc(s: ^Call_Stack) -> Call_Stack_Thread {
	cur := call_stack_current_thread(s)
	forked := call_stack_thread_copy(cur)
	s.thread_counter += 1
	forked.thread_index = s.thread_counter
	return forked
}

// Replace the active threads list with a single thread (deep-copy of the
// argument). Mirrors C# CallStack.currentThread setter, used by ChooseChoiceIndex
// to restore the thread state captured at choice generation.
call_stack_set_current_thread :: proc(s: ^Call_Stack, thread: ^Call_Stack_Thread) {
	for &t in s.threads do call_stack_thread_destroy(&t)
	clear(&s.threads)
	append(&s.threads, call_stack_thread_copy(thread))
}

call_stack_pop_thread :: proc(s: ^Call_Stack) -> bool {
	if !call_stack_can_pop_thread(s) do return false
	last := &s.threads[len(s.threads) - 1]
	call_stack_thread_destroy(last)
	pop(&s.threads)
	return true
}

// ---- Temp variables -------------------------------------------------------
//
// context_index conventions:
//   0    -> globals (handled by Variable_State, NOT here)
//   1..n -> 1-based index into the current thread's callstack
//   -1   -> sentinel meaning "current frame", resolved internally
//
// Matches C#'s contextIndex semantics.

call_stack_get_temporary_variable :: proc(s: ^Call_Stack, name: string, context_index: int = -1) -> ^Object {
	idx := context_index
	if idx == -1 do idx = call_stack_current_element_index(s) + 1
	t := call_stack_current_thread(s)
	if t == nil || idx <= 0 || idx > len(t.callstack) do return nil
	el := &t.callstack[idx - 1]
	if v, ok := el.temporary_variables[name]; ok do return v
	return nil
}

// Returns false if declare_new is false and the variable doesn't already exist.
call_stack_set_temporary_variable :: proc(s: ^Call_Stack, name: string, value: ^Object, declare_new: bool, context_index: int = -1) -> bool {
	idx := context_index
	if idx == -1 do idx = call_stack_current_element_index(s) + 1
	t := call_stack_current_thread(s)
	if t == nil || idx <= 0 || idx > len(t.callstack) do return false
	el := &t.callstack[idx - 1]
	if !declare_new {
		if _, exists := el.temporary_variables[name]; !exists do return false
	}
	el.temporary_variables[name] = value
	return true
}

// Returns 0 for globals or 1-based current-frame index for temps.
// Mirrors C# CallStack.ContextForVariableNamed.
call_stack_context_for_variable_named :: proc(s: ^Call_Stack, name: string) -> int {
	el := call_stack_current_element(s)
	if el == nil do return 0
	if _, ok := el.temporary_variables[name]; ok {
		return call_stack_current_element_index(s) + 1
	}
	return 0
}
