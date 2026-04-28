package ink

import "base:runtime"
import "core:strings"
import "core:testing"

// Reuse the externals fixture (compiled .ink.json baked into the binary).
EXTERNALS_JSON_BYTES        :: #load("../tests/fixtures/externals/Externals.ink.json")
EXTERNAL_UNSAFE_JSON_BYTES  :: #load("../tests/fixtures/external_unsafe/ExternalUnsafe.ink.json")

// Binding takes precedence over the ink fallback. We override `greet` with a
// host callback that returns a string the fallback never produces, then drain
// text once and assert the override fired.
@(test)
test_external_binding_overrides_fallback :: proc(t: ^testing.T) {
	story: Compiled_Story
	if err := compiled_story_load(&story, string(EXTERNALS_JSON_BYTES)); err != .None {
		testing.fail_now(t, "load failed")
	}
	defer compiled_story_destroy(&story)

	state: Story_State
	if !story_state_init(&state, &story) do testing.fail_now(t, "init failed")
	defer story_state_destroy(&state)
	state.allow_external_function_fallbacks = true

	greet_override :: proc(args: External_Args, user_data: rawptr, alloc: runtime.Allocator) -> ^Object {
		o := new(Object, alloc)
		o.variant = String_Value{value = "OVERRIDDEN_GREETING"}
		return o
	}
	story_bind_external(&state, "greet", greet_override)

	// Drain to first choice. Output should contain our override but not the
	// fallback's "Hello," text.
	all := strings.builder_make()
	defer strings.builder_destroy(&all)
	for story_state_can_continue(&state) {
		ok := story_continue(&state)
		txt := story_current_text(&state)
		strings.write_string(&all, txt)
		delete(txt)
		if !ok do break
	}
	out := strings.to_string(all)
	testing.expectf(t, strings.contains(out, "OVERRIDDEN_GREETING"), "override fired; got %q", out)
	testing.expectf(t, !strings.contains(out, "Hello, hero"), "fallback should not run when bound; got %q", out)
}

// Multi-arg binding: `classify(score)` is wired to a host callback that just
// echoes the int it received. Verifies arg passing in source order.
@(test)
test_external_binding_receives_args :: proc(t: ^testing.T) {
	story: Compiled_Story
	if err := compiled_story_load(&story, string(EXTERNALS_JSON_BYTES)); err != .None {
		testing.fail_now(t, "load failed")
	}
	defer compiled_story_destroy(&story)

	state: Story_State
	if !story_state_init(&state, &story) do testing.fail_now(t, "init failed")
	defer story_state_destroy(&state)
	state.allow_external_function_fallbacks = true

	got_score: i64 = -999
	classify_capture :: proc(args: External_Args, user_data: rawptr, alloc: runtime.Allocator) -> ^Object {
		captured := cast(^i64)user_data
		if len(args) > 0 {
			if iv, ok := args[0].variant.(Int_Value); ok do captured^ = iv.value
		}
		o := new(Object, alloc)
		o.variant = String_Value{value = "captured"}
		return o
	}
	story_bind_external(&state, "classify", classify_capture, &got_score)

	// Drive: drain text, pick choice 1 (Score 9), drain again to land on the
	// "Score 9 grade: ..." line — that's where classify(9) gets called.
	drain :: proc(s: ^Story_State) {
		for story_state_can_continue(s) {
			ok := story_continue(s)
			delete(story_current_text(s))
			if !ok do break
		}
	}
	drain(&state)
	if !story_choose_choice_index(&state, 1) do testing.fail_now(t, "pick failed")
	drain(&state)

	testing.expect_value(t, got_score, 9)
}

// Lookahead-unsafe binding gets deferred until after the newline-snapshot
// resolves. With fx() bound as not-lookahead-safe and called between two
// text lines, the first Continue() must NOT invoke fx (snapshot is pending);
// the second Continue() runs from the restored snapshot and invokes it once.
@(test)
test_external_binding_lookahead_unsafe_defers :: proc(t: ^testing.T) {
	story: Compiled_Story
	if err := compiled_story_load(&story, string(EXTERNAL_UNSAFE_JSON_BYTES)); err != .None {
		testing.fail_now(t, "load failed")
	}
	defer compiled_story_destroy(&story)

	state: Story_State
	if !story_state_init(&state, &story) do testing.fail_now(t, "init failed")
	defer story_state_destroy(&state)

	calls := 0
	fx_count :: proc(args: External_Args, user_data: rawptr, alloc: runtime.Allocator) -> ^Object {
		c := cast(^int)user_data
		c^ += 1
		// Return Void.
		o := new(Object, alloc)
		o.variant = Void{}
		return o
	}
	story_bind_external(&state, "fx", fx_count, &calls, lookahead_safe = false)

	// Continue 1: produces "Line 1.\n". fx() is reached during lookahead but
	// deferred — so calls must still be 0 here.
	if !story_continue(&state) do testing.fail_now(t, "continue 1 failed")
	t1 := story_current_text(&state)
	defer delete(t1)
	testing.expect_value(t, t1, "Line 1.\n")
	testing.expectf(t, calls == 0, "fx must be deferred during lookahead; got %d calls", calls)

	// Continue 2: from the restored snapshot, fx fires (no snapshot now), and
	// "Line 2." is produced.
	if !story_continue(&state) do testing.fail_now(t, "continue 2 failed")
	t2 := story_current_text(&state)
	defer delete(t2)
	testing.expect_value(t, t2, "Line 2.\n")
	testing.expect_value(t, calls, 1)
}
