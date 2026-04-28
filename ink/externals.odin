package ink

import "base:runtime"
import "core:fmt"

// EXTERNAL function bindings — host-side callbacks invoked from ink.
//
// Mirrors C# Story.BindExternalFunction / CallExternalFunction. Bindings are
// registered on the Story_State (so they survive reset and follow the same
// arena lifecycle), and the evaluator dispatches to them when it hits an
// `is_external` divert. If a name has no binding and
// `allow_external_function_fallbacks` is true, the runtime instead diverts
// to a same-named knot — letting authors write the fallback in ink.
//
// Polling-only consumer API: there are no async callbacks. The bound
// procedure runs synchronously, may return at most one value (Object_Variant),
// and must not call back into the story.

External_Args :: []^Object

// `args` borrows pointers from the eval stack — read-only during the call.
// `alloc` is the story's runtime arena allocator: bindings should use it to
// allocate any returned ^Object so the value lives as long as the story.
// Return nil for void; non-nil values must be Int/Float/Bool/String/List
// values (the only kinds that can survive on the eval stack).
External_Function :: #type proc(args: External_Args, user_data: rawptr, alloc: runtime.Allocator) -> ^Object

External_Binding :: struct {
	fn:             External_Function,
	user_data:      rawptr,
	lookahead_safe: bool,
}

story_bind_external :: proc(
	s: ^Story_State,
	name: string,
	fn: External_Function,
	user_data: rawptr = nil,
	lookahead_safe: bool = true,
) {
	if s.externals == nil do s.externals = make(map[string]External_Binding)
	s.externals[name] = External_Binding{fn = fn, user_data = user_data, lookahead_safe = lookahead_safe}
}

story_unbind_external :: proc(s: ^Story_State, name: string) {
	if s.externals == nil do return
	delete_key(&s.externals, name)
}

// Verifies every EXTERNAL declaration in the compiled story has either a
// binding or a same-named ink fallback knot. Returns the missing names.
// Executes an `is_external` divert. Mirrors C# Story.CallExternalFunction.
// Returns true (we always consume the divert; on error we still return true
// so the step doesn't fall through to default content handling).
@(private)
execute_external_call :: proc(s: ^Story_State, d: Divert) -> bool {
	name := d.target_path
	bound, has_binding := s.externals[name]

	if has_binding {
		// Lookahead-safe gating, mirroring C# Story.CallExternalFunction:
		//
		//  1. Inside string evaluation (e.g. choice text, "{f()}" interpolation)
		//     an unsafe function can't run at all — the snapshot rewind path
		//     isn't designed to undo string-eval state. Error out.
		//
		//  2. Past a newline-snapshot, defer the call: setting the
		//     saw-lookahead-unsafe flag tells story_continue to rewind to the
		//     snapshot so the function runs once, post-newline, on the next
		//     Continue.
		if !bound.lookahead_safe && output_stream_in_string_evaluation(&s.output_stream) {
			story_state_error(s, fmt.tprintf(
				"external '%s' isn't lookahead-safe and can't run during string evaluation; bind it as lookahead-safe or wrap the call in a temp variable",
				name))
			return true
		}
		if !bound.lookahead_safe && s.snapshot_at_last_newline_exists {
			s.saw_lookahead_unsafe_function_after_newline = true
			return true
		}

		// Pop arguments, reverse to source order.
		alloc := story_state_runtime_allocator(s)
		args := make([]^Object, d.external_args, alloc)
		for i := d.external_args - 1; i >= 0; i -= 1 {
			args[i] = eval_stack_pop(s)
		}
		result := bound.fn(args, bound.user_data, alloc)
		if result == nil {
			void_obj := new(Object, alloc)
			void_obj.variant = Void{}
			eval_stack_push(s, void_obj)
		} else {
			eval_stack_push(s, result)
		}
		return true
	}

	// Fallback: divert into a same-named ink knot, pushing a Function frame
	// so `~ return` returns to the caller.
	if !s.allow_external_function_fallbacks {
		story_state_error(s,
			fmt.tprintf("external function '%s' is unbound and fallbacks are disabled", name))
		return true
	}

	root, is_root := s.compiled_story.root.variant.(Container)
	if !is_root {
		story_state_error(s, "story root is not a container")
		return true
	}
	fallback_obj, found := root.named_only_content[name]
	if !found {
		story_state_error(s,
			fmt.tprintf("external function '%s' has no binding and no ink fallback knot", name))
		return true
	}

	call_stack_push(&s.call_stack, .Function, output_stream_length_with_pushed = len(s.output_stream.stream))
	s.diverted_pointer = pointer_start_of(fallback_obj)
	return true
}

story_validate_external_bindings :: proc(s: ^Story_State, allocator := context.allocator) -> []string {
	missing := make([dynamic]string, 0, 0, allocator)
	if s.compiled_story == nil do return missing[:]

	root, is_root := s.compiled_story.root.variant.(Container)
	if !is_root do return missing[:]

	walk_externals :: proc(c: Container, s: ^Story_State, missing: ^[dynamic]string, allocator: runtime.Allocator) {
		for child in c.content {
			if d, is_d := child.variant.(Divert); is_d && d.is_external {
				name := d.target_path
				if _, bound := s.externals[name]; bound do continue
				root, is_r := s.compiled_story.root.variant.(Container)
				if is_r && s.allow_external_function_fallbacks {
					if _, has_fallback := root.named_only_content[name]; has_fallback do continue
				}
				append(missing, name)
			}
			if cc, is_c := child.variant.(Container); is_c do walk_externals(cc, s, missing, allocator)
		}
		for _, named in c.named_only_content {
			if cc, is_c := named.variant.(Container); is_c do walk_externals(cc, s, missing, allocator)
		}
	}
	walk_externals(root, s, &missing, allocator)
	return missing[:]
}
