package ink_test_runner_odin

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

INTERCEPT_JSON :: #load("../../tests/fixtures/the_intercept/TheIntercept.ink.json")

// All seed_*.log files from the dotnet golden directory, baked in at compile
// time. Sorted by filename so seed_N pairs with the N-th entry.
GOLDEN_SEEDS := #load_directory("../../tests/golden/reference")

// Runs the Odin runner for each seed in 0..9 and byte-diffs the output
// against the dotnet-produced golden log. Pass = byte-identical to inkle's
// reference runtime. Failure for any seed reports the first divergent line
// with surrounding context.
@(test)
test_diff_all_seeds :: proc(t: ^testing.T) {
	// #load_directory's order isn't guaranteed across platforms, and we want
	// seed_N's golden in slot N. Filter to seed_*.log files and sort by name.
	files := make([dynamic]runtime.Load_Directory_File, 0, len(GOLDEN_SEEDS), context.temp_allocator)
	for f in GOLDEN_SEEDS {
		base := f.name
		if i := strings.last_index_byte(base, '/'); i >= 0 do base = base[i + 1:]
		if i := strings.last_index_byte(base, '\\'); i >= 0 do base = base[i + 1:]
		if !strings.has_prefix(base, "seed_") || !strings.has_suffix(base, ".log") do continue
		append(&files, f)
	}
	slice.sort_by(files[:], proc(a, b: runtime.Load_Directory_File) -> bool { return a.name < b.name })

	for f, seed in files {
		check_seed(t, seed, string(f.data))
	}
}

@(private = "file")
check_seed :: proc(t: ^testing.T, seed: int, golden: string) {
	got := run_seed(string(INTERCEPT_JSON), seed)
	defer delete(got)

	// Goldens were written on Windows (CRLF); our builder emits LF. Normalize.
	want_lf, _ := strings.replace_all(golden, "\r\n", "\n", context.temp_allocator)

	if got == want_lf do return

	got_lines := strings.split_lines(got, context.temp_allocator)
	want_lines := strings.split_lines(want_lf, context.temp_allocator)

	min_len := len(got_lines) if len(got_lines) < len(want_lines) else len(want_lines)
	div := -1
	for i in 0 ..< min_len {
		if got_lines[i] != want_lines[i] {
			div = i
			break
		}
	}
	if div == -1 do div = min_len

	context_window := 4
	lo := max(0, div - context_window)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "seed %d: first divergence at line %d (1-based: %d)", seed, div, div + 1)
	fmt.sbprintfln(&b, "  golden has %d lines, odin has %d lines", len(want_lines), len(got_lines))
	fmt.sbprintln(&b)
	fmt.sbprintln(&b, "context (- golden, + odin):")
	for i in lo ..< div {
		fmt.sbprintfln(&b, "    %d  %s", i + 1, want_lines[i] if i < len(want_lines) else "")
	}
	for i in div ..< min(div + context_window, max(len(want_lines), len(got_lines))) {
		gl := want_lines[i] if i < len(want_lines) else "<EOF>"
		ol := got_lines[i] if i < len(got_lines) else "<EOF>"
		fmt.sbprintfln(&b, "  - %d  %s", i + 1, gl)
		fmt.sbprintfln(&b, "  + %d  %s", i + 1, ol)
	}

	testing.expect(t, false, strings.to_string(b))
}
