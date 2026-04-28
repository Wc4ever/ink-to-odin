package ink

import "core:encoding/json"
import "core:mem"
import "core:strconv"

// Load a previously-saved Story_State from the JSON produced by state_to_json
// (or by inkle's reference state.ToJson()). Mirrors StoryState.LoadJson.
//
// state_load_json overlays onto a state that's already been initialized from
// the same Compiled_Story — defaults from the global decl block stay in
// place; this only restores the *changes* and the runtime-mutable state.
//
// Usage:
//   state: Story_State
//   story_state_init(&state, &story)        // runs global decl, snapshots defaults
//   state_load_json(&state, saved_json)     // overlays saved variable values etc.

State_Load_Error :: enum {
	None,
	Parse_Failed,
	Bad_Top_Level,
	Missing_Save_Version,
	Save_Version_Too_Old,
	Missing_Flows,
	Bad_Flow,
	Bad_Pointer,
}

state_load_json :: proc(s: ^Story_State, json_text: string) -> State_Load_Error {
	val, parse_err := json.parse_string(
		json_text,
		spec = .JSON5,
		parse_integers = true,
		allocator = context.temp_allocator,
	)
	if parse_err != .None do return .Parse_Failed

	top, top_ok := val.(json.Object)
	if !top_ok do return .Bad_Top_Level

	// Save version check.
	ver_val, has_ver := top["inkSaveVersion"]
	if !has_ver do return .Missing_Save_Version
	if v, ok := ver_val.(json.Integer); ok {
		if int(v) < 8 do return .Save_Version_Too_Old
	} else {
		return .Missing_Save_Version
	}

	// Reset every flow back to a clean slate.
	for _, &flow in s.inactive_flows do flow_destroy(&flow)
	clear(&s.inactive_flows)
	for &t in s.call_stack.threads do call_stack_thread_destroy(&t)
	clear(&s.call_stack.threads)
	for &c in s.current_choices do choice_destroy(&c)
	clear(&s.current_choices)
	clear(&s.eval_stack)
	clear(&s.output_stream.stream)
	clear(&s.visit_counts)
	clear(&s.turn_indices)
	s.diverted_pointer = POINTER_NULL
	s.current_flow_name = DEFAULT_FLOW_NAME

	// Flows. The active flow is identified by currentFlowName; every other
	// entry under `flows` is loaded into inactive_flows.
	flows_val, has_flows := top["flows"]
	if !has_flows do return .Missing_Flows
	flows_obj, flows_ok := flows_val.(json.Object)
	if !flows_ok do return .Missing_Flows

	target_current := DEFAULT_FLOW_NAME
	if cfn, has_cfn := top["currentFlowName"]; has_cfn {
		if str, ok := cfn.(json.String); ok do target_current = string(str)
	}

	// Load each flow by switching to it (which creates the flow if missing
	// and parks the previous one in inactive_flows), then loading per-flow
	// data into the active slot. Process the active flow LAST so it ends
	// up in the active fields.
	flow_names := make([dynamic]string, 0, len(flows_obj), context.temp_allocator)
	for n in flows_obj do append(&flow_names, n)
	for n in flow_names {
		if n == target_current do continue
		flow_obj, ok := flows_obj[n].(json.Object)
		if !ok do return .Bad_Flow
		story_switch_flow(s, n)
		err := load_flow_into_state(s, flow_obj)
		if err != .None do return err
	}
	if active_obj, ok := flows_obj[target_current].(json.Object); ok {
		story_switch_flow(s, target_current)
		err := load_flow_into_state(s, active_obj)
		if err != .None do return err
	} else if len(flow_names) == 0 {
		return .Bad_Flow
	}

	// Variables: overlay values from JSON onto existing globals; defaults
	// remain. Variables not present in the save keep their default.
	if vs_val, ok := top["variablesState"]; ok {
		if vs_obj, vs_ok := vs_val.(json.Object); vs_ok {
			for k, v in vs_obj {
				obj := json_token_to_runtime_object(s, v)
				if obj != nil {
					s.variables_state.globals[k] = obj
				}
			}
		}
	}

	// Eval stack.
	if es_val, ok := top["evalStack"]; ok {
		if arr, arr_ok := es_val.(json.Array); arr_ok {
			for item in arr {
				if obj := json_token_to_runtime_object(s, item); obj != nil {
					append(&s.eval_stack, obj)
				}
			}
		}
	}

	// Current divert target (optional).
	if dt_val, ok := top["currentDivertTarget"]; ok {
		if path_str, str_ok := dt_val.(json.String); str_ok {
			s.diverted_pointer = story_pointer_at_path_string(s, string(path_str))
		}
	}

	// Visit / turn count maps.
	load_int_dict_into(s, top, "visitCounts", &s.visit_counts)
	load_int_dict_into(s, top, "turnIndices", &s.turn_indices)

	// Scalars.
	if v, ok := top["turnIdx"];         ok { if n, ok2 := v.(json.Integer); ok2 do s.current_turn_index = int(n) }
	if v, ok := top["storySeed"];       ok { if n, ok2 := v.(json.Integer); ok2 do s.story_seed         = int(n) }
	if v, ok := top["previousRandom"];  ok { if n, ok2 := v.(json.Integer); ok2 do s.previous_random    = int(n) }

	return .None
}

