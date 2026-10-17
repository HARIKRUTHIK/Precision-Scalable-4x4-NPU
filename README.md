# Precision-Scalable 4×4 Neural Processing Unit (PSMAC)
### Row-Concurrent Bit-Fusion Systolic MAC Array for Mixed-Precision Edge Inference

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![FPGA: Cyclone IV](https://img.shields.io/badge/FPGA-Altera%20Cyclone%20IV%20EP4CE115-darkgreen.svg)](quartus/psmac_top.qsf)
[![Verification: 2588 Checks](https://img.shields.io/badge/Verification-2%2C588%20Checks%20Passing-brightgreen.svg)](tb/npu_4_4_tb.v)
[![Precision: INT8/INT4/INT2](https://img.shields.io/badge/Precision-INT8%20%7C%20INT4%20%7C%20INT2-orange.svg)](rtl/rfu.v)
[![Arithmetic: Hand--Instantiated Adders](https://img.shields.io/badge/Arithmetic-Zero%20Vendor%20DSP%20Blocks-red.svg)](rtl/sbb.v)

A synthesizable **4×4 weight-stationary systolic MAC array** designed from gate-level arithmetic primitives up, featuring **per-row independently reconfigurable mixed-precision (INT8, INT4, INT2)**. The architecture achieves dynamic precision scaling without requiring vendor DSP blocks, IP cores, or temporal reconfiguration bubbles between rows.

---

## 1. Architectural Highlights

![Top-Level Architecture](docs/v2-systolic-row-precision/img/top_level_architecture.png)

- **Pure Arithmetic Primitives**: Zero usage of Verilog `*` operator or vendor DSP macrocells. Every multiplication resolves into hand-instantiated half-adders (`ha`) and full-adders (`fa`) implementing modified **Baugh-Wooley** sign-magnitude 2-bit cells.
- **Hierarchical Bit-Fusion**:
  - **`sbb.v` (Scalable Building Block)**: 2-bit $\times$ 2-bit multiplier cell handling 2's complement and unsigned operands with carry-save reduction.
  - **`bbu.v` (Bit-Level Processing Unit)**: Combines four `sbb` blocks via Karatsuba-inspired decomposition to execute either one 4-bit $\times$ 4-bit product or four parallel 2-bit products.
  - **`rfu.v` (Reconfigurable Functional Unit)**: Fuses four `bbu` units into one 8-bit $\times$ 8-bit MAC product, two 4-bit MAC products, or four 2-bit MAC products with sign-extension preservation.
- **Row-Concurrent Mixed-Precision**: Rows independently execute different precision modes simultaneously (e.g., Row 0 at INT8, Row 1 at INT4, Rows 2–3 at INT2).
- **Two Generations of Evolution**:
  - **v1 (Independent Tiles)**: Dedicated dual-port local SRAM per tile with sequential FSM sequencer. Identified as memory bandwidth constrained.
  - **v2 (Systolic 4×4 Array with Skew Buffers)**: Shared global activation buffer, systolic horizontal activation flow, and vertical stationary weight residency. [Read the full Evolution Engineering Postmortem](docs/EVOLUTION.md).
- **Automated Verification**: **2,588** verification checks passing across directed corner cases, protocol handshakes, and constrained-random stimulus in `tb/npu_4_4_tb.v`, plus 15 unit-level test suites in `tb/tb_psmac_top.v`.

---

## 2. Arithmetic Bit-Fusion Hierarchy

![Bit Decomposition Hierarchy](docs/v2-systolic-row-precision/img/bit_decomposition_hierarchy.png)

### Precision Modes & Throughput Scaling

$$\text{Mode}[1:0] = \begin{cases} 
2'b10 & \to \text{INT8 Mode: } 1 \times [8\text{-bit} \times 8\text{-bit MAC}] \text{ per tile} \\
2'b01 & \to \text{INT4 Mode: } 2 \times [4\text{-bit} \times 4\text{-bit MAC}] \text{ per tile} \\
2'b00 & \to \text{INT2 Mode: } 4 \times [2\text{-bit} \times 2\text{-bit MAC}] \text{ per tile}
\end{cases}$$

Across the 16-tile array (4 rows $\times$ 4 columns):
- **INT8 Mode**: 16 parallel 8-bit MAC operations/cycle.
- **INT4 Mode**: 32 parallel 4-bit MAC operations/cycle ($2\times$ throughput).
- **INT2 Mode**: 64 parallel 2-bit MAC operations/cycle ($4\times$ throughput).

---

## 3. Tile & Scheduler Microarchitecture

| Tile Architecture (`psmac_top`) | Weight Row Scheduler |
| :---: | :---: |
| ![Tile Microarchitecture](docs/v2-systolic-row-precision/img/tile_psmac_top.png) | ![Weight Row Scheduler](docs/v2-systolic-row-precision/img/weight_row_scheduler.png) |

Each tile integrates:
1. **Reconfigurable Functional Unit (`rfu`)**: Combinational tree computing 80-bit packed raw partial products.
2. **Pipelined Latch Stage (`pipe_reg`)**: Breaks critical path between spatial bit reduction and accumulation.
3. **Multi-Mode Saturated Accumulator (`accumulator`)**: Dynamically shifts and sign-extends the packed 80-bit bus to accumulate into a 32-bit signed result register.

---

## 4. Hardware Implementation & Synthesis Results

Targeted and constrained for the **Intel / Altera Cyclone IV E `EP4CE115F29C7`** on the Terasic DE2-115 development board:

| Metric | Target Specification / Measured Result |
| :--- | :--- |
| **FPGA Family** | Altera Cyclone IV E |
| **Target Device** | `EP4CE115F29C7` (472 I/O, 114,480 LEs) |
| **Board Platform** | Terasic DE2-115 Development Board |
| **Operating Frequency ($F_{max}$)** | **40 MHz** (conservative STA closure on Cyclone IV -7 speed grade) |
| **Embedded Multiplier / DSP Blocks** | **0 / 266 (0%)** — Pure logic element implementation |
| **Logic Elements (Single Tile)** | ~380 LEs per tile |
| **Pin Assignments** | Complete 472-pin mapping in [`constraints/DE2_115_pin_assignments.csv`](constraints/DE2_115_pin_assignments.csv) |
| **Clock / Reset Constraints** | Standard 50 MHz on-board oscillator with PLL synthesis down to 40 MHz |

---

## 5. Repository Structure

```
Precision-Scalable-4x4-NPU/
├── README.md                           # Comprehensive architectural specification
├── LICENSE                             # MIT Open Source License
├── rtl/                                # Synthesizable Verilog HDL (v2 Systolic Suite)
│   ├── npu_4_4.v                       # 4x4 Systolic Array top-level module
│   ├── npu_ctrl.v                      # Multi-phase sequencer FSM (Load W, Load X, Stream, Drain)
│   ├── global_buffer.v                 # Skew-buffered activation and weight memory
│   ├── psmac_top.v                     # Individual systolic tile module
│   ├── rfu.v                           # 80-bit Reconfigurable Functional Unit
│   ├── bbu.v                           # 4-bit Bit-Level Processing Unit (Karatsuba decomposition)
│   ├── sbb.v                           # 2-bit Scalable Baugh-Wooley Multiplier Block
│   ├── accumulator.v                   # Multi-mode 32-bit signed accumulator
│   ├── pipe_reg.v                      # Inter-stage pipeline isolation register
│   └── fsm.v                           # Tile-level execution controller
├── tb/                                 # Verification Testbenches
│   ├── npu_4_4_tb.v                    # Comprehensive systolic array regression (2,588 checks)
│   └── tb_psmac_top.v                  # 15-suite directed tile testbench (INT8, INT4, INT2, corner cases)
├── sim/                                # Simulation Scripts
│   ├── Makefile                        # Icarus Verilog automated test target
│   └── run.sh                          # One-click regression runner
├── quartus/                            # Intel Quartus Prime Synthesis Project
│   ├── psmac_top.qpf                   # Quartus Project File
│   └── psmac_top.qsf                   # Quartus Settings File (Cyclone IV E target)
├── constraints/                        # Board Constraints
│   └── DE2_115_pin_assignments.csv     # Terasic DE2-115 Cyclone IV FPGA pin map
├── docs/                               # Engineering Reports & Presentations
│   ├── NPU_FINAL_FPGA.pdf              # 19-Page Technical Report
│   ├── Precision-Scalable-NPU-44.pptx  # 16-Slide Technical Seminar & Defense Presentation
│   ├── IEEE_TCAS_Reference_Paper.pdf   # IEEE TCAS-II Foundation Paper
│   ├── Project_Specification.pdf       # Academic Project Problem Statement
│   ├── psmac_npu_pitch_deck.html       # Interactive Architectural Pitch Deck
│   ├── EVOLUTION.md                    # Architectural Evolution Analysis (v1 -> v2)
│   └── debugging/                      # Hardware Debugging Postmortems
├── workload/                           # Edge ML Mapping & Quantization Pipelines
│   ├── PSMAC_Pipeline_NPU4x4.ipynb     # Chest X-Ray Pneumonia quantized deployment (16 tiles)
│   └── psmac_ecg_kaggle.ipynb          # ECG Arrhythmia classification workload
└── archive/                            # First-Generation RTL
    └── v1-independent-tile/            # Frozen v1 codebase for historical reference
```

---

## 6. Edge Machine Learning Workloads

The systolic array is validated with end-to-end Python quantization and export pipelines:

1. **Chest X-Ray Pneumonia Detection Pipeline** ([`workload/PSMAC_Pipeline_NPU4x4.ipynb`](workload/PSMAC_Pipeline_NPU4x4.ipynb)):
   - Trains a convolutional neural network on chest radiographs.
   - Applies symmetric min-max INT8 quantization to weights and activations.
   - Splits parameters across 16 tiles (`weights_tile_RR_CC.hex`) and streams activation columns (`input_col_CC_NN.hex`).
   - Bit-accurate comparison between TensorFlow INT8 predictions and hardware output.

2. **ECG Arrhythmia Classification Workload** ([`workload/psmac_ecg_kaggle.ipynb`](workload/psmac_ecg_kaggle.ipynb)):
   - Multi-class cardiac heartbeat arrhythmia detection evaluated under dynamic INT8 $\to$ INT4 $\to$ INT2 precision degradation.

---

## 7. Verification & Quick Start

### Prerequisites
- [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog`, `vvp`) or Siemens ModelSim / QuestaSim.

### Running the Systolic Array Regression Suite
```bash
cd sim
make test
```
To run constrained-random testing with a specific PRNG seed:
```bash
make test SEED=42
```

### Running ModelSim Unit Testbench
```bash
vlog rtl/*.v tb/tb_psmac_top.v
vsim -c -do "run -all; quit" psmac_top_tb
```

---

## 8. Authors & References

- **Author**: Hari Kruthik SK  
- **Institution**: School of Electronics Engineering (SENSE), Vellore Institute of Technology (VIT), Vellore  
- **Reference**: *"A Precision-Scalable Energy-Efficient Bit-Serial Multiply-Accumulate Accelerator for Deep Neural Networks"*, IEEE Transactions on Circuits and Systems II (TCAS-II).
- **License**: Released under the [MIT License](LICENSE).