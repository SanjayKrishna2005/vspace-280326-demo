`default_nettype none


module tt_um_snn_afib_detector (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    // uio[0] is an output (asystole_flag); all others are inputs (driven low)
    assign uio_out[7:1] = 7'b0;
    assign uio_oe       = 8'b0000_0001;   // only bit 0 is output

    wire r_peak = ui_in[0];
    wire w_load = ui_in[1];
    wire w_data = ui_in[2];
    wire w_clk  = ui_in[3];

    wire [5:0]  rr_interval;
    wire [5:0]  rr_delta;
    wire        rr_valid;
    wire        asystole_flag;
    wire [3:0]  spike_interval;
    wire [3:0]  spike_delta;
    wire        spike_valid;
    wire [10:0] neuron_spikes;
    wire        any_spike;
    wire        afib_flag;
    wire        out_valid;
    wire [1:0]  fsm_state;
    wire [2:0]  confidence;
    wire [2:0]  confidence_latch;

    rr_features u_rr_features (
        .clk          (clk),
        .rst_n        (rst_n),
        .ena          (ena),
        .r_peak       (r_peak),
        .rr_interval  (rr_interval),
        .rr_delta     (rr_delta),
        .rr_valid     (rr_valid),
        .asystole_flag(asystole_flag)
    );

    spike_encoder u_spike_enc (
        .clk           (clk),
        .rst_n         (rst_n),
        .ena           (ena),
        .rr_interval   (rr_interval),
        .rr_delta      (rr_delta),
        .rr_valid      (rr_valid),
        .spike_interval(spike_interval),
        .spike_delta   (spike_delta),
        .spike_valid   (spike_valid)
    );

    reservoir u_reservoir (
        .clk           (clk),
        .rst_n         (rst_n),
        .ena           (ena),
        .spike_interval(spike_interval),
        .spike_delta   (spike_delta),
        .spike_valid   (spike_valid),
        .neuron_spikes (neuron_spikes),
        .any_spike     (any_spike)
    );

    readout u_readout (
        .clk             (clk),
        .rst_n           (rst_n),
        .ena             (ena),
        .w_load          (w_load),
        .w_data          (w_data),
        .w_clk           (w_clk),
        .neuron_spikes   (neuron_spikes),
        .spike_valid     (spike_valid),
        .afib_flag       (afib_flag),
        .out_valid       (out_valid),
        .fsm_state       (fsm_state),
        .confidence      (confidence),
        .confidence_latch(confidence_latch)
    );

    assign uo_out[0]   = afib_flag;
    assign uo_out[1]   = out_valid;
    assign uo_out[2]   = any_spike;
    assign uo_out[3]   = fsm_state[0];
    assign uo_out[4]   = fsm_state[1];
    assign uo_out[7:5] = confidence_latch;

    assign uio_out[0]  = asystole_flag;   // bradycardia / asystole output

endmodule