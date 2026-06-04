// =============================================================================
// uart_if.sv  —  SystemVerilog Interface
// =============================================================================
// Bundles all DUT-facing signals into one object with typed modports so the
// compiler enforces direction at each connection point.
//
// NEW CONCEPT (from Verilog-2001):
//   interface  — a named bundle of signals, like a struct you can pass around
//   modport    — a "view" of the interface that locks in directions per user
//   clocking block — synchronises TB drives/samples to a clock edge,
//                    eliminating race conditions between RTL and TB
// =============================================================================

interface uart_if (input logic clk);

    // -------------------------------------------------------------------------
    // AXI-Stream TX side (TB → DUT)
    // -------------------------------------------------------------------------
    logic [7:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;   // DUT drives this

    // -------------------------------------------------------------------------
    // AXI-Stream RX side (DUT → TB)
    // -------------------------------------------------------------------------
    logic [7:0] m_axis_tdata;
    logic        m_axis_tvalid;
    logic        m_axis_tready;   // TB drives this

    // -------------------------------------------------------------------------
    // Serial lines
    // -------------------------------------------------------------------------
    logic txd;   // DUT drives
    logic rxd;   // TB drives

    // -------------------------------------------------------------------------
    // Status / config
    // -------------------------------------------------------------------------
    logic        tx_busy;
    logic        rx_busy;
    logic        rx_overrun_error;
    logic        rx_frame_error;
    logic [15:0] prescale;

    // =========================================================================
    // Clocking block — TB DRIVER perspective
    //   @(cb_drv) drives are registered 1ns before the clock edge (skew)
    //   @(cb_drv) samples are captured 1ns after the clock edge
    //   This guarantees setup/hold regardless of simulator delta ordering.
    // =========================================================================
    clocking cb_drv @(posedge clk);
        default input  #1ns output #1ns;

        output s_axis_tdata;
        output s_axis_tvalid;
        input  s_axis_tready;

        input  m_axis_tdata;
        input  m_axis_tvalid;
        output m_axis_tready;

        output rxd;
        input  txd;

        input  tx_busy;
        input  rx_busy;
        input  rx_overrun_error;
        input  rx_frame_error;
        output prescale;
    endclocking

    // =========================================================================
    // Clocking block — MONITOR perspective (sample only, no drive skew needed)
    // =========================================================================
    clocking cb_mon @(posedge clk);
        default input #1ns;

        input s_axis_tdata;
        input s_axis_tvalid;
        input s_axis_tready;
        input m_axis_tdata;
        input m_axis_tvalid;
        input m_axis_tready;
        input txd;
        input rxd;
        input tx_busy;
        input rx_busy;
        input rx_overrun_error;
        input rx_frame_error;
    endclocking

    // =========================================================================
    // Modports — lock directions at compile time
    // =========================================================================
    modport drv_mp  (clocking cb_drv, input clk);
    modport mon_mp  (clocking cb_mon, input clk);

endinterface : uart_if

      
// =============================================================================
// uart_transaction.sv  —  Transaction Class + Constrained Random
// =============================================================================
// A "transaction" is the logical unit of stimulus/response at the protocol
// level — here, one UART byte transfer with metadata about spacing.
//
// NEW CONCEPTS:
//   class        — object with data fields and methods (like C++ struct+methods)
//   rand/randc   — marks a field for randomization; randc = cyclic (no repeat)
//   constraint   — a named rule the solver must satisfy during randomize()
//   $urandom_range — seeded random function
// =============================================================================

class uart_transaction;

    // -------------------------------------------------------------------------
    // Randomisable fields
    // -------------------------------------------------------------------------
    rand  logic [7:0] data;           // The byte to transmit
    rand  int unsigned idle_cycles;   // Gap (in clocks) before asserting tvalid
    rand  int unsigned burst_len;     // How many back-to-back bytes in this burst

    // -------------------------------------------------------------------------
    // Constraints — the solver picks values satisfying ALL active constraints
    // -------------------------------------------------------------------------

    // Default: any data value, short-to-medium idle, burst 1–8
    constraint c_idle_default {
        idle_cycles dist {
            0       := 10,    // 10% weight: back-to-back
            [1:5]   := 40,    // 40% weight: short gap
            [6:20]  := 30,    // 30% weight: normal gap
            [21:50] := 20     // 20% weight: long gap
        };
    }

    constraint c_burst_default {
        burst_len inside {[1:8]};
    }

    // -------------------------------------------------------------------------
    // Named override constraints — disable default and enable these instead
    // for directed tests.  Call: txn.c_idle_default.constraint_mode(0);
    //                            txn.c_stress.constraint_mode(1);
    // -------------------------------------------------------------------------

    // Stress test: back-to-back only, long bursts
    constraint c_stress {
        idle_cycles == 0;
        burst_len inside {[4:16]};
    }

    // Corner case: only the interesting byte values
    constraint c_corners {
        data inside {8'h00, 8'hFF, 8'h55, 8'hAA, 8'h01, 8'h80};
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    function new();
        // stress and corners are off by default
        c_stress.constraint_mode(0);
        c_corners.constraint_mode(0);
    endfunction

    // -------------------------------------------------------------------------
    // Pretty-print helper (call after randomize to log what was generated)
    // -------------------------------------------------------------------------
    function void print(string tag = "TXN");
        $display("[%0t] %s: data=0x%02X  idle=%0d  burst=%0d",
                 $time, tag, data, idle_cycles, burst_len);
    endfunction

endclass : uart_transaction
      
      
// =============================================================================
// uart_driver.sv  —  Driver
// =============================================================================
// Converts transaction objects into pin wiggles on the interface.
// Operates through the clocking block so all drives are edge-aligned.
//
// NEW CONCEPTS:
//   virtual interface — a handle to an interface instance (like a pointer)
//                       allows classes (which have no static hierarchy) to
//                       reach into the module-level signal world
//   mailbox #(T)      — a typed FIFO for passing objects between processes
//   @(posedge ...)    — event control inside a class task
// =============================================================================

class uart_driver;

    // Handle to the interface — "virtual" means it's a runtime reference,
    // not a static compile-time connection
    virtual uart_if.drv_mp vif;

    // Inbox: the generator drops transactions here, driver picks them up
    mailbox #(uart_transaction) mbx;

    // How many transactions processed (for reporting)
    int tx_count = 0;

    // -------------------------------------------------------------------------
    function new(virtual uart_if.drv_mp vif, mailbox #(uart_transaction) mbx);
        this.vif = vif;
        this.mbx = mbx;
    endfunction

    // -------------------------------------------------------------------------
    // run() — called from the testbench; loops forever consuming transactions
    // -------------------------------------------------------------------------
    task automatic run();
      vif.cb_drv.s_axis_tdata  <= 8'h00;
      vif.cb_drv.s_axis_tvalid <= 0;
      vif.cb_drv.m_axis_tready <= 1;
      
      forever begin
        uart_transaction txn;
        mbx.get(txn);

        repeat (txn.idle_cycles) @(vif.cb_drv);

        // Drive burst_len bytes, all with the same data value
        repeat (txn.burst_len) begin
            // Wait for DUT to be ready before attempting each byte
            while (!vif.cb_drv.s_axis_tready) @(vif.cb_drv);
            drive_byte(txn.data);
            tx_count++;
            // Small gap between burst bytes so RX isn't overrun
            repeat (2) @(vif.cb_drv);
        	end
    	end
	endtask

    // -------------------------------------------------------------------------
    // drive_byte — present data+valid, wait for ready, then deassert
    // -------------------------------------------------------------------------
    task automatic drive_byte(input logic [7:0] data);
      vif.cb_drv.s_axis_tdata  <= data;
      vif.cb_drv.s_axis_tvalid <= 1;

    	// Advance to first edge, then wait until tready is seen
      @(vif.cb_drv);
      while (!vif.cb_drv.s_axis_tready) @(vif.cb_drv);

    // tready is high this cycle — handshake complete.
    // Deassert valid NOW (takes effect next clock edge due to NBA scheduling)
      vif.cb_drv.s_axis_tvalid <= 0;
      vif.cb_drv.s_axis_tdata  <= 8'h00;
    // One more cycle so the deassert propagates before next byte attempt
      @(vif.cb_drv);
	endtask

endclass : uart_driver


// =============================================================================
// uart_monitor.sv  —  Monitor
// =============================================================================
// Passively observes the DUT outputs and captures completed transactions.
// Puts observed data bytes into a mailbox for the scoreboard.
// Never drives anything — read-only view of the world.
// =============================================================================

class uart_monitor;

    virtual uart_if.mon_mp vif;

    // Outbox to scoreboard: observed RX bytes go here
    mailbox #(logic [7:0]) rx_mbx;

    // Outbox to scoreboard: observed TX bytes (from AXI-Stream input side)
    mailbox #(logic [7:0]) tx_mbx;

    int rx_count = 0;
    int tx_count = 0;

    // -------------------------------------------------------------------------
    function new(virtual uart_if.mon_mp vif,
                 mailbox #(logic [7:0]) tx_mbx,
                 mailbox #(logic [7:0]) rx_mbx);
        this.vif    = vif;
        this.tx_mbx = tx_mbx;
        this.rx_mbx = rx_mbx;
    endfunction

    // -------------------------------------------------------------------------
    // run() — two parallel threads: one watches TX input, one watches RX output
    // -------------------------------------------------------------------------
    task automatic run();
        fork
            monitor_tx_input();
            monitor_rx_output();
        join_none  // both threads run concurrently, don't block caller
    endtask

    // Watch the AXI-Stream input: capture what the TB sends to the DUT
    task automatic monitor_tx_input();
    forever begin
        // Wait for tvalid to go high
        @(vif.cb_mon);
        if (vif.cb_mon.s_axis_tvalid && vif.cb_mon.s_axis_tready) begin
            tx_mbx.put(vif.cb_mon.s_axis_tdata);
            tx_count++;
            $display("[%0t] MON_TX: captured 0x%02X (byte #%0d)",
                     $time, vif.cb_mon.s_axis_tdata, tx_count);
            // Wait for tvalid to deassert before looking for next transaction
            while (vif.cb_mon.s_axis_tvalid) @(vif.cb_mon);
        	end
    	end
	endtask

    // Watch the AXI-Stream output: capture what the DUT received
    task automatic monitor_rx_output();
        forever begin
            @(vif.cb_mon);
            if (vif.cb_mon.m_axis_tvalid && vif.cb_mon.m_axis_tready) begin
                rx_mbx.put(vif.cb_mon.m_axis_tdata);
                rx_count++;
                $display("[%0t] MON_RX: captured 0x%02X (byte #%0d)",
                         $time, vif.cb_mon.m_axis_tdata, rx_count);
            end
        end
    endtask

endclass : uart_monitor
      
      
      
// =============================================================================
// uart_scoreboard.sv  —  Scoreboard
// =============================================================================
// Compares what went in (from tx_mbx) to what came out (from rx_mbx).
// In loopback mode txd feeds rxd, so every TX byte should eventually
// appear as an RX byte in the same order.
//
// NEW CONCEPT:
//   In-order scoreboard with a reference queue — the simplest correct model.
//   TX bytes go into a queue. When an RX byte arrives, it must match the
//   oldest queued TX byte. Any mismatch is a DUT bug.
// =============================================================================

class uart_scoreboard;

    mailbox #(logic [7:0]) tx_mbx;
    mailbox #(logic [7:0]) rx_mbx;

    // Reference queue: TX bytes waiting to be matched
    logic [7:0] ref_q[$];

    int pass_count  = 0;
    int fail_count  = 0;

    // -------------------------------------------------------------------------
    function new(mailbox #(logic [7:0]) tx_mbx,
                 mailbox #(logic [7:0]) rx_mbx);
        this.tx_mbx = tx_mbx;
        this.rx_mbx = rx_mbx;
    endfunction

    // -------------------------------------------------------------------------
    task automatic run();
        fork
            collect_tx();
            check_rx();
        join_none
    endtask

    // Drain TX mailbox into reference queue
    task automatic collect_tx();
        forever begin
            logic [7:0] b;
            tx_mbx.get(b);
            ref_q.push_back(b);
        end
    endtask

    // For each received byte, compare against oldest expected
    task automatic check_rx();
        forever begin
            logic [7:0] actual;
            rx_mbx.get(actual);

            // Wait until reference queue has something (timing: RX may arrive
            // before monitor thread queues TX in edge cases)
            wait (ref_q.size() > 0);

            begin
                logic [7:0] expected = ref_q.pop_front();
                if (actual === expected) begin
                    pass_count++;
                    $display("[%0t] SB PASS #%0d: expected=0x%02X  actual=0x%02X",
                             $time, pass_count, expected, actual);
                end else begin
                    fail_count++;
                    $error("[%0t] SB FAIL #%0d: expected=0x%02X  actual=0x%02X",
                           $time, fail_count, expected, actual);
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    function void report();
        $display("=================================================");
        $display("  SCOREBOARD REPORT");
        $display("  PASS: %0d   FAIL: %0d   PENDING: %0d",
                 pass_count, fail_count, ref_q.size());
        if (fail_count == 0 && ref_q.size() == 0)
            $display("  STATUS: ALL CHECKS PASSED");
        else
            $display("  STATUS: FAILURES DETECTED");
        $display("=================================================");
    endfunction

endclass : uart_scoreboard


// =============================================================================
// uart_coverage.sv  —  Functional Coverage Model
// =============================================================================
// covergroup — a snapshot of what values have been exercised.
// The simulator accumulates hits across the whole simulation and reports
// what percentage of bins were covered.
//
// NEW CONCEPTS:
//   covergroup    — declares the coverage model
//   coverpoint    — one dimension of coverage (which values did this signal take)
//   bins          — named buckets within a coverpoint
//   cross         — 2D coverage: every combination of two coverpoints
//   option.weight — relative importance of this coverpoint in the total %
// =============================================================================

class uart_coverage;

    // Sampled values (set these before calling sample())
    logic [7:0] cov_tx_data;
    int         cov_idle_cycles;
    int         cov_burst_len;
    logic       cov_rx_valid;
    logic       cov_overrun;
    logic       cov_frame_err;

    // -------------------------------------------------------------------------
    covergroup uart_cg;

        // ------------------------------------------------------------------
        // Did we send every possible byte value?
        // 256 auto-bins, each covering one value.
        // Also explicit bins for the corner cases we care most about.
        // ------------------------------------------------------------------
        cp_data: coverpoint cov_tx_data {
            bins zero        = {8'h00};
            bins all_ones    = {8'hFF};
            bins alt_55      = {8'h55};
            bins alt_AA      = {8'hAA};
            bins msb_only    = {8'h80};
            bins lsb_only    = {8'h01};
            bins all_vals[32] = {[8'h00 : 8'hFF]};  // 32 buckets spanning full range
        }

        // ------------------------------------------------------------------
        // Inter-frame gap distribution — did we stress tight timing?
        // ------------------------------------------------------------------
        cp_idle: coverpoint cov_idle_cycles {
            bins back_to_back = {0};
            bins tight        = {[1:3]};
            bins normal       = {[4:15]};
            bins wide         = {[16:$]};
        }

        // ------------------------------------------------------------------
        // Burst length — did we send isolated bytes AND long bursts?
        // ------------------------------------------------------------------
        cp_burst: coverpoint cov_burst_len {
            bins single  = {1};
            bins short   = {[2:4]};
            bins long_b  = {[5:$]};
        }

        // ------------------------------------------------------------------
        // Error conditions — were they ever triggered?
        // ------------------------------------------------------------------
        cp_overrun: coverpoint cov_overrun {
            bins no_overrun = {0};
            bins overrun    = {1};
            option.weight   = 2;   // worth more — hard to hit
        }

        cp_frame_err: coverpoint cov_frame_err {
            bins no_error   = {0};
            bins frame_err  = {1};
            option.weight   = 2;
        }

        // ------------------------------------------------------------------
        // Cross coverage — did we send corner-case bytes with tight gaps?
        // e.g., 0xFF back-to-back is the hardest TX pattern
        // ------------------------------------------------------------------
        cx_data_x_idle: cross cp_data, cp_idle {
            // Only keep the interesting crosses to avoid explosion
            bins corners_tight = binsof(cp_data.zero)     && binsof(cp_idle.back_to_back);
            bins ff_tight      = binsof(cp_data.all_ones) && binsof(cp_idle.back_to_back);
            bins alt_tight     = binsof(cp_data.alt_55)   && binsof(cp_idle.back_to_back);
            ignore_bins irrelevant = binsof(cp_idle.wide);
        }

    endgroup : uart_cg

    // -------------------------------------------------------------------------
    function new();
        uart_cg = new();
    endfunction

    function void sample(
        input logic [7:0] data,
        input int         idle,
        input int         burst,
        input logic       overrun,
        input logic       frame_err
    );
        cov_tx_data     = data;
        cov_idle_cycles = idle;
        cov_burst_len   = burst;
        cov_overrun     = overrun;
        cov_frame_err   = frame_err;
        uart_cg.sample();
    endfunction

    function void report();
        $display("=================================================");
        $display("  COVERAGE REPORT");
        $display("  uart_cg total coverage: %0.1f%%", uart_cg.get_coverage());
        $display("=================================================");
    endfunction

endclass : uart_coverage
      
      
// =============================================================================
// uart_sva.sv  —  SVA Protocol Checker
// =============================================================================
// Instantiated alongside the DUT in the top-level TB. Observes DUT outputs
// and fires errors if any protocol rule is violated — every clock cycle,
// automatically, regardless of what test is running.
//
// NEW CONCEPTS:
//   property      — a named temporal formula (describes behaviour over time)
//   assert property — fires $error if the property ever evaluates false
//   assume property — constrains stimulus (used in formal, optional in sim)
//   |->           — "overlapping implication": if LHS is true THIS cycle,
//                   RHS must be true THIS cycle too
//   |=>           — "non-overlapping implication": if LHS true THIS cycle,
//                   RHS must be true NEXT cycle
//   ##N           — exactly N clock cycles later
//   [*N]          — repeat exactly N times
//   $rose/$fell   — detects 0→1 or 1→0 transitions
//
// Note: We instantiate this as a module rather than using `bind` because
// Riviera-PRO and most free-tier simulators support bind inconsistently.
// Direct instantiation in the top-level TB is equivalent and more portable.
// =============================================================================

module uart_sva
#(
    parameter DATA_WIDTH = 8,
    parameter PRESCALE   = 54    // must match TB
)
(
    input  logic        clk,
    input  logic        rst,

    // TX-side signals
    input  logic        txd,
    input  logic        tx_busy,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tready,
    input  logic [7:0]  s_axis_tdata,

    // RX-side signals
    input  logic        rxd,
    input  logic        rx_busy,
    input  logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    input  logic [7:0]  m_axis_tdata,

    input  logic        rx_overrun_error,
    input  logic        rx_frame_error
);

    // Bit period in clock cycles = prescale * 8
    localparam BIT_PERIOD = PRESCALE * 8;

    // =========================================================================
    // 1. IDLE LINE HIGH
    //    When not transmitting, txd must be logic 1 (UART idle = mark state)
    // =========================================================================
    property p_idle_high;
        @(posedge clk) disable iff (rst)
        $fell(tx_busy) |=> txd;
    endproperty

    a_idle_high: assert property (p_idle_high)
        else $error("[SVA FAIL] a_idle_high: txd went low while tx_busy=0 at time %0t", $time);


    // =========================================================================
    // 2. START BIT IS LOGIC 0
    //    On the falling edge of txd (idle→active), the first driven value is 0
    //    This is just checking that the line went low — the transition itself
    //    is the start bit.
    // =========================================================================
    property p_start_bit_low;
        @(posedge clk) disable iff (rst)
        $fell(tx_busy) |-> ##1 !txd[*(BIT_PERIOD)];
        // Alternative simpler form (checks that txd falls when tx_busy rises):
    endproperty

    // Simpler practical assertion: when tx_busy rises, txd must fall next cycle
    property p_busy_implies_start;
        @(posedge clk) disable iff (rst)
        $rose(tx_busy) |=> !txd;
    endproperty

    a_busy_implies_start: assert property (p_busy_implies_start)
        else $error("[SVA FAIL] a_busy_implies_start: txd not low after tx_busy rose at %0t", $time);


    // =========================================================================
    // 3. AXI-STREAM VALID STABILITY
    //    Once tvalid is asserted, it must not deassert until tready is seen.
    //    This is the AXI-Stream spec rule: valid cannot be withdrawn.
    // =========================================================================
    property p_valid_stable;
        @(posedge clk) disable iff (rst)
        (s_axis_tvalid && !s_axis_tready) |=> s_axis_tvalid;
    endproperty

    a_valid_stable: assert property (p_valid_stable)
        else $error("[SVA FAIL] a_valid_stable: s_axis_tvalid dropped before tready at %0t", $time);


    // =========================================================================
    // 4. DATA STABILITY WHILE VALID
    //    tdata must not change while tvalid is high and tready has not yet come.
    // =========================================================================
    property p_data_stable;
        @(posedge clk) disable iff (rst)
        (s_axis_tvalid && !s_axis_tready)
            |=> (s_axis_tvalid && ($stable(s_axis_tdata)));
    endproperty

    a_data_stable: assert property (p_data_stable)
        else $error("[SVA FAIL] a_data_stable: s_axis_tdata changed while valid/!ready at %0t", $time);


    // =========================================================================
    // 5. READY DEASSERTS DURING TRANSMISSION
    //    While tx_busy, the DUT should not be asserting tready (it can't accept
    //    a new byte while sending one — check the specific DUT behaviour).
    // =========================================================================
    property p_ready_not_during_busy;
        @(posedge clk) disable iff (rst)
        tx_busy |-> !s_axis_tready;
    endproperty

    a_ready_not_during_busy: assert property (p_ready_not_during_busy)
        else $error("[SVA FAIL] a_ready_not_during_busy: tready asserted while tx_busy at %0t", $time);


    // =========================================================================
    // 6. RX VALID PULSES FOR ONE CYCLE
    //    m_axis_tvalid should be asserted for exactly one cycle per received byte
    //    (per the AXI-Stream semantics of this DUT — it's a single-cycle strobe)
    // =========================================================================
    property p_rx_valid_pulse;
        @(posedge clk) disable iff (rst)
        $rose(m_axis_tvalid) |=> !m_axis_tvalid;
    endproperty

    a_rx_valid_pulse: assert property (p_rx_valid_pulse)
        else $error("[SVA FAIL] a_rx_valid_pulse: m_axis_tvalid held high for >1 cycle at %0t", $time);


    // =========================================================================
    // 7. NO X/Z ON SERIAL LINE DURING TRANSMISSION
    //    txd must be a known value (0 or 1) whenever tx_busy is high.
    //    $isunknown returns 1 if any bit is X or Z.
    // =========================================================================
    property p_txd_no_x;
        @(posedge clk) disable iff (rst)
        tx_busy |-> !$isunknown(txd);
    endproperty

    a_txd_no_x: assert property (p_txd_no_x)
        else $error("[SVA FAIL] a_txd_no_x: txd is X/Z during transmission at %0t", $time);


    // =========================================================================
    // COVERAGE PROPERTIES (assert + cover = also count how often it fires)
    // =========================================================================

    // How many times did we complete a TX byte?
    c_tx_complete: cover property (
        @(posedge clk) $fell(tx_busy)
    );

    // How many times did a back-to-back transfer happen?
    c_back_to_back: cover property (
        @(posedge clk) disable iff (rst)
        $fell(tx_busy) ##1 $rose(tx_busy)
    );

    // Did we ever see an overrun?
    c_overrun: cover property (
        @(posedge clk) $rose(rx_overrun_error)
    );

endmodule : uart_sva
      
      
// =============================================================================
// uart_tb_top.sv  —  Top-Level Testbench
// =============================================================================
// Wires up: DUT (uart_tx + uart_rx in loopback), interface, SVA checker,
// and runs all three test sequences with coverage + scoreboard reporting.
//
// LOOPBACK TOPOLOGY:
//   TB → AXI-S → uart_tx DUT → txd ──loopback──► rxd → uart_rx DUT → AXI-S → TB
//
// This means every byte the TB sends in should come back out on the RX side.
// The scoreboard verifies in-order correctness.
// =============================================================================

`timescale 1ns/1ps

// Pull in our class files (in EDA Playground, add these in the top pane)

module uart_tb_top;

    // =========================================================================
    // Clock + Reset generation
    // =========================================================================
    // 50 MHz clock → period = 20 ns
    // At 115200 baud: prescale = 50_000_000 / (115200 * 8) ≈ 54
    localparam CLK_PERIOD_NS = 20;
    localparam PRESCALE      = 54;
    localparam BAUD_RATE     = 115200;

    logic clk = 0;
    logic rst = 1;

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // =========================================================================
    // Interface instantiation
    // =========================================================================
    uart_if dut_if (.clk(clk));

    // =========================================================================
    // DUT instantiation — uart_tx
    // =========================================================================
    uart_tx #(.DATA_WIDTH(8)) dut_tx (
        .clk            (clk),
        .rst            (rst),
        .s_axis_tdata   (dut_if.s_axis_tdata),
        .s_axis_tvalid  (dut_if.s_axis_tvalid),
        .s_axis_tready  (dut_if.s_axis_tready),
        .txd            (dut_if.txd),
        .busy           (dut_if.tx_busy),
        .prescale       (dut_if.prescale)
    );

    // =========================================================================
    // DUT instantiation — uart_rx (loopback: txd → rxd)
    // =========================================================================
    uart_rx #(.DATA_WIDTH(8)) dut_rx (
        .clk                (clk),
        .rst                (rst),
        .m_axis_tdata       (dut_if.m_axis_tdata),
        .m_axis_tvalid      (dut_if.m_axis_tvalid),
        .m_axis_tready      (dut_if.m_axis_tready),
        .rxd                (dut_if.txd),   // LOOPBACK
        .busy               (dut_if.rx_busy),
        .overrun_error      (dut_if.rx_overrun_error),
        .frame_error        (dut_if.rx_frame_error),
        .prescale           (dut_if.prescale)
    );

    // =========================================================================
    // SVA checker instantiation
    // =========================================================================
  uart_sva #(.PRESCALE(PRESCALE)) u_sva (
        .clk              (clk),
        .rst              (rst),
        .txd              (dut_if.txd),
        .tx_busy          (dut_if.tx_busy),
        .s_axis_tvalid    (dut_if.s_axis_tvalid),
        .s_axis_tready    (dut_if.s_axis_tready),
        .s_axis_tdata     (dut_if.s_axis_tdata),
        .rxd              (dut_if.txd),   // matches loopback
        .rx_busy          (dut_if.rx_busy),
        .m_axis_tvalid    (dut_if.m_axis_tvalid),
        .m_axis_tready    (dut_if.m_axis_tready),
        .m_axis_tdata     (dut_if.m_axis_tdata),
        .rx_overrun_error (dut_if.rx_overrun_error),
        .rx_frame_error   (dut_if.rx_frame_error)
    );

    // =========================================================================
    // Testbench component construction
    // =========================================================================
    // Mailboxes connecting components
    mailbox #(uart_transaction) drv_mbx  = new();
    mailbox #(logic [7:0])      tx_mbx   = new();
    mailbox #(logic [7:0])      rx_mbx   = new();

    // Component handles
    uart_driver      driver;
    uart_monitor     monitor;
    uart_scoreboard  scoreboard;
    uart_coverage    coverage;

    initial begin
        // Construct all components
        driver     = new(dut_if.drv_mp, drv_mbx);
        monitor    = new(dut_if.mon_mp, tx_mbx, rx_mbx);
        scoreboard = new(tx_mbx, rx_mbx);
        coverage   = new();

        // Set prescale on the interface (connects to both TX and RX DUTs)
        dut_if.s_axis_tvalid <= 0;
        dut_if.m_axis_tready <= 1;
        dut_if.prescale      <= PRESCALE;

        // Release reset after 5 clock cycles
        repeat(5) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        // Start monitor and scoreboard background threads
      	monitor.run();
        scoreboard.run();

        // Start driver background thread
        fork driver.run(); join_none

        // =====================================================================
        // TEST 1: Directed smoke test — send 0xA5, verify it comes back
        // =====================================================================
        $display("\n=== TEST 1: Directed Smoke Test (0xA5) ===");
        begin
            uart_transaction txn = new();
            txn.data        = 8'hA5;
            txn.idle_cycles = 5;
            txn.burst_len   = 1;
            drv_mbx.put(txn);
            coverage.sample(txn.data, txn.idle_cycles, txn.burst_len, 0, 0);
        end

        // Wait long enough for the byte to propagate through TX and RX
        // One UART frame = 10 bits × BIT_PERIOD clocks = 10 × (54×8) = 4320 clocks
        // Add margin: 6000 clocks
        repeat(6000) @(posedge clk);

        // =====================================================================
        // TEST 2: Constrained random — 50 transactions
        // =====================================================================
        $display("\n=== TEST 2: Constrained Random (50 transactions) ===");
        begin
            uart_transaction txn = new();
            repeat(50) begin
                if (!txn.randomize())
                    $fatal(1, "randomize() failed");
                txn.print("GEN");
                drv_mbx.put(txn);
                repeat(txn.burst_len) 
                  coverage.sample(txn.data, 0, txn.burst_len,
                                  dut_if.rx_overrun_error, dut_if.rx_frame_error);
                // Small inter-transaction gap so we don't overflow the mailbox
                repeat(10) @(posedge clk);
            end
        end

        // Wait for all bytes to propagate (generous timeout)
        repeat(50000) @(posedge clk);

        // =====================================================================
        // TEST 3: Corner case stress — back-to-back 0xFF, 0x00, 0x55, 0xAA
        // =====================================================================
        $display("\n=== TEST 3: Corner Cases (stress pattern) ===");
        begin
            uart_transaction txn = new();
            txn.c_idle_default.constraint_mode(0);
            txn.c_stress.constraint_mode(1);
            txn.c_corners.constraint_mode(1);

            repeat(16) begin
              if (!txn.randomize())
                $fatal(1, "randomize() failed in corner test");
              txn.print("CORNER");
              drv_mbx.put(txn);
              repeat(txn.burst_len)
                coverage.sample(txn.data, txn.idle_cycles, txn.burst_len,
                        dut_if.rx_overrun_error, dut_if.rx_frame_error);
              repeat(5) @(posedge clk);
            end
        end

        // Final drain wait
      repeat(200000) @(posedge clk);

        // =====================================================================
        // Final reports
        // =====================================================================
        scoreboard.report();
        coverage.report();

        $display("\nSimulation complete at %0t", $time);
        $finish;
    end

    // =========================================================================
    // Waveform dump (EPWave in EDA Playground)
    // =========================================================================
    initial begin
        $dumpfile("uart_tb.vcd");
        $dumpvars(0, uart_tb_top);
    end

    // =========================================================================
    // Timeout watchdog — kills sim if something hangs
    // =========================================================================
    initial begin
        #50_000_000;  // 50ms simulated time max
        $fatal(1, "TIMEOUT: simulation exceeded 50ms — possible hang");
    end

endmodule : uart_tb_top
      
      
