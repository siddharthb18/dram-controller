// tb_top.sv - testbench for dram_ctrl
//
// Sends random reads and writes to the controller, checks every read
// against a simple reference memory, and collects coverage.
// The DRAM itself is a behavioral model (dram_model.sv) and the timing
// rules are checked separately in dram_timing_checker.sv.
//
// run options: +seed=<n> +num_txns=<n> +dump

`timescale 1ns/1ps
`include "dram_defs.vh"

module tb_top;

  // same values as the RTL defaults
  localparam BANK_BITS = 2;
  localparam ROW_BITS  = 8;
  localparam COL_BITS  = 4;
  localparam DATA_W    = 16;
  localparam ADDR_W    = ROW_BITS + BANK_BITS + COL_BITS;
  localparam NUM_BANKS = 1 << BANK_BITS;

  localparam T_RCD  = 3;
  localparam T_RP   = 3;
  localparam T_RAS  = 7;
  localparam T_CL   = 3;
  localparam T_RFC  = 10;
  localparam T_REFI = 300;

  // only use rows 0-7 so the same rows come up again often
  localparam NUM_ROWS_USED = 8;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;   // 100 MHz

  logic                 req_valid = 0;
  logic                 req_ready;
  logic                 req_write = 0;
  logic [ADDR_W-1:0]    req_addr  = '0;
  logic [DATA_W-1:0]    req_wdata = '0;
  logic                 rsp_valid;
  logic [DATA_W-1:0]    rsp_rdata;

  logic [2:0]           dram_cmd;
  logic [BANK_BITS-1:0] dram_bank;
  logic [ROW_BITS-1:0]  dram_row;
  logic [COL_BITS-1:0]  dram_col;
  logic [DATA_W-1:0]    dram_wdata;
  logic [DATA_W-1:0]    dram_rdata;

  // for gate-level sim (+define+GLS) the netlist has no parameters
