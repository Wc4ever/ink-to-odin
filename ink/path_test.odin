package ink

import "core:testing"

@(test)
test_path_parse_absolute :: proc(t: ^testing.T) {
	p := path_parse("knot.stitch.5")
	defer path_destroy(&p)

	testing.expect(t, !p.is_relative, "absolute path should not be relative")
	testing.expect_value(t, len(p.components), 3)
	testing.expect_value(t, p.components[0].name, "knot")
	testing.expect_value(t, p.components[1].name, "stitch")
	testing.expect(t, path_component_is_index(p.components[2]), "third should be index")
	testing.expect_value(t, p.components[2].index, 5)
}

@(test)
test_path_parse_relative :: proc(t: ^testing.T) {
	p := path_parse(".^.^.hello.5")
	defer path_destroy(&p)

	testing.expect(t, p.is_relative, "should be relative")
	testing.expect_value(t, len(p.components), 4)
	testing.expect(t, path_component_is_parent(p.components[0]), "[0] is ^")
	testing.expect(t, path_component_is_parent(p.components[1]), "[1] is ^")
	testing.expect_value(t, p.components[2].name, "hello")
	testing.expect_value(t, p.components[3].index, 5)
}

@(test)
test_path_parse_empty :: proc(t: ^testing.T) {
	p := path_parse("")
	defer path_destroy(&p)
	testing.expect(t, path_is_root(p), "empty string is root")

	pself := path_parse(".")
	defer path_destroy(&pself)
	testing.expect(t, pself.is_relative && len(pself.components) == 0, ". is self")
}

@(test)
test_path_roundtrip :: proc(t: ^testing.T) {
	cases := []string{
		"knot.stitch.5",
		".^.^.hello.5",
		"start.0.g-0.2",
		"my_knot",
		"42",
	}
	for src in cases {
		p := path_parse(src)
		defer path_destroy(&p)
		s := path_to_string(p)
		defer delete(s)
		testing.expect_value(t, s, src)
	}
}

@(test)
test_path_append_basic :: proc(t: ^testing.T) {
	base := path_parse("a.b")
	defer path_destroy(&base)
	suffix := path_parse("c.d")
	defer path_destroy(&suffix)

	combined := path_append(base, suffix)
	defer path_destroy(&combined)

	s := path_to_string(combined)
	defer delete(s)
	testing.expect_value(t, s, "a.b.c.d")
}

@(test)
test_path_append_with_parent_moves :: proc(t: ^testing.T) {
	// Each leading ^ in suffix pops one from base.
	base := path_parse("a.b.c")
	defer path_destroy(&base)
	suffix := path_parse("^.^.x")
	defer path_destroy(&suffix)

	combined := path_append(base, suffix)
	defer path_destroy(&combined)

	s := path_to_string(combined)
	defer delete(s)
	testing.expect_value(t, s, "a.x")
}

@(test)
test_path_append_more_parents_than_base :: proc(t: ^testing.T) {
	base := path_parse("a")
	defer path_destroy(&base)
	suffix := path_parse("^.^.x")
	defer path_destroy(&suffix)

	combined := path_append(base, suffix)
	defer path_destroy(&combined)

	s := path_to_string(combined)
	defer delete(s)
	// base exhausted, leftover ^ stays unmatched? In C# the loop counts ALL
	// leading parents, then keeps base[:len-upward] (clamped at 0) and
	// suffix[upward:]. So with base "a" and suffix "^.^.x":
	//   upward=2, keep_from_base=max(0, 1-2)=0, suffix[2:]="x" → "x".
	testing.expect_value(t, s, "x")
}

@(test)
test_path_equals :: proc(t: ^testing.T) {
	a := path_parse("knot.stitch.5")
	defer path_destroy(&a)
	b := path_parse("knot.stitch.5")
	defer path_destroy(&b)
	c := path_parse("knot.stitch.6")
	defer path_destroy(&c)
	d := path_parse(".knot.stitch.5")
	defer path_destroy(&d)

	testing.expect(t, path_equals(a, b), "identical paths equal")
	testing.expect(t, !path_equals(a, c), "different index → not equal")
	testing.expect(t, !path_equals(a, d), "absolute vs relative → not equal")
}

@(test)
test_path_head_tail_last :: proc(t: ^testing.T) {
	p := path_parse("a.b.c")
	defer path_destroy(&p)

	head, h_ok := path_head(p)
	testing.expect(t, h_ok, "head ok")
	testing.expect_value(t, head.name, "a")

	last, l_ok := path_last_component(p)
	testing.expect(t, l_ok, "last ok")
	testing.expect_value(t, last.name, "c")

	tail := path_tail(p)
	defer path_destroy(&tail)
	s := path_to_string(tail)
	defer delete(s)
	testing.expect_value(t, s, "b.c")
}

@(test)
test_path_tail_short :: proc(t: ^testing.T) {
	// Length < 2 should yield path_self(), per C# Path.tail.
	p := path_parse("only")
	defer path_destroy(&p)
	tail := path_tail(p)
	defer path_destroy(&tail)
	testing.expect(t, tail.is_relative && len(tail.components) == 0, "tail of single-component is self")
}
