# DRAM memory controller

A small DRAM-style memory controller in Verilog with a SystemVerilog testbench.
I made it to learn how a memory controller deals with banks, open rows, timing
and refresh. Simulated with VCS, then synthesized with Design Compiler on the
osu018 library, all on the Olympus server.

## How it works

The controller takes one read or write request at a time and turns it into
DRAM commands (ACT, RD, WR, PRE, PREA, REF).

The memory has 4 banks, and each bank can have one row open at a time.
Opening a row (ACT) and closing it (PRE) take a few cycles, so each request
falls into one of three cases:

- **row hit**: the row is already open, so it just reads or writes
- **row miss**: another row is open, so it closes it, opens the right one, then reads or writes
- **empty**: nothing is open in that bank, so it opens the row, then reads or writes

Rows stay open after an access (open-page policy), so the next access to the
same row is fast.

Timing rules are parameters, in clock cycles:

| Parameter | Meaning |
|---|---|
| tRCD = 3 | ACT to RD/WR |
| tRP = 3 | PRE to ACT |
| tRAS = 7 | ACT to PRE (minimum time a row stays open) |
| CL = 3 | RD to data |
| tRFC = 10 | time a refresh takes |
| tREFI = 300 | time between refreshes |

Every 300 cycles a refresh is due. The controller stops taking requests,
closes all banks, refreshes, then goes back to normal.

The whole thing is one state machine: IDLE, PRE, ACT, RW, RD_WAIT, plus
REF_PRE, REF and REF_WAIT for refresh. Address format is `{row, bank, col}`
(8-bit row, 2-bit bank, 4-bit column) with 16-bit data.

## Testbench

- Random reads and writes. 60% of requests go to the last row used in that
  bank, so there is a good mix of hits and misses.
- A scoreboard that keeps a copy of memory and checks every read against it.
- A behavioral DRAM model that stores the data and returns it CL cycles after a read.
- A timing checker that only watches the command bus and flags any tRCD, tRP,
  tRAS, tRFC or refresh-interval violation.
- Functional coverage: every request type in every bank, reads and writes,
  and refreshes with and without a request waiting.

## Results

10 seeds, 2,000 requests each (VCS):

- 10/10 passed, 0 data mismatches, 0 timing violations
- row hit rate 57.8%
- average read latency: 6 cycles on a hit, 9 on an empty bank, 12 on a miss
- functional coverage 100%; code coverage on the controller is 99% line and
  100% condition

FSM transition coverage is 75%. The missing transitions are reset in the
middle of a request, which the testbench doesn't do (it only resets at the start).

Synthesis on osu018 with a 10 ns (100 MHz) clock:

- 1,321 cells, 177 flip-flops, total area 56,168
- timing met with 7.22 ns of slack (longest path is 2.69 ns)
- gate-level simulation of the netlist with SDF delays passes and gives the
  same results as the RTL simulation

The reports are in `reports/`.

## Running it

On Olympus:

```bash
source /opt/coe/synopsys/vcs/W-2024.09-SP2-4/setup.vcs.sh
make regress     # 10 seeds, prints a summary table
make cov         # coverage report in cov_report/

source /opt/coe/synopsys/syn/V-2023.12-SP1/setup.syn.sh
make synth       # reports in syn/reports/

source /opt/coe/synopsys/vcs/W-2024.09-SP2-4/setup.vcs.sh
make gls         # gate-level sim
```

The synthesis setup changes `VCS_HOME`, so source the VCS setup again before
`make gls`. The osu018 library path is set in `syn/synth.tcl` and in the Makefile
(`LIB_V`).

## Files

```
rtl/dram_ctrl.v            the controller
rtl/dram_defs.vh           command codes
tb/tb_top.sv               testbench (random traffic, scoreboard, coverage)
tb/dram_model.sv           behavioral DRAM
tb/dram_timing_checker.sv  timing checks on the command bus
syn/synth.tcl              Design Compiler script
scripts/parse_logs.py      summary table from the regression logs
```

## What I'd add next

- a small request queue that serves row hits first (FR-FCFS)
- more timing rules: tWR, tRRD, tFAW
- a test that resets in the middle of traffic
