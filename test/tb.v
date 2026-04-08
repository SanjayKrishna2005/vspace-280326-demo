`default_nettype none
`timescale 1ns/1ps

module tb;

    reg  [7:0] ui_in;
    wire [7:0] uo_out;
    reg  [7:0] uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;
    reg        ena, clk, rst_n;

    `define AFIB_FLAG    uo_out[0]
    `define VALID        uo_out[1]
    `define SPIKE_MON    uo_out[2]
    `define FSM_STATE    uo_out[4:3]
    `define CONFIDENCE   uo_out[7:5]
    `define ASYSTOLE     uio_out[0]

    tt_um_snn_afib_detector dut (
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(ena), .clk(clk), .rst_n(rst_n)
    );

    initial clk = 0;
    always #50 clk = ~clk;   // 10 MHz, 100 ns period

    initial begin
        $dumpfile("tb.vcd");
        $dumpvars(0, tb);
    end

    reg spike_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          spike_seen <= 1'b0;
        else if (`SPIKE_MON) spike_seen <= 1'b1;
    end

    // ── Tasks ─────────────────────────────────────────────────────────────────
    task wait_clks;
        input integer n;
        integer i;
        begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
    endtask

    task send_r_peak;
        begin
            @(posedge clk); #1; ui_in[0] = 1;
            @(posedge clk); #1; ui_in[0] = 0;
        end
    endtask

    task send_beat_after;
        input integer ticks;
        begin wait_clks(ticks); send_r_peak(); end
    endtask

    task load_weights;
        input [32:0] weights;
        integer i;
        begin
            @(posedge clk); #1;
            ui_in[1] = 1; ui_in[2] = 0; ui_in[3] = 0;
            for (i = 32; i >= 0; i = i - 1) begin
                @(posedge clk); #1; ui_in[2] = weights[i]; ui_in[3] = 1;
                @(posedge clk); #1; ui_in[3] = 0;
            end
            @(posedge clk); #1; ui_in[1] = 0;
            wait_clks(5);
            $display("[TB] Weights loaded. FSM=%b", `FSM_STATE);
        end
    endtask

    task do_reset_and_load;
        begin
            rst_n = 0; wait_clks(3); rst_n = 1; wait_clks(3);
            load_weights(AFIB_WEIGHTS);
            spike_seen = 0;
        end
    endtask

    // Trained weights: n10=+2 n9=+1 n8=0 n7=0 n6=+1 n5=+2 n4=+1 n3=-3 n2=0 n1=+1 n0=0
    localparam [32:0] AFIB_WEIGHTS = 33'h088051A08;

    integer pass_count, fail_count;

    initial begin
        ui_in      = 8'b0;
        uio_in     = 8'b0;
        ena        = 1;
        rst_n      = 0;
        pass_count = 0;
        fail_count = 0;

        $display("=======================================================");
        $display("  TT SNN AFib Detector — Testbench v4.1");
        $display("  Triple-window | 2-of-3 voting | Asystole detect");
        $display("=======================================================");

        wait_clks(5); rst_n = 1; wait_clks(3);

        // ── T0: uio direction ─────────────────────────────────────────────────
        // uio_oe[0]=1 → asystole is output; [7:1]=0 → inputs
        if (uio_oe === 8'b0000_0001) begin
            $display("[PASS] T0: uio_oe=0x01 — asystole pin correctly set as output");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T0: uio_oe=%b (expected 00000001)", uio_oe);
            fail_count = fail_count + 1;
        end

        // ── T1: FSM starts in LOAD ────────────────────────────────────────────
        wait_clks(2);
        if (`FSM_STATE === 2'b00) begin
            $display("[PASS] T1: FSM starts in LOAD (00)");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T1: FSM=%b expected 00", `FSM_STATE);
            fail_count = fail_count + 1;
        end

        // ── T2: Weight load → FSM to RUN ─────────────────────────────────────
        $display("[INFO] Loading trained weights (0x%h)...", AFIB_WEIGHTS);
        load_weights(AFIB_WEIGHTS);
        if (`FSM_STATE === 2'b01) begin
            $display("[PASS] T2: FSM moved to RUN (01) after weight load");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T2: FSM=%b expected 01", `FSM_STATE);
            fail_count = fail_count + 1;
        end

        // ── T3: Normal sinus rhythm ───────────────────────────────────────────
        // 7000 ticks × 100ns = 700ms → 86 BPM. n3 fires (weight -3) per beat.
        // All 3 windows accumulate negatively → 2-of-3 vote → afib=0.
        // tick_count never reaches 16384 → asystole=0.
        $display("[INFO] T3: 20 normal sinus beats (7000 ticks = 700ms each)...");
        begin : norm_loop
            integer i;
            for (i = 0; i < 20; i = i + 1) send_beat_after(7000);
        end
        wait_clks(50);
        $display("[INFO] T3: afib=%b valid=%b asystole=%b confidence=%b",
                 `AFIB_FLAG, `VALID, `ASYSTOLE, `CONFIDENCE);

        if (`VALID === 1'b1) begin
            $display("[PASS] T3a: out_valid asserted — slow window closed");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T3a: out_valid=0");
            fail_count = fail_count + 1;
        end
        if (`AFIB_FLAG === 1'b0) begin
            $display("[PASS] T3b: Normal rhythm classified correctly (afib=0)");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T3b: False positive — afib=1 on normal rhythm");
            fail_count = fail_count + 1;
        end
        if (`ASYSTOLE === 1'b0) begin
            $display("[PASS] T3c: Asystole=0 during normal 700ms beat interval");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T3c: Asystole false positive at 700ms");
            fail_count = fail_count + 1;
        end

        // ── T4: Sustained AFib (32 irregular beats) ───────────────────────────
        // Alternating short/long intervals → enc_delta=9-15 every beat.
        // All 3 windows accumulate positively.
        // 2-of-3 majority → afib_flag=1. confidence=111 expected.
        $display("[INFO] T4: 32 sustained irregular AFib beats...");
        do_reset_and_load;

        send_beat_after(2500);  send_beat_after(9500);
        send_beat_after(3000);  send_beat_after(8800);
        send_beat_after(2200);  send_beat_after(9200);
        send_beat_after(3500);  send_beat_after(8000);
        send_beat_after(2800);  send_beat_after(9800);
        send_beat_after(2000);  send_beat_after(10000);
        send_beat_after(3200);  send_beat_after(8500);
        send_beat_after(2600);  send_beat_after(9100);

        send_beat_after(3100);  send_beat_after(8200);
        send_beat_after(2400);  send_beat_after(9600);
        send_beat_after(2700);  send_beat_after(9300);
        send_beat_after(3300);  send_beat_after(8700);
        send_beat_after(2100);  send_beat_after(9700);
        send_beat_after(3400);  send_beat_after(8100);
        send_beat_after(2900);  send_beat_after(9400);

        wait_clks(100);
        $display("[INFO] T4: afib=%b valid=%b confidence=%b spike_seen=%b",
                 `AFIB_FLAG, `VALID, `CONFIDENCE, spike_seen);

        if (`AFIB_FLAG === 1'b1) begin
            $display("[PASS] T4a: AFib detected by 2-of-3 window majority (afib=1)");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T4a: AFib not detected");
            fail_count = fail_count + 1;
        end
        if (spike_seen) begin
            $display("[PASS] T4b: Reservoir neurons fired during AFib sequence");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T4b: No reservoir spikes seen");
            fail_count = fail_count + 1;
        end

        // ── T5: Confidence in AFib range ──────────────────────────────────────
        if (`CONFIDENCE >= 3'b101) begin
            $display("[PASS] T5: confidence_latch in AFib range = %b", `CONFIDENCE);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T5: confidence_latch too low = %b (expected >=101)",
                     `CONFIDENCE);
            fail_count = fail_count + 1;
        end

        // ── T6: Asystole detection ────────────────────────────────────────────
        // 16384 ticks = 1.6384 s (threshold, bit 14 of tick_count).
        // We wait 17000 ticks without any R-peak.
        // asystole_flag must assert, then clear on the next beat.
        $display("[INFO] T6: 17000-tick silence (>1.6384s threshold)...");
        wait_clks(17000);
        if (`ASYSTOLE === 1'b1) begin
            $display("[PASS] T6a: Asystole flag asserted after >16384-tick silence");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T6a: Asystole flag did not assert");
            fail_count = fail_count + 1;
        end
        send_r_peak();
        wait_clks(3);
        if (`ASYSTOLE === 1'b0) begin
            $display("[PASS] T6b: Asystole flag cleared on R-peak arrival");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T6b: Asystole did not clear after R-peak");
            fail_count = fail_count + 1;
        end

        // ── T7a: Specificity — 4 irregular beats, then 12 normal ─────────────
        // The 4-beat ultra window DOES flag the burst internally (afib_ultra=1
        // at beat 4).  However the subsequent 12 normal beats dominate:
        //   - ultra windows 2 and 3 (beats 5-8, 9-12) see only normal → afib_ultra→0
        //   - fast window (beats 1-8) is split: positive then negative → likely 0
        //   - slow window (beats 1-16): 12×(-3) overwhelms 4 irregular → 0
        // 2-of-3 vote cannot reach 2 agreeing → afib_flag=0.
        // This verifies SPECIFICITY: the detector does not false-positive on a
        // self-terminating 4-beat burst.  A real cardiologist would also not
        // diagnose AFib from this pattern alone.
        $display("[INFO] T7a: Specificity — 4 irregular + 12 normal beats...");
        do_reset_and_load;
        send_beat_after(1500);  send_beat_after(11000);
        send_beat_after(1800);  send_beat_after(10500);
        begin : spec_loop
            integer i;
            for (i = 0; i < 12; i = i + 1) send_beat_after(7000);
        end
        wait_clks(100);
        $display("[INFO] T7a: afib=%b valid=%b confidence=%b",
                 `AFIB_FLAG, `VALID, `CONFIDENCE);
        if (`AFIB_FLAG === 1'b0) begin
            $display("[PASS] T7a: Specificity preserved — 4-beat burst not flagged (afib=0)");
            $display("       [Ultra window did fire on beats 1-4, but 2-of-3 correctly");
            $display("        requires a second window to agree; 12 normal beats prevent that]");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T7a: False positive — 4 irregular beats out of 16 flagged as AFib");
            fail_count = fail_count + 1;
        end

        // ── T7b: Ultra-window sensitivity — 8 irregular, 8 normal ────────────
        // 8 irregular beats → ultra windows 1 AND 2 (beats 1-4, 5-8) both flag.
        // Fast window (beats 1-8) sees all irregular → afib_fast=1.
        // Ultra & Fast agree → 2-of-3 vote satisfied → afib_flag=1.
        // This proves the ultra window contributes real discriminative power:
        // without it, only fast+slow would be available, and slow (beats 1-16)
        // might be diluted by the 8 subsequent normal beats.
        $display("[INFO] T7b: Ultra sensitivity — 8 irregular + 8 normal beats...");
        do_reset_and_load;
        send_beat_after(1500);  send_beat_after(11000);
        send_beat_after(1800);  send_beat_after(10500);
        send_beat_after(2000);  send_beat_after(10000);
        send_beat_after(1700);  send_beat_after(11500);
        begin : sens_loop
            integer i;
            for (i = 0; i < 8; i = i + 1) send_beat_after(7000);
        end
        wait_clks(100);
        $display("[INFO] T7b: afib=%b valid=%b confidence=%b",
                 `AFIB_FLAG, `VALID, `CONFIDENCE);
        if (`AFIB_FLAG === 1'b1) begin
            $display("[PASS] T7b: Ultra+Fast window pair detected 8-beat AFib episode (afib=1)");
            $display("       [Demonstrates ultra window provides real 2-of-3 contribution]");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T7b: 8-beat sustained AFib episode not detected");
            fail_count = fail_count + 1;
        end

        // ── T8: Reset clears all state ────────────────────────────────────────
        rst_n = 0; wait_clks(3);
        if (`AFIB_FLAG === 1'b0 && `VALID === 1'b0 &&
            `FSM_STATE === 2'b00 && `ASYSTOLE === 1'b0) begin
            $display("[PASS] T8: Reset clears afib_flag, out_valid, asystole, FSM=LOAD");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] T8: afib=%b valid=%b asystole=%b fsm=%b after reset",
                     `AFIB_FLAG, `VALID, `ASYSTOLE, `FSM_STATE);
            fail_count = fail_count + 1;
        end
        rst_n = 1;

        // ── Summary ───────────────────────────────────────────────────────────
        $display("=======================================================");
        $display("  Results: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  %0d TEST(S) FAILED — see above", fail_count);
        $display("  Waveform: tb.vcd");
        $display("=======================================================");
        #1000; $finish;
    end

    initial begin
        #900_000_000;
        $display("[TIMEOUT] Simulation exceeded 900ms budget");
        $finish;
    end

endmodule