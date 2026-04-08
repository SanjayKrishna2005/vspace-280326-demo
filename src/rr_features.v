`default_nettype none

// rr_features: extracts RR interval, beat-to-beat delta, and detects asystole/
// extreme bradycardia.
//
// Asystole logic:
//   tick_count counts system clocks between consecutive R-peak rising edges.
//   At 10 MHz, 1 tick = 100 ns.
//   16384 ticks = 1.6384 s → heart rate ≈ 37 BPM (clinical bradycardia limit).
//   tick_count[14] goes high when no R-peak has arrived for >= 1.6 s.
//   tick_count[15] goes high at 3.2 s (near-asystole / missed-beat territory).
//   asystole_flag is a registered output: SET when tick_count crosses the
//   threshold and CLEARED on the next R-peak rising edge.  Registered (not
//   combinational) so it holds cleanly between beats and has no glitch risk on
//   uio_out.

module rr_features (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire       r_peak,
    output reg  [5:0] rr_interval,
    output reg  [5:0] rr_delta,
    output reg        rr_valid,
    output reg        asystole_flag   // NEW: bradycardia / asystole indicator
);
    reg [15:0] tick_count;
    reg  [5:0] rr_prev;
    reg        r_peak_prev;
    wire       r_peak_rise = r_peak & ~r_peak_prev;

    // Threshold: tick_count[14] asserts at 16 384 ticks = 1.6384 s ~37 BPM.
    // Using bit-select instead of a full 16-bit comparator saves ~6 cells:
    // yosys reduces |tick_count[15:14] to two OR'd FF outputs with no adder.
    wire brd_thresh = tick_count[15] | tick_count[14];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_count    <= 16'd0;
            rr_interval   <= 6'd32;
            rr_delta      <= 6'd0;
            rr_prev       <= 6'd32;
            rr_valid      <= 1'b0;
            r_peak_prev   <= 1'b0;
            asystole_flag <= 1'b0;
        end else if (ena) begin
            r_peak_prev <= r_peak;
            rr_valid    <= 1'b0;

            if (r_peak_rise) begin
                // New beat: compute interval and delta, then clear counter
                rr_interval   <= (tick_count[15:9] > 7'd63)
                                 ? 6'd63 : tick_count[15:9];
                rr_delta      <= (tick_count[15:9] > rr_prev)
                                 ? tick_count[15:9] - rr_prev
                                 : rr_prev - tick_count[15:9];
                rr_prev       <= (tick_count[15:9] > 7'd63)
                                 ? 6'd63 : tick_count[15:9];
                rr_valid      <= 1'b1;
                tick_count    <= 16'd0;
                asystole_flag <= 1'b0;   // beat arrived: clear flag
            end else begin
                if (tick_count < 16'hFFFF)
                    tick_count <= tick_count + 16'd1;
                // Set flag as soon as inter-beat gap crosses threshold.
                // Once set it holds until the next r_peak_rise clears it.
                if (brd_thresh)
                    asystole_flag <= 1'b1;
            end
        end
    end

endmodule