// Fixture for EXTERNAL function dispatch with ink-side fallbacks.
// Both runners enable allowExternalFunctionFallbacks; the runtime sees
// `EXTERNAL roll(sides)` and a `=== function roll(sides)` knot of the
// same name, and routes calls to the fallback when no host binding is
// registered. This exercises the externals dispatch path without
// requiring the dotnet runner to know about specific bindings.

EXTERNAL roll(sides)
EXTERNAL greet(who)
EXTERNAL classify(score)

VAR last_roll = 0
VAR last_score = 0

-> arena

== arena ==
{ READ_COUNT(-> arena) > 4: -> done }
~ last_roll = roll(6)
You roll a {last_roll} (visit {READ_COUNT(-> arena)}).
{greet("hero")}

+ [Score 5]
  ~ last_score = 5
  -> evaluate
+ [Score 9]
  ~ last_score = 9
  -> evaluate
+ [Score 12]
  ~ last_score = 12
  -> evaluate
+ [Skip]
  -> arena

== evaluate ==
~ temp grade = classify(last_score)
Score {last_score} grade: {grade}.
-> arena

== done ==
After {READ_COUNT(-> arena)} rolls, you head home.
-> END

// ---- Fallbacks for the externals --------------------------------------

=== function roll(sides) ===
~ return RANDOM(1, sides)

=== function greet(who) ===
Hello, {who}!

=== function classify(score) ===
{ score < 6:
  ~ return "low"
}
{ score < 10:
  ~ return "mid"
}
~ return "high"
