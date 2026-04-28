package ink_test_runner_odin

import "core:fmt"
import "core:os"
import "core:strings"
import ink "../../ink"

// Odin counterpart to the dotnet ink-test-runner. Plays TheIntercept.ink.json
// under seeded random walks (seeds 0..9) and writes per-step logs in the
// same format as the dotnet runner so we can byte-diff the two.
//
// Format matches Program.cs lines 53-110:
//   SEED N
//   TURN_LIMIT M
//
//   === STEP K (label) ===
//   [OUTPUT "..."]
//   TAGS [...]
//   [ERROR/WARNING ...]
//   STATE_JSON_BEGIN
//   { ... sorted state JSON ... }
//   STATE_JSON_END
//
//   [CHOICES n
//     [i] "text" index=... pathOnChoice=... threadAtGen=...
//   PICK n]
//
//   ...
//
//   TOTAL_STEPS K
//   TURNS T
//   HALT_REASON {end_of_story|turn_limit}
//
// Outputs to ../../tests/golden/odin/seed_{0..9}.log (relative to cwd at
// invocation time).

SEED_COUNT :: 10
TURN_LIMIT :: 500
STORY_PATH :: "../../tests/fixtures/the_intercept/TheIntercept.ink.json"
LOGS_DIR   :: "../../tests/golden/odin"

main :: proc() {
	story_bytes, ok := os.read_entire_file(STORY_PATH)
	if !ok {
		fmt.eprintfln("could not read %s (run from tools/ink-test-runner-odin/)", STORY_PATH)
		os.exit(1)
	}
	defer delete(story_bytes)

	if !os.exists(LOGS_DIR) {
		if err := os.make_directory(LOGS_DIR); err != nil {
			fmt.eprintfln("could not create %s: %v", LOGS_DIR, err)
			os.exit(1)
		}
	}

	for seed in 0 ..< SEED_COUNT {
		log := run_seed(string(story_bytes), seed)
		defer delete(log)
		path := fmt.aprintf("%s/seed_%d.log", LOGS_DIR, seed)
		defer delete(path)
		if !os.write_entire_file(path, transmute([]byte)log) {
			fmt.eprintfln("could not write %s", path)
			os.exit(1)
		}
		fmt.printfln("Wrote %s", path)
	}
}

run_seed :: proc(story_json: string, seed: int) -> string {
	compiled: ink.Compiled_Story
	if err := ink.compiled_story_load(&compiled, story_json); err != .None {
		return fmt.aprintf("LOAD_FAILED: %v", err)
	}
	defer ink.compiled_story_destroy(&compiled)

	state: ink.Story_State
	if !ink.story_state_init(&state, &compiled) {
		return "STATE_INIT_FAILED"
	}
	defer ink.story_state_destroy(&state)

	state.story_seed = seed
	state.previous_random = 0

	pick_rng: Net_Random
	net_random_init(&pick_rng, seed)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintfln(&b, "SEED %d", seed)
	fmt.sbprintfln(&b, "TURN_LIMIT %d", TURN_LIMIT)
	fmt.sbprintln(&b)

	append_step(&b, 0, "initial", &state)
	step := 1
	turn := 0
	halt := "end_of_story"

	for turn < TURN_LIMIT {
		// Drain text
		for ink.story_state_can_continue(&state) {
			if !ink.story_continue(&state) do break
			fmt.sbprintfln(&b, "=== STEP %d (continue) ===", step)
			out := ink.story_current_text(&state)
			fmt.sbprintfln(&b, "OUTPUT %s", quote(out))
			delete(out)
			append_tags(&b, &state)
			append_errs(&b, &state)
			append_state_json(&b, &state)
			step += 1
			if ink.story_state_has_error(&state) do break
		}

		append_errs(&b, &state)

		choices := ink.story_current_choices(&state)
		if len(choices) == 0 {
			fmt.sbprintln(&b, "=== END ===")
			break
		}

		fmt.sbprintfln(&b, "CHOICES %d", len(choices))
		for c, i in choices {
			fmt.sbprintfln(
				&b, "  [%d] %s index=%d pathOnChoice=%s threadAtGen=%d",
				i, quote(c.text), c.index, c.target_path, c.original_thread_index,
			)
		}

		pick := net_random_next(&pick_rng) % len(choices)
		if pick < 0 do pick += len(choices)
		fmt.sbprintfln(&b, "PICK %d", pick)
		ink.story_choose_choice_index(&state, pick)
		turn += 1

		append_step(&b, step, "after_pick", &state)
		step += 1
	}

	if turn >= TURN_LIMIT {
		fmt.sbprintln(&b, "=== HALT_TURN_LIMIT ===")
		halt = "turn_limit"
	}

	fmt.sbprintln(&b)
	fmt.sbprintfln(&b, "TOTAL_STEPS %d", step - 1)
	fmt.sbprintfln(&b, "TURNS %d", turn)
	fmt.sbprintfln(&b, "HALT_REASON %s", halt)
	return strings.clone(strings.to_string(b))
}

append_step :: proc(b: ^strings.Builder, step: int, label: string, s: ^ink.Story_State) {
	fmt.sbprintfln(b, "=== STEP %d (%s) ===", step, label)
	append_tags(b, s)
	append_errs(b, s)
	append_state_json(b, s)
}

append_tags :: proc(b: ^strings.Builder, s: ^ink.Story_State) {
	tags := ink.story_current_tags(s)
	defer delete(tags)
	if len(tags) == 0 {
		fmt.sbprintln(b, "TAGS []")
		return
	}
	fmt.sbprint(b, "TAGS [")
	for tag, i in tags {
		if i > 0 do fmt.sbprint(b, ", ")
		fmt.sbprint(b, quote(tag))
	}
	fmt.sbprintln(b, "]")
}

append_errs :: proc(b: ^strings.Builder, s: ^ink.Story_State) {
	for e in s.current_errors do fmt.sbprintfln(b, "ERROR %s", quote(e))
	for w in s.current_warnings do fmt.sbprintfln(b, "WARNING %s", quote(w))
}

append_state_json :: proc(b: ^strings.Builder, s: ^ink.Story_State) {
	js := ink.state_to_json(s)
	defer delete(js)
	fmt.sbprintln(b, "STATE_JSON_BEGIN")
	fmt.sbprintln(b, js)
	fmt.sbprintln(b, "STATE_JSON_END")
	fmt.sbprintln(b)
}

quote :: proc(s: string) -> string {
	bldr := strings.builder_make(context.temp_allocator)
	strings.write_byte(&bldr, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '\\': strings.write_string(&bldr, "\\\\")
		case '"':  strings.write_string(&bldr, "\\\"")
		case '\n': strings.write_string(&bldr, "\\n")
		case '\r': strings.write_string(&bldr, "\\r")
		case '\t': strings.write_string(&bldr, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(&bldr, "\\u%04X", c)
			} else {
				strings.write_byte(&bldr, c)
			}
		}
	}
	strings.write_byte(&bldr, '"')
	return strings.to_string(bldr)
}
