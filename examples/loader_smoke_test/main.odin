package loader_smoke_test

import "core:fmt"
import "core:os"
import ink "../../ink"

STORY_PATH :: "../../tests/fixtures/the_intercept/TheIntercept.ink.json"

main :: proc() {
	json_bytes, ok := os.read_entire_file(STORY_PATH)
	if !ok {
		fmt.eprintfln("could not read %s", STORY_PATH)
		os.exit(1)
	}
	defer delete(json_bytes)

	story: ink.Compiled_Story
	if err := ink.compiled_story_load(&story, string(json_bytes)); err != .None {
		fmt.eprintfln("load failed: %v", err)
		os.exit(1)
	}
	defer ink.compiled_story_destroy(&story)

	fmt.printfln("inkFormatVersion: %d", story.ink_format_version)

	root, ok_root := story.root.variant.(ink.Container)
	if !ok_root {
		fmt.eprintln("root is not a container")
		os.exit(1)
	}
	fmt.printfln("root content count:   %d", len(root.content))
	fmt.printfln("root named-only keys: %d", len(root.named_only_content))

	count_objects(story.root, &counters)
	fmt.println()
	fmt.println("graph census:")
	fmt.printfln("  containers:       %d", counters.containers)
	fmt.printfln("  string values:    %d", counters.strings)
	fmt.printfln("  int values:       %d", counters.ints)
	fmt.printfln("  float values:     %d", counters.floats)
	fmt.printfln("  bool values:      %d", counters.bools)
	fmt.printfln("  diverts:          %d", counters.diverts)
	fmt.printfln("  choice points:    %d", counters.choice_points)
	fmt.printfln("  var refs:         %d", counters.var_refs)
	fmt.printfln("  var assigns:      %d", counters.var_assigns)
	fmt.printfln("  control commands: %d", counters.control_cmds)
	fmt.printfln("  native funcs:     %d", counters.native_funcs)
	fmt.printfln("  glue:             %d", counters.glues)
	fmt.printfln("  divert targets:   %d", counters.divert_targets)
	fmt.printfln("  var pointers:     %d", counters.var_pointers)
	fmt.printfln("  list values:      %d", counters.list_values)
	fmt.printfln("  tags (legacy):    %d", counters.tags)
	fmt.printfln("  voids:            %d", counters.voids)
	fmt.printfln("  total:            %d", counters.total)
}

Counters :: struct {
	containers, strings, ints, floats, bools:   int,
	diverts, choice_points:                     int,
	var_refs, var_assigns:                      int,
	control_cmds, native_funcs:                 int,
	glues, divert_targets, var_pointers:        int,
	list_values, tags, voids:                   int,
	total:                                      int,
}

counters: Counters

count_objects :: proc(obj: ^ink.Object, c: ^Counters) {
	if obj == nil do return
	c.total += 1
	switch v in obj.variant {
	case ink.Container:
		c.containers += 1
		for child in v.content do count_objects(child, c)
		for _, child in v.named_only_content do count_objects(child, c)
	case ink.String_Value:                  c.strings += 1
	case ink.Int_Value:                     c.ints += 1
	case ink.Float_Value:                   c.floats += 1
	case ink.Bool_Value:                    c.bools += 1
	case ink.Divert:                        c.diverts += 1
	case ink.Choice_Point:                  c.choice_points += 1
	case ink.Variable_Reference:            c.var_refs += 1
	case ink.Variable_Assignment:           c.var_assigns += 1
	case ink.Control_Command:               c.control_cmds += 1
	case ink.Native_Function_Call:          c.native_funcs += 1
	case ink.Glue:                          c.glues += 1
	case ink.Divert_Target_Value:           c.divert_targets += 1
	case ink.Variable_Pointer_Value:        c.var_pointers += 1
	case ink.List_Value:                    c.list_values += 1
	case ink.Tag:                           c.tags += 1
	case ink.Void:                          c.voids += 1
	}
}
