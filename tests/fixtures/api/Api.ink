// Tiny fixture exercising the game-facing API helpers (globals, global tags,
// per-knot tags). Used by ink/api_test.odin only — not part of the diff
// harness because there's nothing seeded-RNG-dependent here.

# title: Api Test
# author: ink-to-odin
# version: 1

VAR score = 7
VAR player_name = "Hero"
VAR is_admin = false

-> intro

== intro ==
# location: hub
# difficulty: easy
You start with score {score}.
* [Continue] -> END
