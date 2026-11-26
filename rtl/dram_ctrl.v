// dram_ctrl.v
// Simple DRAM-style memory controller.
//
//  - NUM_BANKS banks, each with one open-row buffer (open-page policy:
//    a row stays open after an access until a different row is needed
//    or a refresh is due).
//  - Commands: ACT, RD, WR, PRE, PREA, REF (see dram_defs.vh).
//  - Timing rules are parameters, in clock cycles:
//      T_RCD  ACT -> RD/WR, same bank
//      T_RP   PRE/PREA -> ACT or REF
//      T_RAS  ACT -> PRE, same bank (minimum time a row stays open)
//      T_CL   RD -> read data on the bus
//      T_RFC  REF -> next command
//      T_REFI refresh interval (a refresh is requested every T_REFI cycles)
//  - Host side: one request at a time with a valid/ready handshake.
//    Reads return data on rsp_valid/rsp_rdata. Writes need no response.
//
// Address map: req_addr = {row, bank, col}

`timescale 1ns/1ps
`include "dram_defs.vh"

module dram_ctrl #(
  parameter BANK_BITS = 2,
  parameter ROW_BITS  = 8,
  parameter COL_BITS  = 4,
  parameter DATA_W    = 16,
  parameter ADDR_W    = ROW_BITS + BANK_BITS + COL_BITS,
  parameter T_RCD     = 3,
  parameter T_RP      = 3,
  parameter T_RAS     = 7,
  parameter T_CL      = 3,
  parameter T_RFC     = 10,
  parameter T_REFI    = 300
) (
  input                       clk,
  input                       rst_n,

  // host request interface
  input                       req_valid,
  output                      req_ready,
  input                       req_write,
  input      [ADDR_W-1:0]     req_addr,
  input      [DATA_W-1:0]     req_wdata,
  output reg                  rsp_valid,
  output reg [DATA_W-1:0]     rsp_rdata,

  // DRAM command bus
  output reg [2:0]            dram_cmd,
  output reg [BANK_BITS-1:0]  dram_bank,
  output reg [ROW_BITS-1:0]   dram_row,
  output reg [COL_BITS-1:0]   dram_col,
  output reg [DATA_W-1:0]     dram_wdata,
  input      [DATA_W-1:0]     dram_rdata
);

  localparam NUM_BANKS = 1 << BANK_BITS;

  // FSM states
  localparam S_IDLE     = 4'd0;
  localparam S_PRE      = 4'd1;  // close the wrong row (row miss)
  localparam S_ACT      = 4'd2;  // open the needed row
  localparam S_RW       = 4'd3;  // issue RD or WR
  localparam S_RD_WAIT  = 4'd4;  // wait CL, capture read data
  localparam S_REF_PRE  = 4'd5;  // close all banks before refresh
  localparam S_REF      = 4'd6;  // issue REF
  localparam S_REF_WAIT = 4'd7;  // wait tRFC

  reg [3:0] state;

  // per-bank open-row buffer state
  reg                 open_valid [0:NUM_BANKS-1];
  reg [ROW_BITS-1:0]  open_row   [0:NUM_BANKS-1];
  reg [7:0]           ras_cnt    [0:NUM_BANKS-1]; // cycles left before PRE is legal

  // shared wait counter for sequential timing (tRCD, tRP, tCL, tRFC)
  reg [7:0]  wait_cnt;

  // refresh timer
  reg [15:0] refi_cnt;
  reg        ref_pending;

  // latched request
  reg                 cur_write;
  reg [BANK_BITS-1:0] cur_bank;
  reg [ROW_BITS-1:0]  cur_row;
  reg [COL_BITS-1:0]  cur_col;
  reg [DATA_W-1:0]    cur_wdata;

  // decode the incoming address
  wire [COL_BITS-1:0]  in_col  = req_addr[COL_BITS-1:0];
  wire [BANK_BITS-1:0] in_bank = req_addr[COL_BITS +: BANK_BITS];
  wire [ROW_BITS-1:0]  in_row  = req_addr[COL_BITS+BANK_BITS +: ROW_BITS];

  assign req_ready = (state == S_IDLE) && !ref_pending;

  // all open banks have met tRAS, and at least one bank is open
  reg all_ras_ok;
  reg any_open;
  integer j;
  always @(*) begin
    all_ras_ok = 1'b1;
    any_open   = 1'b0;
    for (j = 0; j < NUM_BANKS; j = j + 1) begin
      if (open_valid[j]) begin
        any_open = 1'b1;
        if (ras_cnt[j] != 0) all_ras_ok = 1'b0;
      end
    end
  end

  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      wait_cnt    <= 8'd0;
      refi_cnt    <= T_REFI - 1;
      ref_pending <= 1'b0;
      rsp_valid   <= 1'b0;
      rsp_rdata   <= {DATA_W{1'b0}};
      dram_cmd    <= `CMD_NOP;
      dram_bank   <= {BANK_BITS{1'b0}};
      dram_row    <= {ROW_BITS{1'b0}};
      dram_col    <= {COL_BITS{1'b0}};
      dram_wdata  <= {DATA_W{1'b0}};
      cur_write   <= 1'b0;
      cur_bank    <= {BANK_BITS{1'b0}};
      cur_row     <= {ROW_BITS{1'b0}};
      cur_col     <= {COL_BITS{1'b0}};
      cur_wdata   <= {DATA_W{1'b0}};
      for (i = 0; i < NUM_BANKS; i = i + 1) begin
        open_valid[i] <= 1'b0;
        open_row[i]   <= {ROW_BITS{1'b0}};
        ras_cnt[i]    <= 8'd0;
      end
    end else begin
      // defaults: no command, no response this cycle
      dram_cmd  <= `CMD_NOP;
      rsp_valid <= 1'b0;

      // counters tick down every cycle
      if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
      for (i = 0; i < NUM_BANKS; i = i + 1)
        if (ras_cnt[i] != 0) ras_cnt[i] <= ras_cnt[i] - 1'b1;

      // periodic refresh request
      if (refi_cnt == 0) begin
        refi_cnt    <= T_REFI - 1;
        ref_pending <= 1'b1;
      end else begin
        refi_cnt <= refi_cnt - 1'b1;
      end

      case (state)
        S_IDLE: begin
          if (ref_pending) begin
            state <= S_REF_PRE;
          end else if (req_valid) begin
            cur_write <= req_write;
            cur_bank  <= in_bank;
            cur_row   <= in_row;
            cur_col   <= in_col;
            cur_wdata <= req_wdata;
            if (open_valid[in_bank] && open_row[in_bank] == in_row)
              state <= S_RW;    // row hit: go straight to RD/WR
            else if (open_valid[in_bank])
              state <= S_PRE;   // row miss: close the other row first
            else
              state <= S_ACT;   // bank closed: just open the row
          end
        end

        S_PRE: begin
          if (ras_cnt[cur_bank] == 0) begin
            dram_cmd             <= `CMD_PRE;
            dram_bank            <= cur_bank;
            open_valid[cur_bank] <= 1'b0;
            wait_cnt             <= T_RP - 1;
            state                <= S_ACT;
          end
        end

        S_ACT: begin
          if (wait_cnt == 0) begin
            dram_cmd             <= `CMD_ACT;
            dram_bank            <= cur_bank;
            dram_row             <= cur_row;
            open_valid[cur_bank] <= 1'b1;
            open_row[cur_bank]   <= cur_row;
            ras_cnt[cur_bank]    <= T_RAS - 1;
            wait_cnt             <= T_RCD - 1;
            state                <= S_RW;
          end
        end

        S_RW: begin
          if (wait_cnt == 0) begin
            dram_bank  <= cur_bank;
            dram_col   <= cur_col;
            if (cur_write) begin
              dram_cmd   <= `CMD_WR;
              dram_wdata <= cur_wdata;
              state      <= S_IDLE;
            end else begin
              dram_cmd <= `CMD_RD;
              wait_cnt <= T_CL;
              state    <= S_RD_WAIT;
            end
          end
        end

        S_RD_WAIT: begin
          if (wait_cnt == 0) begin
            rsp_valid <= 1'b1;
            rsp_rdata <= dram_rdata;
            state     <= S_IDLE;
          end
        end

        S_REF_PRE: begin
          if (!any_open) begin
            state <= S_REF;
          end else if (all_ras_ok) begin
            dram_cmd <= `CMD_PREA;
            for (i = 0; i < NUM_BANKS; i = i + 1)
              open_valid[i] <= 1'b0;
            wait_cnt <= T_RP - 1;
            state    <= S_REF;
          end
        end

        S_REF: begin
          if (wait_cnt == 0) begin
            dram_cmd    <= `CMD_REF;
            ref_pending <= 1'b0;
            wait_cnt    <= T_RFC - 1;
            state       <= S_REF_WAIT;
          end
        end

        S_REF_WAIT: begin
          if (wait_cnt == 0) state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
