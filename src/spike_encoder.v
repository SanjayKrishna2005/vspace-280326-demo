`default_nettype none

module spike_encoder (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire [5:0] rr_interval,
    input  wire [5:0] rr_delta,
    input  wire       rr_valid,
    output reg  [3:0] spike_interval,
    output reg  [3:0] spike_delta,
    output reg        spike_valid
);
    wire [3:0] enc_interval = 4'd15 - rr_interval[5:2];
    wire [3:0] enc_delta    = (rr_delta > 6'd15) ? 4'd15 : rr_delta[3:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spike_interval <= 4'd0;
            spike_delta    <= 4'd0;
            spike_valid    <= 1'b0;
        end else if (ena) begin
            spike_valid <= 1'b0;
            if (rr_valid) begin
                spike_interval <= enc_interval;
                spike_delta    <= enc_delta;
                spike_valid    <= 1'b1;
            end
        end
    end

endmodule