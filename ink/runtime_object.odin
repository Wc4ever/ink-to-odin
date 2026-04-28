package ink

// Every node in a compiled ink story is an Object. The variant tells us
// what kind of node it is. Parent pointers let us resolve Paths upward;
// children live inside Container variants.
//
// Ownership: all Objects for a loaded story are allocated from a single
// arena owned by Story. story_destroy frees the arena in one shot.

Object :: struct {
	parent:  ^Object,
	variant: Object_Variant,
}

Object_Variant :: union {
	Container,
	Int_Value,
	Float_Value,
	Bool_Value,
	String_Value,
	Divert_Target_Value,
	Variable_Pointer_Value,
	List_Value,
	Control_Command,
	Native_Function_Call,
	Divert,
	Choice_Point,
	Variable_Reference,
	Variable_Assignment,
	Tag,
	Glue,
	Void,
}

// ---- Containers -----------------------------------------------------------

Container :: struct {
	name:               string,             // empty if anonymous
	content:            [dynamic]^Object,   // ordered indexed children
	named_only_content: map[string]^Object, // named children that aren't in `content`
	flags:              Container_Flags,
}

Container_Flag :: enum u8 {
	Visits,           // runtime should track visit count
	Turns,            // runtime should track turn-of-last-visit
	Count_Start_Only, // visit count only increments on entry to first child
}
Container_Flags :: bit_set[Container_Flag; u8]

// ---- Control / native ops -------------------------------------------------

Control_Command :: enum {
	Eval_Start,
	Eval_Output,
	Eval_End,
	Duplicate,
	Pop_Evaluated_Value,
	Pop_Function,
	Pop_Tunnel,
	Begin_String,
	End_String,
	No_Op,
	Choice_Count,
	Turns,
	Turns_Since,
	Read_Count,
	Random,
	Seed_Random,
	Visit_Index,
	Sequence_Shuffle_Index,
	Start_Thread,
	Done,
	End,
	List_From_Int,
	List_Range,
	List_Random,
	Begin_Tag,
	End_Tag,
}

// Stored as the source symbol ("+", "==", "MIN", etc.). The evaluator
// dispatches on the name; an enum is added later if dispatch hot-spots show.
Native_Function_Call :: struct {
	name: string,
}

// ---- Diverts and choices --------------------------------------------------

Push_Pop_Type :: enum {
	Tunnel,
	Function,
	Function_Evaluation_From_Game,
}

// Path fields are kept as strings (matching C#'s pathStringOnChoice /
// targetPathString). The evaluator parses to Path on demand.
Divert :: struct {
	target_path:          string, // empty if variable_divert_name is set
	variable_divert_name: string, // for ->VAR style diverts
	stack_push_type:      Push_Pop_Type,
	pushes_to_stack:      bool,
	is_external:          bool,
	external_args:        int,
	is_conditional:       bool,
}

Choice_Point :: struct {
	path_on_choice: string,
	flags:          Choice_Flags,
}

Choice_Flag :: enum u8 {
	Has_Condition,
	Has_Start_Content,
	Has_Choice_Only_Content,
	Once_Only,
	Is_Invisible_Default,
}
Choice_Flags :: bit_set[Choice_Flag; u8]

// ---- Variable ops ---------------------------------------------------------

Variable_Reference :: struct {
	name:           string, // empty if reading a read-count instead
	path_for_count: string,
}

Variable_Assignment :: struct {
	name:        string,
	is_new_decl: bool,
	is_global:   bool,
}

// ---- Markers --------------------------------------------------------------

Tag :: struct {
	text: string, // for legacy "# tag" syntax; new-style uses Begin_Tag/End_Tag
}

Glue :: struct {} // suppresses surrounding whitespace
Void :: struct {} // value pushed by functions that return nothing
