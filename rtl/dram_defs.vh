// DRAM command encoding, shared by the controller and the testbench.
`ifndef DRAM_DEFS_VH
`define DRAM_DEFS_VH

`define CMD_NOP  3'd0
`define CMD_ACT  3'd1   // activate (open) a row in one bank
`define CMD_RD   3'd2   // read a column from the open row
`define CMD_WR   3'd3   // write a column in the open row
`define CMD_PRE  3'd4   // precharge (close) one bank
`define CMD_PREA 3'd5   // precharge all banks
`define CMD_REF  3'd6   // refresh (all banks must be closed)

`endif
