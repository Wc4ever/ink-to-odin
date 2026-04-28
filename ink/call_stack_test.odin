package ink

import "core:mem/virtual"
import "core:testing"

// Most call-stack tests don't actually need a real story — a single Container
// suffices as the "root" for the start-of-root pointer. Temp-var values are
// likewise stand-ins that we just compare by pointer identity.

@(private = "file")
setup_arena :: proc(t: ^testing.T) -> virtual.Arena {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	return arena
}

@(private = "file")
mk_root :: proc() -> ^Object {
	o := new(Object)
	o.variant = Container{}
	return o
}

@(private = "file")
mk_value :: proc(n: i64) -> ^Object {
	o := new(Object)
	o.variant = Int_Value{value = n}
	return o
}

@(test)
test_call_stack_init_depth :: proc(t: ^testing.T) {
	arena := setup_arena(t)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	root := mk_root()
	s: Call_Stack
	call_stack_init(&s, root)
	defer call_stack_destroy(&s)

	testing.expect_value(t, call_stack_depth(&s), 1)
	testing.expect_value(t, call_stack_current_element_index(&s), 0)
	testing.expect_value(t, len(s.threads), 1)

	cur := call_stack_current_element(&s)
	testing.expect(t, cur != nil, "have a current element")
	testing.expect_value(t, cur.type, Push_Pop_Type.Tunnel)
	testing.expect_value(t, cur.current_pointer.container, root)
	testing.expect_value(t, cur.current_pointer.index, 0)
}

@(test)
test_call_stack_push_pop :: proc(t: ^testing.T) {
	arena := setup_arena(t)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	root := mk_root()
	s: Call_Stack
	call_stack_init(&s, root)
	defer call_stack_destroy(&s)

	// Push a function frame.
	call_stack_push(&s, .Function)
	testing.expect_value(t, call_stack_depth(&s), 2)
	testing.expect_value(t, call_stack_current_element(&s).type, Push_Pop_Type.Function)

	// Type-mismatched pop should refuse.
	testing.expect(t, !call_stack_pop(&s, .Tunnel), "pop with wrong type fails")
	testing.expect_value(t, call_stack_depth(&s), 2)

	// Correct type pops.
	testing.expect(t, call_stack_pop(&s, .Function), "pop with right type succeeds")
	testing.expect_value(t, call_stack_depth(&s), 1)

	// Can't pop the bottom Tunnel frame.
	testing.expect(t, !call_stack_can_pop(&s), "can't pop final frame")
	testing.expect(t, !call_stack_pop(&s), "pop fails at depth 1")
}

@(test)
test_call_stack_temp_variables :: proc(t: ^testing.T) {
	arena := setup_arena(t)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	root := mk_root()
	s: Call_Stack
	call_stack_init(&s, root)
	defer call_stack_destroy(&s)

	v1 := mk_value(42)
	v2 := mk_value(7)

	// Declare a new temp in the current (only) frame.
	testing.expect(t, call_stack_set_temporary_variable(&s, "x", v1, declare_new = true), "declare ok")
	testing.expect_value(t, call_stack_get_temporary_variable(&s, "x"), v1)

	// Reassigning an existing temp without declare_new must succeed.
	testing.expect(t, call_stack_set_temporary_variable(&s, "x", v2, declare_new = false), "reassign ok")
	testing.expect_value(t, call_stack_get_temporary_variable(&s, "x"), v2)

	// Reassigning an UNKNOWN temp without declare_new must fail.
	testing.expect(t, !call_stack_set_temporary_variable(&s, "y", v1, declare_new = false), "undeclared reassign fails")
	testing.expect(t, call_stack_get_temporary_variable(&s, "y") == nil, "y still nil")

	// context_for_variable_named: present -> 1, missing -> 0 (global).
	testing.expect_value(t, call_stack_context_for_variable_named(&s, "x"), 1)
	testing.expect_value(t, call_stack_context_for_variable_named(&s, "missing"), 0)
}

