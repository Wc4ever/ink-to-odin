package ink

import "core:strings"

// Output_Stream: ordered buffer of objects emitted by the evaluator,
// resolved into the player-visible TEXT and TAGS that the consumer sees.
//
// Mirrors the output-stream half of ink-engine-runtime/StoryState.cs.
//
// Key behaviours:
//   - Head/tail whitespace splitting on appended strings: leading and
//     trailing newlines are extracted as their own String_Value entries so
//     glue and function-trim logic can operate on them individually.
//   - Glue ("<>") chomps any trailing whitespace from the stream.
//   - Function frames trim leading and trailing whitespace around their
//     own output; we record where the function started in the stream and
//     trim back when non-whitespace finally arrives.
//   - Tag content is bracketed by Begin_Tag / End_Tag control commands;
//     legacy Tag objects exist for older saves.
//
// Ownership: Output_Stream owns its [dynamic]^Object buffer. The Object
// values it stores are NOT owned — they're either compiled-story content
// or runtime-created values that live in some other allocator (the runtime
// arena that backs evaluator-produced values). Some operations need an
// allocator argument because they synthesize new String_Value Objects when
// splitting head/tail whitespace.

Output_Stream :: struct {
	stream: [dynamic]^Object,
}

// ---- Lifecycle ------------------------------------------------------------

output_stream_init :: proc(s: ^Output_Stream) {
	s.stream = make([dynamic]^Object, 0, 16)
}

output_stream_destroy :: proc(s: ^Output_Stream) {
	delete(s.stream)
	s.stream = nil
}

output_stream_reset :: proc(s: ^Output_Stream, init_objs: []^Object = nil) {
	clear(&s.stream)
	for o in init_objs {
		append(&s.stream, o)
	}
}

// ---- Public push / pop ----------------------------------------------------

// Append an object. For String_Values, leading/trailing newlines are split
// out so subsequent glue/function-trim logic can drop them individually.
//
// `cs` is consulted for the current function frame's start-of-output marker
// (used to trim around game-side function calls). It may be nil when the
// caller knows no function trimming applies (e.g. tests).
//
// `runtime_alloc` is used for the synthetic String_Values produced by
// head/tail splitting. Pass the runtime arena that backs evaluator-emitted
// objects so the new Object^s outlive this call.
output_stream_push :: proc(s: ^Output_Stream, obj: ^Object, cs: ^Call_Stack, runtime_alloc := context.allocator) {
	if obj == nil do return

	if sv, ok := obj.variant.(String_Value); ok {
		split, did_split := try_splitting_head_tail_whitespace(sv.value, runtime_alloc)
		if did_split {
			for piece in split {
				push_to_output_stream_individual(s, piece, cs)
			}
			return
		}
	}
	push_to_output_stream_individual(s, obj, cs)
}

output_stream_pop :: proc(s: ^Output_Stream, count: int) {
	n := count
	if n > len(s.stream) do n = len(s.stream)
	resize(&s.stream, len(s.stream) - n)
}

// ---- State queries --------------------------------------------------------

output_stream_ends_in_newline :: proc(s: ^Output_Stream) -> bool {
	for i := len(s.stream) - 1; i >= 0; i -= 1 {
		obj := s.stream[i]
		if _, is_cmd := obj.variant.(Control_Command); is_cmd do return false
		if sv, is_str := obj.variant.(String_Value); is_str {
			if string_value_is_newline(sv) do return true
			if string_value_is_non_whitespace(sv) do return false
		}
	}
	return false
}

output_stream_contains_content :: proc(s: ^Output_Stream) -> bool {
	for obj in s.stream {
		if _, is_str := obj.variant.(String_Value); is_str do return true
	}
	return false
}

output_stream_in_string_evaluation :: proc(s: ^Output_Stream) -> bool {
	for i := len(s.stream) - 1; i >= 0; i -= 1 {
		if cmd, ok := s.stream[i].variant.(Control_Command); ok && cmd == .Begin_String {
			return true
		}
	}
	return false
}

// ---- Derived: current text / current tags --------------------------------

// Concatenates all String_Value content NOT inside a Begin_Tag/End_Tag
// section, then runs CleanOutputWhitespace. Caller owns the returned string.
output_stream_current_text :: proc(s: ^Output_Stream, allocator := context.allocator) -> string {
	context.allocator = allocator
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	in_tag := false
	for obj in s.stream {
		if cmd, is_cmd := obj.variant.(Control_Command); is_cmd {
			if cmd == .Begin_Tag {
				in_tag = true
			} else if cmd == .End_Tag {
				in_tag = false
			}
			continue
		}
		if in_tag do continue
		if sv, is_str := obj.variant.(String_Value); is_str {
			strings.write_string(&b, sv.value)
		}
	}

	return clean_output_whitespace(strings.to_string(b), allocator)
}

