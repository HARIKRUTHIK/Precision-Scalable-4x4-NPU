<!--
TEMPLATE — NOT YET FILLED IN.

This file is scaffolding, not a finished postmortem. I (the assistant) don't have
the actual technical details of this bug — the signal-level root cause, the exact
blocking-vs-non-blocking assignment involved, and the fix — so I haven't written
those in. Fill in each section below with the real details before this goes public;
delete this comment block once done.

Everything in the "Summary" line and the shape of the sections is a reasonable
structure for this kind of writeup, not a claim about what actually happened.
-->

# Postmortem: `pause_stream` Blocking/Non-Blocking Race

**Status:** Found and fixed. **Found by:** constrained-random regression, not directed testing.

## Summary

_One or two sentences: what was the user-visible symptom, and what was the actual root cause?_

## Symptom

_What did the failure look like? Which check failed first (golden-model mismatch? a protocol assertion? something else)? Was it reproducible under a fixed seed, or did it only show up intermittently across random seeds?_

## Why Directed Testing Missed It

_The 28 directed tests and 5 protocol scenarios all passed clean. What specific timing relationship did the constrained-random test exercise that the directed tests didn't happen to hit? (e.g., a particular phase relationship between `pause_stream` assertion and the skew-chain state that only certain random seeds produced.)_

## Root Cause

_The actual technical detail: which signal(s) were assigned with blocking (`=`) vs. non-blocking (`<=`) assignments, in which always block, and why that produced a race. Point to the specific line(s) in `global_buffer.v` / `npu_ctrl.v` (whichever file it was in) — ideally with a short before/after code snippet._

```verilog
// before (buggy)


// after (fixed)

```

## Fix

_What changed, and why that's the correct fix rather than a workaround._

## How It Was Verified Fixed

_Re-ran the failing seed(s) — did it also get added as a new directed regression case so it can't silently regress? What's the current total check count after the fix (referenced as 2,588 in the main README — confirm that number was measured post-fix)._

## Lessons

_Anything worth carrying forward — e.g., "any signal that can be frozen/paused externally needs a dedicated randomized test for pause timing, not just directed pause/resume cases," or whatever the actual generalizable lesson was._