@(test)
test_call_stack_temp_variables_scope :: proc(t: ^testing.T) {
	arena := setup_arena(t)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	root := mk_root()
	s: Call_Stack
	call_stack_init(&s, root)
	defer call_stack_destroy(&s)

	outer_x := mk_value(1)
	inner_x := mk_value(2)

	// Set x in outer frame.
	call_stack_set_temporary_variable(&s, "x", outer_x, declare_new = true)
	testing.expect_value(t, call_stack_get_temporary_variable(&s, "x"), outer_x)

	// Push inner frame. New frame doesn't see outer x without context_index.
	call_stack_push(&s, .Function)
	testing.expect(t, call_stack_get_temporary_variable(&s, "x") == nil, "inner frame fresh")

	// Declare x in inner frame.
	call_stack_set_temporary_variable(&s, "x", inner_x, declare_new = true)
	testing.expect_value(t, call_stack_get_temporary_variable(&s, "x"), inner_x)

	// Reach into outer frame by 1-based context_index = 1.
	testing.expect_value(t, call_stack_get_temporary_variable(&s, "x", context_index = 1), outer_x)

	// Pop inner frame; x should be outer's value again.
	call_stack_pop(&s, .Function)
	testing.expect_value(t, call_stack_get_temporary_variable(&s, "x"), outer_x)
}

@(test)
test_call_stack_threads :: proc(t: ^testing.T) {
	arena := setup_arena(t)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	root := mk_root()
	s: Call_Stack
	call_stack_init(&s, root)
	defer call_stack_destroy(&s)

	v_outer := mk_value(10)
	call_stack_set_temporary_variable(&s, "shared", v_outer, declare_new = true)

	// Pushing a thread copies the current thread's frames + temps.
	testing.expect(t, !call_stack_can_pop_thread(&s), "single thread can't pop thread")
	call_stack_push_thread(&s)
	testing.expect_value(t, len(s.threads), 2)
	testing.expect_value(t, s.thread_counter, 1)
	testing.expect_value(t, call_stack_current_thread(&s).thread_index, 1)

	// Inside the new thread, the copied "shared" var is visible.
	testing.expect_value(t, call_stack_get_temporary_variable(&s, "shared"), v_outer)

	// Mutating the new thread's "shared" must not affect the original.
	v_new := mk_value(99)
	call_stack_set_temporary_variable(&s, "shared", v_new, declare_new = false)
	testing.expect_value(t, call_stack_get_temporary_variable(&s, "shared"), v_new)

	// Pop the new thread; we're back to the original frame & value.
	testing.expect(t, call_stack_can_pop_thread(&s), "two threads -> can pop")
	testing.expect(t, call_stack_pop_thread(&s), "pop_thread succeeds")
	testing.expect_value(t, len(s.threads), 1)
	testing.expect_value(t, call_stack_get_temporary_variable(&s, "shared"), v_outer)
}

@(test)
test_call_stack_copy_independence :: proc(t: ^testing.T) {
	arena := setup_arena(t)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	root := mk_root()
	s: Call_Stack
	call_stack_init(&s, root)
	defer call_stack_destroy(&s)

	v1 := mk_value(1)
	call_stack_set_temporary_variable(&s, "x", v1, declare_new = true)
	call_stack_push(&s, .Function)
	v2 := mk_value(2)
	call_stack_set_temporary_variable(&s, "y", v2, declare_new = true)

	clone := call_stack_copy(&s)
	defer call_stack_destroy(&clone)

	// Mutate the original in ways that must NOT propagate to the clone.
	v1_new := mk_value(101)
	call_stack_set_temporary_variable(&s, "x", v1_new, declare_new = false, context_index = 1)
	call_stack_pop(&s, .Function)

	// Clone still has the inner frame and the original "x" binding.
	testing.expect_value(t, call_stack_depth(&clone), 2)
	testing.expect_value(t, call_stack_get_temporary_variable(&clone, "y"), v2)
	testing.expect_value(t, call_stack_get_temporary_variable(&clone, "x", context_index = 1), v1)
}

@(test)
test_call_stack_reset :: proc(t: ^testing.T) {
	arena := setup_arena(t)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	root := mk_root()
	s: Call_Stack
	call_stack_init(&s, root)
	defer call_stack_destroy(&s)

	call_stack_push(&s, .Function)
	call_stack_push_thread(&s)
	testing.expect_value(t, len(s.threads), 2)
	testing.expect_value(t, call_stack_depth(&s), 2)

	call_stack_reset(&s)
	testing.expect_value(t, len(s.threads), 1)
	testing.expect_value(t, call_stack_depth(&s), 1)
	// thread_counter is preserved across reset (matches upstream Reset()).
	testing.expect_value(t, s.thread_counter, 1)
}
