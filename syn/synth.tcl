# synth.tcl - synthesize dram_ctrl with the osu018 standard cell library
#
# Batch:  cd syn && dc_shell -f synth.tcl
# GUI:    cd syn && design_vision   then   source synth.tcl
#
# The library path defaults to the ECEN 468 Lab 7 copy on Olympus.
# Override it with:  setenv OSU018_DB /path/to/osu018_stdcells.db

if {[info exists env(OSU018_DB)]} {
  set LIB_DB $env(OSU018_DB)
} else {
  set LIB_DB "$env(HOME)/ECEN468/Lab7/src1/osu018_stdcells.db"
}

# clock period in ns (10 ns = 100 MHz); override with setenv CLK_PERIOD
if {[info exists env(CLK_PERIOD)]} {
  set CLK_PERIOD $env(CLK_PERIOD)
} else {
  set CLK_PERIOD 10.0
}

set_app_var search_path    ". ../rtl $search_path"
set_app_var target_library $LIB_DB
set_app_var link_library   "* $LIB_DB"
set_app_var symbol_library $LIB_DB

file mkdir reports netlist sdf work
define_design_lib WORK -path ./work

# ---------------------------------------------------------- read design
analyze -format verilog {../rtl/dram_ctrl.v}
elaborate dram_ctrl
current_design dram_ctrl
link
check_design > reports/check_design.rpt

# --------------------------------------------------------- constraints
create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_input_delay  1.0 -clock clk [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]
set_output_delay 1.0 -clock clk [all_outputs]
set_false_path -from [get_ports rst_n]

# --------------------------------------------------------------- compile
compile -exact_map

# --------------------------------------------------------------- reports
report_area                         > reports/area.rpt
report_area -hierarchy              > reports/area_hier.rpt
report_timing -max_paths 5          > reports/timing.rpt
report_qor                          > reports/qor.rpt
report_power                        > reports/power.rpt
report_reference                    > reports/cells.rpt
report_constraint -all_violators    > reports/violators.rpt

write -hierarchy -format verilog -output netlist/dram_ctrl_netlist.v
write_sdf sdf/dram_ctrl.sdf
write_sdc netlist/dram_ctrl.sdc

puts "Synthesis done. Reports are in syn/reports/"

# leave the GUI open when sourced from Design Vision
if {$synopsys_program_name == "dc_shell"} {
  exit
}
