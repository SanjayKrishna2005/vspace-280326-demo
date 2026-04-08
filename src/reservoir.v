`default_nettype none

module reservoir (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ena,
    input  wire [3:0]  spike_interval,
    input  wire [3:0]  spike_delta,
    input  wire        spike_valid,
    output wire [7:0]  neuron_spikes,   // reduced from 11 to 8
    output wire        any_spike
);

    wire [3:0] gi = spike_valid ? spike_interval : 4'b0;
    wire [3:0] gd = spike_valid ? spike_delta    : 4'b0;

    wire [7:0] s;
    assign neuron_spikes = s;
    assign any_spike     = |s;

    // ── Neurons 0-3: RR interval input stream ─────────────────────────────
    lif_neuron #(.THRESHOLD(8'd5), .WEIGHT(3'd4)) n0  (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[0]), .spike_out(s[0]));
    lif_neuron #(.THRESHOLD(8'd4), .WEIGHT(3'd5)) n1  (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[1]), .spike_out(s[1]));
    lif_neuron #(.THRESHOLD(8'd6), .WEIGHT(3'd3)) n2  (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[2]), .spike_out(s[2]));
    lif_neuron #(.THRESHOLD(8'd4), .WEIGHT(3'd6)) n3  (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[3]), .spike_out(s[3]));

    // ── Neurons 4-7: HRV delta input stream ──────────────────────────────
    lif_neuron #(.THRESHOLD(8'd3), .WEIGHT(3'd5)) n4  (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[0]), .spike_out(s[4]));
    lif_neuron #(.THRESHOLD(8'd3), .WEIGHT(3'd4)) n5  (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[1]), .spike_out(s[5]));
    lif_neuron #(.THRESHOLD(8'd4), .WEIGHT(3'd6)) n6  (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[2]), .spike_out(s[6]));
    // n7: recurrent connection removed (spike_reg dropped), now pure gd[3]
    lif_neuron #(.THRESHOLD(8'd2), .WEIGHT(3'd3)) n7  (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[3]), .spike_out(s[7]));

    // ── n8, n9, n10 removed (recurrent mixing neurons) ────────────────────
    // ── spike_reg removed ────────────────────────────────────────────────

endmodule