// ---- Internals ------------------------------------------------------------

@(private)
load_flow_into_state :: proc(s: ^Story_State, flow_obj: json.Object) -> State_Load_Error {
	// Clear active flow's per-flow data before populating from JSON. Required
	// because story_switch_flow (which the caller may have just used to create
	// a fresh slot) initializes the flow with a default thread / empty stream
	// that we need to overwrite, not append to.
	for &t in s.call_stack.threads do call_stack_thread_destroy(&t)
	clear(&s.call_stack.threads)
	for &c in s.current_choices do choice_destroy(&c)
	clear(&s.current_choices)
	clear(&s.output_stream.stream)

	// callstack: { threadCounter, threads: [...] }
	if cs_val, ok := flow_obj["callstack"]; ok {
		if cs_obj, cs_ok := cs_val.(json.Object); cs_ok {
			if tc, has_tc := cs_obj["threadCounter"]; has_tc {
				if n, ok := tc.(json.Integer); ok do s.call_stack.thread_counter = int(n)
			}
			if threads_val, has_threads := cs_obj["threads"]; has_threads {
				if threads_arr, arr_ok := threads_val.(json.Array); arr_ok {
					for tj in threads_arr {
						if t_obj, t_ok := tj.(json.Object); t_ok {
							thread, terr := load_thread(s, t_obj)
							if terr != .None do return terr
							append(&s.call_stack.threads, thread)
						}
					}
				}
			}
		}
	}

	// outputStream (after callstack so previous-pointer resolution works).
	if os_val, ok := flow_obj["outputStream"]; ok {
		if arr, arr_ok := os_val.(json.Array); arr_ok {
			for item in arr {
				if obj := json_token_to_runtime_object(s, item); obj != nil {
					append(&s.output_stream.stream, obj)
				}
			}
		}
	}

	// currentChoices: array of saved-state Choice objects.
	if cc_val, ok := flow_obj["currentChoices"]; ok {
		if arr, arr_ok := cc_val.(json.Array); arr_ok {
			for item in arr {
				if c_obj, c_ok := item.(json.Object); c_ok {
					choice := load_choice(s, c_obj)
					append(&s.current_choices, choice)
				}
			}
		}
	}

	// choiceThreads: map of "<index>" -> thread, for choices whose forked
	// thread is no longer active. Attach to matching Choices.
	if ct_val, ok := flow_obj["choiceThreads"]; ok {
		if ct_obj, ct_ok := ct_val.(json.Object); ct_ok {
			for k, v in ct_obj {
				idx, parsed := strconv.parse_int(k, 10)
				if !parsed do continue
				t_obj, t_ok := v.(json.Object)
				if !t_ok do continue
				thread, terr := load_thread(s, t_obj)
				if terr != .None do return terr
				attached := false
				for &c in s.current_choices {
					if c.original_thread_index == idx {
						call_stack_thread_destroy(&c.thread_at_generation)
						c.thread_at_generation = thread
						attached = true
						break
					}
				}
				if !attached do call_stack_thread_destroy(&thread)
			}
		}
	}

	// Choices whose original_thread_index matches an *active* thread copy
	// that one (matches Flow.LoadFlowChoiceThreads behaviour).
	for &c in s.current_choices {
		if c.thread_at_generation.callstack != nil do continue
		t := call_stack_thread_with_index(&s.call_stack, c.original_thread_index)
		if t != nil do c.thread_at_generation = call_stack_thread_copy(t)
	}

	return .None
}

