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

    // ── Shared adaptation logic (Option B) ───────────────────────────────────
    // One spike_count register tracks total reservoir firings per 16-beat window.
    // At window boundary (adapt_en), compares against HIGH_MARK / LOW_MARK and
    // generates thresh_up or thresh_dn for one cycle — broadcast to all neurons.
    // This replaces 8 × per-neuron spike_counts, saving ~32 cells.
    //
    // HIGH_MARK = 10: if >10 out of 16 possible neuron-beat events fired,
    //                 reservoir is too active → raise all thresholds
    // LOW_MARK  =  2: if < 2 firings in 16 beats, reservoir too quiet
    //                 → lower all thresholds

    localparam HIGH_MARK = 4'd10;
    localparam LOW_MARK  = 4'd2;

    reg [3:0] spike_count;        // shared: counts any_spike pulses per window
    reg [3:0] adapt_beat_count;   // counts spike_valid events, wraps at 16
    reg       adapt_en;           // one-cycle pulse every 16 beats
    reg       thresh_up;          // one-cycle: tell all neurons to raise threshold
    reg       thresh_dn;          // one-cycle: tell all neurons to lower threshold

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spike_count      <= 4'd0;
            adapt_beat_count <= 4'd0;
            adapt_en         <= 1'b0;
            thresh_up        <= 1'b0;
            thresh_dn        <= 1'b0;
        end else if (ena) begin
            // Default: de-assert all pulses every cycle
            adapt_en  <= 1'b0;
            thresh_up <= 1'b0;
            thresh_dn <= 1'b0;

            // Count any neuron firing within the window
            if (spike_valid && any_spike) begin
                spike_count <= (spike_count < 4'd15)
                               ? spike_count + 4'd1
                               : 4'd15;
            end

            // Beat counter — wraps every 16 spike_valid events
            if (spike_valid) begin
                if (adapt_beat_count == 4'd15) begin
                    adapt_beat_count <= 4'd0;
                    adapt_en         <= 1'b1;

                    // Decide direction based on window firing rate
                    if (spike_count > HIGH_MARK)
                        thresh_up <= 1'b1;   // too active  → raise threshold
                    else if (spike_count < LOW_MARK)
                        thresh_dn <= 1'b1;   // too quiet   → lower threshold
                    // else: in sweet spot → no change

                    spike_count <= 4'd0;     // reset for next window
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
    lif_neuron #(.THRESHOLD(8'd5), .WEIGHT(3'd4)) n0 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[0]),              .thresh_up(thresh_up),.thresh_dn(thresh_dn),.spike_out(s[0]));
    lif_neuron #(.THRESHOLD(8'd4), .WEIGHT(3'd5)) n1 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[1]),              .thresh_up(thresh_up),.thresh_dn(thresh_dn),.spike_out(s[1]));
    lif_neuron #(.THRESHOLD(8'd6), .WEIGHT(3'd3)) n2 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[2]),              .thresh_up(thresh_up),.thresh_dn(thresh_dn),.spike_out(s[2]));
    lif_neuron #(.THRESHOLD(8'd4), .WEIGHT(3'd6)) n3 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gi[3]),              .thresh_up(thresh_up),.thresh_dn(thresh_dn),.spike_out(s[3]));

    // ── Neurons 4-7: HRV delta input stream ──────────────────────────────────
    lif_neuron #(.THRESHOLD(8'd3), .WEIGHT(3'd5)) n4 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[0]),              .thresh_up(thresh_up),.thresh_dn(thresh_dn),.spike_out(s[4]));
    lif_neuron #(.THRESHOLD(8'd3), .WEIGHT(3'd4)) n5 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[1]),              .thresh_up(thresh_up),.thresh_dn(thresh_dn),.spike_out(s[5]));
    lif_neuron #(.THRESHOLD(8'd4), .WEIGHT(3'd6)) n6 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[2]),              .thresh_up(thresh_up),.thresh_dn(thresh_dn),.spike_out(s[6]));
    // n7: Option A recurrence — gd[3] OR previous beat's n0 spike
    lif_neuron #(.THRESHOLD(8'd2), .WEIGHT(3'd3)) n7 (.clk(clk),.rst_n(rst_n),.ena(ena),.spike_valid(spike_valid),.spike_in(gd[3] | spike_reg1), .thresh_up(thresh_up),.thresh_dn(thresh_dn),.spike_out(s[7]));

endmodule