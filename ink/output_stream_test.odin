package ink

import "core:mem/virtual"
import "core:testing"

// All the helpers below allocate from context.allocator (the test arena).

@(private = "file")
str_obj :: proc(s: string) -> ^Object {
	o := new(Object)
	o.variant = String_Value{value = s}
	return o
}

@(private = "file")
glue_obj :: proc() -> ^Object {
	o := new(Object)
	o.variant = Glue{}
	return o
}

@(private = "file")
cmd_obj :: proc(c: Control_Command) -> ^Object {
	o := new(Object)
	o.variant = c
	return o
}

@(private = "file")
tag_obj :: proc(text: string) -> ^Object {
	o := new(Object)
	o.variant = Tag{text = text}
	return o
}

// ---- whitespace cleanup --------------------------------------------------

@(test)
test_clean_output_whitespace :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"hello", "hello"},
		{"   hello", "hello"},
		{"hello   ", "hello"},
		{"   hello   ", "hello"},
		{"a   b", "a b"},
		{"a\tb",   "a b"},
		{"a\nb",   "a\nb"},
		{"a   \nb",   "a\nb"}, // trailing inline ws before \n drops
		{"\n  \nhello", "\n\nhello"},
	}
	for c in cases {
		got := clean_output_whitespace(c[0])
		defer delete(got)
		testing.expect_value(t, got, c[1])
	}
}

// ---- push: simple appends -------------------------------------------------

@(test)
test_push_basic :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	os: Output_Stream
	output_stream_init(&os)
	defer output_stream_destroy(&os)

	output_stream_push(&os, str_obj("hello "), nil)
	output_stream_push(&os, str_obj("world"), nil)
	txt := output_stream_current_text(&os)
	testing.expect_value(t, txt, "hello world")
}

// Leading newline is dropped (no preceding content), and consecutive newlines
// dedup. Trailing newlines are kept unless trimmed by glue.
@(test)
test_push_dedup_newlines :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	os: Output_Stream
	output_stream_init(&os)
	defer output_stream_destroy(&os)

	// Two leading newlines: first one is dropped (no content yet), second
	// is dropped (would lead with newline).
	output_stream_push(&os, str_obj("\n"), nil)
	output_stream_push(&os, str_obj("\n"), nil)
	output_stream_push(&os, str_obj("hi"), nil)
	output_stream_push(&os, str_obj("\n"), nil)
	output_stream_push(&os, str_obj("\n"), nil) // dedup
	txt := output_stream_current_text(&os)
	testing.expect_value(t, txt, "hi\n")
}

// Glue between two strings collapses any trailing whitespace that came
// before it.
@(test)
test_push_glue_eats_trailing_whitespace :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	os: Output_Stream
	output_stream_init(&os)
	defer output_stream_destroy(&os)

	output_stream_push(&os, str_obj("foo"), nil)
	output_stream_push(&os, str_obj("\n"), nil)
	output_stream_push(&os, glue_obj(), nil)
	output_stream_push(&os, str_obj("bar"), nil)

	txt := output_stream_current_text(&os)
	testing.expect_value(t, txt, "foobar")
}

// ---- head/tail split -----------------------------------------------------

@(test)
test_head_tail_split :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	os: Output_Stream
	output_stream_init(&os)
	defer output_stream_destroy(&os)

	// "  hello world\n" — leading inline ws + non-leading newline at tail.
	// Head: no \n, so nothing splits at the head. Tail: trailing \n splits.
	output_stream_push(&os, str_obj("  hello world\n"), nil)

	txt := output_stream_current_text(&os)
	// Leading "  " collapses since it's at start-of-line.
	testing.expect_value(t, txt, "hello world\n")
}

// ---- query helpers --------------------------------------------------------

@(test)
test_ends_in_newline_and_contains_content :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	os: Output_Stream
	output_stream_init(&os)
	defer output_stream_destroy(&os)

	testing.expect(t, !output_stream_ends_in_newline(&os), "empty -> false")
	testing.expect(t, !output_stream_contains_content(&os), "empty -> no content")

	output_stream_push(&os, str_obj("hi"), nil)
	testing.expect(t, output_stream_contains_content(&os), "has content after string")
	testing.expect(t, !output_stream_ends_in_newline(&os), "doesn't end in newline yet")

	output_stream_push(&os, str_obj("\n"), nil)
	testing.expect(t, output_stream_ends_in_newline(&os), "now ends in newline")
}

// ---- tags -----------------------------------------------------------------

@(test)
test_current_tags_legacy :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	os: Output_Stream
	output_stream_init(&os)
	defer output_stream_destroy(&os)

	output_stream_push(&os, tag_obj("first"), nil)
	output_stream_push(&os, str_obj("body"), nil)
	output_stream_push(&os, tag_obj("second"), nil)

	tags := output_stream_current_tags(&os)
	testing.expect_value(t, len(tags), 2)
	testing.expect_value(t, tags[0], "first")
	testing.expect_value(t, tags[1], "second")

	// current_text excludes tag content.
	txt := output_stream_current_text(&os)
	testing.expect_value(t, txt, "body")
}

@(test)
test_current_tags_new_style :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	os: Output_Stream
	output_stream_init(&os)
	defer output_stream_destroy(&os)

	// Stream: text "body" then BEGIN_TAG "  hello  world  " END_TAG
	output_stream_push(&os, str_obj("body"), nil)
	output_stream_push(&os, cmd_obj(.Begin_Tag), nil)
	output_stream_push(&os, str_obj("  hello  world  "), nil)
	output_stream_push(&os, cmd_obj(.End_Tag), nil)

	tags := output_stream_current_tags(&os)
	testing.expect_value(t, len(tags), 1)
	testing.expect_value(t, tags[0], "hello world")

	txt := output_stream_current_text(&os)
	testing.expect_value(t, txt, "body")
}

// ---- function-trim integration -------------------------------------------

@(test)
test_function_trim_leading_whitespace :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// Set up a call_stack with a Function frame whose function_start_in_output_stream
	// is set to where the function's output begins.
	root := new(Object)
	root.variant = Container{}
	cs: Call_Stack
	call_stack_init(&cs, root)
	defer call_stack_destroy(&cs)

	os: Output_Stream
	output_stream_init(&os)
	defer output_stream_destroy(&os)

	// Outside the function, push some text.
	output_stream_push(&os, str_obj("outside"), &cs)

	// Push a Function frame and record its starting index.
	call_stack_push(&cs, .Function)
	call_stack_current_element(&cs).function_start_in_output_stream = len(os.stream)

	// Inside the function, the leading newline is trimmed by the function-
	// frame mechanism. (Non-newline whitespace is left to clean_output_whitespace.)
	output_stream_push(&os, str_obj("\n"), &cs)
	output_stream_push(&os, str_obj("body"), &cs)
	output_stream_push(&os, str_obj("\n"), &cs)

	txt := output_stream_current_text(&os)
	testing.expect_value(t, txt, "outsidebody\n")
}
