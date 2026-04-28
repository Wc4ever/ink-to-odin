// Minimal fixture for the lookahead-safe deferral path. fx() is called
// between two text lines; with an unsafe binding, the runtime should defer
// the call until the snapshot rewind has resolved (i.e. fire it once on
// the second Continue, not during the first one's lookahead).

EXTERNAL fx()

-> main

== main ==
Line 1.
~ fx()
Line 2.
-> END