`ifdef GLS
  dram_ctrl dut (
`else
  dram_ctrl #(
    .BANK_BITS(BANK_BITS), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .DATA_W(DATA_W),
    .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS), .T_CL(T_CL), .T_RFC(T_RFC), .T_REFI(T_REFI)
  ) dut (
`endif
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
    .req_addr(req_addr), .req_wdata(req_wdata),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata),
    .dram_cmd(dram_cmd), .dram_bank(dram_bank), .dram_row(dram_row),
    .dram_col(dram_col), .dram_wdata(dram_wdata), .dram_rdata(dram_rdata)
  );

  dram_model #(
    .BANK_BITS(BANK_BITS), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .DATA_W(DATA_W), .T_CL(T_CL)
  ) u_dram (
    .clk(clk), .rst_n(rst_n), .cmd(dram_cmd), .bank(dram_bank), .row(dram_row),
    .col(dram_col), .wdata(dram_wdata), .rdata(dram_rdata)
  );

  dram_timing_checker #(
    .BANK_BITS(BANK_BITS), .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS),
    .T_RFC(T_RFC), .T_REFI(T_REFI)
  ) u_chk (
    .clk(clk), .rst_n(rst_n), .cmd(dram_cmd), .bank(dram_bank)
  );

  // one random request
  typedef enum int { HIT = 0, MISS = 1, EMPTY = 2 } kind_e;
  typedef enum int { SAME_ROW = 0, NEW_ROW = 1 } loc_e;

  class dram_txn;
    rand bit                  write;
    rand bit [BANK_BITS-1:0]  bank;
    rand bit [ROW_BITS-1:0]   row;
    rand bit [COL_BITS-1:0]   col;
    rand bit [DATA_W-1:0]     data;
    rand loc_e                loc;

    // last row used in each bank, so I can ask for the same row again
    bit [ROW_BITS-1:0] last_row [NUM_BANKS];

    constraint c_op   { write dist {1 := 50, 0 := 50}; }
    constraint c_loc  { loc dist {SAME_ROW := 60, NEW_ROW := 40}; }
    constraint c_rows { row < NUM_ROWS_USED; }
    constraint c_hit  { loc == SAME_ROW -> row == last_row[bank]; }

    function bit [ADDR_W-1:0] addr();
      return {row, bank, col};
    endfunction
  endclass

  // coverage: every request type in every bank, reads and writes,
  // and refreshes with and without a request waiting
  covergroup cg_req with function sample(kind_e k, bit [BANK_BITS-1:0] b, bit w);
    cp_kind: coverpoint k;
    cp_bank: coverpoint b;
    cp_op:   coverpoint w { bins read = {0}; bins write = {1}; }
    x_kind_bank: cross cp_kind, cp_bank;
    x_kind_op:   cross cp_kind, cp_op;
  endgroup

  covergroup cg_ref with function sample(bit collided, int banks_open);
    cp_collision: coverpoint collided { bins idle = {0}; bins req_waiting = {1}; }
    cp_open:      coverpoint banks_open {
      bins none = {0};
      bins some = {[1:NUM_BANKS-1]};
      bins all  = {NUM_BANKS};
    }
  endgroup

  cg_req cov_req = new();
  cg_ref cov_ref = new();

  // counters for the end-of-test summary
  int n_reads = 0, n_writes = 0;
  int n_kind [3] = '{0, 0, 0};
  int n_bank [NUM_BANKS];
  int n_refresh = 0, n_collisions = 0;
  int n_mismatch = 0, n_checked = 0;
  longint lat_sum [3] = '{0, 0, 0};
  int     lat_cnt [3] = '{0, 0, 0};
  longint cycle = 0;

  always @(posedge clk) cycle <= cycle + 1;

  // Track which row is open in each bank by watching the command bus.
  // This is how the testbench decides if a request is a hit, miss or empty.
  bit                tb_open [NUM_BANKS];
  bit [ROW_BITS-1:0] tb_row  [NUM_BANKS];
  int                open_at_prea = 0;

  always @(posedge clk) begin
    if (!rst_n) begin
      for (int b = 0; b < NUM_BANKS; b++) tb_open[b] <= 0;
      open_at_prea <= 0;
    end else begin
      case (dram_cmd)
        `CMD_ACT: begin tb_open[dram_bank] <= 1; tb_row[dram_bank] <= dram_row; end
        `CMD_PRE: tb_open[dram_bank] <= 0;
        `CMD_PREA: begin
          automatic int cnt = 0;
          for (int b = 0; b < NUM_BANKS; b++) begin
            cnt += tb_open[b];
            tb_open[b] <= 0;
          end
          open_at_prea <= cnt;
        end
        `CMD_REF: begin
          automatic bit collided = req_valid && !req_ready;
          n_refresh++;
          if (collided) n_collisions++;
          cov_ref.sample(collided, open_at_prea);
          open_at_prea <= 0;
        end
        default: ;
      endcase
    end
  end

  // Scoreboard: writes go into ref_mem, and each read pushes the value
  // it should return. When the controller responds, compare.
  bit [DATA_W-1:0] ref_mem [bit [ADDR_W-1:0]];

  typedef struct {
    bit [ADDR_W-1:0] addr;
    bit [DATA_W-1:0] data;
    kind_e           kind;
    longint          t_start;
  } exp_t;

  exp_t exp_q [$];

  always @(posedge clk) begin
    if (rst_n && req_valid && req_ready) begin
      automatic bit [BANK_BITS-1:0] b = req_addr[COL_BITS +: BANK_BITS];
      automatic bit [ROW_BITS-1:0]  r = req_addr[COL_BITS+BANK_BITS +: ROW_BITS];
      kind_e k;
      if (tb_open[b] && tb_row[b] == r) k = HIT;
      else if (tb_open[b])              k = MISS;
      else                              k = EMPTY;

      n_kind[k]++;
      n_bank[b]++;
      cov_req.sample(k, b, req_write);
      if (req_write) begin
        n_writes++;
        ref_mem[req_addr] = req_wdata;
      end else begin
        exp_t e;
        n_reads++;
        e.addr    = req_addr;
        e.data    = ref_mem.exists(req_addr) ? ref_mem[req_addr] : '0;
        e.kind    = k;
        e.t_start = cycle;
        exp_q.push_back(e);
      end
    end

    if (rst_n && rsp_valid) begin
      if (exp_q.size() == 0) begin
        n_mismatch++;
        $error("[SCB] read response with no read outstanding");
      end else begin
        automatic exp_t e = exp_q.pop_front();
        n_checked++;
        lat_sum[e.kind] += cycle - e.t_start;
        lat_cnt[e.kind]++;
        if (rsp_rdata !== e.data) begin
          n_mismatch++;
          $error("[SCB] MISMATCH addr=0x%0h expected=0x%04h got=0x%04h", e.addr, e.data, rsp_rdata);
        end
      end
    end
  end

  int seed     = 1;
  int num_txns = 2000;

  // Drive inputs on the falling edge so they are stable at the rising edge.
  // If req_ready is high at a falling edge, the request is taken at the
  // next rising edge.
  task automatic send(dram_txn t);
    @(negedge clk);
    req_valid = 1;
    req_write = t.write;
    req_addr  = t.addr();
    req_wdata = t.data;
    while (req_ready !== 1'b1) begin
      if ($isunknown(req_ready))
        $fatal(1, "[DRV] req_ready is X/Z at %0t: DUT state is unknown", $time);
      @(negedge clk);
    end
    @(negedge clk);
    req_valid = 0;
  endtask

  function automatic real avg(int k);
    return lat_cnt[k] ? real'(lat_sum[k]) / lat_cnt[k] : 0.0;
  endfunction

  initial begin
    dram_txn t;
    int total_err;

    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("num_txns=%d", num_txns));
    void'($urandom(seed));
    for (int b = 0; b < NUM_BANKS; b++) n_bank[b] = 0;

    $display("INFO seed=%0d num_txns=%0d", seed, num_txns);

    t = new();
    repeat (5) @(posedge clk);
    @(negedge clk);   // release reset away from the rising edge
    rst_n = 1;
    repeat (2) @(posedge clk);

    for (int n = 0; n < num_txns; n++) begin
      if (!t.randomize()) $fatal(1, "randomize failed");
      send(t);
      t.last_row[t.bank] = t.row;
      // sometimes wait a few cycles, and rarely wait longer than tREFI
      // so a refresh also happens while nothing is waiting
      if ($urandom_range(0, 3) == 0) repeat ($urandom_range(1, 4)) @(negedge clk);
      if ($urandom_range(0, 199) == 0) repeat (T_REFI + 50) @(negedge clk);
    end

    // let the last read come back
    repeat (50) @(posedge clk);

    total_err = n_mismatch + u_chk.errors + u_dram.errors;
    if (exp_q.size() != 0) begin
      $error("[SCB] %0d reads never returned", exp_q.size());
      total_err++;
    end

    $display("RESULT seed=%0d txns=%0d reads=%0d writes=%0d hits=%0d misses=%0d empties=%0d refreshes=%0d collisions=%0d checked=%0d mismatches=%0d timing_errors=%0d protocol_errors=%0d timing_checks=%0d cycles=%0d",
             seed, num_txns, n_reads, n_writes, n_kind[HIT], n_kind[MISS], n_kind[EMPTY],
             n_refresh, n_collisions, n_checked, n_mismatch, u_chk.errors, u_dram.errors,
             u_chk.checks, cycle);
    $display("BANKS %0d %0d %0d %0d", n_bank[0], n_bank[1], n_bank[2], n_bank[3]);
    $display("LATENCY hit=%0.2f miss=%0.2f empty=%0.2f", avg(HIT), avg(MISS), avg(EMPTY));
    $display("COVERAGE req=%0.2f ref=%0.2f", cov_req.get_coverage(), cov_ref.get_coverage());
    if (total_err == 0) $display("TEST PASSED");
    else                $display("TEST FAILED (%0d errors)", total_err);
    $finish;
  end

  // stop if something hangs
  initial begin
    #(10ms);
    $display("TEST FAILED (timeout)");
    $finish;
  end

  // waveform dump: +dump
  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("dram_ctrl.vcd");
      $dumpvars(0, tb_top);
    end
  end

endmodule
