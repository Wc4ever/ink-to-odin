package ink

import "base:runtime"
import "core:slice"
import "core:strings"

// Runtime list operations. All builders allocate the result map in the
// supplied allocator and return a fresh Ink_List; callers wrap it in an
// Object{variant: List_Value{...}} when needed.
//
// Mirrors ink-engine-runtime/InkList.cs operations.

// Empty list with the same origin set as `template` (so type info is
// preserved across operations that can produce empty results).
@(private)
ink_list_empty_like :: proc(template: Ink_List, alloc: runtime.Allocator) -> Ink_List {
	out: Ink_List
	out.items = make(map[List_Item]int, allocator = alloc)
	out.origin_names = template.origin_names
	return out
}

@(private)
ink_list_clone :: proc(src: Ink_List, alloc: runtime.Allocator) -> Ink_List {
	out: Ink_List
	out.items = make(map[List_Item]int, allocator = alloc)
	for k, v in src.items do out.items[k] = v
	out.origin_names = src.origin_names
	return out
}

// Items sorted by (value asc, item_name asc) — the order ink uses when
// stringifying a list (Fire, Water for {Element.Fire=1, Element.Water=2}).
// Pairs (item, value) up front so the comparator stays closure-free.
@(private)
List_Item_Pair :: struct {
	item:  List_Item,
	value: int,
}

@(private)
ink_list_sorted_items :: proc(l: Ink_List, alloc := context.allocator) -> []List_Item {
	pairs := make([dynamic]List_Item_Pair, 0, len(l.items), alloc)
	for k, v in l.items do append(&pairs, List_Item_Pair{item = k, value = v})
	slice.sort_by(pairs[:], proc(a, b: List_Item_Pair) -> bool {
		if a.value != b.value do return a.value < b.value
		return a.item.item_name < b.item.item_name
	})
	out := make([]List_Item, len(pairs), alloc)
	for p, i in pairs do out[i] = p.item
	return out
}

// Stringification: comma-separated item names sorted by (value, name).
// Mirrors C# InkList.ToString (just item names, no Origin. prefix).
@(private)
ink_list_to_string :: proc(l: Ink_List, alloc := context.allocator) -> string {
	if len(l.items) == 0 do return ""
	sorted := ink_list_sorted_items(l, context.temp_allocator)
	parts := make([dynamic]string, 0, len(sorted)*2, context.temp_allocator)
	for it, i in sorted {
		if i > 0 do append(&parts, ", ")
		append(&parts, it.item_name)
	}
	return strings.concatenate(parts[:], alloc)
}

// Set ops -----------------------------------------------------------------

@(private)
ink_list_union :: proc(a, b: Ink_List, alloc: runtime.Allocator) -> Ink_List {
	out := ink_list_clone(a, alloc)
	for k, v in b.items do out.items[k] = v
	return out
}

@(private)
ink_list_difference :: proc(a, b: Ink_List, alloc: runtime.Allocator) -> Ink_List {
	out := ink_list_empty_like(a, alloc)
	for k, v in a.items {
		if _, in_b := b.items[k]; !in_b do out.items[k] = v
	}
	return out
}

@(private)
ink_list_intersect :: proc(a, b: Ink_List, alloc: runtime.Allocator) -> Ink_List {
	out := ink_list_empty_like(a, alloc)
	for k, v in a.items {
		if _, in_b := b.items[k]; in_b do out.items[k] = v
	}
	return out
}

// "a ? b" — does a contain all items of b? An empty b is trivially contained.
@(private)
ink_list_contains_all :: proc(a, b: Ink_List) -> bool {
	if len(b.items) == 0 do return false // matches C# InkList.ContainsItemsFrom semantics? See note
	for k in b.items {
		if _, ok := a.items[k]; !ok do return false
	}
	return true
}

// Comparisons: numerical, based on min/max value across all items.
@(private)
ink_list_max_value :: proc(l: Ink_List) -> int {
	m := min(int)
	for _, v in l.items do if v > m do m = v
	return m
}

@(private)
ink_list_min_value :: proc(l: Ink_List) -> int {
	m := max(int)
	for _, v in l.items do if v < m do m = v
	return m
}

