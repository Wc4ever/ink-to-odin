// Fixture for RANDOM, READ_COUNT, and TURNS_SINCE control commands.
// Sticky choices loop the walker through tavern → ale|bard|leave; each
// path exercises one or more of the targets so seeded random walks cover
// all three control commands within a few turns.

VAR last_roll = 0
VAR last_pick = 0

-> tavern

== tavern ==
You enter the tavern. (visit {READ_COUNT(-> tavern)})
~ last_roll = RANDOM(1, 6)
A roll of {last_roll}.
{ last_roll > 3: It's a high roll. | A low roll. }

+ [Order ale] -> ale
+ [Visit bard] -> bard
+ [Leave] -> leave

== ale ==
You drink ale. (count {READ_COUNT(-> ale)})
{ TURNS_SINCE(-> bard) < 0: You haven't met the bard yet. | Bard heard {TURNS_SINCE(-> bard)} turns ago. }
-> tavern

== bard ==
The bard sings.
~ last_pick = RANDOM(10, 20)
The bard's number is {last_pick}.
{ TURNS_SINCE(-> ale) < 0: Ale untasted. | Last ale {TURNS_SINCE(-> ale)} turns ago. }
-> tavern

== leave ==
You leave after {READ_COUNT(-> tavern)} tavern visits.
Ale {READ_COUNT(-> ale)} times. Bard {READ_COUNT(-> bard)} times.
{ READ_COUNT(-> ale) > 0 && READ_COUNT(-> bard) > 0: You experienced both. | Partial visit. }
-> END
