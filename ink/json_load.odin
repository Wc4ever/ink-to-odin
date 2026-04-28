package ink

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"

Load_Error :: enum {
	None,
	Arena_Init_Failed,
	Parse_Failed,
	Bad_Top_Level,
	Missing_Ink_Version,
	Missing_Root,
	Bad_Container,
	Unknown_Token,
}

// Loads inklecate's compiled story JSON into the runtime object graph.
// Format reference: vendor/ink/ink-engine-runtime/JsonSerialisation.cs
//
// On success, story.root is the top-level Container and the arena owns
// every allocation made during parsing. On failure, the arena is torn
// down before returning, so the Compiled_Story is left zeroed.
compiled_story_load :: proc(story: ^Compiled_Story, json_text: string) -> Load_Error {
	if err := virtual.arena_init_growing(&story.arena); err != nil {
		return .Arena_Init_Failed
	}

	arena_alloc := virtual.arena_allocator(&story.arena)
	context.allocator = arena_alloc

	// parse_integers=true is mandatory: without it every numeric literal
	// becomes f64, and we can't tell ink's IntValue apart from FloatValue.
	root_value, parse_err := json.parse_string(
		json_text,
		spec = .JSON5,
		parse_integers = true,
		allocator = arena_alloc,
	)
	if parse_err != .None {
		virtual.arena_destroy(&story.arena)
		story^ = {}
		return .Parse_Failed
	}

	top, top_ok := root_value.(json.Object)
	if !top_ok {
		virtual.arena_destroy(&story.arena)
		story^ = {}
		return .Bad_Top_Level
	}

	ver_val, ver_ok := top["inkVersion"]
	if !ver_ok {
		virtual.arena_destroy(&story.arena)
		story^ = {}
		return .Missing_Ink_Version
	}
	if v, ok := ver_val.(json.Integer); ok {
		story.ink_format_version = int(v)
	} else {
		virtual.arena_destroy(&story.arena)
		story^ = {}
		return .Missing_Ink_Version
	}

	root_token, root_ok := top["root"]
	if !root_ok {
		virtual.arena_destroy(&story.arena)
		story^ = {}
		return .Missing_Root
	}
	root_arr, arr_ok := root_token.(json.Array)
	if !arr_ok {
		virtual.arena_destroy(&story.arena)
		story^ = {}
		return .Bad_Container
	}

	story.root = json_array_to_container(root_arr)
	if story.root == nil {
		virtual.arena_destroy(&story.arena)
		story^ = {}
		return .Bad_Container
	}

	// listDefs (optional) — deferred. TheIntercept doesn't use LISTs.

	return .None
}

// ---- Internals ------------------------------------------------------------

@(private)
new_object :: proc(variant: Object_Variant, parent: ^Object = nil) -> ^Object {
	obj := new(Object)
	obj.parent = parent
	obj.variant = variant
	return obj
}

@(private)
json_token_to_object :: proc(token: json.Value) -> ^Object {
	switch v in token {
	case json.Null:
		return nil
	case json.Boolean:
		return new_object(Bool_Value{value = bool(v)})
	case json.Integer:
		return new_object(Int_Value{value = i64(v)})
	case json.Float:
		return new_object(Float_Value{value = f64(v)})
	case json.String:
		return json_string_to_object(string(v))
	case json.Array:
		return json_array_to_container(v)
	case json.Object:
		return json_object_to_object(v)
	}
	return nil
}

@(private)
json_string_to_object :: proc(s: string) -> ^Object {
	if len(s) == 0 {
		return new_object(String_Value{value = ""})
	}

	// "^foo" → string value "foo"; "^^foo" → string value "^foo".
	if s[0] == '^' {
		return new_object(String_Value{value = s[1:]})
	}
	if s == "\n" {
		return new_object(String_Value{value = "\n"})
	}
	if s == "<>" {
		return new_object(Glue{})
	}
	if s == "void" {
		return new_object(Void{})
	}

	if cmd, ok := control_command_from_name(s); ok {
		return new_object(cmd)
	}

	// "L^" is the on-disk encoding of native function "^" (intersect),
	// disambiguated from the ^-prefixed string-value encoding.
	name := s
	if name == "L^" {
		name = "^"
	}
	return new_object(Native_Function_Call{name = name})
}

