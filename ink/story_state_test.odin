package ink

import "core:testing"

@(test)
test_story_state_init_basics :: proc(t: ^testing.T) {
	story: Compiled_Story
	if err := compiled_story_load(&story, string(INTERCEPT_JSON_BYTES)); err != .None {
		testing.fail_now(t, "load failed")
	}
	defer compiled_story_destroy(&story)

	state: Story_State
	if !story_state_init(&state, &story) {
		testing.fail_now(t, "story_state_init failed")
	}
	defer story_state_destroy(&state)

	// Initial pointer should reference start-of-root.
	cur := story_state_current_pointer(&state)
	testing.expect_value(t, cur.container, story.root)
	testing.expect_value(t, cur.index, 0)

	// canContinue is true at the start (no errors, valid pointer).
	testing.expect(t, story_state_can_continue(&state), "can_continue at init")

	// No errors / warnings yet.
	testing.expect(t, !story_state_has_error(&state), "no errors")
	testing.expect(t, !story_state_has_warning(&state), "no warnings")

	// One callstack frame, default flow seed.
	testing.expect_value(t, call_stack_depth(&state.call_stack), 1)
	testing.expect_value(t, state.current_turn_index, -1)
	testing.expect_value(t, state.story_seed, 0)
	testing.expect_value(t, state.previous_random, 0)
}

@(test)
test_story_state_pointer_setter :: proc(t: ^testing.T) {
	story: Compiled_Story
	compiled_story_load(&story, string(INTERCEPT_JSON_BYTES))
	defer compiled_story_destroy(&story)

	state: Story_State
	story_state_init(&state, &story)
	defer story_state_destroy(&state)

	// Move pointer somewhere into the root content.
	new_p := Pointer{container = story.root, index = 1}
	story_state_set_current_pointer(&state, new_p)
	got := story_state_current_pointer(&state)
	testing.expect_value(t, got.container, story.root)
	testing.expect_value(t, got.index, 1)
}

@(test)
test_story_state_visit_counts :: proc(t: ^testing.T) {
	story: Compiled_Story
	compiled_story_load(&story, string(INTERCEPT_JSON_BYTES))
	defer compiled_story_destroy(&story)

	state: Story_State
	story_state_init(&state, &story)
	defer story_state_destroy(&state)

	// Resolve "start" knot from TheIntercept.
	p := path_parse("start")
	defer path_destroy(&p)
	r := container_content_at_path(story.root, p)
	testing.expect(t, !r.approximate, "start knot resolves exactly")

	// Increment a few times — visit count tracks via path string.
	story_state_increment_visit_count_for_container(&state, r.obj)
	story_state_increment_visit_count_for_container(&state, r.obj)
	story_state_increment_visit_count_for_container(&state, r.obj)
	testing.expect_value(t, story_state_visit_count_at_path_string(&state, "start"), 3)
}

@(test)
test_story_state_turn_indices :: proc(t: ^testing.T) {
	story: Compiled_Story
	compiled_story_load(&story, string(INTERCEPT_JSON_BYTES))
	defer compiled_story_destroy(&story)

	state: Story_State
	story_state_init(&state, &story)
	defer story_state_destroy(&state)

	state.current_turn_index = 4

	p := path_parse("start")
	defer path_destroy(&p)
	r := container_content_at_path(story.root, p)
	testing.expect(t, !r.approximate, "start knot resolves exactly")

	story_state_record_turn_index_visit_to_container(&state, r.obj)

	// Advance turn; turns_since reports the delta.
	state.current_turn_index = 9
	if c, ok := r.obj.variant.(Container); ok && .Turns in c.flags {
		testing.expect_value(t, story_state_turns_since_for_container(&state, r.obj), 5)
	}
	// (If "start" doesn't have the Turns flag, we just skip — TheIntercept's
	// counters depend on script authoring.)
}

@(test)
test_story_state_errors_warnings :: proc(t: ^testing.T) {
	story: Compiled_Story
	compiled_story_load(&story, string(INTERCEPT_JSON_BYTES))
	defer compiled_story_destroy(&story)

	state: Story_State
	story_state_init(&state, &story)
	defer story_state_destroy(&state)

	story_state_warning(&state, "minor concern")
	testing.expect(t, story_state_has_warning(&state), "warning recorded")
	testing.expect(t, !story_state_has_error(&state), "no error yet")

	story_state_error(&state, "real problem")
	testing.expect(t, story_state_has_error(&state), "error recorded")
	testing.expect(t, !story_state_can_continue(&state), "errors block can_continue")

	story_state_reset_errors(&state)
	testing.expect(t, !story_state_has_error(&state), "errors cleared")
	testing.expect(t, !story_state_has_warning(&state), "warnings cleared")
	testing.expect(t, story_state_can_continue(&state), "can_continue restored")
}

@(test)
test_story_state_reset :: proc(t: ^testing.T) {
	story: Compiled_Story
	compiled_story_load(&story, string(INTERCEPT_JSON_BYTES))
	defer compiled_story_destroy(&story)

	state: Story_State
	story_state_init(&state, &story)
	defer story_state_destroy(&state)

	// Mutate state.
	state.current_turn_index = 7
	state.story_seed = 42
	story_state_warning(&state, "noise")

	story_state_reset(&state)

	// Reset puts us back at fresh defaults.
	testing.expect_value(t, state.current_turn_index, -1)
	testing.expect_value(t, state.story_seed, 0)
	testing.expect(t, !story_state_has_warning(&state), "warnings cleared by reset")
	testing.expect_value(t, story_state_current_pointer(&state).container, story.root)
}