@(private)
load_thread :: proc(s: ^Story_State, obj: json.Object) -> (Call_Stack_Thread, State_Load_Error) {
	t := Call_Stack_Thread {
		callstack        = make([dynamic]Call_Stack_Element, 0, 4),
		previous_pointer = POINTER_NULL,
	}

	if ti_val, ok := obj["threadIndex"]; ok {
		if n, ok2 := ti_val.(json.Integer); ok2 do t.thread_index = int(n)
	}

	if cs_val, ok := obj["callstack"]; ok {
		if arr, arr_ok := cs_val.(json.Array); arr_ok {
			for el_v in arr {
				if el_obj, el_ok := el_v.(json.Object); el_ok {
					el := load_callstack_element(s, el_obj)
					append(&t.callstack, el)
				}
			}
		}
	}

	// previousContentObject: a path to the resolved previous_pointer's object.
	if prev_val, ok := obj["previousContentObject"]; ok {
		if path_str, ps_ok := prev_val.(json.String); ps_ok {
			t.previous_pointer = story_pointer_at_path_string(s, string(path_str))
		}
	}

	return t, .None
}

@(private)
load_callstack_element :: proc(s: ^Story_State, obj: json.Object) -> Call_Stack_Element {
	el := Call_Stack_Element {
		current_pointer     = POINTER_NULL,
		temporary_variables = make(map[string]^Object),
	}

	// cPath presence (even empty "") signals "this element has a pointer".
	// "" resolves to the root container.
	cpath_v, has_cpath := obj["cPath"]
	if has_cpath {
		cpath, _ := cpath_v.(json.String)
		idx := 0
		if v, ok := obj["idx"]; ok {
			if n, n_ok := v.(json.Integer); n_ok do idx = int(n)
		}
		container: ^Object
		if len(string(cpath)) == 0 {
			container = s.compiled_story.root
		} else {
			r := container_content_at_path(
				s.compiled_story.root,
				path_parse(string(cpath), story_state_runtime_allocator(s)),
			)
			container = r.obj
		}
		if container != nil {
			el.current_pointer = Pointer{container = container, index = idx}
		}
	}

	if v, ok := obj["exp"]; ok {
		if b, b_ok := v.(json.Boolean); b_ok do el.in_expression_evaluation = bool(b)
	}
	if v, ok := obj["type"]; ok {
		if n, n_ok := v.(json.Integer); n_ok {
			switch int(n) {
			case 0: el.type = .Tunnel
			case 1: el.type = .Function
			case 2: el.type = .Function_Evaluation_From_Game
			}
		}
	}
	if v, ok := obj["temp"]; ok {
		if temp_obj, temp_ok := v.(json.Object); temp_ok {
			for k, val in temp_obj {
				if rt := json_token_to_runtime_object(s, val); rt != nil {
					el.temporary_variables[k] = rt
				}
			}
		}
	}
	return el
}

@(private)
load_choice :: proc(s: ^Story_State, obj: json.Object) -> Choice {
	c := Choice{}
	if v, ok := obj["text"]; ok {
		if str, str_ok := v.(json.String); str_ok do c.text = string(str)
	}
	if v, ok := obj["index"]; ok {
		if n, n_ok := v.(json.Integer); n_ok do c.index = int(n)
	}
	if v, ok := obj["originalChoicePath"]; ok {
		if str, str_ok := v.(json.String); str_ok do c.source_path = string(str)
	}
	if v, ok := obj["targetPath"]; ok {
		if str, str_ok := v.(json.String); str_ok do c.target_path = string(str)
	}
	if v, ok := obj["originalThreadIndex"]; ok {
		if n, n_ok := v.(json.Integer); n_ok do c.original_thread_index = int(n)
	}
	if v, ok := obj["tags"]; ok {
		if arr, arr_ok := v.(json.Array); arr_ok {
			tags := make([]string, len(arr))
			for tag_v, i in arr {
				if str, str_ok := tag_v.(json.String); str_ok do tags[i] = string(str)
			}
			c.tags = tags
		}
	}
	return c
}

@(private)
load_int_dict_into :: proc(s: ^Story_State, top: json.Object, key: string, dst: ^map[string]int) {
	v, ok := top[key]
	if !ok do return
	obj, obj_ok := v.(json.Object)
	if !obj_ok do return
	for k, val in obj {
		if n, n_ok := val.(json.Integer); n_ok {
			// Clone key into runtime arena so it outlives the temp_allocator-held parse.
			alloc := story_state_runtime_allocator(s)
			bytes := make([]byte, len(k), alloc)
			copy(bytes, transmute([]byte)k)
			dst[string(bytes)] = int(n)
		}
	}
}