@(private)
json_object_to_object :: proc(obj: json.Object) -> ^Object {
	// Divert target value: {"^->": "path"}
	if v, ok := obj["^->"]; ok {
		if s, s_ok := v.(json.String); s_ok {
			return new_object(Divert_Target_Value{target = string(s)})
		}
	}

	// Variable pointer: {"^var": "name", "ci": int}
	if v, ok := obj["^var"]; ok {
		if name, name_ok := v.(json.String); name_ok {
			ctx_idx: int = -1
			if ci_val, ci_ok := obj["ci"]; ci_ok {
				if ci, ci_int := ci_val.(json.Integer); ci_int {
					ctx_idx = int(ci)
				}
			}
			return new_object(Variable_Pointer_Value{name = string(name), context_index = ctx_idx})
		}
	}

	// Diverts: "->", "f()", "->t->", "x()"
	{
		div: Divert
		is_div := false
		div_target_val: json.Value
		if v, ok := obj["->"]; ok {
			is_div = true
			div_target_val = v
			div.stack_push_type = .Function // unused when pushes_to_stack=false
		} else if v, ok := obj["f()"]; ok {
			is_div = true
			div_target_val = v
			div.pushes_to_stack = true
			div.stack_push_type = .Function
		} else if v, ok := obj["->t->"]; ok {
			is_div = true
			div_target_val = v
			div.pushes_to_stack = true
			div.stack_push_type = .Tunnel
		} else if v, ok := obj["x()"]; ok {
			is_div = true
			div_target_val = v
			div.is_external = true
			div.stack_push_type = .Function
		}
		if is_div {
			target_str: string
			if s, s_ok := div_target_val.(json.String); s_ok {
				target_str = string(s)
			}
			if _, has_var := obj["var"]; has_var {
				div.variable_divert_name = target_str
			} else {
				div.target_path = target_str
			}
			if _, has_cond := obj["c"]; has_cond {
				div.is_conditional = true
			}
			if div.is_external {
				if v, ok := obj["exArgs"]; ok {
					if n, n_ok := v.(json.Integer); n_ok {
						div.external_args = int(n)
					}
				}
			}
			return new_object(div)
		}
	}

	// Choice point: {"*": pathString, "flg": int}
	if v, ok := obj["*"]; ok {
		cp: Choice_Point
		if s, s_ok := v.(json.String); s_ok {
			cp.path_on_choice = string(s)
		}
		if flg_val, flg_ok := obj["flg"]; flg_ok {
			if n, n_ok := flg_val.(json.Integer); n_ok {
				cp.flags = choice_flags_from_bits(int(n))
			}
		}
		return new_object(cp)
	}

	// Variable reference: {"VAR?": name} or {"CNT?": pathStr}
	if v, ok := obj["VAR?"]; ok {
		if s, s_ok := v.(json.String); s_ok {
			return new_object(Variable_Reference{name = string(s)})
		}
	}
	if v, ok := obj["CNT?"]; ok {
		if s, s_ok := v.(json.String); s_ok {
			return new_object(Variable_Reference{path_for_count = string(s)})
		}
	}

	// Variable assignment: {"VAR=": name, "re"?: true} (global) or {"temp=": name}
	is_var_ass := false
	is_global := false
	var_name_val: json.Value
	if v, ok := obj["VAR="]; ok {
		is_var_ass = true
		is_global = true
		var_name_val = v
	} else if v, ok := obj["temp="]; ok {
		is_var_ass = true
		var_name_val = v
	}
	if is_var_ass {
		va: Variable_Assignment
		if s, s_ok := var_name_val.(json.String); s_ok {
			va.name = string(s)
		}
		va.is_global = is_global
		_, has_re := obj["re"]
		va.is_new_decl = !has_re
		return new_object(va)
	}

	// Legacy tag: {"#": "tag text"}
	if v, ok := obj["#"]; ok {
		if s, s_ok := v.(json.String); s_ok {
			return new_object(Tag{text = string(s)})
		}
	}

	// List value: {"list": {item: int, ...}, "origins"?: [name, ...]}
	if v, ok := obj["list"]; ok {
		if items_obj, items_ok := v.(json.Object); items_ok {
			lv: List_Value
			lv.value.items = make(map[List_Item]int)
			for key, val in items_obj {
				if n, n_ok := val.(json.Integer); n_ok {
					origin, item := split_list_item_key(key)
					lv.value.items[List_Item{origin_name = origin, item_name = item}] = int(n)
				}
			}
			if origins_val, origins_ok := obj["origins"]; origins_ok {
				if arr, arr_ok := origins_val.(json.Array); arr_ok {
					names := make([]string, len(arr))
					for n, i in arr {
						if s, s_ok := n.(json.String); s_ok {
							names[i] = string(s)
						}
					}
					lv.value.origin_names = names
				}
			}
			return new_object(lv)
		}
	}

	// Save-state-only: Choice (originalChoicePath / etc.). Not part of
	// compiled-story content; ignore here. Will be handled by save/load.

	return nil
}