// Tags come from two sources, both supported here:
//   - Legacy Tag objects (older format): each Tag.text becomes one tag, as-is.
//   - New-style: text between Begin_Tag and End_Tag control commands is
//     accumulated, whitespace-cleaned, and emitted as one tag per pair.
output_stream_current_tags :: proc(s: ^Output_Stream, allocator := context.allocator) -> []string {
	context.allocator = allocator

	tags := make([dynamic]string, 0, 4)
	in_tag := false
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	for obj in s.stream {
		if cmd, is_cmd := obj.variant.(Control_Command); is_cmd {
			if cmd == .Begin_Tag {
				// A Begin_Tag mid-section flushes the prior accumulated tag.
				if in_tag && strings.builder_len(b) > 0 {
					append(&tags, clean_output_whitespace(strings.to_string(b), allocator))
					strings.builder_reset(&b)
				}
				in_tag = true
			} else if cmd == .End_Tag {
				if strings.builder_len(b) > 0 {
					append(&tags, clean_output_whitespace(strings.to_string(b), allocator))
					strings.builder_reset(&b)
				}
				in_tag = false
			}
			continue
		}
		if in_tag {
			if sv, is_str := obj.variant.(String_Value); is_str {
				strings.write_string(&b, sv.value)
			}
			continue
		}
		// Outside a tag section: pick up legacy Tag objects.
		if tag, is_tag := obj.variant.(Tag); is_tag && len(tag.text) > 0 {
			append(&tags, strings.clone(tag.text, allocator))
		}
	}

	// Trailing dangling Begin_Tag with no End_Tag — flush whatever is buffered.
	if strings.builder_len(b) > 0 {
		append(&tags, clean_output_whitespace(strings.to_string(b), allocator))
	}

	return tags[:]
}

// ---- Whitespace cleanup ---------------------------------------------------

// Mirrors CleanOutputWhitespace: collapses runs of inline space/tab into a
// single space, trims runs adjacent to newlines and to start-of-line, but
// preserves newlines themselves and non-whitespace characters.
clean_output_whitespace :: proc(input: string, allocator := context.allocator) -> string {
	context.allocator = allocator
	b := strings.builder_make_len_cap(0, len(input))

	current_ws_start := -1
	start_of_line := 0

	for i in 0 ..< len(input) {
		c := input[i]
		is_inline_ws := c == ' ' || c == '\t'

		if is_inline_ws && current_ws_start == -1 {
			current_ws_start = i
		}

		if !is_inline_ws {
			if c != '\n' && current_ws_start > 0 && current_ws_start != start_of_line {
				strings.write_byte(&b, ' ')
			}
			current_ws_start = -1
		}

		if c == '\n' {
			start_of_line = i + 1
		}

		if !is_inline_ws {
			strings.write_byte(&b, c)
		}
	}

	return strings.to_string(b)
}

// ---- Internals: head/tail split -------------------------------------------

// Splits leading and trailing whitespace blocks containing newlines into
// their own String_Values so they can be trimmed individually. Returns
// (split_pieces, true) when splitting occurred, otherwise ({}, false).
@(private)
try_splitting_head_tail_whitespace :: proc(str: string, runtime_alloc := context.allocator) -> ([]^Object, bool) {
	head_first_nl := -1
	head_last_nl  := -1
	for i in 0 ..< len(str) {
		c := str[i]
		if c == '\n' {
			if head_first_nl == -1 do head_first_nl = i
			head_last_nl = i
		} else if c == ' ' || c == '\t' {
			continue
		} else {
			break
		}
	}

	tail_last_nl  := -1
	tail_first_nl := -1
	for i := len(str) - 1; i >= 0; i -= 1 {
		c := str[i]
		if c == '\n' {
			if tail_last_nl == -1 do tail_last_nl = i
			tail_first_nl = i
		} else if c == ' ' || c == '\t' {
			continue
		} else {
			break
		}
	}

	if head_first_nl == -1 && tail_last_nl == -1 do return nil, false

	pieces := make([dynamic]^Object, 0, 4, runtime_alloc)
	inner_start := 0
	inner_end   := len(str)

	if head_first_nl != -1 {
		if head_first_nl > 0 {
			append(&pieces, mk_string_value(str[:head_first_nl], runtime_alloc))
		}
		append(&pieces, mk_string_value("\n", runtime_alloc))
		inner_start = head_last_nl + 1
	}
	if tail_last_nl != -1 {
		inner_end = tail_first_nl
	}
	if inner_end > inner_start {
		append(&pieces, mk_string_value(str[inner_start:inner_end], runtime_alloc))
	}
	if tail_last_nl != -1 && tail_first_nl > head_last_nl {
		append(&pieces, mk_string_value("\n", runtime_alloc))
		if tail_last_nl < len(str) - 1 {
			append(&pieces, mk_string_value(str[tail_last_nl + 1:], runtime_alloc))
		}
	}
	return pieces[:], true
}

