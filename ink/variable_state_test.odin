package ink

import "core:mem/virtual"
import "core:testing"

// Test fixtures: an arena-backed mini-runtime with a call_stack and
// variable_state ready to use. Everything is freed by destroying the arena.

@(private = "file")
mk_int_val :: proc(n: i64) -> ^Object {
	o := new(Object)
	o.variant = Int_Value{value = n}
	return o
}

@(private = "file")
mk_bool_val :: proc(b: bool) -> ^Object {
	o := new(Object)
	o.variant = Bool_Value{value = b}
	return o
}

@(private = "file")
mk_var_ptr_val :: proc(name: string, ctx_idx: int) -> ^Object {
	o := new(Object)
	o.variant = Variable_Pointer_Value{name = name, context_index = ctx_idx}
	return o
}

@(private = "file")
mk_dummy_root :: proc() -> ^Object {
	o := new(Object)
	o.variant = Container{}
	return o
}

@(test)
test_variable_state_globals_basic :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	cs: Call_Stack
	call_stack_init(&cs, mk_dummy_root())
	defer call_stack_destroy(&cs)

	vs: Variable_State
	variable_state_init(&vs, &cs)
	defer variable_state_destroy(&vs)

	// Simulate global decl: declare via assign, then snapshot defaults.
	v_init := mk_int_val(0)
	variable_state_assign(&vs, Variable_Assignment{name = "forceful", is_new_decl = true, is_global = true}, v_init)
	variable_state_snapshot_default_globals(&vs)

	// Read back: returns the declared value.
	testing.expect_value(t, variable_state_get_global(&vs, "forceful"), v_init)
	testing.expect(t, variable_state_global_exists(&vs, "forceful"), "exists after declaration")
	testing.expect(t, !variable_state_global_exists(&vs, "missing"), "missing not present")

	// Public set_global only works on declared names.
	v1 := mk_int_val(1)
	testing.expect(t, variable_state_set_global(&vs, "forceful", v1), "set declared global ok")
	testing.expect_value(t, variable_state_get_global(&vs, "forceful"), v1)
	testing.expect(t, !variable_state_set_global(&vs, "ghost", mk_int_val(99)), "set undeclared rejected")
	testing.expect_value(t, variable_state_get_global(&vs, "ghost"), nil)
}

@(test)
test_variable_state_defaults_persist :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	cs: Call_Stack
	call_stack_init(&cs, mk_dummy_root())
	defer call_stack_destroy(&cs)
	vs: Variable_State
	variable_state_init(&vs, &cs)
	defer variable_state_destroy(&vs)

	v_default := mk_int_val(0)
	variable_state_assign(&vs, Variable_Assignment{name = "evasive", is_new_decl = true, is_global = true}, v_default)
	variable_state_snapshot_default_globals(&vs)

	// Mutate the live global; default must remain.
	v_mutated := mk_int_val(7)
	variable_state_set_global(&vs, "evasive", v_mutated)
	testing.expect_value(t, variable_state_get_global(&vs, "evasive"), v_mutated)
	testing.expect_value(t, variable_state_get_default(&vs, "evasive"), v_default)
}

@(test)
test_variable_state_assign_temp :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	cs: Call_Stack
	call_stack_init(&cs, mk_dummy_root())
	defer call_stack_destroy(&cs)
	vs: Variable_State
	variable_state_init(&vs, &cs)
	defer variable_state_destroy(&vs)

	// Push a function frame; assign a temp inside it.
	call_stack_push(&cs, .Function)
	v := mk_int_val(5)
	variable_state_assign(&vs, Variable_Assignment{name = "i", is_new_decl = true, is_global = false}, v)

	// get_variable_with_name with -1 falls through to current temp frame.
	testing.expect_value(t, variable_state_get_variable_with_name(&vs, "i"), v)
}

@(test)
test_variable_state_pointer_deref :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	cs: Call_Stack
	call_stack_init(&cs, mk_dummy_root())
	defer call_stack_destroy(&cs)
	vs: Variable_State
	variable_state_init(&vs, &cs)
	defer variable_state_destroy(&vs)

	// Declare a global "target" with an int value.
	target_val := mk_int_val(42)
	variable_state_assign(&vs, Variable_Assignment{name = "target", is_new_decl = true, is_global = true}, target_val)
	variable_state_snapshot_default_globals(&vs)

	// Declare a global "ref" that's a Variable_Pointer_Value pointing at "target".
	// is_new_decl + global means resolve_variable_pointer locks the context (-1 -> 0).
	ptr := mk_var_ptr_val("target", -1)
	variable_state_assign(&vs, Variable_Assignment{name = "ref", is_new_decl = true, is_global = true}, ptr)

	// get_variable_with_name on "ref" should follow the pointer to target_val.
	testing.expect_value(t, variable_state_get_variable_with_name(&vs, "ref"), target_val)

	// get_raw_variable_with_name should return the pointer itself (a Variable_Pointer_Value).
	raw := variable_state_get_raw_variable_with_name(&vs, "ref", 0)
	testing.expect(t, raw != nil, "raw lookup non-nil")
	if vp, is_vp := raw.variant.(Variable_Pointer_Value); is_vp {
		testing.expect_value(t, vp.name, "target")
		testing.expect_value(t, vp.context_index, 0) // resolved to global
	} else {
		testing.fail_now(t, "raw value should be a Variable_Pointer_Value")
	}
}

@(test)
test_variable_state_assign_through_pointer :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	cs: Call_Stack
	call_stack_init(&cs, mk_dummy_root())
	defer call_stack_destroy(&cs)
	vs: Variable_State
	variable_state_init(&vs, &cs)
	defer variable_state_destroy(&vs)

	// Declare globals: target = 0, ref -> target.
	v0 := mk_int_val(0)
	variable_state_assign(&vs, Variable_Assignment{name = "target", is_new_decl = true, is_global = true}, v0)
	variable_state_snapshot_default_globals(&vs)
	variable_state_assign(&vs, Variable_Assignment{name = "ref", is_new_decl = true, is_global = true}, mk_var_ptr_val("target", -1))

	// Reassigning "ref" (not a new decl) should chase the pointer and write to "target".
	v_new := mk_int_val(99)
	variable_state_assign(&vs, Variable_Assignment{name = "ref", is_new_decl = false, is_global = true}, v_new)

	testing.expect_value(t, variable_state_get_global(&vs, "target"), v_new)
	// "ref" itself is unchanged (still the Variable_Pointer_Value).
	raw := variable_state_get_raw_variable_with_name(&vs, "ref", 0)
	_, still_ptr := raw.variant.(Variable_Pointer_Value)
	testing.expect(t, still_ptr, "ref still points to target")
}

@(test)
test_variable_state_context_index :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	cs: Call_Stack
	call_stack_init(&cs, mk_dummy_root())
	defer call_stack_destroy(&cs)
	vs: Variable_State
	variable_state_init(&vs, &cs)
	defer variable_state_destroy(&vs)

	variable_state_assign(&vs, Variable_Assignment{name = "g", is_new_decl = true, is_global = true}, mk_int_val(0))
	variable_state_snapshot_default_globals(&vs)

	testing.expect_value(t, variable_state_get_context_index_of_variable_named(&vs, "g"), 0)

	// Push a frame, then non-global names report current frame index.
	call_stack_push(&cs, .Function)
	idx := variable_state_get_context_index_of_variable_named(&vs, "not_a_global")
	testing.expect_value(t, idx, call_stack_current_element_index(&cs))
}
