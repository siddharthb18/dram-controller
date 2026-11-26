// dram_timing_checker.sv
// Watches the DRAM command bus and checks the timing rules with
// assertions. It only looks at the bus, so it checks the controller
// from the outside, the same way a real DRAM would see it.

`timescale 1ns/1ps
`include "dram_defs.vh"

module dram_timing_checker #(
  parameter BANK_BITS = 2,
  parameter T_RCD     = 3,
  parameter T_RP      = 3,
  parameter T_RAS     = 7,
  parameter T_RFC     = 10,
  parameter T_REFI    = 300,
  parameter REF_SLACK = 40    // how late a refresh may be issued
) (
  input                 clk,
  input                 rst_n,
  input [2:0]           cmd,
  input [BANK_BITS-1:0] bank
);

  localparam NUM_BANKS = 1 << BANK_BITS;
  localparam longint NEVER = -100000;

  longint cyc = 0;
  longint last_act [NUM_BANKS];
  longint last_pre [NUM_BANKS];   // PRE or PREA
  longint last_ref = NEVER;       // last REF, for tRFC
  longint ref_window = 0;         // start of the current refresh interval
  bit     is_open  [NUM_BANKS];
  int     errors = 0;

  initial begin
    for (int b = 0; b < NUM_BANKS; b++) begin
      last_act[b] = NEVER;
      last_pre[b] = NEVER;
      is_open[b]  = 0;
    end
  end

  // count how many timing checks ran, to show the checker is active
  int checks = 0;

  task automatic check(input bit ok, input string msg);
    checks++;
    if (!ok) begin
      errors++;
      $error("[TIMING] cycle %0d: %s", cyc, msg);
    end
  endtask

  always @(posedge clk) begin
    if (!rst_n) begin
      cyc        <= 0;
      ref_window <= 0;
    end else begin
      cyc <= cyc + 1;

      // nothing may be issued while a refresh is in progress
      if (cmd != `CMD_NOP)
        check(cyc - last_ref >= T_RFC,
              $sformatf("command %0d issued %0d cycles after REF (tRFC=%0d)",
                        cmd, cyc - last_ref, T_RFC));

      case (cmd)
        `CMD_ACT: begin
          check(cyc - last_pre[bank] >= T_RP,
                $sformatf("tRP: ACT bank %0d only %0d cycles after PRE", bank, cyc - last_pre[bank]));
          last_act[bank] <= cyc;
          is_open[bank]  <= 1;
        end
        `CMD_RD, `CMD_WR: begin
          check(cyc - last_act[bank] >= T_RCD,
                $sformatf("tRCD: RD/WR bank %0d only %0d cycles after ACT", bank, cyc - last_act[bank]));
        end
        `CMD_PRE: begin
          check(cyc - last_act[bank] >= T_RAS,
                $sformatf("tRAS: PRE bank %0d only %0d cycles after ACT", bank, cyc - last_act[bank]));
          last_pre[bank] <= cyc;
          is_open[bank]  <= 0;
        end
        `CMD_PREA: begin
          for (int b = 0; b < NUM_BANKS; b++) begin
            if (is_open[b])
              check(cyc - last_act[b] >= T_RAS,
                    $sformatf("tRAS: PREA closes bank %0d only %0d cycles after ACT", b, cyc - last_act[b]));
            last_pre[b] <= cyc;
            is_open[b]  <= 0;
          end
        end
        `CMD_REF: begin
          for (int b = 0; b < NUM_BANKS; b++) begin
            if (is_open[b])
              check(0, $sformatf("REF issued while bank %0d is open", b));
            else
              check(cyc - last_pre[b] >= T_RP,
                    $sformatf("tRP: REF only %0d cycles after precharge of bank %0d", cyc - last_pre[b], b));
          end
          check(cyc - ref_window <= T_REFI + REF_SLACK,
                $sformatf("refresh late: %0d cycles since last REF (tREFI=%0d)", cyc - ref_window, T_REFI));
          last_ref   <= cyc;
          ref_window <= cyc;
        end
        default: ;
      endcase

      // refresh must not be starved for too long
      if (cmd != `CMD_REF && cyc - ref_window == T_REFI + REF_SLACK + 1)
        check(0, "no REF issued within tREFI + slack");
    end
  end

  function automatic void sva_fail(input string msg);
    errors++;
    $error("[SVA] %s", msg);
  endfunction

  // a few concurrent SVA properties on the bus
  a_no_x_cmd: assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(cmd))
    else sva_fail("command bus has X/Z");

  a_ref_then_nop: assert property (@(posedge clk) disable iff (!rst_n)
                                   cmd == `CMD_REF |=> cmd == `CMD_NOP)
    else sva_fail("command issued right after REF");

  a_rw_bank_open: assert property (@(posedge clk) disable iff (!rst_n)
                                   (cmd == `CMD_RD || cmd == `CMD_WR) |-> is_open[bank])
    else sva_fail("RD/WR to a bank with no open row");

endmodule
