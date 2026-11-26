# Run on Olympus. Set up the tools first:
#   source /opt/coe/synopsys/vcs/W-2024.09-SP2-4/setup.vcs.sh     (sim, cov, gls)
#   source /opt/coe/synopsys/syn/V-2023.12-SP1/setup.syn.sh       (synth)
#
#   make sim       one run (SEED=1)
#   make regress   10 seeds + summary table
#   make cov       merged coverage report
#   make synth     synthesis on osu018
#   make gls       gate-level sim of the synthesized netlist

SEED     ?= 1
NUM_TXNS ?= 2000
SEEDS    ?= 1 2 3 4 5 6 7 8 9 10
CM       := line+cond+fsm+tgl

LIB_V   ?= $(HOME)/ECEN468/Lab7/src1/osu018_stdcells.v
NETLIST := syn/netlist/dram_ctrl_netlist.v
SDF     := syn/sdf/dram_ctrl.sdf
TB      := tb/dram_model.sv tb/dram_timing_checker.sv tb/tb_top.sv

.PHONY: sim regress cov summary synth gls clean

simv: files.f rtl/* tb/*
	@mkdir -p logs
	vcs -full64 -sverilog -timescale=1ns/1ps -f files.f -top tb_top \
	    -cm $(CM) -debug_access+all -o simv -l logs/compile.log

sim: simv
	./simv +seed=$(SEED) +ntb_random_seed=$(SEED) +num_txns=$(NUM_TXNS) \
	    -cm $(CM) -cm_name seed_$(SEED) -l logs/seed_$(SEED).log

regress: simv
	@for s in $(SEEDS); do \
	  ./simv +seed=$$s +ntb_random_seed=$$s +num_txns=$(NUM_TXNS) \
	      -cm $(CM) -cm_name seed_$$s -l logs/seed_$$s.log > /dev/null; \
	done
	python3 scripts/parse_logs.py logs/seed_*.log

summary:
	python3 scripts/parse_logs.py logs/seed_*.log

cov:
	urg -dir simv.vdb -format text -report cov_report

synth:
	cd syn && dc_shell -f synth.tcl | tee synth.log

gls: $(NETLIST)
	@mkdir -p logs
	vcs -full64 -sverilog -timescale=1ns/1ps +define+GLS +incdir+rtl \
	    -v $(LIB_V) $(NETLIST) $(TB) -top tb_top \
	    -sdf max:tb_top.dut:$(SDF) +neg_tchk -o simv_gls -l logs/compile_gls.log
	./simv_gls +seed=$(SEED) +num_txns=$(NUM_TXNS) -l logs/gls_seed_$(SEED).log

clean:
	rm -rf simv* csrc ucli.key vc_hdrs.h cov_report logs results cm.log \
	       .fsm.sch.verilog.xml *.vcd syn/work syn/synth.log syn/*.svf syn/command.log
