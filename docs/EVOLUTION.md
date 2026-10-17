# Design Evolution: v1 → v2

## v1 — Independent-Tile MAC Array

The first working version built 16 independent tiles arranged in a 4×4 grid. Each tile owned its own local `weight_mem` (separate weight and input SRAM), computed a full dot product on its own, and reported done when finished — there was no dataflow between tiles at all. `out_valid` for the whole array was simply the AND of all 16 tiles finishing independently.

This was the right place to start: it's simple to reason about, simple to verify (each tile can be tested in isolation), and it gets a working precision-scalable multiplier hierarchy (SBB → BBU → RFU) validated end-to-end before adding any inter-tile complexity. Full details: [`docs/v1-independent-tile/README.md`](v1-independent-tile/README.md).

**The problem**: every tile needing its own memory port is fundamentally wasteful when neighboring tiles are working on data that could be reused. 16 independent weight ports and 16 independent input ports for a 4×4 array is 16× the memory bandwidth and roughly 16× the SRAM area of a design that shares and reuses that same data — for no computational benefit, since most of what each tile reads is either identical to or a simple shift of what its neighbor just read.

## v2 — Weight-Stationary Systolic Array

The fix is the standard one for exactly this problem, and it's why systolic arrays (TPU-style accelerators) exist instead of brute-forcing N independent MAC units: **keep weights stationary in the PE and stream activations through, reusing each value across every tile it passes**. Rather than 16 local memories, a single shared Global Buffer holds all weights and inputs, broadcasts weights row-by-row into the mesh where they latch and stay, and streams activations left-to-right with per-row skew so that partial sums flowing down a column always correspond to inputs that have propagated the same horizontal distance.

This rearchitecture is also what makes **per-row reconfigurable precision** meaningful. In v1, giving each of the 16 independent tiles its own precision setting would have been possible but pointless — there was no shared structure for a "row" to mean anything. Once weights are broadcast row-by-row through a shared bus, riding the per-row mode alongside the per-row weight broadcast is a small, natural addition: each row latches its own `{sx, sy, mode}` at the exact moment it latches its own weights, so four rows can run four different precisions in the same pass with no reconfiguration gap between them.

Full details: [`docs/v2-systolic-row-precision/README.md`](v2-systolic-row-precision/README.md).

## What carried over unchanged

The arithmetic core — `sbb` → `bbu` → `rfu` — is byte-for-byte the same hierarchy in both versions. The redesign is entirely at the system/dataflow level: how weights and activations *reach* that arithmetic core, not what the core does with them once they arrive.

## What's still open

See [§11 Known Limitations](v2-systolic-row-precision/README.md#11-known-limitations) in the v2 README for the current list — legacy dead ports from the v1→v2 transition, unread BBU1/BBU2 outputs in non-INT8 modes, and application-level validation that needs to be re-run against v2.
