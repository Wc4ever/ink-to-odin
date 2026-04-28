package intercept_cli

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import ink "../../ink"

// Plays TheIntercept in the terminal: drains text after each Continue,
// prints the choice list, reads a number from stdin, repeats until the
// story ends.
//
// Build & run from this directory:
//   odin run .
//
// At a choice prompt:
//   <n>  — pick choice n (0-indexed)
//   q    — quit
//   <enter> — repeat the prompt

INTERCEPT_JSON :: #load("../../tests/fixtures/the_intercept/TheIntercept.ink.json")

main :: proc() {
	// ink emits UTF-8; on Windows the console defaults to the local ANSI
	// code page so we have to switch it explicitly. No-op elsewhere.
	setup_utf8_console()

	story: ink.Compiled_Story
	if err := ink.compiled_story_load(&story, string(INTERCEPT_JSON)); err != .None {
		fmt.eprintfln("compiled_story_load: %v", err)
		os.exit(1)
	}
	defer ink.compiled_story_destroy(&story)

	state: ink.Story_State
	if !ink.story_state_init(&state, &story) {
		fmt.eprintln("story_state_init failed")
		os.exit(1)
	}
	defer ink.story_state_destroy(&state)

	stdin_reader: bufio.Reader
	bufio.reader_init(&stdin_reader, os.stream_from_handle(os.stdin))
	defer bufio.reader_destroy(&stdin_reader)

	for {
		// Drain text up to the next choice point or end.
		for ink.story_state_can_continue(&state) {
			if !ink.story_continue(&state) do break

			text := ink.story_current_text(&state)
			defer delete(text)
			fmt.print(text)

			tags := ink.story_current_tags(&state)
			defer delete(tags)
			for tag in tags do fmt.printfln("  [tag] %s", tag)

			if ink.story_state_has_error(&state) {
				for e in state.current_errors do fmt.eprintfln("ERROR: %s", e)
				os.exit(1)
			}
		}

		choices := ink.story_current_choices(&state)
		if len(choices) == 0 {
			fmt.println()
			fmt.println("=== END ===")
			return
		}

		// Present and prompt.
		fmt.println()
		for c, i in choices {
			fmt.printfln("  %d) %s", i + 1, c.text)
		}

		pick, ok := prompt_pick(&stdin_reader, len(choices))
		if !ok {
			fmt.println("(quit)")
			return
		}
		fmt.println()
		ink.story_choose_choice_index(&state, pick)
	}
}

// Reads stdin and returns a 0-indexed choice in [0, n_choices). On 'q' or EOF,
// returns ok=false. Re-prompts on bad input.
prompt_pick :: proc(r: ^bufio.Reader, n_choices: int) -> (pick: int, ok: bool) {
	for {
		fmt.printf("> ")
		os.flush(os.stdout)
		line, err := bufio.reader_read_string(r, '\n', context.temp_allocator)
		if err != nil {
			// EOF or read error.
			fmt.println()
			return 0, false
		}
		s := strings.trim_space(line)
		if len(s) == 0 do continue
		if s == "q" || s == "Q" || s == "quit" do return 0, false
		n, parsed := strconv.parse_int(s, 10)
		if !parsed || n < 1 || n > n_choices {
			fmt.printfln("(pick a number 1..%d, or q to quit)", n_choices)
			continue
		}
		return n - 1, true
	}
}
