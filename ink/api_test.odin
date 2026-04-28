package ink

import "core:slice"
import "core:strings"
import "core:testing"

API_JSON_BYTES :: #load("../tests/fixtures/api/Api.ink.json")

@(private = "file")
load_api :: proc(t: ^testing.T, story: ^Compiled_Story, state: ^Story_State) {
	if err := compiled_story_load(story, string(API_JSON_BYTES)); err != .None {
		testing.fail_now(t, "load failed")
	}
	if !story_state_init(state, story) {
		testing.fail_now(t, "init failed")
	}
}

@(test)
test_api_get_variables :: proc(t: ^testing.T) {
	story: Compiled_Story
	state: Story_State
	load_api(t, &story, &state)
	defer compiled_story_destroy(&story)
	defer story_state_destroy(&state)

	score, ok_s := story_get_variable_int(&state, "score")
	testing.expect(t, ok_s, "score readable")
	testing.expect_value(t, score, 7)

	name, ok_n := story_get_variable_string(&state, "player_name")
	testing.expect(t, ok_n, "player_name readable")
	testing.expect_value(t, name, "Hero")

	admin, ok_a := story_get_variable_bool(&state, "is_admin")
	testing.expect(t, ok_a, "is_admin readable")
	testing.expect_value(t, admin, false)

	// Unknown name → ok=false, no error pushed.
	_, ok_x := story_get_variable_int(&state, "nonexistent")
	testing.expect(t, !ok_x, "unknown variable returns ok=false")
	testing.expect(t, !story_state_has_error(&state), "lookup of unknown var must not error")
}

@(test)
test_api_set_variables :: proc(t: ^testing.T) {
	story: Compiled_Story
	state: Story_State
	load_api(t, &story, &state)
	defer compiled_story_destroy(&story)
	defer story_state_destroy(&state)

	testing.expect(t, story_set_variable_int(&state, "score", 42), "set score")
	got, ok := story_get_variable_int(&state, "score")
	testing.expect(t, ok, "re-read score")
	testing.expect_value(t, got, 42)

	testing.expect(t, story_set_variable_string(&state, "player_name", "Updated"), "set player_name")
	name, _ := story_get_variable_string(&state, "player_name")
	testing.expect_value(t, name, "Updated")

	testing.expect(t, story_set_variable_bool(&state, "is_admin", true), "set is_admin")
	admin, _ := story_get_variable_bool(&state, "is_admin")
	testing.expect_value(t, admin, true)

	// Setting an undeclared variable returns false (matches C# this[name] setter).
	testing.expect(t, !story_set_variable_int(&state, "nope", 1), "undeclared set fails")
}

@(test)
test_api_global_tags :: proc(t: ^testing.T) {
	story: Compiled_Story
	state: Story_State
	load_api(t, &story, &state)
	defer compiled_story_destroy(&story)
	defer story_state_destroy(&state)

	tags := story_global_tags(&state)
	defer delete(tags)

	testing.expect_value(t, len(tags), 3)
	if len(tags) >= 3 {
		testing.expect(t, slice.contains(tags, "title: Api Test"), "title tag")
		testing.expect(t, slice.contains(tags, "author: ink-to-odin"), "author tag")
		testing.expect(t, slice.contains(tags, "version: 1"), "version tag")
	}
}

@(test)
test_api_knot_tags :: proc(t: ^testing.T) {
	story: Compiled_Story
	state: Story_State
	load_api(t, &story, &state)
	defer compiled_story_destroy(&story)
	defer story_state_destroy(&state)

	tags := story_tags_at_path(&state, "intro")
	defer delete(tags)

	testing.expect_value(t, len(tags), 2)
	if len(tags) >= 2 {
		testing.expect(t, slice.contains(tags, "location: hub"), "location tag")
		testing.expect(t, slice.contains(tags, "difficulty: easy"), "difficulty tag")
	}
}

@(test)
test_api_errors_warnings :: proc(t: ^testing.T) {
	story: Compiled_Story
	state: Story_State
	load_api(t, &story, &state)
	defer compiled_story_destroy(&story)
	defer story_state_destroy(&state)

	testing.expect_value(t, len(story_errors(&state)), 0)
	testing.expect_value(t, len(story_warnings(&state)), 0)

	story_state_error(&state, "synthetic error")
	story_state_warning(&state, "synthetic warning")
	testing.expect_value(t, len(story_errors(&state)), 1)
	testing.expect_value(t, len(story_warnings(&state)), 1)

	story_clear_errors(&state)
	story_clear_warnings(&state)
	testing.expect_value(t, len(story_errors(&state)), 0)
	testing.expect_value(t, len(story_warnings(&state)), 0)
}

// End-to-end: set a global, run the story, observe the new value in output.
@(test)
test_api_set_then_run :: proc(t: ^testing.T) {
	story: Compiled_Story
	state: Story_State
	load_api(t, &story, &state)
	defer compiled_story_destroy(&story)
	defer story_state_destroy(&state)

	testing.expect(t, story_set_variable_int(&state, "score", 99), "set score=99")

	combined := strings.builder_make()
	defer strings.builder_destroy(&combined)
	for story_state_can_continue(&state) {
		ok := story_continue(&state)
		txt := story_current_text(&state)
		strings.write_string(&combined, txt)
		delete(txt)
		if !ok do break
	}
	out := strings.to_string(combined)
	testing.expectf(t, strings.contains(out, "score 99"), "output reflects set: %q", out)
}