@(private)
mk_string_value :: proc(s: string, allocator := context.allocator) -> ^Object {
	o := new(Object, allocator)
	o.variant = String_Value{value = s}
	return o
}

// ---- Internals: per-object push (glue, function-trim, dedup newlines) ----

@(private)
push_to_output_stream_individual :: proc(s: ^Output_Stream, obj: ^Object, cs: ^Call_Stack) {
	include := true

	if _, is_glue := obj.variant.(Glue); is_glue {
		trim_newlines_from_output_stream(s)
		// Glue itself is included so future strings can find it.
	} else if sv, is_str := obj.variant.(String_Value); is_str {
		// Find the nearest function-frame start (or -1 if not inside a
		// function frame in the current thread).
		function_trim_index := -1
		if cs != nil {
			cur := call_stack_current_element(cs)
			if cur != nil && cur.type == .Function {
				function_trim_index = cur.function_start_in_output_stream
			}
		}

		// Walk back: latest glue beats earlier function-trim, but a
		// Begin_String control command stops both (we're in string eval).
		glue_trim_index := -1
		for i := len(s.stream) - 1; i >= 0; i -= 1 {
			o := s.stream[i]
			if _, is_g := o.variant.(Glue); is_g {
				glue_trim_index = i
				break
			}
			if cmd, is_cmd := o.variant.(Control_Command); is_cmd && cmd == .Begin_String {
				if i >= function_trim_index do function_trim_index = -1
				break
			}
		}

		trim_index := -1
		switch {
		case glue_trim_index != -1 && function_trim_index != -1:
			trim_index = min(glue_trim_index, function_trim_index)
		case glue_trim_index != -1:
			trim_index = glue_trim_index
		case:
			trim_index = function_trim_index
		}

		if trim_index != -1 {
			if string_value_is_newline(sv) {
				include = false
			} else if string_value_is_non_whitespace(sv) {
				if glue_trim_index > -1 do remove_existing_glue(s)

				// Tell every active function frame that real text has now
				// been emitted, so leading-whitespace trimming stops.
				if function_trim_index > -1 && cs != nil {
					t := call_stack_current_thread(cs)
					if t != nil {
						for i := len(t.callstack) - 1; i >= 0; i -= 1 {
							el := &t.callstack[i]
							if el.type == .Function {
								el.function_start_in_output_stream = -1
							} else {
								break
							}
						}
					}
				}
			}
		} else if string_value_is_newline(sv) {
			// Outside any trim window: dedup leading + consecutive newlines.
			if output_stream_ends_in_newline(s) || !output_stream_contains_content(s) {
				include = false
			}
		}
	}

	if include {
		append(&s.stream, obj)
	}
}

@(private)
trim_newlines_from_output_stream :: proc(s: ^Output_Stream) {
	remove_from := -1
	i := len(s.stream) - 1
	for i >= 0 {
		obj := s.stream[i]
		if _, is_cmd := obj.variant.(Control_Command); is_cmd do break
		if sv, is_str := obj.variant.(String_Value); is_str {
			if string_value_is_non_whitespace(sv) do break
			if string_value_is_newline(sv) do remove_from = i
		}
		i -= 1
	}

	if remove_from >= 0 {
		// Remove every String_Value at or after remove_from (skip non-strings).
		j := remove_from
		for j < len(s.stream) {
			if _, is_str := s.stream[j].variant.(String_Value); is_str {
				ordered_remove(&s.stream, j)
			} else {
				j += 1
			}
		}
	}
}

@(private)
remove_existing_glue :: proc(s: ^Output_Stream) {
	for i := len(s.stream) - 1; i >= 0; i -= 1 {
		o := s.stream[i]
		if _, is_glue := o.variant.(Glue); is_glue {
			ordered_remove(&s.stream, i)
		} else if _, is_cmd := o.variant.(Control_Command); is_cmd {
			break
		}
	}
}

// ---- String value predicates ----------------------------------------------

@(private)
string_value_is_newline :: proc(sv: String_Value) -> bool {
	return sv.value == "\n"
}

@(private)
string_value_is_non_whitespace :: proc(sv: String_Value) -> bool {
	for i in 0 ..< len(sv.value) {
		c := sv.value[i]
		if c != ' ' && c != '\t' && c != '\n' do return true
	}
	return false
}
