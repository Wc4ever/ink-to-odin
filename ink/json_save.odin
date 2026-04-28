package ink

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"

// State -> JSON. Mirrors ink-engine-runtime's StoryState.WriteJson plus the
// helpers in JsonSerialisation.cs (WriteRuntimeObject, etc.).
//
// Output is formatted to match Newtonsoft.Json's Formatting.Indented exactly
// (2-space indent, ": " key separator, "[]"/"{}" for empties on a single
// line) AND has all object keys sorted alphabetically. This is what the
// dotnet test-runner produces after parsing+sorting state.ToJson() output,
// so byte-identical Odin output compares cleanly.
//
// Strings owned by the returned value live in the caller's allocator.

state_to_json :: proc(s: ^Story_State, allocator := context.allocator) -> string {
	w := jw_make(allocator)
	defer jw_destroy(&w)
	write_state(&w, s)
	return strings.clone(strings.to_string(w.b), allocator)
}

// ---- Internal: state encoding --------------------------------------------

@(private)
write_state :: proc(w: ^JW, s: ^Story_State) {
	jw_obj_start(w)

	// Sorted alphabetically: currentDivertTarget(opt), currentFlowName,
	// evalStack, flows, inkFormatVersion, inkSaveVersion, previousRandom,
	// storySeed, turnIdx, turnIndices, variablesState, visitCounts.

	if !pointer_is_null(s.diverted_pointer) {
		jw_property(w, "currentDivertTarget")
		obj := pointer_resolve(s.diverted_pointer)
		path_str: string
		if obj != nil {
			p := object_path(obj, w.alloc)
			path_str = path_to_string(p, w.alloc)
			defer path_destroy(&p, w.alloc)
			defer delete(path_str, w.alloc)
		}
		jw_string(w, path_str)
	}

	jw_property(w, "currentFlowName")
	jw_string(w, s.current_flow_name)

	jw_property(w, "evalStack")
	write_runtime_object_list(w, s.eval_stack[:])

	jw_property(w, "flows")
	jw_obj_start(w)
	{
		// Sort all flow names (active + inactive) so output order is stable.
		names := make([dynamic]string, 0, len(s.inactive_flows) + 1, w.alloc)
		defer delete(names)
		append(&names, s.current_flow_name)
		for n in s.inactive_flows do append(&names, n)
		slice.sort(names[:])
		for n in names {
			jw_property(w, n)
			if n == s.current_flow_name {
				write_flow(w, &s.call_stack, &s.output_stream, s.current_choices[:])
			} else {
				flow := s.inactive_flows[n]
				write_flow(w, &flow.call_stack, &flow.output_stream, flow.current_choices[:])
			}
		}
	}
	jw_obj_end(w)

	jw_property(w, "inkFormatVersion")
	jw_int(w, i64(s.compiled_story.ink_format_version))

	jw_property(w, "inkSaveVersion")
	jw_int(w, i64(INK_SAVE_STATE_VERSION))

	jw_property(w, "previousRandom")
	jw_int(w, i64(s.previous_random))

	jw_property(w, "storySeed")
	jw_int(w, i64(s.story_seed))

	jw_property(w, "turnIdx")
	jw_int(w, i64(s.current_turn_index))

	jw_property(w, "turnIndices")
	write_int_dict_sorted(w, s.turn_indices)

	jw_property(w, "variablesState")
	write_variables_state(w, s)

	jw_property(w, "visitCounts")
	write_int_dict_sorted(w, s.visit_counts)

	jw_obj_end(w)
}

