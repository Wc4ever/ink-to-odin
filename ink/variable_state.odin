package ink

// Variable_State: globals (current + defaults), variable-pointer deref,
// and the assignment routine the evaluator calls for `~ var = value`.
//
// Polling-only consumer API — no observer callbacks (see memory feedback).
//
// Ownership:
//   - globals / defaults are maps from name -> ^Object. Variable_State owns
//     the maps but NOT the Objects they point to. Object values come either
//     from the compiled story arena (for default values copied from global
//     decls) or from a runtime arena owned by Story_State (for runtime
//     assignments). Callers manage those arenas.
//   - call_stack is a non-owning back-reference; Variable_State doesn't
//     allocate or destroy the call stack.
//
// Mirrors ink-engine-runtime/VariablesState.cs minus observers and patch
// (StatePatch is a background-save isolation mechanism, deferred).

Variable_State :: struct {
	globals:    map[string]^Object,
	defaults:   map[string]^Object,
	call_stack: ^Call_Stack,
}

// ---- Lifecycle ------------------------------------------------------------

variable_state_init :: proc(vs: ^Variable_State, call_stack: ^Call_Stack) {
	vs.globals = make(map[string]^Object)
	vs.defaults = make(map[string]^Object)
	vs.call_stack = call_stack
}

variable_state_destroy :: proc(vs: ^Variable_State) {
	delete(vs.globals)
	delete(vs.defaults)
	vs.globals = nil
	vs.defaults = nil
	vs.call_stack = nil
}

// Called once after the global decl container has finished evaluating.
// Freezes the current globals as the "default" set used for fallback reads
// and for skipping unchanged values when serializing state.
variable_state_snapshot_default_globals :: proc(vs: ^Variable_State) {
	clear(&vs.defaults)
	for name, val in vs.globals {
		vs.defaults[name] = val
	}
}

// ---- Public polling API ---------------------------------------------------

// Read a global by name. Returns the current value, falling back to the
// default if no override has been written (matches C# this[name] getter).
// Returns nil for unknown names.
variable_state_get_global :: proc(vs: ^Variable_State, name: string) -> ^Object {
	if v, ok := vs.globals[name]; ok do return v
	if v, ok := vs.defaults[name]; ok do return v
	return nil
}

// Write a global. Returns false if `name` was never declared in the story
// (matches C# this[name] setter, which throws StoryException). Game code
// uses this to push state into the runtime; the evaluator uses
// variable_state_assign instead, which carries declaration metadata.
variable_state_set_global :: proc(vs: ^Variable_State, name: string, value: ^Object) -> bool {
	if _, ok := vs.defaults[name]; !ok do return false
	vs.globals[name] = value
	return true
}

variable_state_global_exists :: proc(vs: ^Variable_State, name: string) -> bool {
	if _, ok := vs.globals[name]; ok do return true
	if _, ok := vs.defaults[name]; ok do return true
	return false
}

variable_state_get_default :: proc(vs: ^Variable_State, name: string) -> ^Object {
	if v, ok := vs.defaults[name]; ok do return v
	return nil
}

// ---- Evaluator-facing API -------------------------------------------------

// Resolve a name to its current value at a given context.
//
// context_index conventions (matching CallStack):
//   0   -> globals
//   1+  -> 1-based callstack frame for temporary lookup
//   -1  -> "globals if defined as global, else current temp frame"
//
// Variable_Pointer_Value targets are dereferenced before returning.
variable_state_get_variable_with_name :: proc(vs: ^Variable_State, name: string, context_index: int = -1) -> ^Object {
	raw := variable_state_get_raw_variable_with_name(vs, name, context_index)
	if raw == nil do return nil
	if vp, is_vp := raw.variant.(Variable_Pointer_Value); is_vp {
		return variable_state_value_at_variable_pointer(vs, vp)
	}
	return raw
}

// Same as get_variable_with_name but does NOT dereference variable pointers.
variable_state_get_raw_variable_with_name :: proc(vs: ^Variable_State, name: string, context_index: int) -> ^Object {
	// Globals first when context permits.
	if context_index == 0 || context_index == -1 {
		if v, ok := vs.globals[name]; ok do return v
		if v, ok := vs.defaults[name]; ok do return v
		// (List-item lookup against ListDefinitionsOrigin goes here when we
		// add LIST support. TheIntercept doesn't use lists, so omit for now.)
	}
	// Fall through to temp.
	return call_stack_get_temporary_variable(vs.call_stack, name, context_index)
}

