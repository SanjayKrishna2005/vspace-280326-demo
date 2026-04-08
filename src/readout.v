`default_nettype none



module readout (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ena,
    input  wire        w_load,
    input  wire        w_data,
    input  wire        w_clk,
    input  wire [10:0] neuron_spikes,
    input  wire        spike_valid,
    output reg         afib_flag,
    output reg         out_valid,
    output reg  [1:0]  fsm_state,
    output wire [2:0]  confidence,
    output reg  [2:0]  confidence_latch
);

    // ── Parameters ───────────────────────────────────────────────────────────
    localparam ULTRA_WINDOW = 3'd4;             // 4 beats
    localparam FAST_WINDOW  = 4'd8;             // 8 beats
    localparam SLOW_WINDOW  = 5'd16;            // 16 beats

    localparam signed [8:0]  ULTRA_THRESH = -9'sd1;
    localparam signed [8:0]  FAST_THRESH  = -9'sd1;
    localparam signed [9:0]  SLOW_THRESH  = -10'sd2;

    localparam LOAD   = 2'b00;
    localparam RUN    = 2'b01;
    localparam OUTPUT = 2'b10;

    // ── Weight shift register ─────────────────────────────────────────────────
    reg [32:0] weight_sr;
    reg        w_clk_prev;
    reg        w_load_seen;

    wire [2:0] w0  = weight_sr[ 2: 0];  wire [2:0] w1  = weight_sr[ 5: 3];
    wire [2:0] w2  = weight_sr[ 8: 6];  wire [2:0] w3  = weight_sr[11: 9];
    wire [2:0] w4  = weight_sr[14:12];  wire [2:0] w5  = weight_sr[17:15];
    wire [2:0] w6  = weight_sr[20:18];  wire [2:0] w7  = weight_sr[23:21];
    wire [2:0] w8  = weight_sr[26:24];  wire [2:0] w9  = weight_sr[29:27];
    wire [2:0] w10 = weight_sr[32:30];

    // ── Sign-extend 3-bit 2's complement weights to 9-bit signed ─────────────
    wire signed [8:0] ws0  = {{6{w0[2]}},  w0};
    wire signed [8:0] ws1  = {{6{w1[2]}},  w1};
    wire signed [8:0] ws2  = {{6{w2[2]}},  w2};
    wire signed [8:0] ws3  = {{6{w3[2]}},  w3};
    wire signed [8:0] ws4  = {{6{w4[2]}},  w4};
    wire signed [8:0] ws5  = {{6{w5[2]}},  w5};
    wire signed [8:0] ws6  = {{6{w6[2]}},  w6};
    wire signed [8:0] ws7  = {{6{w7[2]}},  w7};
    wire signed [8:0] ws8  = {{6{w8[2]}},  w8};
    wire signed [8:0] ws9  = {{6{w9[2]}},  w9};
    wire signed [8:0] ws10 = {{6{w10[2]}}, w10};

    // ── Per-neuron spike contributions (gated by spike presence) ─────────────
    wire signed [8:0] c0  = neuron_spikes[0]  ? ws0  : 9'sd0;
    wire signed [8:0] c1  = neuron_spikes[1]  ? ws1  : 9'sd0;
    wire signed [8:0] c2  = neuron_spikes[2]  ? ws2  : 9'sd0;
    wire signed [8:0] c3  = neuron_spikes[3]  ? ws3  : 9'sd0;
    wire signed [8:0] c4  = neuron_spikes[4]  ? ws4  : 9'sd0;
    wire signed [8:0] c5  = neuron_spikes[5]  ? ws5  : 9'sd0;
    wire signed [8:0] c6  = neuron_spikes[6]  ? ws6  : 9'sd0;
    wire signed [8:0] c7  = neuron_spikes[7]  ? ws7  : 9'sd0;
    wire signed [8:0] c8  = neuron_spikes[8]  ? ws8  : 9'sd0;
    wire signed [8:0] c9  = neuron_spikes[9]  ? ws9  : 9'sd0;
    wire signed [8:0] c10 = neuron_spikes[10] ? ws10 : 9'sd0;

    // ── Per-beat signed sum across all 11 neurons ─────────────────────────────
    wire signed [12:0] cycle_sum =
        $signed(c0)  + $signed(c1)  + $signed(c2)  + $signed(c3)  +
        $signed(c4)  + $signed(c5)  + $signed(c6)  + $signed(c7)  +
        $signed(c8)  + $signed(c9)  + $signed(c10);

    // Truncated views fed to each window accumulator
    wire signed [8:0]  cycle_fast = cycle_sum[8:0];   // 9-bit for ultra & fast
    wire signed [9:0]  cycle_slow = cycle_sum[9:0];   // 10-bit for slow

    // ── Window accumulators ───────────────────────────────────────────────────
    // ULTRA (4-beat) — shares beat_fast counter, no extra counter register
    reg signed [8:0]  accum_ultra;
    reg               afib_ultra;


    // FAST (8-beat) — unchanged from original
    reg signed [8:0]  accum_fast;
    reg [3:0]         beat_fast;
    reg               afib_fast;
    reg signed [8:0]  accum_fast_snap;

    // SLOW (16-beat) — unchanged from original
    reg signed [9:0]  accum_slow;
    reg [4:0]         beat_slow;
    reg               afib_slow;

    // ── Ultra-window closes at beat 3 and beat 7 (every 4 beats) ─────────────
    wire ultra_close = (beat_fast == ULTRA_WINDOW - 1) |
                       (beat_fast == FAST_WINDOW  - 1);

    // ── Live confidence from fast-window snapshot ─────────────────────────────
    assign confidence =
        (accum_fast_snap >= FAST_THRESH + 9'sd8) ? 3'b111 :
        (accum_fast_snap >= FAST_THRESH + 9'sd4) ? 3'b110 :
        (accum_fast_snap >= FAST_THRESH)          ? 3'b101 :
        (accum_fast_snap <= FAST_THRESH - 9'sd8) ? 3'b000 :
        (accum_fast_snap <= FAST_THRESH - 9'sd4) ? 3'b001 : 3'b010;

    // ── Main FSM ──────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_sr        <= 33'b0;
            w_clk_prev       <= 1'b0;
            w_load_seen      <= 1'b0;
            accum_ultra      <= 9'sd0;
            accum_fast       <= 9'sd0;
            accum_slow       <= 10'sd0;
            accum_fast_snap  <= 9'sd0;
            beat_fast        <= 4'd0;
            beat_slow        <= 5'd0;
            afib_ultra       <= 1'b0;
            afib_fast        <= 1'b0;
            afib_slow        <= 1'b0;
            afib_flag        <= 1'b0;
            out_valid        <= 1'b0;
            confidence_latch <= 3'b010;
            fsm_state        <= LOAD;
        end else if (ena) begin
            w_clk_prev  <= w_clk;

            case (fsm_state)

                // ── LOAD: clock in weights via serial interface ───────────────
                LOAD: begin
                    out_valid <= 1'b0;
                    if (w_load)
                        w_load_seen <= 1'b1;
                    if (w_clk & ~w_clk_prev)
                        weight_sr <= {weight_sr[31:0], w_data};
                    if (w_load_seen && !w_load) begin
                        fsm_state   <= RUN;
                        accum_ultra <= 9'sd0;
                        accum_fast  <= 9'sd0;
                        accum_slow  <= 10'sd0;
                        beat_fast   <= 4'd0;
                        beat_slow   <= 5'd0;
                        w_load_seen <= 1'b0;
                    end
                end

                // ── RUN: accumulate spike scores across all three windows ─────
                RUN: begin
                    if (w_load) begin
                        fsm_state <= LOAD;
                    end else if (spike_valid) begin

                        // All three windows accumulate this beat's score
                        accum_ultra <= accum_ultra + cycle_fast;
                        accum_fast  <= accum_fast  + cycle_fast;
                        accum_slow  <= accum_slow  + cycle_slow;
                        beat_fast   <= beat_fast   + 4'd1;
                        beat_slow   <= beat_slow   + 5'd1;

                        // ── ULTRA window closes every 4 beats ─────────────────
                      
                        if (ultra_close) begin
                            afib_ultra  <= (accum_ultra > ULTRA_THRESH);
                            accum_ultra <= 9'sd0;
                        end

                        // ── FAST window closes every 8 beats ──────────────────
                        if (beat_fast == FAST_WINDOW - 1) begin
                            afib_fast       <= (accum_fast > FAST_THRESH);
                            accum_fast_snap <= accum_fast;
                            accum_fast      <= 9'sd0;
                            beat_fast       <= 4'd0;
                        end

                        // ── SLOW window closes every 16 beats → trigger OUTPUT─
                        if (beat_slow == SLOW_WINDOW - 1) begin
                            afib_slow  <= (accum_slow > SLOW_THRESH);
                            accum_slow <= 10'sd0;
                            beat_slow  <= 5'd0;
                            fsm_state  <= OUTPUT;
                        end
                    end
                end

               
                OUTPUT: begin
                    confidence_latch <= confidence;
                    afib_flag   <= (afib_ultra & afib_fast)  |
                                   (afib_fast  & afib_slow)  |
                                   (afib_ultra & afib_slow);
                    out_valid   <= 1'b1;
                    fsm_state   <= RUN;
                end

                default: fsm_state <= LOAD;
            endcase
        end
    end

endmodule