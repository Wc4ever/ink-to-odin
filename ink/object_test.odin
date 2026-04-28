package ink

import "core:mem/virtual"
import "core:testing"

// ---- Synthetic-tree test helpers -----------------------------------------
// Each test creates an arena, builds a small story tree with these helpers,
// asserts, and frees everything in one shot via virtual.arena_destroy.

@(private = "file")
mk_str :: proc(s: string) -> ^Object {
	o := new(Object)
	o.variant = String_Value{value = s}
	return o
}

@(private = "file")
mk_int :: proc(n: i64) -> ^Object {
	o := new(Object)
	o.variant = Int_Value{value = n}
	return o
}

@(private = "file")
mk_container :: proc(content: []^Object = nil) -> ^Object {
	o := new(Object)
	c := Container{}
	c.content = make([dynamic]^Object, 0, len(content))
	for child in content {
		append(&c.content, child)
		child.parent = o
	}
	o.variant = c
	return o
}

@(private = "file")
add_named :: proc(parent, child: ^Object, name: string) {
	pc, ok := &parent.variant.(Container)
	if !ok do return
	if pc.named_only_content == nil {
		pc.named_only_content = make(map[string]^Object)
	}
	pc.named_only_content[name] = child
	child.parent = parent
	if cc, is_c := &child.variant.(Container); is_c {
		cc.name = name
	}
}

// ---- Pointer tests --------------------------------------------------------

@(test)
test_pointer_null :: proc(t: ^testing.T) {
	testing.expect(t, pointer_is_null(POINTER_NULL), "POINTER_NULL is null")
	testing.expect(t, pointer_resolve(POINTER_NULL) == nil, "null resolves to nil")
}

@(test)
test_pointer_resolve :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	hello := mk_str("hello")
	world := mk_str("world")
	c := mk_container({hello, world})

	p0 := pointer_start_of(c)
	testing.expect_value(t, pointer_resolve(p0), hello)

	p1 := Pointer{container = c, index = 1}
	testing.expect_value(t, pointer_resolve(p1), world)

	// Negative index -> the container itself.
	p_self := Pointer{container = c, index = -1}
	testing.expect_value(t, pointer_resolve(p_self), c)

	// Overrun -> nil.
	p_over := Pointer{container = c, index = 99}
	testing.expect(t, pointer_resolve(p_over) == nil, "overrun is nil")
}

// ---- Object path tests ----------------------------------------------------

@(test)
test_object_root_container :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	leaf := mk_str("leaf")
	mid := mk_container({leaf})
	root := mk_container()
	add_named(root, mid, "middle")

	testing.expect_value(t, object_root_container(leaf), root)
	testing.expect_value(t, object_root_container(mid), root)
	testing.expect_value(t, object_root_container(root), root)
	testing.expect(t, object_root_container(nil) == nil, "nil -> nil")
}

@(test)
test_object_path :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// root
	//   named-only:
	//     "knot" -> Container
	//                  content:
	//                    [0] "hello"
	//                    [1] "world"
	leaf0 := mk_str("hello")
	leaf1 := mk_str("world")
	knot := mk_container({leaf0, leaf1})
	root := mk_container()
	add_named(root, knot, "knot")

	// "knot" itself
	p_knot := object_path(knot)
	s := path_to_string(p_knot)
	defer delete(s)
	testing.expect_value(t, s, "knot")

	// "knot.0" — leaf at index 0 of knot.
	p_leaf := object_path(leaf0)
	s2 := path_to_string(p_leaf)
	defer delete(s2)
	testing.expect_value(t, s2, "knot.0")
}

// ---- Container path resolution -------------------------------------------

@(test)
test_container_content_at_path_indexed :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	a := mk_str("a")
	b := mk_str("b")
	c := mk_str("c")
	root := mk_container({a, b, c})

	p := path_parse("1")
	defer path_destroy(&p)
	r := container_content_at_path(root, p)
	testing.expect(t, !r.approximate, "exact match")
	testing.expect_value(t, r.obj, b)
}

@(test)
test_container_content_at_path_named :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	hello := mk_str("hello")
	knot := mk_container({hello})
	root := mk_container()
	add_named(root, knot, "knot")

	p := path_parse("knot.0")
	defer path_destroy(&p)
	r := container_content_at_path(root, p)
	testing.expect(t, !r.approximate, "exact match")
	testing.expect_value(t, r.obj, hello)
}

@(test)
test_container_content_at_path_approximate_oob :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	a := mk_str("a")
	root := mk_container({a})

	p := path_parse("5")
	defer path_destroy(&p)
	r := container_content_at_path(root, p)
	testing.expect(t, r.approximate, "out-of-range -> approximate")
	testing.expect_value(t, r.obj, root)
}

@(test)
test_container_content_at_path_approximate_unknown_name :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	root := mk_container()

	p := path_parse("nonexistent")
	defer path_destroy(&p)
	r := container_content_at_path(root, p)
	testing.expect(t, r.approximate, "unknown name -> approximate")
	testing.expect_value(t, r.obj, root)
}

@(test)
test_resolve_relative_from_container :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// root contains knot1 ([x]) and knot2 ([y]).
	x := mk_str("x")
	knot1 := mk_container({x})
	y := mk_str("y")
	knot2 := mk_container({y})
	root := mk_container()
	add_named(root, knot1, "knot1")
	add_named(root, knot2, "knot2")

	// From knot1 (a container), ".^.knot2.0" walks to root → knot2 → y.
	p := path_parse(".^.knot2.0")
	defer path_destroy(&p)
	r := object_resolve_path(knot1, p)
	testing.expect(t, !r.approximate, "relative resolution succeeds from container")
	testing.expect_value(t, r.obj, y)
}

@(test)
test_resolve_relative_from_non_container :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	x := mk_str("x")
	knot1 := mk_container({x})
	y := mk_str("y")
	knot2 := mk_container({y})
	root := mk_container()
	add_named(root, knot1, "knot1")
	add_named(root, knot2, "knot2")

	// From x (non-container), the first ^ is consumed by the implicit hop
	// to x.parent (knot1). Reaching knot2 requires a SECOND ^ to climb to root.
	p := path_parse(".^.^.knot2.0")
	defer path_destroy(&p)
	r := object_resolve_path(x, p)
	testing.expect(t, !r.approximate, "relative resolution succeeds from non-container")
	testing.expect_value(t, r.obj, y)
}

// ---- Integration: TheIntercept -------------------------------------------

INTERCEPT_JSON_BYTES :: #load("../tests/fixtures/the_intercept/TheIntercept.ink.json")

@(test)
test_intercept_resolve_known_knots :: proc(t: ^testing.T) {
	story: Compiled_Story
	if err := compiled_story_load(&story, string(INTERCEPT_JSON_BYTES)); err != .None {
		testing.fail_now(t, "load failed")
	}
	defer compiled_story_destroy(&story)

	// "start" is the entry knot of TheIntercept.ink.
	p_start := path_parse("start")
	defer path_destroy(&p_start)
	r := container_content_at_path(story.root, p_start)
	testing.expect(t, !r.approximate, "found 'start' knot exactly")
	if cc, is_c := r.obj.variant.(Container); is_c {
		testing.expect_value(t, cc.name, "start")
	} else {
		testing.fail_now(t, "'start' resolved to a non-container")
	}

	// Round-trip: object_path on the found knot should yield "start".
	back := object_path(r.obj)
	defer path_destroy(&back)
	s := path_to_string(back)
	defer delete(s)
	testing.expect_value(t, s, "start")
}
