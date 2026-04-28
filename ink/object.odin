package ink

// Object/Container traversal helpers.
//
// These procs operate on the Object graph built by the JSON loader:
// computing an Object's absolute Path, finding the root, looking up a
// child by Path_Component, and resolving a Path to a target Object.
//
// Mirrors ink-engine-runtime/Object.cs and Container.cs. None of these
// allocate unless explicitly stated (object_path is the exception).

// SearchResult — Container.ContentAtPath returns the deepest object it could
// reach, plus a flag noting whether it had to stop short.
Search_Result :: struct {
	obj:         ^Object,
	approximate: bool,
}

// Walks the parent chain to the root. Returns nil if obj is nil.
// Caller may further assert that the returned object is a Container.
object_root_container :: proc(obj: ^Object) -> ^Object {
	cur := obj
	for cur != nil && cur.parent != nil {
		cur = cur.parent
	}
	return cur
}

// Builds the absolute path to obj by walking up parent containers.
// At each level the contribution is either a name component (if the child
// is a named Container) or an index component (its position in parent.content).
//
// Returned Path's components slice is allocated in `allocator`. Free with
// path_destroy. The Path_Component.name slices borrow the underlying
// Container.name strings, so the caller must keep the story alive.
object_path :: proc(obj: ^Object, allocator := context.allocator) -> Path {
	if obj == nil || obj.parent == nil do return Path{}

	// Collect components walking upward; reverse at the end.
	tmp := make([dynamic]Path_Component, 0, 8, allocator)
	defer delete(tmp)

	child := obj
	parent := child.parent
	for parent != nil {
		comp, ok := path_component_for_child_in_parent(parent, child)
		if !ok do break
		append(&tmp, comp)
		child = parent
		parent = child.parent
	}

	n := len(tmp)
	out := make([]Path_Component, n, allocator)
	for i in 0 ..< n {
		out[i] = tmp[n - 1 - i]
	}
	return Path{components = out}
}

// Resolves a Path against an Object, handling absolute vs relative.
// - Absolute: start from the root.
// - Relative: start from `from` if it is a Container; else from from.parent
//   (consuming the leading "^" component, which is implied by the hop up).
object_resolve_path :: proc(from: ^Object, path: Path) -> Search_Result {
	if !path.is_relative {
		root := object_root_container(from)
		return container_content_at_path(root, path)
	}

	nearest := from
	start := 0
	if _, is_container := from.variant.(Container); !is_container {
		nearest = from.parent
		if len(path.components) > 0 && path_component_is_parent(path.components[0]) {
			start = 1
		}
	}
	return container_content_at_path_partial(nearest, path, start, len(path.components))
}

// ---- Container procs ------------------------------------------------------

// Walks `path` from `container`, returning the deepest reachable object
// and an `approximate` flag set when the path couldn't be fully resolved
// (out-of-range index, missing named child, or non-Container hit before
// the path was exhausted).
container_content_at_path :: proc(container: ^Object, path: Path) -> Search_Result {
	return container_content_at_path_partial(container, path, 0, len(path.components))
}

container_content_at_path_partial :: proc(container: ^Object, path: Path, start, length: int) -> Search_Result {
	result := Search_Result{obj = container}
	current_container := container

	for i in start ..< length {
		comp := path.components[i]

		if current_container == nil {
			result.approximate = true
			break
		}
		if _, is_c := current_container.variant.(Container); !is_c {
			result.approximate = true
			break
		}

		found := container_content_with_path_component(current_container, comp)
		if found == nil {
			result.approximate = true
			break
		}

		// If we still have components left, the next hop must be a container.
		if i < length - 1 {
			if _, is_next_c := found.variant.(Container); !is_next_c {
				result.approximate = true
				result.obj = found
				return result
			}
		}

		result.obj = found
		current_container = found
	}

	return result
}

// Looks up a single path component within a container.
//   - Index  : returns content[index] if in range, else nil
//   - Parent : returns container.parent (may be nil at root)
//   - Name   : returns the named child (search content for in-place named
//             containers first, then fall back to named_only_content)
container_content_with_path_component :: proc(container: ^Object, comp: Path_Component) -> ^Object {
	if container == nil do return nil
	c, ok := container.variant.(Container)
	if !ok do return nil

	if path_component_is_index(comp) {
		if comp.index >= 0 && comp.index < len(c.content) {
			return c.content[comp.index]
		}
		return nil
	}
	if path_component_is_parent(comp) {
		return container.parent
	}
	// Named children may live in content (named container stored positionally)
	// or in named_only_content (label/knot/stitch with no positional placement).
	// C# Container has a unified namedContent dict; we just scan both stores.
	for child in c.content {
		if cc, is_c := child.variant.(Container); is_c && cc.name == comp.name {
			return child
		}
	}
	if obj, found := c.named_only_content[comp.name]; found {
		return obj
	}
	return nil
}

// ---- Internals ------------------------------------------------------------

@(private)
path_component_for_child_in_parent :: proc(parent, child: ^Object) -> (comp: Path_Component, ok: bool) {
	pc, parent_is_c := parent.variant.(Container)
	if !parent_is_c do return {}, false

	// Named container child -> name component.
	if cc, child_is_c := child.variant.(Container); child_is_c && len(cc.name) > 0 {
		return path_component_name(cc.name), true
	}

	// Otherwise locate child in parent.content.
	for c, i in pc.content {
		if c == child do return path_component_index(i), true
	}
	return {}, false
}