@(private)
write_flow :: proc(w: ^JW, cs: ^Call_Stack, os: ^Output_Stream, choices: []Choice) {
	jw_obj_start(w)

	// Sorted: callstack, choiceThreads (opt), currentChoices, outputStream.
	jw_property(w, "callstack")
	write_callstack(w, cs)

	// choiceThreads: serialize each forked thread whose index is no longer
	// present in the active callstack. Mirrors Flow.WriteJson. Keys are
	// sorted lexicographically (matching the dotnet runner's post-parse
	// alphabetical sort, where "10" sorts before "8").
	{
		Entry :: struct { key: string, thread: ^Call_Stack_Thread }
		entries := make([dynamic]Entry, 0, len(choices), w.alloc)
		defer {
			for &e in entries do delete(e.key, w.alloc)
			delete(entries)
		}
		for i := 0; i < len(choices); i += 1 {
			c := &choices[i]
			idx := c.thread_at_generation.thread_index
			if call_stack_thread_with_index(cs, idx) != nil do continue
			key := fmt.aprintf("%d", idx, allocator = w.alloc)
			append(&entries, Entry{key = key, thread = &c.thread_at_generation})
		}
		if len(entries) > 0 {
			slice.sort_by(entries[:], proc(a, b: Entry) -> bool { return a.key < b.key })
			jw_property(w, "choiceThreads")
			jw_obj_start(w)
			for &e in entries {
				jw_property(w, e.key)
				write_thread(w, e.thread)
			}
			jw_obj_end(w)
		}
	}

	jw_property(w, "currentChoices")
	write_choices(w, choices)

	jw_property(w, "outputStream")
	write_runtime_object_list(w, os.stream[:])

	jw_obj_end(w)
}

@(private)
write_callstack :: proc(w: ^JW, cs: ^Call_Stack) {
	jw_obj_start(w)

	// Sorted: threadCounter, threads
	jw_property(w, "threadCounter")
	jw_int(w, i64(cs.thread_counter))

	jw_property(w, "threads")
	jw_arr_start(w)
	for &thread in cs.threads {
		jw_arr_value(w)
		write_thread(w, &thread)
	}
	jw_arr_end(w)

	jw_obj_end(w)
}

@(private)
write_thread :: proc(w: ^JW, t: ^Call_Stack_Thread) {
	jw_obj_start(w)

	// Sorted: callstack, previousContentObject (opt), threadIndex
	jw_property(w, "callstack")
	jw_arr_start(w)
	for &el in t.callstack {
		jw_arr_value(w)
		write_call_stack_element(w, &el)
	}
	jw_arr_end(w)

	if !pointer_is_null(t.previous_pointer) {
		obj := pointer_resolve(t.previous_pointer)
		if obj != nil {
			p := object_path(obj, w.alloc)
			defer path_destroy(&p, w.alloc)
			path_str := path_to_string(p, w.alloc)
			defer delete(path_str, w.alloc)
			jw_property(w, "previousContentObject")
			jw_string(w, path_str)
		}
	}

	jw_property(w, "threadIndex")
	jw_int(w, i64(t.thread_index))

	jw_obj_end(w)
}

@(private)
write_call_stack_element :: proc(w: ^JW, el: ^Call_Stack_Element) {
	jw_obj_start(w)

	// Sorted: cPath (opt), exp, idx, temp (opt), type
	// Sorted alphabetically: cPath, exp, idx, temp, type.
	// cPath + idx only emitted when the pointer addresses a real container —
	// at story start (pointer = (root, 0)) cPath is "" and idx is 0; after
	// content has run out the pointer is null and both fields are omitted.
	has_pointer := !pointer_is_null(el.current_pointer) && el.current_pointer.container != nil
	if has_pointer {
		p := object_path(el.current_pointer.container, w.alloc)
		defer path_destroy(&p, w.alloc)
		path_str := path_to_string(p, w.alloc)
		defer delete(path_str, w.alloc)
		jw_property(w, "cPath")
		jw_string(w, path_str)
	}

	jw_property(w, "exp")
	jw_bool(w, el.in_expression_evaluation)

	if has_pointer {
		jw_property(w, "idx")
		idx := el.current_pointer.index
		if idx < 0 do idx = 0
		jw_int(w, i64(idx))
	}

	if len(el.temporary_variables) > 0 {
		jw_property(w, "temp")
		write_runtime_object_dict(w, el.temporary_variables)
	}

	jw_property(w, "type")
	jw_int(w, push_pop_type_to_int(el.type))

	jw_obj_end(w)
}

@(private)
write_variables_state :: proc(w: ^JW, s: ^Story_State) {
	jw_obj_start(w)
	// Skip keys whose current value matches the default — mirrors C#'s
	// dontSaveDefaultValues=true.
	keys := make([dynamic]string, 0, len(s.variables_state.globals), w.alloc)
	defer delete(keys)
	for k in s.variables_state.globals do append(&keys, k)
	slice.sort(keys[:])
	for k in keys {
		v := s.variables_state.globals[k]
		def, has_def := s.variables_state.defaults[k]
		if has_def && runtime_objects_equal(v, def) do continue
		jw_property(w, k)
		write_runtime_object(w, v)
	}
	jw_obj_end(w)
}

