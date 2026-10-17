# NPU-4×4 — Precision-Scalable Neural Processing Unit

A fully custom **4×4 systolic MAC array** built from arithmetic primitives, supporting runtime-switchable INT8 / INT4 / INT2 precision modes. Every multiply-accumulate operation traces back to hand-crafted half-adders and full-adders — no DSP blocks, no vendor inference, no shortcuts.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Design Philosophy](#2-design-philosophy)
3. [Architecture](#3-architecture)
   - 3.1 [Top-Level: npu_4_4](#31-top-level-npu_44)
   - 3.2 [Tile: psmac_top](#32-tile-psmac_top)
   - 3.3 [Reconfigurable Functional Unit (RFU)](#33-reconfigurable-functional-unit-rfu)
   - 3.4 [Bit-Block Unit (BBU)](#34-bit-block-unit-bbu)
   - 3.5 [Signed Bit-Block (SBB) — The Arithmetic Primitive](#35-signed-bit-block-sbb--the-arithmetic-primitive)
   - 3.6 [Pipeline Register](#36-pipeline-register)
   - 3.7 [Accumulator](#37-accumulator)
   - 3.8 [Weight Memory](#38-weight-memory)
   - 3.9 [Tile FSM](#39-tile-fsm)
   - 3.10 [NPU Controller (npu_ctrl)](#310-npu-controller-npu_ctrl)
4. [Precision Modes](#4-precision-modes)
5. [Data Flow](#5-data-flow)
6. [Signal Reference](#6-signal-reference)
7. [Hardware Metrics](#7-hardware-metrics)
8. [Verification](#8-verification)
9. [Applications](#9-applications)

---

## 1. Overview

| Property | Value |
|---|---|
| Array size | 4 rows × 4 columns = **16 tiles** |
| Precision modes | INT8 / INT4 / INT2 (runtime switchable) |
| Max vector length | 256 elements per tile |
| Result width | 32-bit signed accumulator per tile |
| Clock cycles (INT8, vec=16) | **16 cycles** |
| Clock cycles (INT4, vec=16) | **8 cycles** |
| Clock cycles (INT2, vec=16) | **4 cycles** |
| Arithmetic foundation | Half-adders + Full-adders (gate-level) |
| Control | Autonomous 5-state FSM sequencer |

The design answers a single question: **how much can you strip from a multiply-accumulate unit before it stops being useful?** The answer is: all the way down to 2-bit operands, without ever changing the hardware. The same 16 tiles that run a hospital-grade INT8 inference can be switched to INT2 mode and run the same network four times faster on a coin-cell budget.

---

## 2. Design Philosophy

Most NPU designs reach for DSP slices or pre-built multipliers. This design goes the other direction — every multiplication is decomposed into **3-bit × 3-bit partial products** assembled by signed bit-block (SBB) primitives built from half-adders and full-adders. The result is a hierarchy where precision is a structural property, not a mode bit you hand to a black-box multiplier.

```
gate primitives (AND, XOR)
       │
       ▼
  ha / fa  ─── Half Adder / Full Adder
       │
       ▼
  sbb  ─────── Signed Bit-Block  (3b × 3b → 5b signed)
       │
       ▼
  BBU  ─────── Bit-Block Unit    (4b × 4b, 4 SBBs)
       │
       ▼
  RFU  ─────── Reconfigurable FU (8b × 8b, 4 BBUs, mode-steered output)
       │
       ▼
  psmac_top ── Tile (memory + RFU + pipeline + accumulator + FSM)
       │
       ▼
  npu_4_4 ──── 4×4 array + global controller
```

Each layer adds one abstraction. Nothing is hidden. Any signal in the design is traceable back to a wire between two gates.

---

## 3. Architecture

### 3.1 Top-Level: `npu_4_4`

![npu_4_4 top-level block diagram](img_npu_top.png)

The top level instantiates 16 `psmac_top` tiles in a `generate` loop indexed `[row][col]`. Tile index is `row*4 + col`. Write enables are gated combinationally — tile `k` only sees `we_w` when `tile_sel == k`, and all tiles in column `c` share `x_mem` writes when `col_sel == c`. The `out_valid` output is a bitwise AND of all 16 tile `out_valid` signals — the top level only asserts completion when every tile has finished.

### 3.2 Tile: `psmac_top`

Each of the 16 tiles is a self-contained compute unit with its own memory, arithmetic pipeline, and FSM.

![psmac_top tile block diagram](img_psmac_top.png)

**Pipeline timing (INT8, one MAC operation):**

```
Cycle N:    FSM in RUN → addr=N drives w_mem/x_mem → w_out/x_out valid (async read)
                         RFU computes product combinationally
Cycle N+1:  pipe_reg latches RFU output → data_out valid
            acc_en_d1 asserted (one cycle delayed to align with pipe_reg)
Cycle N+1:  accumulator adds data_out to running sum
```

The one-cycle delay register (`acc_en_d1`) is the critical timing element — it ensures the accumulator sees stable data from the pipeline register, not combinational RFU output.

### 3.3 Reconfigurable Functional Unit (RFU)

The RFU computes one byte × byte product per cycle and steers the output format based on `mode`.

![RFU — 8-bit × 8-bit reconfigurable functional unit](img_rfu.png)

The key insight: in INT8 mode the four BBU outputs are combined via shift-and-add to reconstruct the full 16-bit product. In INT4 mode the BBU outputs are kept separate as four independent 4-bit products. In INT2 mode each BBU's internal SBB outputs are kept separate as sixteen independent 2-bit products. **The same four BBU instances handle all three cases — the output mux selects how many partial products to expose.**

Signed arithmetic is handled by selectively masking the sign bits of the high nibbles. `sx` controls whether `xH` is treated as signed, `sy` controls `yH`. In INT8 mode both are asserted for fully signed multiplication.

### 3.4 Bit-Block Unit (BBU)

Each BBU computes a 4-bit × 4-bit product using four SBB instances.

![BBU — 4-bit × 4-bit bit-block unit](img_bbu.png)

The same partial-product recombination pattern as the RFU, but one level down in the hierarchy. Signed extension is passed through from the parent: the MSB of each 4-bit nibble carries the sign only when the corresponding `sx`/`sy` flag is asserted.

### 3.5 Signed Bit-Block (SBB) — The Arithmetic Primitive

The SBB is the innermost compute element. It multiplies two **3-bit operands** (with optional sign extension on bit 2) and produces a **5-bit signed product**. It is built entirely from half-adders and full-adders — no `*` operator, no LUT inference beyond what the logic implies.

```
SBB truth (unsigned example, sx=sy=0):
  x[2:0] × y[2:0] → p[4:0]

Partial product array:
  p[0]   = x0·y0
  p[1]   = x0·y1 ⊕ x1·y0                    (HA)
  p[2]   = x1·y1 ⊕ x2·y0  ⊕ carry(p1)       (FA + HA with x0·y2)
  p[3]   = carry chain through FA2, FA3
  p[4]   = sign correction term

Signed mode (sx=1 or sy=1):
  x[2] or y[2] used as sign bit
  NAND gates negate cross-products involving sign bits
  sign correction injected via constant 1'b1 in FA2
```

The five output bits of SBB map directly into the partial product array of BBU. There is no intermediate register — the entire multiply path from SBB inputs to accumulator is combinational within one clock cycle.

**Gate-level composition:**
```
SBB contains:  2 × HA + 3 × FA
BBU contains:  4 × SBB  = 8 HA + 12 FA
RFU contains:  4 × BBU  = 32 HA + 48 FA
Tile contains: 1 × RFU  = 32 HA + 48 FA  (plus pipeline + accumulator)
Array contains: 16 tiles = 512 HA + 768 FA
```

### 3.6 Pipeline Register

An 80-bit register that sits between the RFU and accumulator. Clocked on `pipe_en` from the FSM, it latches the full RFU output (which is valid within the same cycle as the memory read, but may be unstable during address transitions). Also latches `mode`, `sx`, `sy` so the accumulator always sees the mode that was active when the RFU computed, not whatever mode might be set by the time accumulation happens.

```
  Input  [79:0]  rfu_out  — full RFU partial product bus
  Output [79:0]  data_out — registered, stable for accumulator
         [1:0]   mode_out — registered mode
                 sx_out, sy_out
```

### 3.7 Accumulator

A 32-bit signed accumulator that interprets the pipeline register output according to the latched mode.

```verilog
// INT8 (mode=10): one 16-bit product per cycle
wire signed [31:0] int8_sum = {{16{data_out[15]}}, data_out[15:0]};

// INT4 (mode=01): two 11-bit products per cycle, summed
wire signed [31:0] int4_p0  = {{21{data_out[10]}}, data_out[10:0]};
wire signed [31:0] int4_p3  = {{21{data_out[43]}}, data_out[43:33]};
wire signed [31:0] int4_sum = int4_p0 + int4_p3;

// INT2 (mode=00): four 5-bit products per cycle, summed
wire signed [31:0] int2_sum = int2_p0 + int2_p1 + int2_p2 + int2_p3;

always @(posedge clk)
    if (clear)  result <= 0;
    else if (acc_en) result <= result + tree_out;
```

The `clear` signal fires one cycle before accumulation begins (FSM CLEAR state), ensuring no residue from a previous operation contaminates the new result. This is the architectural guarantee that back-to-back inferences are always independent.

### 3.8 Weight Memory

Each tile contains a dual-port SRAM with one write port and one read port, split into two arrays:

```
  w_mem[0:DEPTH-1]  — weight vector (written by host, read by FSM)
  x_mem[0:DEPTH-1]  — input vector  (written by host, read by FSM)

  Write (synchronous):  we_w → w_mem[w_addr] ← w_data
                        we_x → x_mem[x_addr] ← x_data
  Read  (asynchronous): w_out = w_mem[addr]   (combinational)
                        x_out = x_mem[addr]   (combinational)
```

Asynchronous read is intentional — it means the memory output is valid in the same cycle that `addr` is presented, allowing the RFU to compute combinationally and the result to be captured by the pipeline register on the next edge. DEPTH=256 means each tile can store a 256-element weight vector, supporting up to 256-element dot products per pass.

### 3.9 Tile FSM

A 4-state Moore FSM inside each `psmac_top` that independently manages the compute sequence for that tile.

![PSMAC tile FSM — 4 states](img_psmac_fsm.png)

`run_target` is computed from `vec_len` and `mode`:
```
  INT8 (mode=10):  run_target = vec_len
  INT4 (mode=01):  run_target = vec_len >> 1   (2 products per cycle)
  INT2 (mode=00):  run_target = vec_len >> 2   (4 products per cycle)
```

The DONE state exists to flush the last product through the pipeline register, which has one cycle of latency. Without it the final accumulation would be missed.

### 3.10 NPU Controller (`npu_ctrl`)

A 5-state global sequencer that orchestrates the full inference sequence across all 16 tiles.

![npu_ctrl FSM — 5 states](img_npu_ctrl_fsm.png)

The RUN state is exactly one clock cycle — `psmac_en` is a single-cycle pulse that triggers all 16 tile FSMs simultaneously. After that pulse the controller enters COLLECT and waits for all 16 `out_valid` signals to be asserted (via the `all_valid = &ov_bus` signal from the top level). `npu_valid` is asserted for one cycle when COLLECT sees `all_valid`, then cleared immediately on return to IDLE.

---

## 4. Precision Modes

All three modes use the same hardware. The mode bits change how the RFU routes partial products and how the accumulator interprets the pipeline bus.

| mode[1:0] | Name | Products / cycle | run_target   | Accumulator lane                          |
|----------|------|------------------|--------------|-------------------------------------------|
| 2'b10    | INT8 | 1                | vec_len      | data_out[15:0] (sign-extended)            |
| 2'b01    | INT4 | 2                | vec_len >> 1 | [10:0] + [43:33]                          |
| 2'b00    | INT2 | 4                | vec_len >> 2 | [4:0] + [19:15] + [64:60] + [79:75]       |

**Switching precision at runtime** requires only changing `mode` before asserting `npu_en`. The tile FMSs, memories, and pipeline all respond to the current mode value. No reset required, no reconfiguration latency.

**Throughput scaling:**

```
  vec_len = 16 elements
  
  INT8:  16 cycles  (1 byte processed per cycle)
  INT4:   8 cycles  (2 nibbles packed per byte, 2× throughput)
  INT2:   4 cycles  (4 pairs packed per byte, 4× throughput)
```

---

## 5. Data Flow

A complete inference pass for one dot product (Layer 0, one neuron):

```
Step 1 — Pre-load weights (before npu_en)
  Host writes W[0..vl-1] into tile's w_mem via we_w / tile_sel / w_addr / w_data

Step 2 — Pre-load inputs (before npu_en)
  Host writes X[0..vl-1] into column's x_mem via we_x / col_sel / x_addr / x_data

Step 3 — npu_en pulse (1 cycle)
  npu_ctrl transitions IDLE → LOAD_W → LOAD_X → RUN → COLLECT

Step 4 — RUN (1 cycle)
  npu_ctrl asserts psmac_en for exactly 1 cycle
  All 16 tile FSMs transition IDLE → CLEAR → RUN simultaneously

Step 5 — Accumulation (vec_len cycles for INT8)
  Each cycle:
    addr = counter (0, 1, 2, ...)
    w_mem[addr] → w_out (combinational)
    x_mem[addr] → x_out (combinational)
    RFU(w_out, x_out) → rfu_out (combinational, same cycle)
    pipe_reg latches rfu_out on clock edge
    accumulator adds pipe_reg output (with acc_en_d1 alignment)

Step 6 — DONE flush (1 cycle)
  pipe_en asserted, acc_en_d1 fires for last product
  out_valid_fsm asserted

Step 7 — Result collection
  out_valid (delayed 1 cycle) goes high
  all_valid = &ov_bus → npu_valid pulse
  Host reads result_out by driving result_sel = tile_index
```

---

## 6. Signal Reference

### Top-level ports (`npu_4_4`)

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock |
| `rst` | in | 1 | Synchronous reset (active high) |
| `npu_en` | in | 1 | Start inference (1-cycle pulse) |
| `mode` | in | 2 | Precision: `10`=INT8, `01`=INT4, `00`=INT2 |
| `vec_len` | in | 8 | Number of elements in dot product |
| `sx` | in | 1 | Sign flag for X operand (1=signed) |
| `sy` | in | 1 | Sign flag for Y (weight) operand (1=signed) |
| `we_w` | in | 1 | Weight memory write enable |
| `tile_sel` | in | 4 | Target tile for weight write (0–15) |
| `w_addr` | in | 8 | Weight memory address |
| `w_data` | in | 8 | Weight data byte |
| `we_x` | in | 1 | Input memory write enable |
| `col_sel` | in | 2 | Target column for input write (0–3) |
| `x_addr` | in | 8 | Input memory address |
| `x_data` | in | 8 | Input data byte |
| `result_sel` | in | 4 | Select which tile result to read (0–15) |
| `result_out` | out | 32 | 32-bit signed result for selected tile |
| `out_valid` | out | 1 | High when all 16 tiles have valid results |

### Internal observation signals

| Signal | Source | Description |
|---|---|---|
| `DUT.npu_valid` | `npu_ctrl` | 1-cycle pulse on inference complete |
| `DUT.psmac_en` | `npu_ctrl` | 1-cycle trigger to all tile FSMs |
| `DUT.state_dbg` | `npu_ctrl` | 3-bit FSM state (0=IDLE … 4=COLLECT) |
| `DUT.CTRL.tile_sel` | `npu_ctrl` | Current tile being addressed |
| `DUT.CTRL.col_sel` | `npu_ctrl` | Current column being addressed |

---

## 7. Hardware Metrics

### Cycle counts

| Operation | INT8 | INT4 | INT2 |
|---|---|---|---|
| vec_len = 1 | 4 | 3 | 3 |
| vec_len = 4 | 7 | 5 | 4 |
| vec_len = 16 | 19 | 11 | 7 |
| vec_len = 256 | 259 | 131 | 67 |

*(Includes CLEAR=1 cycle + RUN=vec/rate cycles + DONE=1 cycle + pipeline latency)*

### Relative efficiency across modes

| Mode | Products/cycle | Cycles (vec=16) | Relative throughput | Relative power (estimated) |
|---|---|---|---|---|
| INT8 | 1 | 16 | 1× | 1.00× |
| INT4 | 2 | 8 | 2× | ~0.52× |
| INT2 | 4 | 4 | 4× | ~0.27× |

### Structural composition

| Module | Count per tile | Count across 16 tiles |
|---|---|---|
| SBB (3b×3b) | 16 | 256 |
| BBU (4b×4b) | 4 | 64 |
| RFU (8b×8b) | 1 | 16 |
| HA (half-adder) | 32 | 512 |
| FA (full-adder) | 48 | 768 |
| Pipeline registers | 80b | 1280b |
| Accumulator | 32b | 512b |
| Weight + input SRAM | 2 × 256B | 8 KB total |

### Controller overhead

| Signal | Guarantee |
|---|---|
| `psmac_en` pulse width | Exactly 1 clock cycle |
| `npu_valid` pulse width | Exactly 1 clock cycle |
| `out_valid` persistence | Held until next `psmac_en` |
| Tile FSM isolation | Each tile independently valid |
| Back-to-back latency | 0 idle cycles between operations |

### Verified test coverage (447 checks, 0 failures)

| Group | What is tested |
|---|---|
| Reset & initial state | Out-of-reset cleanliness |
| Per-tile addressability | All 16 tiles independently loaded and read |
| INT8 dot products | Uniform and unique weights, vec_len 1–16 |
| Signed arithmetic | neg×neg, pos×neg, ±128 extremes |
| Column isolation | 4-column input routing correctness |
| Back-to-back operations | Accumulator cleared between runs |
| npu_valid timing | 1-cycle pulse, correct IDLE behaviour |
| psmac_en pulse width | Monitored every cycle across all tests |
| INT4 mode | Packed nibble arithmetic |
| INT2 mode | Packed pair arithmetic |
| Mode switching | INT8→INT4→INT8 without reset |
| Rapid reset/relaunch | 3× stress with different data each time |

---

## 8. Verification

The testbench (`npu_4_4_tb.v`) drives the DUT through 20 test groups covering 447 individual checks. All weights and inputs are pre-loaded via hierarchical force (`DUT.row[r].col[c].tile.WEIGHT_MEM.w_mem[addr]`) to avoid the bus-conflict problem that arises when the testbench and controller simultaneously drive the same write-enable nets.

Key verification decisions:

**Gold reference model** — the testbench maintains a software reference array `w_ref[tile][addr]` and `x_ref[col][addr]` that mirrors every hierarchical write. Expected dot products are computed in the testbench and compared cycle-accurately against the NPU result.

**psmac_en monitor** — a continuous `always` block counts consecutive cycles of `psmac_en` high and flags any run exceeding 1 cycle. This caught a controller bug early where `npu_valid` was cleared only in `LOAD_W` rather than on `IDLE`, causing `run_npu()` to return early before the new operation completed.

**npu_valid timing group (Group 10)** — specifically verifies the 1-cycle pulse contract: `npu_valid` must be low before the operation, high exactly once when COLLECT sees `all_valid`, and low again on the next cycle.

---

## 9. Applications

The NPU's value is not the classifier — any software model can classify ECG data. The value is the **deployment tier**. A single chip can serve three hardware contexts without modification:

**ECG Arrhythmia Detection (MIT-BIH)**
Classifies Normal / SVT / VT heartbeats from a 16-dimensional PCA feature vector extracted from a 187-sample heartbeat window. A 3-layer MLP (16→3→3→3) maps directly onto the tile array — Layer 0 uses all 16 tiles, Layers 1 and 2 use 3 tiles each with zero-padded vec_len=4.

| Mode | Cycles | Use case |
|---|---|---|
| INT8 | 24 | ICU bedside monitor, mains-powered |
| INT4 | 12 | Ambulatory Holter device, rechargeable |
| INT2 | 6 | Stick-on patch, coin cell, weeks of runtime |

Achieved 99.42% float accuracy, 96.75% INT8 quantised accuracy, 100% hardware match rate across 20 test vectors.

**Drone Acoustic Detection**
A 40-coefficient mel filterbank feature vector extracted from a 25ms audio window feeds a 2-class (drone / background) MLP. The always-on INT2 mode — 33 cycles per classification window — draws well under 1 mW, enabling continuous acoustic surveillance on a harvested-energy sensor node.

**Keyword Spotting**
MFCC features from the Google Speech Commands dataset feed a wake-word detector. INT2 mode processes one 25ms window every 35 cycles, enabling always-on detection at a power budget compatible with wireless earbuds and implantable hearing devices.

The precision story is the same in every application: **the same trained weights, the same hardware, three different power-latency operating points selected at boot time** — or switched mid-operation without a reset.

---

## File Index

```
npu_4_4.v        — Top-level 4×4 array + controller integration
npu_ctrl.v       — 5-state global sequencer (IDLE/LOAD_W/LOAD_X/RUN/COLLECT)
psmac_top.v      — Tile wrapper (memory + RFU + pipeline + accumulator + FSM)
rfu.v            — Reconfigurable Functional Unit (8b×8b, 4 BBUs)
BBU.v            — Bit-Block Unit (4b×4b, 4 SBBs)
sbb.v            — Signed Bit-Block (3b×3b, ha+fa primitives) + ha + fa
pipe_reg.v       — 80-bit pipeline register
accumulator.v    — 32-bit signed accumulator with mode-steered input tree
weight_mem.v     — Dual-array SRAM (w_mem + x_mem, depth=256)
fsm.v            — Per-tile 4-state FSM (IDLE/CLEAR/RUN/DONE)
npu_4_4_tb.v     — Top-level testbench (447 checks, 20 groups)
```

---

*Built from AND gates up.*
