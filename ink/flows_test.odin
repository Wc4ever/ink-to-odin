package ink

import "core:slice"
import "core:strings"
import "core:testing"

// Multi-flow tests. Reuse Api.ink as a generic two-knot story; flows are a
// runtime construct so the .ink file doesn't need to know about them.

@(private = "file")
load_for_flow_test :: proc(t: ^testing.T, story: ^Compiled_Story, state: ^Story_State) {
	if err := compiled_story_load(story, string(API_JSON_BYTES)); err != .None {
		testing.fail_now(t, "load failed")
	}
	if !story_state_init(state, story) do testing.fail_now(t, "init failed")
}

@(private = "file")
drain :: proc(s: ^Story_State, out: ^strings.Builder) {
	for story_state_can_continue(s) {
		ok := story_continue(s)
		txt := story_current_text(s)
		strings.write_string(out, txt)
		delete(txt)
		if !ok do break
	}
}

// Initial state: one flow ("DEFAULT_FLOW") active, zero inactive.
@(test)
test_flow_initial_state :: proc(t: ^testing.T) {
	story: Compiled_Story
	state: Story_State
	load_for_flow_test(t, &story, &state)
	defer compiled_story_destroy(&story)
	defer story_state_destroy(&state)

	testing.expect_value(t, story_current_flow_name(&state), DEFAULT_FLOW_NAME)
	names := story_alive_flow_names(&state)
	defer delete(names)
	testing.expect_value(t, len(names), 1)
}

// switch_flow creates a fresh flow on first reference and switching back to
// the previous one preserves its state.
@(test)
test_flow_switch_creates_and_preserves :: proc(t: ^testing.T) {
	story: Compiled_Story
	state: Story_State
	load_for_flow_test(t, &story, &state)
	defer compiled_story_destroy(&story)
	defer story_state_destroy(&state)

	// Drive default flow through the intro line. After this, default flow
	// should have non-empty output / one pending choice.
	main_buf := strings.builder_make()
	defer strings.builder_destroy(&main_buf)
	drain(&state, &main_buf)
	main_text := strings.to_string(main_buf)
	testing.expect(t, strings.contains(main_text, "score 7"), "default flow ran intro")
	testing.expect_value(t, len(story_current_choices(&state)), 1)

	// Switch to a new flow ("bard"). Its initial state is fresh: one frame at
	// root start, no choices, no output yet — and globals are SHARED with the
	// default flow (score = 7).
	story_switch_flow(&state, "bard")
	testing.expect_value(t, story_current_flow_name(&state), "bard")
	testing.expect_value(t, len(story_current_choices(&state)), 0)
	score, _ := story_get_variable_int(&state, "score")
	testing.expect_value(t, score, 7) // shared globals

	// Drive bard flow — it sees the same story content, runs intro again.
	bard_buf := strings.builder_make()
	defer strings.builder_destroy(&bard_buf)
	drain(&state, &bard_buf)
	testing.expect(t, strings.contains(strings.to_string(bard_buf), "score 7"), "bard flow ran intro")
	testing.expect_value(t, len(story_current_choices(&state)), 1)

	// Switch back to default. Its choice should still be pending (the bard
	// drive didn't disturb default's per-flow state).
	story_switch_to_default_flow(&state)
	testing.expect_value(t, story_current_flow_name(&state), DEFAULT_FLOW_NAME)
	testing.expect_value(t, len(story_current_choices(&state)), 1)

	names := story_alive_flow_names(&state)
	defer delete(names)
	testing.expect_value(t, len(names), 2)
	testing.expect(t, slice.contains(names, DEFAULT_FLOW_NAME))
	testing.expect(t, slice.contains(names, "bard"))
}

// remove_flow drops an inactive flow; refuses to drop the active one or default.
@(test)
test_flow_remove :: proc(t: ^testing.T) {
	story: Compiled_Story
	state: Story_State
	load_for_flow_test(t, &story, &state)
	defer compiled_story_destroy(&story)
	defer story_state_destroy(&state)

	story_switch_flow(&state, "side")
	story_switch_to_default_flow(&state)

	// Remove the inactive "side" flow.
	testing.expect(t, story_remove_flow(&state, "side"), "remove side")

	// Removing a non-existent flow returns false.
	testing.expect(t, !story_remove_flow(&state, "side"), "double remove fails")

	// Active flow can't be removed.
	testing.expect(t, !story_remove_flow(&state, DEFAULT_FLOW_NAME), "active flow can't be removed")

	// Default flow can never be removed even if not active.
	story_switch_flow(&state, "another")
	testing.expect(t, !story_remove_flow(&state, DEFAULT_FLOW_NAME), "default flow refused")
}

// Save/load round-trip with two flows. JSON of two saves taken from the same
// state via state_to_json → state_load_json → state_to_json must match
// byte-for-byte.
@(test)
test_flow_round_trip :: proc(t: ^testing.T) {
	story: Compiled_Story
	state1: Story_State
	load_for_flow_test(t, &story, &state1)
	defer compiled_story_destroy(&story)
	defer story_state_destroy(&state1)

	// Drive default a step, set up a "bard" flow, leave default active.
	buf := strings.builder_make()
	defer strings.builder_destroy(&buf)
	drain(&state1, &buf)
	story_switch_flow(&state1, "bard")
	bard_buf := strings.builder_make()
	defer strings.builder_destroy(&bard_buf)
	drain(&state1, &bard_buf)
	story_switch_to_default_flow(&state1)

	first := state_to_json(&state1)
	defer delete(first)
	testing.expect(t, strings.contains(first, "\"bard\":"), "bard appears in JSON")
	testing.expect(t, strings.contains(first, "\"DEFAULT_FLOW\":"), "default appears in JSON")

	// Fresh state, load.
	state2: Story_State
	if !story_state_init(&state2, &story) do testing.fail_now(t, "init state2 failed")
	defer story_state_destroy(&state2)
	if err := state_load_json(&state2, first); err != .None {
		testing.expectf(t, false, "load failed: %v", err)
		return
	}

	// Both flows should be present, default active.
	testing.expect_value(t, story_current_flow_name(&state2), DEFAULT_FLOW_NAME)
	names := story_alive_flow_names(&state2)
	defer delete(names)
	testing.expect_value(t, len(names), 2)
	testing.expect(t, slice.contains(names, "bard"))

	// Re-serialize and assert byte-equality.
	second := state_to_json(&state2)
	defer delete(second)
	testing.expect_value(t, second, first)
}