// ---- Choices --------------------------------------------------------------

@(private)
write_choices :: proc(w: ^JW, choices: []Choice) {
	jw_arr_start(w)
	for &c in choices {
		jw_arr_value(w)
		write_choice(w, &c)
	}
	jw_arr_end(w)
}

@(private)
write_choice :: proc(w: ^JW, c: ^Choice) {
	jw_obj_start(w)

	// Sorted: index, originalChoicePath, originalThreadIndex, tags(opt), targetPath, text
	jw_property(w, "index")
	jw_int(w, i64(c.index))

	jw_property(w, "originalChoicePath")
	jw_string(w, c.source_path)

	jw_property(w, "originalThreadIndex")
	jw_int(w, i64(c.original_thread_index))

	if c.tags != nil && len(c.tags) > 0 {
		jw_property(w, "tags")
		jw_arr_start(w)
		for tag in c.tags {
			jw_arr_value(w)
			jw_string(w, tag)
		}
		jw_arr_end(w)
	}

	jw_property(w, "targetPath")
	jw_string(w, c.target_path)

	jw_property(w, "text")
	jw_string(w, c.text)

	jw_obj_end(w)
}

// ---- Runtime object encoding ---------------------------------------------
// Inverse of JTokenToRuntimeObject in JsonSerialisation.cs.

@(private)
write_runtime_object_list :: proc(w: ^JW, objs: []^Object) {
	jw_arr_start(w)
	for o in objs {
		jw_arr_value(w)
		write_runtime_object(w, o)
	}
	jw_arr_end(w)
}

@(private)
write_runtime_object_dict :: proc(w: ^JW, m: map[string]^Object) {
	jw_obj_start(w)
	keys := make([dynamic]string, 0, len(m), w.alloc)
	defer delete(keys)
	for k in m do append(&keys, k)
	slice.sort(keys[:])
	for k in keys {
		jw_property(w, k)
		write_runtime_object(w, m[k])
	}
	jw_obj_end(w)
}

@(private)
write_int_dict_sorted :: proc(w: ^JW, m: map[string]int) {
	jw_obj_start(w)
	keys := make([dynamic]string, 0, len(m), w.alloc)
	defer delete(keys)
	for k in m do append(&keys, k)
	slice.sort(keys[:])
	for k in keys {
		jw_property(w, k)
		jw_int(w, i64(m[k]))
	}
	jw_obj_end(w)
}

