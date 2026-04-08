`default_nettype none

module rr_features (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire       r_peak,
    output reg  [5:0] rr_interval,
    output reg  [5:0] rr_delta,
    output reg        rr_valid,
    output reg        asystole_flag   
);
    reg [15:0] tick_count;
    reg  [5:0] rr_prev;
    reg        r_peak_prev;
    wire       r_peak_rise = r_peak & ~r_peak_prev;

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
                rr_interval   <= (tick_count[15:9] > 7'd63)
                                 ? 6'd63 : tick_count[15:9];
                rr_delta      <= (tick_count[15:9] > rr_prev)
                                 ? tick_count[15:9] - rr_prev
                                 : rr_prev - tick_count[15:9];
                rr_prev       <= (tick_count[15:9] > 7'd63)
                                 ? 6'd63 : tick_count[15:9];
                rr_valid      <= 1'b1;
                tick_count    <= 16'd0;
                asystole_flag <= 1'b0;   
            end else begin
                if (tick_count < 16'hFFFF)
                    tick_count <= tick_count + 16'd1;
                if (brd_thresh)
                    asystole_flag <= 1'b1;
            end
        end
    end
endmodule

