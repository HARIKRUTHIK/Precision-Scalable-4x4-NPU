# Build/run the npu_4_4 regression with Icarus Verilog.
#
#   make test           run the full regression
#   make test SEED=42   run with a fixed seed for the constrained-random test
#   make wave            open the last VCD dump in gtkwave
#   make clean           remove build artifacts

RTL_DIR := ../rtl
TB_DIR  := ../tb

RTL_SRCS := \
	$(RTL_DIR)/sbb.v \
	$(RTL_DIR)/bbu.v \
	$(RTL_DIR)/rfu.v \
	$(RTL_DIR)/pipe_reg.v \
	$(RTL_DIR)/accumulator.v \
	$(RTL_DIR)/fsm.v \
	$(RTL_DIR)/psmac_top.v \
	$(RTL_DIR)/global_buffer.v \
	$(RTL_DIR)/npu_ctrl.v \
	$(RTL_DIR)/npu_4_4.v

TB_SRC  := $(TB_DIR)/npu_4_4_tb.v

SIM_OUT := npu_sim.out
VCD     := npu_sim.vcd

SEED ?=

.PHONY: test wave clean

$(SIM_OUT): $(RTL_SRCS) $(TB_SRC)
	iverilog -g2012 -o $(SIM_OUT) $(TB_SRC) $(RTL_SRCS)

test: $(SIM_OUT)
ifdef SEED
	vvp $(SIM_OUT) +seed=$(SEED)
else
	vvp $(SIM_OUT)
endif

wave: $(VCD)
	gtkwave $(VCD) &

clean:
	rm -f $(SIM_OUT) $(VCD)