@(private)
write_runtime_object :: proc(w: ^JW, o: ^Object) {
	if o == nil {
		jw_null(w)
		return
	}
	switch v in o.variant {
	case Container:
		// Containers in eval stack / output stream are rare — not handled
		// in v1. Emit null so the writer doesn't break.
		jw_null(w)

	case Bool_Value:    jw_bool(w, v.value)
	case Int_Value:     jw_int(w, v.value)
	case Float_Value:   jw_float(w, v.value)
	case String_Value:
		// "\n" -> "\n" string literal (raw newline);
		// otherwise prefix with ^.
		if v.value == "\n" {
			jw_string(w, "\n")
		} else {
			jw_string_prefixed(w, "^", v.value)
		}

	case Divert_Target_Value:
		jw_obj_start(w)
		jw_property(w, "^->")
		jw_string(w, v.target)
		jw_obj_end(w)

	case Variable_Pointer_Value:
		jw_obj_start(w)
		jw_property(w, "^var")
		jw_string(w, v.name)
		jw_property(w, "ci")
		jw_int(w, i64(v.context_index))
		jw_obj_end(w)

	case Glue:
		jw_string(w, "<>")

	case Void:
		jw_string(w, "void")

	case Control_Command:
		jw_string(w, control_command_name(v))

	case Native_Function_Call:
		// "^" collides with string-prefix encoding; remap to "L^" on disk.
		name := v.name
		if name == "^" do name = "L^"
		jw_string(w, name)

	case Variable_Reference:
		jw_obj_start(w)
		if len(v.name) > 0 {
			jw_property(w, "VAR?")
			jw_string(w, v.name)
		} else {
			jw_property(w, "CNT?")
			jw_string(w, v.path_for_count)
		}
		jw_obj_end(w)

	case Variable_Assignment:
		jw_obj_start(w)
		// Sorted: re(opt), then VAR= or temp=
		// Actually upstream emits VAR=/temp= first, then re. Sort doesn't
		// affect dotnet's post-parse sort, so order here doesn't matter.
		key := v.is_global ? "VAR=" : "temp="
		jw_property(w, key)
		jw_string(w, v.name)
		if !v.is_new_decl {
			jw_property(w, "re")
			jw_bool(w, true)
		}
		jw_obj_end(w)

	case Tag:
		jw_obj_start(w)
		jw_property(w, "#")
		jw_string(w, v.text)
		jw_obj_end(w)

	case Choice_Point:
		jw_obj_start(w)
		jw_property(w, "*")
		jw_string(w, v.path_on_choice)
		jw_property(w, "flg")
		jw_int(w, i64(choice_flags_to_bits(v.flags)))
		jw_obj_end(w)

	case Divert:
		jw_obj_start(w)
		// Sorted alphabetical-ish; concrete ordering depends on dotnet sort.
		key: string
		if v.is_external {
			key = "x()"
		} else if v.pushes_to_stack {
			key = v.stack_push_type == .Function ? "f()" : "->t->"
		} else {
			key = "->"
		}
		target := len(v.variable_divert_name) > 0 ? v.variable_divert_name : v.target_path

		if v.is_conditional {
			jw_property(w, "c")
			jw_bool(w, true)
		}
		if v.is_external && v.external_args > 0 {
			jw_property(w, "exArgs")
			jw_int(w, i64(v.external_args))
		}
		jw_property(w, key)
		jw_string(w, target)
		if len(v.variable_divert_name) > 0 {
			jw_property(w, "var")
			jw_bool(w, true)
		}
		jw_obj_end(w)

	case List_Value:
		write_list_value(w, v)
	}
}

// {"list": {"Origin.Item": value, ...}, "origins"?: [...]}
// Items are emitted alphabetically by full name so output is byte-deterministic.
// "origins" appears only for empty lists with retained type info, mirroring
// JsonSerialisation.WriteListRuntimeObj (Count == 0 && originNames != null).
@(private)
write_list_value :: proc(w: ^JW, lv: List_Value) {
	jw_obj_start(w)
	jw_property(w, "list")
	jw_obj_start(w)

	keys := make([dynamic]string, 0, len(lv.value.items), w.alloc)
	defer {
		for k in keys do delete(k, w.alloc)
		delete(keys)
	}
	for item in lv.value.items {
		full := full_list_item_name(item, w.alloc)
		append(&keys, full)
	}
	slice.sort(keys[:])

	for k in keys {
		origin, item := split_list_item_key(k)
		val, _ := lv.value.items[List_Item{origin_name = origin, item_name = item}]
		jw_property(w, k)
		jw_int(w, i64(val))
	}
	jw_obj_end(w)

	if len(lv.value.items) == 0 && len(lv.value.origin_names) > 0 {
		jw_property(w, "origins")
		jw_arr_start(w)
		for n in lv.value.origin_names {
			jw_string(w, n)
		}
		jw_arr_end(w)
	}
	jw_obj_end(w)
}

@(private)
full_list_item_name :: proc(item: List_Item, alloc := context.allocator) -> string {
	if len(item.origin_name) == 0 do return strings.clone(item.item_name, alloc)
	return strings.concatenate({item.origin_name, ".", item.item_name}, alloc)
}

// ---- Helpers --------------------------------------------------------------

