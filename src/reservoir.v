`default_nettype none

module reservoir (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ena,
    input  wire [3:0]  spike_interval,
    input  wire [3:0]  spike_delta,
    input  wire        spike_valid,
    output wire [7:0]  neuron_spikes,
    output wire        any_spike
);

    wire [3:0] gi = spike_valid ? spike_interval : 4'b0;
    wire [3:0] gd = spike_valid ? spike_delta    : 4'b0;

    wire [7:0] s;
    assign neuron_spikes = s;
    assign any_spike     = |s;

    // ── Slow-window beat counter for adapt_en generation ─────────────────────
    // Counts heartbeat events (spike_valid pulses). Every 16 beats it fires
    // adapt_en for exactly one clock cycle — this is the adaptation trigger
    // sent to every neuron. Matches the readout slow window cadence so
    // adaptation and detection operate on the same time horizon.
    reg [3:0] adapt_beat_count;
    reg       adapt_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adapt_beat_count <= 4'd0;
            adapt_en         <= 1'b0;
        end else if (ena) begin
            adapt_en <= 1'b0;   // default: de-assert every cycle
            if (spike_valid) begin
                if (adapt_beat_count == 4'd15) begin
                    adapt_beat_count <= 4'd0;
                    adapt_en         <= 1'b1;   // one-cycle pulse every 16 beats
                end else begin
                    adapt_beat_count <= adapt_beat_count + 4'd1;
                end
            end
        end
    end

    // ── 1-bit temporal feedback register (Option A recurrence) ───────────────
    // Captures n0's output from the previous beat. Feeds into n7 to make it
    // sensitive to sustained moderate irregularity across consecutive beats.
    reg spike_reg1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            spike_reg1 <= 1'b0;
        else if (ena && spike_valid)
            spike_reg1 <= s[0];
    end

    // ── Neurons 0-3: RR interval input stream ────────────────────────────────
    lif_neuron #(.THRESHOLD(8'd5), .WEIGHT(3'd4)) n0 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[0]),              .adapt_en(adapt_en),.spike_out(s[0]));
    lif_neuron #(.THRESHOLD(8'd4), .WEIGHT(3'd5)) n1 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[1]),              .adapt_en(adapt_en),.spike_out(s[1]));
    lif_neuron #(.THRESHOLD(8'd6), .WEIGHT(3'd3)) n2 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[2]),              .adapt_en(adapt_en),.spike_out(s[2]));
    lif_neuron #(.THRESHOLD(8'd4), .WEIGHT(3'd6)) n3 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[3]),              .adapt_en(adapt_en),.spike_out(s[3]));

    // ── Neurons 4-7: HRV delta input stream ──────────────────────────────────
    lif_neuron #(.THRESHOLD(8'd3), .WEIGHT(3'd5)) n4 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[0]),              .adapt_en(adapt_en),.spike_out(s[4]));
    lif_neuron #(.THRESHOLD(8'd3), .WEIGHT(3'd4)) n5 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[1]),              .adapt_en(adapt_en),.spike_out(s[5]));
    lif_neuron #(.THRESHOLD(8'd4), .WEIGHT(3'd6)) n6 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[2]),              .adapt_en(adapt_en),.spike_out(s[6]));
    // n7: Option A recurrence — gd[3] OR previous beat's n0 spike
    lif_neuron #(.THRESHOLD(8'd2), .WEIGHT(3'd3)) n7 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[3] | spike_reg1), .adapt_en(adapt_en),.spike_out(s[7]));

endmodule