package ink

// Pointer is a (Container, index) pair that locates a position inside the
// compiled story tree. It's the runtime's "instruction pointer": cheaper to
// step than a Path, since most steps just bump `index` by one.
//
// Semantics (matching ink-engine-runtime/Pointer.cs):
//   - container == nil      -> null pointer
//   - index    <  0         -> the pointer addresses the container itself,
//                              not any of its children
//   - 0 <= index < count    -> addresses content[index]
//   - index >= count        -> overrun (resolve returns nil, used to detect
//                              "fell off the end" while stepping)

Pointer :: struct {
	container: ^Object, // expected to be a Container variant; nil for null
	index:     int,
}

POINTER_NULL :: Pointer{container = nil, index = -1}

pointer_start_of :: proc(container: ^Object) -> Pointer {
	return Pointer{container = container, index = 0}
}

pointer_is_null :: proc(p: Pointer) -> bool {
	return p.container == nil
}

// Returns the Object that this pointer addresses, or nil if it overruns.
// When index < 0, returns the container itself (matches C# Pointer.Resolve).
pointer_resolve :: proc(p: Pointer) -> ^Object {
	if p.index < 0 do return p.container
	if p.container == nil do return nil

	c, ok := p.container.variant.(Container)
	if !ok do return nil

	if len(c.content) == 0 do return p.container
	if p.index >= len(c.content) do return nil
	return c.content[p.index]
}

// Path of the position this pointer addresses. Caller owns the returned
// Path's component slice; pass to path_destroy when done.
pointer_path :: proc(p: Pointer, allocator := context.allocator) -> (path: Path, ok: bool) {
	if pointer_is_null(p) do return Path{}, false

	base := object_path(p.container, allocator)
	if p.index < 0 do return base, true

	extended := path_append_component(base, path_component_index(p.index), allocator)
	path_destroy(&base, allocator)
	return extended, true
}
