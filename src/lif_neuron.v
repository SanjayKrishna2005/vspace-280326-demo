`default_nettype none

// ── LIF Neuron with Shared Adaptive Threshold (Option B) ─────────────────────
// thresh_adapt register is the only addition over the baseline LIF.
// The decision of whether to nudge up/down is made centrally in reservoir
// using one shared spike_count — so this neuron only needs to receive
// thresh_up / thresh_dn direction signals and act on them.
//
// Gate cost vs baseline: 4-bit thresh_adapt reg + clamp mux = ~5 cells/neuron
// Total across 8 neurons: ~40 cells (vs ~80 cells for per-neuron spike_count)
//
// Threshold clamped to [THRESH_MIN, THRESH_MAX] to prevent runaway.

module lif_neuron #(
    parameter THRESHOLD  = 8'd5,   // initial threshold — reset value only
    parameter WEIGHT     = 3'd4,
    parameter THRESH_MIN = 4'd2,   // floor
    parameter THRESH_MAX = 4'd14   // ceiling
) (
    input  wire clk,
    input  wire rst_n,
    input  wire ena,
    input  wire spike_valid,
    input  wire spike_in,
    input  wire thresh_up,         // pulse: raise threshold by 1 (from reservoir)
    input  wire thresh_dn,         // pulse: lower threshold by 1 (from reservoir)
    output reg  spike_out
);

    reg [3:0] potential;
    reg [3:0] thresh_adapt;        // live adaptive threshold — init to THRESHOLD

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            potential    <= 4'd0;
            spike_out    <= 1'b0;
            thresh_adapt <= THRESHOLD[3:0];
        end else if (ena) begin

            // ── Threshold adaptation — driven by reservoir's shared decision ──
            // thresh_up and thresh_dn are mutually exclusive one-cycle pulses.
            // Clamp to [THRESH_MIN, THRESH_MAX] — no runaway in either direction.
            if (thresh_up && thresh_adapt < THRESH_MAX[3:0])
                thresh_adapt <= thresh_adapt + 4'd1;
            else if (thresh_dn && thresh_adapt > THRESH_MIN[3:0])
                thresh_adapt <= thresh_adapt - 4'd1;

            // ── LIF dynamics — every heartbeat event ─────────────────────────
            if (spike_valid) begin
                if (potential >= thresh_adapt) begin
                    spike_out <= 1'b1;
                    potential <= 4'd0;
                end else begin
                    spike_out <= 1'b0;
                    potential <= (potential >> 1) + (spike_in ? {1'b0, WEIGHT} : 4'd0);
                end
            end

        end
    end

endmodule