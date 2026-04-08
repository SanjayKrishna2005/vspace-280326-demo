`default_nettype none

// ── LIF Neuron with Adaptive Threshold (Option 2) ────────────────────────────
// Each neuron tracks how many times it fires within a slow window (16 beats).
// When adapt_en pulses (once per slow window):
//   - fired >  HIGH_MARK times → threshold nudges UP   (neuron was too trigger-happy)
//   - fired <  LOW_MARK  times → threshold nudges DOWN (neuron was too silent)
//   - otherwise              → threshold holds
// Threshold is clamped to [THRESH_MIN, THRESH_MAX] to prevent runaway.
// Cost per neuron: 4-bit spike_count + 4-bit thresh_adapt + 2 comparators + adder
// ≈ ~2 extra cells per neuron, ~16 cells total across 8 neurons.

module lif_neuron #(
    parameter THRESHOLD  = 8'd5,   // initial threshold (also reset value)
    parameter WEIGHT     = 3'd4,
    parameter HIGH_MARK  = 4'd10,  // fires > 10/16 beats → too sensitive → raise
    parameter LOW_MARK   = 4'd2,   // fires < 2/16  beats → too quiet   → lower
    parameter THRESH_MIN = 4'd2,   // floor — never go below this
    parameter THRESH_MAX = 4'd14   // ceiling — never go above this
) (
    input  wire clk,
    input  wire rst_n,
    input  wire ena,
    input  wire spike_valid,
    input  wire spike_in,
    input  wire adapt_en,          // pulse once per slow window (every 16 beats)
    output reg  spike_out
);

    reg [3:0] potential;
    reg [3:0] spike_count;         // counts fires within current adapt window
    reg [3:0] thresh_adapt;        // live adaptive threshold register

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            potential    <= 4'd0;
            spike_out    <= 1'b0;
            spike_count  <= 4'd0;
            thresh_adapt <= THRESHOLD[3:0];   // initialise to parameter value
        end else if (ena) begin

            // ── Threshold adaptation — runs at slow window boundary ───────────
            // adapt_en is a single-cycle pulse from reservoir every 16 beats.
            // Nudge threshold up/down based on firing rate in the last window,
            // then reset the spike counter for the next window.
            if (adapt_en) begin
                if (spike_count > HIGH_MARK) begin
                    // Fired too often → raise threshold (clamp at THRESH_MAX)
                    thresh_adapt <= (thresh_adapt < THRESH_MAX)
                                    ? thresh_adapt + 4'd1
                                    : THRESH_MAX;
                end else if (spike_count < LOW_MARK) begin
                    // Fired too rarely → lower threshold (clamp at THRESH_MIN)
                    thresh_adapt <= (thresh_adapt > THRESH_MIN)
                                    ? thresh_adapt - 4'd1
                                    : THRESH_MIN;
                end
                // else: firing rate in sweet spot → hold threshold
                spike_count <= 4'd0;   // reset window counter
            end

            // ── Normal LIF dynamics — runs on every heartbeat event ───────────
            if (spike_valid) begin
                if (potential >= thresh_adapt) begin
                    spike_out   <= 1'b1;
                    potential   <= 4'd0;
                    // Count this fire toward the adapt window
                    spike_count <= (spike_count < 4'd15)
                                   ? spike_count + 4'd1
                                   : 4'd15;   // saturate, don't wrap
                end else begin
                    spike_out <= 1'b0;
                    potential <= (potential >> 1) + (spike_in ? {1'b0, WEIGHT} : 4'd0);
                end
            end

        end
        // No else: hold state between heartbeat events
    end

endmodule