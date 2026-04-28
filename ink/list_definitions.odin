package ink

// LIST definitions parsed from the compiled story's "listDefs" block.
// Used to:
//   - resolve unqualified item names ("Burn" → Effect.Burn = 1) at runtime
//   - look up an item's numeric value
//   - enumerate all items of a list (LIST_ALL, LIST_INVERT, LIST_RANGE)
//
// Mirrors C# Ink.Runtime.ListDefinitionsOrigin.

List_Item_Ref :: struct {
	origin_name: string,
	value:       int,
}

List_Definition :: struct {
	name:           string,
	items_by_name:  map[string]int,    // "Burn" -> 1
	names_by_value: map[int]string,    // 1 -> "Burn" (for sorted item iteration)
}

List_Definitions :: struct {
	by_list: map[string]^List_Definition,
	// Flat reverse index: item short name -> all (origin, value) pairs.
	// One slot when the name is unique across lists; multiple when ambiguous.
	by_item: map[string][dynamic]List_Item_Ref,
}

list_definitions_lookup_unique :: proc(d: ^List_Definitions, item_name: string) -> (ref: List_Item_Ref, ok: bool) {
	if d == nil do return {}, false
	refs, has := d.by_item[item_name]
	if !has || len(refs) != 1 do return {}, false
	return refs[0], true
}

// Resolve "Origin.Item" or just "Item" to (origin, value).
list_definitions_lookup_full :: proc(d: ^List_Definitions, full_name: string) -> (ref: List_Item_Ref, ok: bool) {
	if d == nil do return {}, false
	origin, item := split_list_item_key(full_name)
	if len(origin) > 0 {
		def, has_def := d.by_list[origin]
		if !has_def do return {}, false
		v, has_v := def.items_by_name[item]
		if !has_v do return {}, false
		return List_Item_Ref{origin_name = origin, value = v}, true
	}
	return list_definitions_lookup_unique(d, item)
}
