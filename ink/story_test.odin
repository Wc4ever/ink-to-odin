package ink

import "core:fmt"
import "core:strings"
import "core:testing"

// Helper: drive the story until it can no longer continue (parks at choices
// or the end). Concatenates current_text from each Continue into `out`.
@(private = "file")
drain_until_choice :: proc(s: ^Story_State, out: ^strings.Builder, max_iters := 64) {
	for i in 0 ..< max_iters {
		if !story_state_can_continue(s) do break
		ok := story_continue(s)
		txt := story_current_text(s)
		strings.write_string(out, txt)
		delete(txt)
		if !ok do break
	}
}

// First-turn milestone: TheIntercept loads, the global decl runs, the
// conditional branch picks the else case (DEBUG=false), and the runtime
// emits the opening gather line and presents one choice ("Hut 14").
@(test)
test_intercept_first_turn :: proc(t: ^testing.T) {
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

	combined := strings.builder_make()
	defer strings.builder_destroy(&combined)
	drain_until_choice(&state, &combined)

	all := strings.to_string(combined)
	testing.expect(t, strings.contains(all, "They are keeping me waiting"), "got opening gather text")
	testing.expect(t, !story_state_has_error(&state), "no errors during continuation")

	choices := story_current_choices(&state)
	testing.expect_value(t, len(choices), 1)
	if len(choices) == 1 {
		testing.expect_value(t, choices[0].text, "Hut 14")
	}
}

// "Always pick choice 0" exploration: drive the runtime as far as it goes,
// printing each turn's text and choice list. Useful for spotting the next
// stuck instruction. The test asserts no errors so we surface them clearly.
@(test)
test_intercept_drive :: proc(t: ^testing.T) {
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

	import_fmt :: 1 // just so the import is used in this scope
	_ = import_fmt

	for turn in 0 ..< 50 {
		buf := strings.builder_make()
		defer strings.builder_destroy(&buf)
		drain_until_choice(&state, &buf)

		choices := story_current_choices(&state)

		if state.current_errors != nil && len(state.current_errors) > 0 {
			testing.expectf(t, false, "turn %d errored: %v", turn, state.current_errors)
			return
		}
		if len(choices) == 0 do break

		if !story_choose_choice_index(&state, 0) {
			testing.expectf(t, false, "turn %d: choose_choice_index(0) failed", turn)
			return
		}
	}
}

_ :: fmt // keep import alive even though no test currently calls fmt.println

// Pins the byte-for-byte equivalence of the initial state JSON to the
// dotnet runner's STEP 0 block. If this drifts we want to know immediately.
@(test)
test_state_to_json_initial_matches_dotnet :: proc(t: ^testing.T) {
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

	got := state_to_json(&state)
	defer delete(got)

	// Hand-built expected output, pulled from the dotnet runner's golden
	// seed_0.log lines 7-40 (between STATE_JSON_BEGIN and STATE_JSON_END).
	want := `{
  "currentFlowName": "DEFAULT_FLOW",
  "evalStack": [],
  "flows": {
    "DEFAULT_FLOW": {
      "callstack": {
        "threadCounter": 0,
        "threads": [
          {
            "callstack": [
              {
                "cPath": "",
                "exp": false,
                "idx": 0,
                "type": 0
              }
            ],
            "threadIndex": 0
          }
        ]
      },
      "currentChoices": [],
      "outputStream": []
    }
  },
  "inkFormatVersion": 21,
  "inkSaveVersion": 10,
  "previousRandom": 0,
  "storySeed": 0,
  "turnIdx": -1,
  "turnIndices": {},
  "variablesState": {},
  "visitCounts": {}
}`
	testing.expect_value(t, got, want)
}

// Second-turn milestone: choosing "Hut 14" should transition past the choice
// point, emit the post-selection narration, and present the inner choices
// (Think/Plan/Divert/Wait per the .ink script).
@(test)
test_intercept_choose_first :: proc(t: ^testing.T) {
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

	combined := strings.builder_make()
	defer strings.builder_destroy(&combined)

	// Drain to first choice, then pick it.
	drain_until_choice(&state, &combined)
	if !story_choose_choice_index(&state, 0) {
		testing.fail_now(t, "story_choose_choice_index failed")
	}

	// Drain again to the next choice point.
	turn2_start := strings.builder_len(combined)
	drain_until_choice(&state, &combined)

	turn2_text := strings.to_string(combined)[turn2_start:]
	testing.expectf(t, !story_state_has_error(&state),
		"no errors after choosing; saw: %v", state.current_errors)
	testing.expectf(t, strings.contains(turn2_text, "The door was locked"),
		"post-choice narration emitted; got: %q", turn2_text)

	// The script presents [Think] [Plan] [Divert] [Wait] (4 inner choices)
	// once we reach the (opts) gather.
	choices := story_current_choices(&state)
	testing.expectf(t, len(choices) >= 1, "at least one inner choice presented; got %d", len(choices))
}
