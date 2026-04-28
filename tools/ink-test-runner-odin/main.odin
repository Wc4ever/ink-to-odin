package ink_test_runner_odin

import "core:fmt"
import "core:os"
import "core:slice"
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
// Usage:
//   odin run tools/ink-test-runner-odin             # all fixtures
//   odin run tools/ink-test-runner-odin -- <name>   # one fixture
//
// Outputs go to ../../tests/golden/odin/<fixture>/seed_{0..9}.log relative
// to cwd at invocation time. <fixture> is a directory name under
// ../../tests/fixtures/ — must contain exactly one *.ink.json file.

SEED_COUNT    :: 10
TURN_LIMIT    :: 500
FIXTURES_ROOT :: "../../tests/fixtures"
LOGS_ROOT     :: "../../tests/golden/odin"

main :: proc() {
	fixtures: [dynamic]string
	defer delete(fixtures)

	args := os.args[1:]
	if len(args) == 0 || args[0] == "all" {
		f, err := os.open(FIXTURES_ROOT)
		if err != nil {
			fmt.eprintfln("could not open %s: %v", FIXTURES_ROOT, err)
			os.exit(1)
		}
		defer os.close(f)
		entries, rerr := os.read_dir(f, 0, context.temp_allocator)
		if rerr != nil {
			fmt.eprintfln("could not read %s: %v", FIXTURES_ROOT, rerr)
			os.exit(1)
		}
		for e in entries do if e.is_dir do append(&fixtures, e.name)
		slice.sort(fixtures[:])
	} else {
		append(&fixtures, args[0])
	}

	for name in fixtures do run_fixture(name)
}

run_fixture :: proc(name: string) {
	story_path := find_story_path(name)
	defer delete(story_path)

	story_bytes, ok := os.read_entire_file(story_path)
	if !ok {
		fmt.eprintfln("could not read %s", story_path)
		os.exit(1)
	}
	defer delete(story_bytes)

	logs_dir := fmt.aprintf("%s/%s", LOGS_ROOT, name)
	defer delete(logs_dir)
	if !os.exists(LOGS_ROOT) do os.make_directory(LOGS_ROOT)
	if !os.exists(logs_dir) {
		if err := os.make_directory(logs_dir); err != nil {
			fmt.eprintfln("could not create %s: %v", logs_dir, err)
			os.exit(1)
		}
	}

	for seed in 0 ..< SEED_COUNT {
		log := run_seed(string(story_bytes), seed)
		defer delete(log)
		path := fmt.aprintf("%s/seed_%d.log", logs_dir, seed)
		defer delete(path)
		if !os.write_entire_file(path, transmute([]byte)log) {
			fmt.eprintfln("could not write %s", path)
			os.exit(1)
		}
		fmt.printfln("Wrote %s", path)
	}
}

find_story_path :: proc(name: string) -> string {
	dir := fmt.aprintf("%s/%s", FIXTURES_ROOT, name)
	f, ferr := os.open(dir)
	if ferr != nil {
		fmt.eprintfln("fixture dir not found: %s", dir)
		delete(dir)
		os.exit(1)
	}
	entries, rerr := os.read_dir(f, 0, context.temp_allocator)
	os.close(f)
	if rerr != nil {
		fmt.eprintfln("could not read %s: %v", dir, rerr)
		delete(dir)
		os.exit(1)
	}
	for e in entries {
		if !e.is_dir && strings.has_suffix(e.name, ".ink.json") {
			path := fmt.aprintf("%s/%s", dir, e.name)
			delete(dir)
			return path
		}
	}
	fmt.eprintfln("no *.ink.json in %s", dir)
	delete(dir)
	os.exit(1)
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
