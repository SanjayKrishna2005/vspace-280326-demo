`default_nettype none

module lif_neuron #(
    parameter THRESHOLD = 8'd5,
    parameter WEIGHT    = 3'd4
) (
    input  wire clk,
    input  wire rst_n,
    input  wire ena,
    input  wire spike_valid,   
    input  wire spike_in,
    output reg  spike_out
);
    reg [3:0] potential;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            potential <= 4'd0;
            spike_out <= 1'b0;
        end else if (ena && spike_valid) begin
            
            if (potential >= THRESHOLD) begin
                spike_out <= 1'b1;
                potential <= 4'd0;
            end else begin
                spike_out <= 1'b0;
                potential <= (potential >> 1) + (spike_in ? {1'b0, WEIGHT} : 4'd0);
            end
        end
        
    end

endmodule