// LIST_MAX / LIST_MIN — produce a single-item list with that extreme.
@(private)
ink_list_max_as_list :: proc(l: Ink_List, alloc: runtime.Allocator) -> Ink_List {
	out := ink_list_empty_like(l, alloc)
	if len(l.items) == 0 do return out
	best_k: List_Item
	best_v := min(int)
	first := true
	for k, v in l.items {
		if first || v > best_v || (v == best_v && k.item_name < best_k.item_name) {
			best_k, best_v, first = k, v, false
		}
	}
	out.items[best_k] = best_v
	return out
}

@(private)
ink_list_min_as_list :: proc(l: Ink_List, alloc: runtime.Allocator) -> Ink_List {
	out := ink_list_empty_like(l, alloc)
	if len(l.items) == 0 do return out
	best_k: List_Item
	best_v := max(int)
	first := true
	for k, v in l.items {
		if first || v < best_v || (v == best_v && k.item_name < best_k.item_name) {
			best_k, best_v, first = k, v, false
		}
	}
	out.items[best_k] = best_v
	return out
}

// LIST_ALL: union of every item across all origins referenced by `l`. The
// origin set is whatever lists `l`'s items came from, plus any origin_names
// retained on empty lists. Defs is the story-wide registry.
@(private)
ink_list_all :: proc(l: Ink_List, defs: ^List_Definitions, alloc: runtime.Allocator) -> Ink_List {
	out: Ink_List
	out.items = make(map[List_Item]int, allocator = alloc)
	if defs == nil do return out

	origins := list_origins_of(l)
	for origin_name in origins {
		def, has := defs.by_list[origin_name]
		if !has do continue
		for item_name, value in def.items_by_name {
			out.items[List_Item{origin_name = origin_name, item_name = item_name}] = value
		}
	}
	return out
}

// LIST_INVERT: items in ALL_ORIGINS minus items already in l.
@(private)
ink_list_invert :: proc(l: Ink_List, defs: ^List_Definitions, alloc: runtime.Allocator) -> Ink_List {
	all := ink_list_all(l, defs, alloc)
	for k in l.items do delete_key(&all.items, k)
	return all
}

// list ± int: for each item, look up the origin's item with value (item.value + delta);
// keep only those that resolve. Items whose origin has no def are dropped.
@(private)
ink_list_shift :: proc(l: Ink_List, delta: int, defs: ^List_Definitions, alloc: runtime.Allocator) -> Ink_List {
	out: Ink_List
	out.items = make(map[List_Item]int, allocator = alloc)
	out.origin_names = l.origin_names
	if defs == nil do return out
	for k, v in l.items {
		def, has := defs.by_list[k.origin_name]
		if !has do continue
		target := v + delta
		if name, found := def.names_by_value[target]; found {
			out.items[List_Item{origin_name = k.origin_name, item_name = name}] = target
		}
	}
	return out
}

// LIST_RANGE: keep only items in [min_val, max_val]. min/max may themselves
// be ints OR single-item lists; resolution is the caller's job.
@(private)
ink_list_range :: proc(l: Ink_List, min_val, max_val: int, alloc: runtime.Allocator) -> Ink_List {
	out := ink_list_empty_like(l, alloc)
	for k, v in l.items {
		if v >= min_val && v <= max_val do out.items[k] = v
	}
	return out
}

// LIST_VALUE for a single-item list: that item's value. For empty/multi-item
// lists, C# InkListItem.Value semantics: 0 for empty, the only item's value
// for size-1, otherwise the highest-valued item's value (per InkList.maxItem).
@(private)
ink_list_single_value :: proc(l: Ink_List) -> int {
	if len(l.items) == 0 do return 0
	if len(l.items) == 1 {
		for _, v in l.items do return v
	}
	// Pick max-value item (matches LIST_VALUE semantics on multi-item lists).
	return ink_list_max_value(l)
}

@(private)
list_origins_of :: proc(l: Ink_List) -> []string {
	// Build a unique-name slice from items + retained origin_names.
	seen := make(map[string]bool, allocator = context.temp_allocator)
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	for k in l.items {
		if k.origin_name not_in seen {
			seen[k.origin_name] = true
			append(&out, k.origin_name)
		}
	}
	for n in l.origin_names {
		if n not_in seen {
			seen[n] = true
			append(&out, n)
		}
	}
	return out[:]
}

// Wrap a freshly built Ink_List in an Object so eval_stack_push can take it.
@(private)
new_list_object :: proc(l: Ink_List, alloc: runtime.Allocator) -> ^Object {
	o := new(Object, alloc)
	o.variant = List_Value{value = l}
	return o
}
