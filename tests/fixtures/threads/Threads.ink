// Fixture for the StartThread control command.
// `<- options` injects the choices in `options` alongside the choices in
// the parent knot, exercising thread fork (push at "thread" cmd) and the
// per-choice thread-restore (when a choice is picked, the runtime restores
// the callstack snapshot taken when the thread was generated).

VAR rounds = 0

-> entrance

== entrance ==
{ rounds >= 4: -> ending }
~ rounds += 1
You stand at the entrance. Round {rounds}.
<- options
What now?

+ [March in]
  You march in.
  -> entrance
+ [Hesitate]
  You wait.
  -> entrance

== options ==
+ [Check pack]
  You rummage through your pack.
  -> entrance
+ [Listen]
  You listen carefully.
  -> entrance
- DONE

== ending ==
You decide to leave after {rounds} rounds.
-> END
