package ink

import "core:strconv"
import "core:strings"

// A Path locates an Object inside the compiled story tree.
// Stored as a slice of components (named, indexed, or "^" parent marker)
// plus an absolute-vs-relative flag.
//
// String form (mirroring inkle's Path.cs):
//   "knot.stitch.5"    -> absolute, three components
//   ".^.^.hello.5"     -> relative, prefix "." marks relative; "^" components walk up
//
// Path is treated as immutable. Mutating procs return new Paths; the caller
// owns the components slice and frees with path_destroy when done.

Path :: struct {
	components:  []Path_Component,
	is_relative: bool,
}

// One field is meaningful at a time:
//   index >= 0           -> index component (e.g. ".5")
//   index == -1, name=="^" -> parent marker
//   index == -1, name!=""  -> named component
Path_Component :: struct {
	index: int,
	name:  string,
}

PARENT_NAME :: "^"

// ---- Constructors ---------------------------------------------------------

path_component_index :: proc(i: int) -> Path_Component {
	assert(i >= 0)
	return Path_Component{index = i}
}

path_component_name :: proc(name: string) -> Path_Component {
	assert(len(name) > 0)
	return Path_Component{index = -1, name = name}
}

path_component_parent :: proc() -> Path_Component {
	return Path_Component{index = -1, name = PARENT_NAME}
}

path_component_is_index :: proc(c: Path_Component) -> bool {
	return c.index >= 0
}

path_component_is_parent :: proc(c: Path_Component) -> bool {
	return c.index < 0 && c.name == PARENT_NAME
}

path_component_equals :: proc(a, b: Path_Component) -> bool {
	if path_component_is_index(a) != path_component_is_index(b) do return false
	if path_component_is_index(a) do return a.index == b.index
	return a.name == b.name
}

// ---- Path lifecycle -------------------------------------------------------

// "self" path: relative, no components. The C# equivalent is Path.self.
path_self :: proc() -> Path {
	return Path{is_relative = true}
}

path_destroy :: proc(p: ^Path, allocator := context.allocator) {
	delete(p.components, allocator)
	p.components = nil
	p.is_relative = false
}

path_clone :: proc(p: Path, allocator := context.allocator) -> Path {
	dst := make([]Path_Component, len(p.components), allocator)
	copy(dst, p.components)
	return Path{components = dst, is_relative = p.is_relative}
}

// ---- Accessors ------------------------------------------------------------

path_length :: proc(p: Path) -> int {
	return len(p.components)
}

path_is_root :: proc(p: Path) -> bool {
	return !p.is_relative && len(p.components) == 0
}

path_head :: proc(p: Path) -> (head: Path_Component, ok: bool) {
	if len(p.components) == 0 do return {}, false
	return p.components[0], true
}

path_last_component :: proc(p: Path) -> (last: Path_Component, ok: bool) {
	n := len(p.components)
	if n == 0 do return {}, false
	return p.components[n - 1], true
}

// All components except the first. Returns path_self() when length < 2,
// matching C#'s Path.tail behaviour.
path_tail :: proc(p: Path, allocator := context.allocator) -> Path {
	if len(p.components) < 2 do return path_self()
	dst := make([]Path_Component, len(p.components) - 1, allocator)
	copy(dst, p.components[1:])
	return Path{components = dst, is_relative = false}
}

path_contains_named_component :: proc(p: Path) -> bool {
	for c in p.components {
		if !path_component_is_index(c) do return true
	}
	return false
}

// ---- Append ---------------------------------------------------------------

// Resolves `suffix` against `base`. Each leading "^" component in suffix
// pops one component off the end of base before concatenating the rest.
// Mirrors C#'s PathByAppendingPath, including the "absorb upward moves"
// behaviour that makes diverts like "->^.^.elsewhere" navigate correctly.
path_append :: proc(base, suffix: Path, allocator := context.allocator) -> Path {
	upward := 0
	for i in 0 ..< len(suffix.components) {
		if !path_component_is_parent(suffix.components[i]) do break
		upward += 1
	}

	keep_from_base := len(base.components) - upward
	if keep_from_base < 0 do keep_from_base = 0
	tail_count := len(suffix.components) - upward

	dst := make([]Path_Component, keep_from_base + tail_count, allocator)
	copy(dst[:keep_from_base], base.components[:keep_from_base])
	copy(dst[keep_from_base:], suffix.components[upward:])
	return Path{components = dst, is_relative = base.is_relative}
}

path_append_component :: proc(base: Path, c: Path_Component, allocator := context.allocator) -> Path {
	dst := make([]Path_Component, len(base.components) + 1, allocator)
	copy(dst, base.components)
	dst[len(base.components)] = c
	return Path{components = dst, is_relative = base.is_relative}
}

// ---- Parsing / formatting -------------------------------------------------

// Parses an inklecate-format path string. "" or "." returns an empty path.
//
// Named components borrow slices of the input string `s`. Caller must keep
// `s` alive for the lifetime of the returned Path. (Same convention as the
// JSON loader: strings flow through arena lifetimes; no defensive clones.)
path_parse :: proc(s: string, allocator := context.allocator) -> Path {
	if len(s) == 0 do return Path{}

	body := s
	is_relative := false
	if body[0] == '.' {
		is_relative = true
		body = body[1:]
	}
	if len(body) == 0 do return Path{is_relative = is_relative}

	// Two passes: count components, then fill. Avoids the [dynamic] from
	// strings.split (which we'd otherwise need to delete) and keeps name
	// slices pointing into `body` rather than into a separate split buffer.
	count := 1
	for i in 0 ..< len(body) {
		if body[i] == '.' do count += 1
	}

	components := make([]Path_Component, count, allocator)
	idx := 0
	start := 0
	for i in 0 ..= len(body) {
		if i == len(body) || body[i] == '.' {
			part := body[start:i]
			if n, ok := strconv.parse_int(part, 10); ok {
				components[idx] = Path_Component{index = n}
			} else {
				components[idx] = Path_Component{index = -1, name = part}
			}
			idx += 1
			start = i + 1
		}
	}
	return Path{components = components, is_relative = is_relative}
}

// Render a path to its inklecate string form. Inverse of path_parse.
path_to_string :: proc(p: Path, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	if p.is_relative {
		strings.write_byte(&b, '.')
	}
	for c, i in p.components {
		if i > 0 do strings.write_byte(&b, '.')
		if path_component_is_index(c) {
			strings.write_int(&b, c.index)
		} else {
			strings.write_string(&b, c.name)
		}
	}
	return strings.to_string(b)
}

// ---- Equality -------------------------------------------------------------

path_equals :: proc(a, b: Path) -> bool {
	if a.is_relative != b.is_relative do return false
	if len(a.components) != len(b.components) do return false
	for i in 0 ..< len(a.components) {
		if !path_component_equals(a.components[i], b.components[i]) do return false
	}
	return true
}
