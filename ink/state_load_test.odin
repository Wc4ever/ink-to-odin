package ink

import "core:strings"
import "core:testing"

// Round-trip: state_to_json → state_load_json → state_to_json must be byte
// identical. If the load path drops a field or changes a representation, the
// second snapshot drifts.
@(test)
test_state_load_round_trip_initial :: proc(t: ^testing.T) {
	story: Compiled_Story
	if err := compiled_story_load(&story, string(INTERCEPT_JSON_BYTES)); err != .None {
		testing.fail_now(t, "load failed")
	}
	defer compiled_story_destroy(&story)

	state1: Story_State
	if !story_state_init(&state1, &story) do testing.fail_now(t, "story_state_init failed (state1)")
	defer story_state_destroy(&state1)

	first := state_to_json(&state1)
	defer delete(first)

	state2: Story_State
	if !story_state_init(&state2, &story) do testing.fail_now(t, "story_state_init failed (state2)")
	defer story_state_destroy(&state2)

	if err := state_load_json(&state2, first); err != .None {
		testing.expectf(t, false, "state_load_json failed: %v", err)
		return
	}

	second_a := state_to_json(&state2)
	defer delete(second_a)

	testing.expect_value(t, second_a, first)
}

// Mid-playthrough round-trip: drive a few turns, snapshot, load into a fresh
// state, snapshot again — both JSONs must match. Catches load bugs in the
// callstack / output stream / choice paths that the initial-state test misses.
@(test)
test_state_load_round_trip_mid_play :: proc(t: ^testing.T) {
	story: Compiled_Story
	if err := compiled_story_load(&story, string(INTERCEPT_JSON_BYTES)); err != .None {
		testing.fail_now(t, "load failed")
	}
	defer compiled_story_destroy(&story)

	state1: Story_State
	if !story_state_init(&state1, &story) do testing.fail_now(t, "init failed (state1)")
	defer story_state_destroy(&state1)

	// Drive two turns of "always pick choice 0" so we end up parked at a
	// non-trivial choice point with output stream + callstack populated.
	for turn in 0 ..< 2 {
		buf := strings.builder_make()
		defer strings.builder_destroy(&buf)
		for story_state_can_continue(&state1) {
			ok := story_continue(&state1)
			txt := story_current_text(&state1)
			strings.write_string(&buf, txt)
			delete(txt)
			if !ok do break
		}
		if len(story_current_choices(&state1)) == 0 do break
		if !story_choose_choice_index(&state1, 0) {
			testing.expectf(t, false, "turn %d pick failed", turn)
			return
		}
	}

	first := state_to_json(&state1)
	defer delete(first)

	state2: Story_State
	if !story_state_init(&state2, &story) do testing.fail_now(t, "init failed (state2)")
	defer story_state_destroy(&state2)

	if err := state_load_json(&state2, first); err != .None {
		testing.expectf(t, false, "state_load_json failed: %v", err)
		return
	}

	second := state_to_json(&state2)
	defer delete(second)

	testing.expect_value(t, second, first)
}

// Save/resume integration: drive partway, snapshot; then either keep playing
// the original state OR load the snapshot into a fresh state and play that
// further. Both branches must converge on the same final-state JSON. Catches
// load bugs that round-tripping alone won't surface (e.g. dangling pointers
// inside callstack elements, broken thread-at-generation refs in choices).
@(test)
test_state_load_save_then_resume :: proc(t: ^testing.T) {
	story: Compiled_Story
	if err := compiled_story_load(&story, string(INTERCEPT_JSON_BYTES)); err != .None {
		testing.fail_now(t, "load failed")
	}
	defer compiled_story_destroy(&story)

	drive_n_turns :: proc(s: ^Story_State, n: int) -> bool {
		for turn in 0 ..< n {
			for story_state_can_continue(s) {
				ok := story_continue(s)
				txt := story_current_text(s)
				delete(txt)
				if !ok do break
			}
			if len(story_current_choices(s)) == 0 do return true
			if !story_choose_choice_index(s, 0) do return false
		}
		return true
	}

	drain_text :: proc(s: ^Story_State) {
		for story_state_can_continue(s) {
			ok := story_continue(s)
			txt := story_current_text(s)
			delete(txt)
			if !ok do break
		}
	}

	// Original: drive 3 turns, snapshot, drive 3 more turns, drain to halt.
	original: Story_State
	if !story_state_init(&original, &story) do testing.fail_now(t, "init failed (original)")
	defer story_state_destroy(&original)

	if !drive_n_turns(&original, 3) do testing.fail_now(t, "drive 3 turns failed")
	mid_save := state_to_json(&original)
	defer delete(mid_save)

	if !drive_n_turns(&original, 3) do testing.fail_now(t, "post-save drive failed")
	drain_text(&original)
	original_final := state_to_json(&original)
	defer delete(original_final)

	// Resumed: fresh state, load the mid-save, drive 3 more turns from there.
	resumed: Story_State
	if !story_state_init(&resumed, &story) do testing.fail_now(t, "init failed (resumed)")
	defer story_state_destroy(&resumed)
	if err := state_load_json(&resumed, mid_save); err != .None {
		testing.expectf(t, false, "state_load_json failed: %v", err)
		return
	}
	if !drive_n_turns(&resumed, 3) do testing.fail_now(t, "post-load drive failed")
	drain_text(&resumed)
	resumed_final := state_to_json(&resumed)
	defer delete(resumed_final)

	testing.expect_value(t, resumed_final, original_final)
}
