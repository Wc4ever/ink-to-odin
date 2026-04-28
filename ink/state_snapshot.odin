package ink

// State_Snapshot: captures the parts of Story_State that need to roll back
// at a newline lookahead. Mirrors the effect of upstream's
// `StoryState.CopyAndStartPatching` + `RestoreStateSnapshot` without the
// background-save patch indirection — we just deep-copy on snap and swap
// pointers on restore.
//
// Fields here are deep clones of the live state's collections; the ^Object
// values are shared with the live state since runtime objects live in
// Story_State.runtime_arena and aren't mutated under us.
//
// Lifecycle inside story_continue:
//   take      — at a newline+canContinue (or whenever a lookahead point begins).
//   restore   — when we discover the lookahead extended visible text past the
//               newline. Live state's mutable collections are freed and
//               replaced with the snapshot's clones. snap is "consumed".
//   discard   — when the loop exits cleanly without needing a rollback (e.g.
//               glue removed the newline, or canContinue went false at a
//               clean newline). Frees the snapshot's clones.

@(private)
State_Snapshot :: struct {
	// Full output stream array (not just length): glue's trim-newlines
	// behaviour can shrink the stream then a later push grows it back to
	// the same length with different contents, so a length-only snapshot
	// would silently corrupt the rollback.
	output_stream:      [dynamic]^Object,

	globals:            map[string]^Object,
	eval_stack:         [dynamic]^Object,

	threads:            [dynamic]Call_Stack_Thread,
	thread_counter:     int,

	current_choices:    [dynamic]Choice,

	visit_counts:       map[string]int,
	turn_indices:       map[string]int,

	current_turn_index: int,
	story_seed:         int,
	previous_random:    int,
	did_safe_exit:      bool,
	diverted_pointer:   Pointer,
}

@(private)
state_snapshot_take :: proc(s: ^Story_State) -> State_Snapshot {
	snap := State_Snapshot {
		thread_counter     = s.call_stack.thread_counter,
		current_turn_index = s.current_turn_index,
		story_seed         = s.story_seed,
		previous_random    = s.previous_random,
		did_safe_exit      = s.did_safe_exit,
		diverted_pointer   = s.diverted_pointer,
	}

	snap.output_stream = make([dynamic]^Object, 0, len(s.output_stream.stream))
	for o in s.output_stream.stream do append(&snap.output_stream, o)

	snap.globals = make(map[string]^Object, len(s.variables_state.globals))
	for k, v in s.variables_state.globals do snap.globals[k] = v

	snap.eval_stack = make([dynamic]^Object, 0, len(s.eval_stack))
	for o in s.eval_stack do append(&snap.eval_stack, o)

	snap.threads = make([dynamic]Call_Stack_Thread, 0, len(s.call_stack.threads))
	for &t in s.call_stack.threads {
		append(&snap.threads, call_stack_thread_copy(&t))
	}

	snap.current_choices = make([dynamic]Choice, 0, len(s.current_choices))
	for &c in s.current_choices {
		copy_c := c
		copy_c.thread_at_generation = call_stack_thread_copy(&c.thread_at_generation)
		if c.tags != nil {
			tags := make([]string, len(c.tags))
			for tag, i in c.tags do tags[i] = tag
			copy_c.tags = tags
		}
		append(&snap.current_choices, copy_c)
	}

	snap.visit_counts = make(map[string]int, len(s.visit_counts))
	for k, v in s.visit_counts do snap.visit_counts[k] = v
	snap.turn_indices = make(map[string]int, len(s.turn_indices))
	for k, v in s.turn_indices do snap.turn_indices[k] = v

	return snap
}

@(private)
state_snapshot_restore :: proc(s: ^Story_State, snap: ^State_Snapshot) {
	delete(s.output_stream.stream)
	s.output_stream.stream = snap.output_stream
	snap.output_stream = nil

	delete(s.variables_state.globals)
	s.variables_state.globals = snap.globals
	snap.globals = nil

	delete(s.eval_stack)
	s.eval_stack = snap.eval_stack
	snap.eval_stack = nil

	for &t in s.call_stack.threads do call_stack_thread_destroy(&t)
	delete(s.call_stack.threads)
	s.call_stack.threads = snap.threads
	snap.threads = nil
	s.call_stack.thread_counter = snap.thread_counter

	for &c in s.current_choices do choice_destroy(&c)
	delete(s.current_choices)
	s.current_choices = snap.current_choices
	snap.current_choices = nil

	delete(s.visit_counts)
	s.visit_counts = snap.visit_counts
	snap.visit_counts = nil

	delete(s.turn_indices)
	s.turn_indices = snap.turn_indices
	snap.turn_indices = nil

	s.current_turn_index = snap.current_turn_index
	s.story_seed         = snap.story_seed
	s.previous_random    = snap.previous_random
	s.did_safe_exit      = snap.did_safe_exit
	s.diverted_pointer   = snap.diverted_pointer
}

@(private)
state_snapshot_discard :: proc(snap: ^State_Snapshot) {
	delete(snap.output_stream)
	delete(snap.globals)
	delete(snap.eval_stack)
	for &t in snap.threads do call_stack_thread_destroy(&t)
	delete(snap.threads)
	for &c in snap.current_choices do choice_destroy(&c)
	delete(snap.current_choices)
	delete(snap.visit_counts)
	delete(snap.turn_indices)
	snap^ = {}
}
