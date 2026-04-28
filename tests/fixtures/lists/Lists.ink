// Test fixture for ink LIST support. Designed to exercise as many list
// operations as possible while still terminating under a seeded random walk
// within ~50 turns regardless of seed.
//
// Coverage targets:
//   - LIST declarations (defaults via parens, explicit numeric values)
//   - List literals: (Fire, Water)
//   - Assignment, +=, -=, =()
//   - Set ops: + (union), - (difference), ^ (intersection), ? (contains),
//     !? (not contains)
//   - Comparisons: ==, !=, <, >, <=, >=
//   - Builtins: LIST_VALUE, LIST_COUNT, LIST_MIN, LIST_MAX, LIST_RANDOM,
//     LIST_ALL, LIST_INVERT, LIST_RANGE
//   - Conditional choices on list state
//   - Printing lists (joined names) and individual list items
//   - Persistence in state JSON across turns

LIST Element = Fire, Water, Earth, Air
LIST Damage = (Light), Medium=5, Heavy=10
LIST Effect = (Burn), Wet, Stun, Poison

VAR weakness   = (Fire, Water)
VAR attacks    = ()
VAR effects    = Burn
VAR damage     = Light
VAR turns      = 0

-> start

== start ==
{ turns >= 6: -> ending }
~ turns += 1

Turn {turns}. The dragon is weak against {weakness} (count {LIST_COUNT(weakness)}).
Your attacks: {attacks}. Your effects: {effects}. Damage: {damage} ({LIST_VALUE(damage)}).
{ attacks ? weakness:    A weakness is in play.    | No weakness in play yet. }
{ attacks !? Earth:      Earth still untried.      | Earth in the mix. }
{ LIST_COUNT(attacks) >= 2: Combo armed ({LIST_COUNT(attacks)} elements). }
{ damage < Heavy:        Power below cap.          | Power maxed. }
{ damage == Medium:      Medium tier engaged. }

+ [Cast Fire]
    ~ attacks += Fire
+ [Cast Water]
    ~ attacks += Water
+ [Cast Earth]
    ~ attacks += Earth
+ [Cast Air]
    ~ attacks += Air
+ { damage < Heavy } [Boost damage]
    ~ damage = Heavy
+ { damage > Light } [Damp damage]
    ~ damage = Light
+ { LIST_COUNT(attacks) > 0 } [Drop Fire]
    ~ attacks -= Fire
+ { effects !? Stun } [Add Stun]
    ~ effects += Stun
+ { effects !? Poison } [Add Poison]
    ~ effects += Poison
+ [Inspect intersection]
    Common with weakness: { attacks ^ weakness }.
+ [Inspect difference]
    Untried weakness: { weakness - attacks }.
+ [Reset attacks]
    ~ attacks = ()

- -> start

== ending ==
Battle over after {turns} turns.
Final attacks:  {attacks}
Final effects:  {effects}
Damage tier:    {damage} (value {LIST_VALUE(damage)})

All Effects:    {LIST_ALL(effects)}
All Damage:     {LIST_ALL(damage)}
Effect count:   {LIST_COUNT(effects)}
Min effect:     {LIST_MIN(effects)}
Max effect:     {LIST_MAX(effects)}
Inverted FX:    {LIST_INVERT(effects)}
Range FX 2..3:  {LIST_RANGE(LIST_ALL(effects), 2, 3)}

Random of all FX: {LIST_RANDOM(LIST_ALL(effects))}
Damage by int 5:  {Damage(5)}
Element by int 3: {Element(3)}
Damage + 1:       {damage + 1}
Damage - 1:       {damage - 1}

{ attacks == weakness:    Perfect counter.        | Imperfect attack set. }
{ attacks ^ weakness:     Hits landed: {attacks ^ weakness}. | No effective hits. }
{ effects ? (Burn, Stun): Burn+Stun synergy.      | No Burn+Stun synergy. }
{ damage >= Medium:       Significant damage.     | Light damage only. }

-> END