variable_state_value_at_variable_pointer :: proc(vs: ^Variable_State, ptr: Variable_Pointer_Value) -> ^Object {
	return variable_state_get_variable_with_name(vs, ptr.name, ptr.context_index)
}

// Implements `~ var = value`.
//
// `value_arena_alloc` is used when we need to construct a freshly-resolved
// Variable_Pointer_Value (for new ref-param declarations). It should be the
// runtime/turn allocator owned by Story_State.
variable_state_assign :: proc(vs: ^Variable_State, va: Variable_Assignment, value: ^Object, value_arena_alloc := context.allocator) {
	name := va.name
	v := value
	ctx_idx := -1

	// Decide whether this assignment lands in globals or temps.
	set_global := false
	if va.is_new_decl {
		set_global = va.is_global
	} else {
		set_global = variable_state_global_exists(vs, name)
	}

	if va.is_new_decl {
		// New ref-param: if value is a VariablePointerValue, lock down its
		// context index now so later reassignments can chase the chain.
		if vp, is_vp := v.variant.(Variable_Pointer_Value); is_vp {
			resolved := variable_state_resolve_variable_pointer(vs, vp)
			obj := new(Object, value_arena_alloc)
			obj.variant = resolved
			v = obj
		}
	} else {
		// Reassignment: walk any existing pointer chain and redirect to the
		// ultimate target. Each hop may flip global<->temp.
		for {
			existing := variable_state_get_raw_variable_with_name(vs, name, ctx_idx)
			if existing == nil do break
			ep, is_vp := existing.variant.(Variable_Pointer_Value)
			if !is_vp do break
			name = ep.name
			ctx_idx = ep.context_index
			set_global = (ctx_idx == 0)
		}
	}

	if set_global {
		// Apply list-origin retention before storing.
		old, _ := vs.globals[name]
		v = retain_list_origins_for_assignment(old, v)
		vs.globals[name] = v
	} else {
		call_stack_set_temporary_variable(vs.call_stack, name, v, va.is_new_decl, ctx_idx)
	}
}

// Resolve a Variable_Pointer_Value with possibly unknown context_index to one
// with a concrete context (0 = global, 1+ = callstack frame).
variable_state_resolve_variable_pointer :: proc(vs: ^Variable_State, ptr: Variable_Pointer_Value) -> Variable_Pointer_Value {
	ctx_idx := ptr.context_index
	if ctx_idx == -1 {
		ctx_idx = variable_state_get_context_index_of_variable_named(vs, ptr.name)
	}

	target := variable_state_get_raw_variable_with_name(vs, ptr.name, ctx_idx)

	// Pointer-to-a-pointer: collapse one layer to avoid building chains
	// across nested ref-param calls.
	if target != nil {
		if double, is_vp := target.variant.(Variable_Pointer_Value); is_vp {
			return double
		}
	}

	return Variable_Pointer_Value{name = ptr.name, context_index = ctx_idx}
}

// 0 if `name` is a global; current callstack frame index otherwise.
variable_state_get_context_index_of_variable_named :: proc(vs: ^Variable_State, name: string) -> int {
	if variable_state_global_exists(vs, name) do return 0
	return call_stack_current_element_index(vs.call_stack)
}

// ---- Helpers --------------------------------------------------------------

// When assigning a List_Value, the new list inherits the old list's origins
// when the new one was constructed empty. Mirrors C#
// ListValue.RetainListOriginsForAssignment.
@(private)
retain_list_origins_for_assignment :: proc(old, new_val: ^Object) -> ^Object {
	if old == nil || new_val == nil do return new_val
	old_list, old_ok := &old.variant.(List_Value)
	new_list, new_ok := &new_val.variant.(List_Value)
	if !old_ok || !new_ok do return new_val
	if len(new_list.value.items) == 0 && new_list.value.origin_names == nil {
		new_list.value.origin_names = old_list.value.origin_names
	}
	return new_val
}
