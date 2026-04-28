package ink

// Values are the things pushed onto the evaluation stack at runtime.
// Each is a distinct Object_Variant so a switch over Object.variant
// handles them naturally.

Int_Value :: struct {
	value: i64,
}

Float_Value :: struct {
	value: f64,
}

Bool_Value :: struct {
	value: bool,
}

String_Value :: struct {
	value: string, // borrowed from the string arena owned by Story
}

Divert_Target_Value :: struct {
	target: string, // path string, parsed to Path on demand
}

Variable_Pointer_Value :: struct {
	name:           string,
	context_index:  int, // -1 = unknown / global; 0..n = call-stack frame index
}

List_Value :: struct {
	value: Ink_List,
}

// ---- Ink lists ------------------------------------------------------------
// Ink lists are sets of named items drawn from one or more origin LIST defs.
// Each item carries its origin so cross-origin operations (union, etc.) work.

List_Item :: struct {
	origin_name: string,
	item_name:   string,
}

Ink_List :: struct {
	items:        map[List_Item]int, // item → integer value within its origin
	origin_names: []string,           // referenced LIST definitions; resolved at runtime
}