@(private)
runtime_objects_equal :: proc(a, b: ^Object) -> bool {
	if a == nil || b == nil do return a == b
	switch va in a.variant {
	case Bool_Value:    if vb, ok := b.variant.(Bool_Value);    ok do return va.value == vb.value
	case Int_Value:     if vb, ok := b.variant.(Int_Value);     ok do return va.value == vb.value
	case Float_Value:   if vb, ok := b.variant.(Float_Value);   ok do return va.value == vb.value
	case String_Value:  if vb, ok := b.variant.(String_Value);  ok do return va.value == vb.value
	case Divert_Target_Value:
		if vb, ok := b.variant.(Divert_Target_Value); ok do return va.target == vb.target
	case Variable_Pointer_Value:
		if vb, ok := b.variant.(Variable_Pointer_Value); ok do return va.name == vb.name && va.context_index == vb.context_index
	case List_Value:
		if vb, ok := b.variant.(List_Value); ok do return ink_lists_equal(va.value, vb.value)
	case Container, Glue, Void, Tag, Control_Command, Native_Function_Call, Divert, Choice_Point, Variable_Reference, Variable_Assignment:
		return false
	}
	return false
}

@(private)
ink_lists_equal :: proc(a, b: Ink_List) -> bool {
	if len(a.items) != len(b.items) do return false
	for k, v in a.items {
		bv, ok := b.items[k]
		if !ok || bv != v do return false
	}
	return true
}

@(private)
push_pop_type_to_int :: proc(t: Push_Pop_Type) -> i64 {
	switch t {
	case .Tunnel:                          return 0
	case .Function:                        return 1
	case .Function_Evaluation_From_Game:   return 2
	}
	return 0
}

@(private)
choice_flags_to_bits :: proc(f: Choice_Flags) -> int {
	bits := 0
	if .Has_Condition           in f do bits |= 0x1
	if .Has_Start_Content       in f do bits |= 0x2
	if .Has_Choice_Only_Content in f do bits |= 0x4
	if .Is_Invisible_Default    in f do bits |= 0x8
	if .Once_Only               in f do bits |= 0x10
	return bits
}

@(private)
control_command_name :: proc(cmd: Control_Command) -> string {
	switch cmd {
	case .Eval_Start:              return "ev"
	case .Eval_Output:             return "out"
	case .Eval_End:                return "/ev"
	case .Duplicate:               return "du"
	case .Pop_Evaluated_Value:     return "pop"
	case .Pop_Function:            return "~ret"
	case .Pop_Tunnel:              return "->->"
	case .Begin_String:            return "str"
	case .End_String:              return "/str"
	case .No_Op:                   return "nop"
	case .Choice_Count:            return "choiceCnt"
	case .Turns:                   return "turn"
	case .Turns_Since:             return "turns"
	case .Read_Count:              return "readc"
	case .Random:                  return "rnd"
	case .Seed_Random:             return "srnd"
	case .Visit_Index:             return "visit"
	case .Sequence_Shuffle_Index:  return "seq"
	case .Start_Thread:            return "thread"
	case .Done:                    return "done"
	case .End:                     return "end"
	case .List_From_Int:           return "listInt"
	case .List_Range:              return "range"
	case .List_Random:             return "lrnd"
	case .Begin_Tag:               return "#"
	case .End_Tag:                 return "/#"
	}
	return ""
}

// ---- Tiny JSON writer with sort-friendly mid-stream output ---------------
// Produces Newtonsoft.Json Formatting.Indented compatible output: 2-space
// indent, ": " separator, "[]"/"{}" for empties on one line.

@(private)
JW :: struct {
	b:      strings.Builder,
	indent: int,
	starts: [dynamic]bool,    // per-level: true while current level is empty
	alloc:  mem.Allocator,    // backs builder + scratch (paths, sorted key arrays)
}

@(private)
jw_make :: proc(allocator := context.allocator) -> JW {
	context.allocator = allocator
	return JW{
		b      = strings.builder_make(),
		starts = make([dynamic]bool, 0, 8),
		alloc  = allocator,
	}
}

@(private)
jw_destroy :: proc(w: ^JW) {
	strings.builder_destroy(&w.b)
	delete(w.starts)
}

@(private)
jw_obj_start :: proc(w: ^JW) {
	jw_value_separator_if_needed(w)
	strings.write_byte(&w.b, '{')
	append(&w.starts, true)
	w.indent += 1
}

@(private)
jw_obj_end :: proc(w: ^JW) {
	is_empty := pop(&w.starts)
	w.indent -= 1
	if !is_empty {
		strings.write_byte(&w.b, '\n')
		jw_write_indent(w)
	}
	strings.write_byte(&w.b, '}')
}