@(private)
json_array_to_container :: proc(arr: json.Array) -> ^Object {
	if len(arr) == 0 {
		return new_object(Container{})
	}

	container_obj := new(Object)
	c := Container{}

	last := arr[len(arr) - 1]
	terminator, has_terminator := last.(json.Object)
	body_count := len(arr)
	if has_terminator {
		body_count -= 1
	}

	c.content = make([dynamic]^Object, 0, body_count)
	for i in 0 ..< body_count {
		child := json_token_to_object(arr[i])
		if child != nil {
			child.parent = container_obj
			append(&c.content, child)
		}
	}

	if has_terminator {
		c.named_only_content = make(map[string]^Object)
		for key, val in terminator {
			switch key {
			case "#f":
				if n, ok := val.(json.Integer); ok {
					c.flags = container_flags_from_bits(int(n))
				}
			case "#n":
				if s, ok := val.(json.String); ok {
					c.name = string(s)
				}
			case:
				named_child := json_token_to_object(val)
				if named_child != nil {
					named_child.parent = container_obj
					if sub_container, is_container := &named_child.variant.(Container); is_container {
						sub_container.name = key
					}
					c.named_only_content[key] = named_child
				}
			}
		}
	}

	container_obj.variant = c
	return container_obj
}

// ---- Lookups --------------------------------------------------------------

@(private)
control_command_from_name :: proc(s: string) -> (Control_Command, bool) {
	switch s {
	case "ev":        return .Eval_Start, true
	case "out":       return .Eval_Output, true
	case "/ev":       return .Eval_End, true
	case "du":        return .Duplicate, true
	case "pop":       return .Pop_Evaluated_Value, true
	case "~ret":      return .Pop_Function, true
	case "->->":      return .Pop_Tunnel, true
	case "str":       return .Begin_String, true
	case "/str":      return .End_String, true
	case "nop":       return .No_Op, true
	case "choiceCnt": return .Choice_Count, true
	case "turn":      return .Turns, true
	case "turns":     return .Turns_Since, true
	case "readc":     return .Read_Count, true
	case "rnd":       return .Random, true
	case "srnd":      return .Seed_Random, true
	case "visit":     return .Visit_Index, true
	case "seq":       return .Sequence_Shuffle_Index, true
	case "thread":    return .Start_Thread, true
	case "done":      return .Done, true
	case "end":       return .End, true
	case "listInt":   return .List_From_Int, true
	case "range":     return .List_Range, true
	case "lrnd":      return .List_Random, true
	case "#":         return .Begin_Tag, true
	case "/#":        return .End_Tag, true
	}
	return .No_Op, false
}

@(private)
container_flags_from_bits :: proc(bits: int) -> Container_Flags {
	flags: Container_Flags
	if bits & 0x1 != 0 do flags += {.Visits}
	if bits & 0x2 != 0 do flags += {.Turns}
	if bits & 0x4 != 0 do flags += {.Count_Start_Only}
	return flags
}

@(private)
choice_flags_from_bits :: proc(bits: int) -> Choice_Flags {
	flags: Choice_Flags
	if bits & 0x1  != 0 do flags += {.Has_Condition}
	if bits & 0x2  != 0 do flags += {.Has_Start_Content}
	if bits & 0x4  != 0 do flags += {.Has_Choice_Only_Content}
	if bits & 0x8  != 0 do flags += {.Is_Invisible_Default}
	if bits & 0x10 != 0 do flags += {.Once_Only}
	return flags
}

@(private)
split_list_item_key :: proc(key: string) -> (origin: string, item: string) {
	dot := strings.index_byte(key, '.')
	if dot < 0 {
		return "", key
	}
	return key[:dot], key[dot + 1:]
}
