// dram_model.sv
// Behavioral DRAM device used by the testbench (not synthesized).
// Keeps one open row per bank, stores data, and returns read data
// T_CL cycles after a RD command. It flags protocol errors such as
// reading a closed bank or activating a bank that is already open.

`timescale 1ns/1ps
`include "dram_defs.vh"

module dram_model #(
  parameter BANK_BITS = 2,
  parameter ROW_BITS  = 8,
  parameter COL_BITS  = 4,
  parameter DATA_W    = 16,
  parameter T_CL      = 3
) (
  input                        clk,
  input                        rst_n,
  input        [2:0]           cmd,
  input        [BANK_BITS-1:0] bank,
  input        [ROW_BITS-1:0]  row,
  input        [COL_BITS-1:0]  col,
  input        [DATA_W-1:0]    wdata,
  output logic [DATA_W-1:0]    rdata
);

  localparam NUM_BANKS = 1 << BANK_BITS;
  localparam DEPTH     = 1 << (BANK_BITS + ROW_BITS + COL_BITS);

  logic [DATA_W-1:0]   mem [DEPTH];
  logic                is_open  [NUM_BANKS];
  logic [ROW_BITS-1:0] open_row [NUM_BANKS];

  // read data pipeline: stage k is on the bus k cycles after the RD
  logic [DATA_W-1:0] rd_pipe [1:T_CL];

  int errors = 0;

  function automatic int idx(input logic [BANK_BITS-1:0] b,
                             input logic [ROW_BITS-1:0]  r,
                             input logic [COL_BITS-1:0]  c);
    return int'({b, r, c});
  endfunction

  initial begin
    for (int k = 0; k < DEPTH; k++) mem[k] = '0;
  end

  // small output delay, like a real device's clock-to-data time, so the
  // data never changes exactly on the clock edge (matters for gate-level
  // simulation with SDF hold checks)
  assign #1 rdata = rd_pipe[T_CL];

  always @(posedge clk) begin
    if (!rst_n) begin
      for (int b = 0; b < NUM_BANKS; b++) is_open[b] <= 1'b0;
      for (int s = 1; s <= T_CL; s++)     rd_pipe[s] <= 'x;
    end else begin
      // shift the read pipeline; empty slots drive X so a mistimed
      // sample in the controller shows up as a data mismatch
      rd_pipe[1] <= 'x;
      for (int s = 2; s <= T_CL; s++) rd_pipe[s] <= rd_pipe[s-1];

      case (cmd)
        `CMD_ACT: begin
          if (is_open[bank]) begin
            errors++;
            $error("[DRAM] ACT to bank %0d which already has row %0d open", bank, open_row[bank]);
          end
          is_open[bank]  <= 1'b1;
          open_row[bank] <= row;
        end
        `CMD_RD: begin
          if (!is_open[bank]) begin
            errors++;
            $error("[DRAM] RD to closed bank %0d", bank);
          end
          rd_pipe[1] <= mem[idx(bank, open_row[bank], col)];
        end
        `CMD_WR: begin
          if (!is_open[bank]) begin
            errors++;
            $error("[DRAM] WR to closed bank %0d", bank);
          end
          mem[idx(bank, open_row[bank], col)] <= wdata;
        end
        `CMD_PRE:  is_open[bank] <= 1'b0;
        `CMD_PREA: for (int b = 0; b < NUM_BANKS; b++) is_open[b] <= 1'b0;
        `CMD_REF: begin
          for (int b = 0; b < NUM_BANKS; b++) begin
            if (is_open[b]) begin
              errors++;
              $error("[DRAM] REF while bank %0d is open", b);
            end
          end
        end
        default: ;
      endcase
    end
  end

endmodule