@(private)
jw_arr_start :: proc(w: ^JW) {
	jw_value_separator_if_needed(w)
	strings.write_byte(&w.b, '[')
	append(&w.starts, true)
	w.indent += 1
}

@(private)
jw_arr_end :: proc(w: ^JW) {
	is_empty := pop(&w.starts)
	w.indent -= 1
	if !is_empty {
		strings.write_byte(&w.b, '\n')
		jw_write_indent(w)
	}
	strings.write_byte(&w.b, ']')
}

@(private)
jw_property :: proc(w: ^JW, key: string) {
	jw_separator_before_entry(w)
	jw_string_raw(w, key)
	strings.write_string(&w.b, ": ")
}

@(private)
jw_arr_value :: proc(w: ^JW) {
	jw_separator_before_entry(w)
}

@(private)
jw_separator_before_entry :: proc(w: ^JW) {
	if len(w.starts) == 0 do return
	if !w.starts[len(w.starts) - 1] {
		strings.write_byte(&w.b, ',')
	}
	strings.write_byte(&w.b, '\n')
	jw_write_indent(w)
	w.starts[len(w.starts) - 1] = false
}

@(private)
jw_value_separator_if_needed :: proc(w: ^JW) {
	// When this is being called *inside* a property value (after `: `),
	// no separator needed.  If we're at array position, the caller should
	// have already called jw_arr_value first to emit the `,\n` separator.
	// jw_property emits "key: " then the caller calls jw_obj_start/etc; we
	// don't need an extra separator there. Used only for arrays:
	if len(w.starts) > 0 {
		// Array elements track via starts too; check whether we're already
		// at the start of an array level. If the parent in starts indicates
		// "first array element", we need to emit `\n + indent` before.
		// Done in jw_arr_value via jw_separator_before_entry which sets
		// the flag; second invocations get the comma. So nothing here.
	}
}

@(private)
jw_write_indent :: proc(w: ^JW) {
	for _ in 0 ..< w.indent * 2 {
		strings.write_byte(&w.b, ' ')
	}
}

@(private)
jw_int :: proc(w: ^JW, n: i64) {
	buf: [32]u8
	out := strconv.itoa(buf[:], int(n))
	strings.write_string(&w.b, out)
}

@(private)
jw_float :: proc(w: ^JW, x: f64) {
	// Newtonsoft writes integers-as-floats with .0 suffix; for clarity we
	// always include a fractional part when the float is integral.
	buf: [64]u8
	out := strconv.ftoa(buf[:], x, 'g', -1, 64)
	strings.write_string(&w.b, out)
	if !strings.contains_any(out, ".eE") {
		strings.write_string(&w.b, ".0")
	}
}

@(private)
jw_bool :: proc(w: ^JW, b: bool) {
	strings.write_string(&w.b, b ? "true" : "false")
}

@(private)
jw_null :: proc(w: ^JW) {
	strings.write_string(&w.b, "null")
}

@(private)
jw_string :: proc(w: ^JW, s: string) {
	jw_string_raw(w, s)
}

@(private)
jw_string_prefixed :: proc(w: ^JW, prefix, s: string) {
	strings.write_byte(&w.b, '"')
	jw_string_inner(w, prefix)
	jw_string_inner(w, s)
	strings.write_byte(&w.b, '"')
}

@(private)
jw_string_raw :: proc(w: ^JW, s: string) {
	strings.write_byte(&w.b, '"')
	jw_string_inner(w, s)
	strings.write_byte(&w.b, '"')
}

@(private)
jw_string_inner :: proc(w: ^JW, s: string) {
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':  strings.write_string(&w.b, "\\\"")
		case '\\': strings.write_string(&w.b, "\\\\")
		case '\n': strings.write_string(&w.b, "\\n")
		case '\r': strings.write_string(&w.b, "\\r")
		case '\t': strings.write_string(&w.b, "\\t")
		case '\b': strings.write_string(&w.b, "\\b")
		case '\f': strings.write_string(&w.b, "\\f")
		case:
			if c < 0x20 {
				strings.write_string(&w.b, fmt.tprintf("\\u%04X", c))
			} else {
				strings.write_byte(&w.b, c)
			}
		}
	}
}
