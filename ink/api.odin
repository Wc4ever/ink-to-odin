package ink

import "core:strings"

// Game-facing convenience helpers. Wrappers over the lower-level state
// machinery so callers don't have to reach into Variable_State / Story_State
// internals to do everyday tasks.
//
// These procs are the recommended entry points for embedding the runtime in
// a game. The lower-level procs (variable_state_*, call_stack_*, etc.) stay
// available for advanced use.

// ---- Variable read / write ------------------------------------------------

// Returns the current value of a global by name (current-or-default), or nil
// if the name is unknown. The returned ^Object is borrowed — its lifetime is
// the Story_State (it's allocated from either the compiled-story arena or the
// runtime arena). Do NOT free it.
story_get_variable :: proc(s: ^Story_State, name: string) -> ^Object {
	return variable_state_get_global(&s.variables_state, name)
}

story_get_variable_int :: proc(s: ^Story_State, name: string) -> (value: i64, ok: bool) {
	o := story_get_variable(s, name)
	if o == nil do return 0, false
	if v, is_int := o.variant.(Int_Value); is_int do return v.value, true
	if v, is_b := o.variant.(Bool_Value); is_b do return v.value ? 1 : 0, true
	if v, is_f := o.variant.(Float_Value); is_f do return i64(v.value), true
	return 0, false
}

story_get_variable_float :: proc(s: ^Story_State, name: string) -> (value: f64, ok: bool) {
	o := story_get_variable(s, name)
	if o == nil do return 0, false
	if v, is_f := o.variant.(Float_Value); is_f do return v.value, true
	if v, is_int := o.variant.(Int_Value); is_int do return f64(v.value), true
	return 0, false
}

story_get_variable_bool :: proc(s: ^Story_State, name: string) -> (value: bool, ok: bool) {
	o := story_get_variable(s, name)
	if o == nil do return false, false
	if v, is_b := o.variant.(Bool_Value); is_b do return v.value, true
	if v, is_int := o.variant.(Int_Value); is_int do return v.value != 0, true
	return false, false
}

// Returned string is borrowed from the underlying String_Value.value. Clone
// it if you need to outlive the next reset/destroy.
story_get_variable_string :: proc(s: ^Story_State, name: string) -> (value: string, ok: bool) {
	o := story_get_variable(s, name)
	if o == nil do return "", false
	if v, is_s := o.variant.(String_Value); is_s do return v.value, true
	return "", false
}

// `value` is cloned into the runtime arena before storing.
story_set_variable_int :: proc(s: ^Story_State, name: string, value: i64) -> bool {
	o := new(Object, story_state_runtime_allocator(s))
	o.variant = Int_Value{value = value}
	return variable_state_set_global(&s.variables_state, name, o)
}

story_set_variable_float :: proc(s: ^Story_State, name: string, value: f64) -> bool {
	o := new(Object, story_state_runtime_allocator(s))
	o.variant = Float_Value{value = value}
	return variable_state_set_global(&s.variables_state, name, o)
}

story_set_variable_bool :: proc(s: ^Story_State, name: string, value: bool) -> bool {
	o := new(Object, story_state_runtime_allocator(s))
	o.variant = Bool_Value{value = value}
	return variable_state_set_global(&s.variables_state, name, o)
}

// `value` is cloned into the runtime arena so caller storage can be freed.
story_set_variable_string :: proc(s: ^Story_State, name: string, value: string) -> bool {
	alloc := story_state_runtime_allocator(s)
	cloned := strings.clone(value, alloc)
	o := new(Object, alloc)
	o.variant = String_Value{value = cloned}
	return variable_state_set_global(&s.variables_state, name, o)
}

// True iff the global was declared at story compile time.
story_has_variable :: proc(s: ^Story_State, name: string) -> bool {
	return variable_state_global_exists(&s.variables_state, name)
}

// ---- Tags -----------------------------------------------------------------

// Top-of-file tags (those above the first knot in the .ink source).
// Result slice is allocator-owned; caller should `delete` it.
story_global_tags :: proc(s: ^Story_State, allocator := context.allocator) -> []string {
	return story_tags_at_path(s, "", allocator)
}

// Tags at the top of a knot or stitch (e.g. "myKnot" or "myKnot.myStitch").
// Mirrors C# Story.TagsForContentAtPath. Result slice is allocator-owned.
story_tags_at_path :: proc(s: ^Story_State, path_str: string, allocator := context.allocator) -> []string {
	if s == nil || s.compiled_story == nil do return nil

	flow: ^Object
	if len(path_str) == 0 {
		flow = s.compiled_story.root
	} else {
		p := path_parse(path_str, context.temp_allocator)
		r := container_content_at_path(s.compiled_story.root, p)
		flow = r.obj
	}
	if flow == nil do return nil

	// Drill into first-child container until we hit a non-container.
	for {
		c, is_c := flow.variant.(Container)
		if !is_c || len(c.content) == 0 do break
		first := c.content[0]
		if _, child_is_c := first.variant.(Container); !child_is_c do break
		flow = first
	}

	c, is_c := flow.variant.(Container)
	if !is_c do return nil

	out := make([dynamic]string, 0, 0, allocator)
	in_tag := false
	for child in c.content {
		if cmd, is_cmd := child.variant.(Control_Command); is_cmd {
			switch cmd {
			case .Begin_Tag: in_tag = true
			case .End_Tag:   in_tag = false
			case .Eval_Start, .Eval_Output, .Eval_End, .Duplicate, .Pop_Evaluated_Value,
			     .Pop_Function, .Pop_Tunnel, .Begin_String, .End_String, .No_Op,
			     .Choice_Count, .Turns, .Turns_Since, .Read_Count, .Random,
			     .Seed_Random, .Visit_Index, .Sequence_Shuffle_Index, .Start_Thread,
			     .Done, .End, .List_From_Int, .List_Range, .List_Random:
				// other control commands aren't tag-related; keep scanning while
				// in_tag (matches upstream's permissive "anything until next tag
				// boundary" walk) but ignore them.
			}
			continue
		}
		if in_tag {
			if sv, is_str := child.variant.(String_Value); is_str {
				append(&out, sv.value)
			} else {
				story_state_error(s, "tag contained non-text content; only plain text is allowed for global/path tags")
				break
			}
			continue
		}
		// Any other content outside a tag block ends the run of header tags.
		// Legacy `Tag` (single-string) form is also gathered.
		if t, is_tag := child.variant.(Tag); is_tag {
			append(&out, t.text)
			continue
		}
		break
	}
	return out[:]
}

// ---- Errors / warnings ----------------------------------------------------

story_errors :: proc(s: ^Story_State) -> []string {
	return s.current_errors[:]
}

story_warnings :: proc(s: ^Story_State) -> []string {
	return s.current_warnings[:]
}

story_clear_errors :: proc(s: ^Story_State) {
	clear(&s.current_errors)
}

story_clear_warnings :: proc(s: ^Story_State) {
	clear(&s.current_warnings)
}
