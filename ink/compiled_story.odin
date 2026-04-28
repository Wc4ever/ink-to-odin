package ink

import "core:mem/virtual"

// Compiled_Story owns every Object allocated for a loaded story. The arena
// allocator backs all of them, so compiled_story_destroy frees the entire
// graph in a single call — no per-node walking, no double-free hazards.
//
// Strings (names, content, target paths, etc.) come from the JSON parser
// running under the same arena, so slices in our types stay valid until
// destroy without any explicit cloning.

Compiled_Story :: struct {
	arena:              virtual.Arena,
	ink_format_version: int,
	root:               ^Object,
}

compiled_story_destroy :: proc(story: ^Compiled_Story) {
	virtual.arena_destroy(&story.arena)
	story.root = nil
	story.ink_format_version = 0
}