// Reverse of write_runtime_object — rebuilds an Object value from its JSON
// encoding. Allocates from the runtime arena so it survives past parse.
@(private)
json_token_to_runtime_object :: proc(s: ^Story_State, tok: json.Value) -> ^Object {
	alloc := story_state_runtime_allocator(s)
	switch v in tok {
	case json.Null:
		return nil
	case json.Boolean:
		o := new(Object, alloc)
		o.variant = Bool_Value{value = bool(v)}
		return o
	case json.Integer:
		o := new(Object, alloc)
		o.variant = Int_Value{value = i64(v)}
		return o
	case json.Float:
		o := new(Object, alloc)
		o.variant = Float_Value{value = f64(v)}
		return o
	case json.String:
		return parse_runtime_string(s, string(v))
	case json.Array:
		// Containers in state are rare; punt to nil for v1.
		return nil
	case json.Object:
		return parse_runtime_object_dict(s, v)
	}
	return nil
}

@(private)
parse_runtime_string :: proc(s: ^Story_State, str: string) -> ^Object {
	alloc := story_state_runtime_allocator(s)
	if len(str) == 0 {
		o := new(Object, alloc)
		o.variant = String_Value{value = ""}
		return o
	}
	if str[0] == '^' {
		// Clone the slice into the runtime arena so it doesn't depend on the
		// temp parse buffer.
		body := str[1:]
		bytes := make([]byte, len(body), alloc)
		copy(bytes, transmute([]byte)body)
		o := new(Object, alloc)
		o.variant = String_Value{value = string(bytes)}
		return o
	}
	if str == "\n" {
		o := new(Object, alloc)
		o.variant = String_Value{value = "\n"}
		return o
	}
	if str == "<>" {
		o := new(Object, alloc)
		o.variant = Glue{}
		return o
	}
	if str == "void" {
		o := new(Object, alloc)
		o.variant = Void{}
		return o
	}
	if cmd, ok := control_command_from_name(str); ok {
		o := new(Object, alloc)
		o.variant = cmd
		return o
	}
	// Native function — clone the name (with "L^" → "^" remap).
	name := str
	if name == "L^" do name = "^"
	bytes := make([]byte, len(name), alloc)
	copy(bytes, transmute([]byte)name)
	o := new(Object, alloc)
	o.variant = Native_Function_Call{name = string(bytes)}
	return o
}

@(private)
parse_runtime_object_dict :: proc(s: ^Story_State, obj: json.Object) -> ^Object {
	alloc := story_state_runtime_allocator(s)

	clone_str :: proc(str: string, alloc: mem.Allocator) -> string {
		bytes := make([]byte, len(str), alloc)
		copy(bytes, transmute([]byte)str)
		return string(bytes)
	}

	if v, ok := obj["^->"]; ok {
		if str, ok2 := v.(json.String); ok2 {
			o := new(Object, alloc)
			o.variant = Divert_Target_Value{target = clone_str(string(str), alloc)}
			return o
		}
	}
	if v, ok := obj["^var"]; ok {
		if name, ok2 := v.(json.String); ok2 {
			ctx_idx := -1
			if ci, ci_ok := obj["ci"]; ci_ok {
				if n, n_ok := ci.(json.Integer); n_ok do ctx_idx = int(n)
			}
			o := new(Object, alloc)
			o.variant = Variable_Pointer_Value{name = clone_str(string(name), alloc), context_index = ctx_idx}
			return o
		}
	}
	if v, ok := obj["#"]; ok {
		if str, ok2 := v.(json.String); ok2 {
			o := new(Object, alloc)
			o.variant = Tag{text = clone_str(string(str), alloc)}
			return o
		}
	}
	// List value: {"list": {"Origin.Item": value, ...}, "origins"?: [...]}
	if v, ok := obj["list"]; ok {
		if items_obj, items_ok := v.(json.Object); items_ok {
			lv: List_Value
			lv.value.items = make(map[List_Item]int, allocator = alloc)
			for key, val in items_obj {
				if n, n_ok := val.(json.Integer); n_ok {
					origin, item := split_list_item_key(key)
					lv.value.items[List_Item{
						origin_name = clone_str(origin, alloc),
						item_name   = clone_str(item, alloc),
					}] = int(n)
				}
			}
			if origins_val, origins_ok := obj["origins"]; origins_ok {
				if arr, arr_ok := origins_val.(json.Array); arr_ok {
					names := make([]string, len(arr), alloc)
					for n, i in arr {
						if str, str_ok := n.(json.String); str_ok {
							names[i] = clone_str(string(str), alloc)
						}
					}
					lv.value.origin_names = names
				}
			}
			o := new(Object, alloc)
			o.variant = lv
			return o
		}
	}
	// Other compiled-tree variants (Divert, ChoicePoint, VariableReference,
	// VariableAssignment) shouldn't normally appear in saved state
	// outputstream / evalstack. Fall through to nil if they do.
	return nil
}
