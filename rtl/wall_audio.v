//=============================================================================
// wall_audio.v -- HDMI audio: a small ambient synth, generated in the FPGA
//
// The contest asks for "??????" (plus audio visualisation as an extension).
// There is no processor on this board -- the rules forbid one -- and no room for
// a music file, so the background music is synthesised here: four sine voices
// over a four-chord loop, 48 kHz, 24-bit.
//
//   0            3.5 s          7 s          10.5 s        14 s
//   Am7 -------> Fmaj7 ------> Cmaj7 ------> G6 ---------> (loop)
//
// Each voice keeps its phase across a chord change, so the boundary does not
// click.  One quarter-sine LUT is time-multiplexed over the four voices: a
// 48 kHz sample is 520 clocks at 25 MHz and the sequencer needs six of them.
//
// The ring at the bottom is what the on-screen scope draws: one point every 32nd
// sample (1.5 kHz) into 240 entries, i.e. the last ~160 ms of waveform.
//=============================================================================
`timescale 1ns/1ps

module wall_audio #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer FS_HZ  = 48_000
)(
    input  wire        clk,           // 25 MHz pixel clock
    input  wire        rst,
    output reg         valid,         // 1-cycle strobe at FS_HZ
    output reg  [23:0] left,          // 24-bit two's complement
    output reg  [23:0] right,
    output wire [7:0]  wav_base,      // oldest entry of the wave ring
    input  wire [7:0]  wav_addr,
    output wire [7:0]  wav_data,
    output wire [7:0]  level          // current |sample|, for a level bar
);
    // ----------------------------------------------------------- 48 kHz strobe
    reg [31:0] fs_acc;
    wire [31:0] fs_next = fs_acc + FS_HZ[31:0];
    wire        fs_tick = (fs_next >= CLK_HZ[31:0]);

    always @(posedge clk) begin
        if (rst) begin
            fs_acc <= 32'd0;
            valid  <= 1'b0;
        end else if (fs_tick) begin
            fs_acc <= fs_next - CLK_HZ[31:0];
            valid  <= 1'b1;
        end else begin
            fs_acc <= fs_next;
            valid  <= 1'b0;
        end
    end

    // ------------------------------------------------- quarter-sine (64 steps)
    // sin((i+0.5) * (pi/2) / 64) * 16383
    reg [5:0]  sin_idx;
    reg [13:0] sin_q;
    always @(*) begin
        case (sin_idx)
            6'd0:  sin_q = 14'd201;   6'd1:  sin_q = 14'd603;
            6'd2:  sin_q = 14'd1005;  6'd3:  sin_q = 14'd1406;
            6'd4:  sin_q = 14'd1806;  6'd5:  sin_q = 14'd2205;
            6'd6:  sin_q = 14'd2603;  6'd7:  sin_q = 14'd2999;
            6'd8:  sin_q = 14'd3393;  6'd9:  sin_q = 14'd3785;
            6'd10: sin_q = 14'd4175;  6'd11: sin_q = 14'd4563;
            6'd12: sin_q = 14'd4948;  6'd13: sin_q = 14'd5330;
            6'd14: sin_q = 14'd5708;  6'd15: sin_q = 14'd6083;
            6'd16: sin_q = 14'd6455;  6'd17: sin_q = 14'd6822;
            6'd18: sin_q = 14'd7186;  6'd19: sin_q = 14'd7545;
            6'd20: sin_q = 14'd7900;  6'd21: sin_q = 14'd8249;
            6'd22: sin_q = 14'd8594;  6'd23: sin_q = 14'd8934;
            6'd24: sin_q = 14'd9268;  6'd25: sin_q = 14'd9597;
            6'd26: sin_q = 14'd9920;  6'd27: sin_q = 14'd10237;
            6'd28: sin_q = 14'd10548; 6'd29: sin_q = 14'd10852;
            6'd30: sin_q = 14'd11150; 6'd31: sin_q = 14'd11441;
            6'd32: sin_q = 14'd11726; 6'd33: sin_q = 14'd12003;
            6'd34: sin_q = 14'd12273; 6'd35: sin_q = 14'd12536;
            6'd36: sin_q = 14'd12791; 6'd37: sin_q = 14'd13038;
            6'd38: sin_q = 14'd13278; 6'd39: sin_q = 14'd13509;
            6'd40: sin_q = 14'd13733; 6'd41: sin_q = 14'd13948;
            6'd42: sin_q = 14'd14154; 6'd43: sin_q = 14'd14353;
            6'd44: sin_q = 14'd14542; 6'd45: sin_q = 14'd14723;
            6'd46: sin_q = 14'd14895; 6'd47: sin_q = 14'd15058;
            6'd48: sin_q = 14'd15212; 6'd49: sin_q = 14'd15356;
            6'd50: sin_q = 14'd15492; 6'd51: sin_q = 14'd15618;
            6'd52: sin_q = 14'd15735; 6'd53: sin_q = 14'd15842;
            6'd54: sin_q = 14'd15940; 6'd55: sin_q = 14'd16028;
            6'd56: sin_q = 14'd16106; 6'd57: sin_q = 14'd16175;
            6'd58: sin_q = 14'd16234; 6'd59: sin_q = 14'd16283;
            6'd60: sin_q = 14'd16323; 6'd61: sin_q = 14'd16352;
            6'd62: sin_q = 14'd16372; 6'd63: sin_q = 14'd16382;
            default: sin_q = 14'd0;
        endcase
    end

    // ------------------------------------------------------------- chord table
    reg [1:0]  chord;
    reg [31:0] ph0, ph1, ph2, ph3;

    function [31:0] inc_of;
        input [1:0] c;
        input [1:0] v;
        begin
            case (c)
                2'd0: case (v)                                        // Am7
                    2'd0: inc_of = 32'd9842633;      // A2
                    2'd1: inc_of = 32'd19685267;     // A3
                    2'd2: inc_of = 32'd23410256;     // C4
                    default: inc_of = 32'd29494793;  // E4
                endcase
                2'd1: case (v)                                        // Fmaj7
                    2'd0: inc_of = 32'd7812367;      // F2
                    2'd1: inc_of = 32'd15623838;     // F3
                    2'd2: inc_of = 32'd23410256;     // C4
                    default: inc_of = 32'd29494793;  // E4
                endcase
                2'd2: case (v)                                        // Cmaj7
                    2'd0: inc_of = 32'd11704681;     // C3
                    2'd1: inc_of = 32'd17537783;     // G3
                    2'd2: inc_of = 32'd23410256;     // C4
                    default: inc_of = 32'd29494793;  // E4
                endcase
                default: case (v)                                     // G6
                    2'd0: inc_of = 32'd8768892;      // G2
                    2'd1: inc_of = 32'd17537783;     // G3
                    2'd2: inc_of = 32'd22095817;     // B3
                    default: inc_of = 32'd26276252;  // D4
                endcase
            endcase
        end
    endfunction

    wire [31:0] ph0_n = ph0 + inc_of(chord, 2'd0);
    wire [31:0] ph1_n = ph1 + inc_of(chord, 2'd1);
    wire [31:0] ph2_n = ph2 + inc_of(chord, 2'd2);
    wire [31:0] ph3_n = ph3 + inc_of(chord, 2'd3);

    // ------------------------------------------------------- sample sequencer
    localparam integer HOLD = 168_000;      // 3.5 s at 48 kHz
    reg [17:0] hold_cnt;
    reg [2:0]  seq;
    reg [31:0] ph_sel;                       // phase of the voice being looked up
    reg signed [18:0] sacc;
    reg [15:0] mix;

    // phase bits 31..22 = 1024 steps per cycle; quadrant = bit 9, mirror = bit 8
    wire [9:0]  p10  = ph_sel[31:22];
    // quarter-sine index: mirror inside each half, sign comes from p10[9]
    always @(*) sin_idx = p10[8] ? ~p10[7:2] : p10[7:2];
    wire signed [15:0] sine_now = p10[9] ? -$signed({2'b00, sin_q})
                                         :  $signed({2'b00, sin_q});

    // ------------------------------------------------- waveform ring for the OSD
    localparam integer WAV_LEN = 240;
    reg [7:0] wav_ram [0:WAV_LEN-1];
    reg [7:0] wptr;
    reg [4:0] dec;
    assign wav_data = wav_ram[wav_addr];
    assign wav_base = wptr;
    assign level    = mix[15] ? (~mix[14:7] + 8'd1) : mix[14:7];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            hold_cnt <= 18'd0;
            chord    <= 2'd0;
            ph0 <= 32'd0; ph1 <= 32'd0; ph2 <= 32'd0; ph3 <= 32'd0;
            seq  <= 3'd0; ph_sel <= 32'd0; sacc <= 19'd0; mix <= 16'd0;
            left  <= 24'd0;
            right <= 24'd0;
            wptr  <= 8'd0;
            dec   <= 5'd0;
        end else begin
            case (seq)
                3'd0: if (valid) begin
                    hold_cnt <= (hold_cnt == HOLD[17:0] - 18'd1) ? 18'd0
                                                                 : (hold_cnt + 18'd1);
                    if (hold_cnt == HOLD[17:0] - 18'd1) chord <= chord + 2'd1;
                    sacc <= 19'd0;
                    seq  <= 3'd1;
                end
                3'd1: begin ph_sel <= ph0; seq <= 3'd2; end
                3'd2: begin sacc <= sacc + sine_now; ph_sel <= ph1; seq <= 3'd3; end
                3'd3: begin sacc <= sacc + sine_now; ph_sel <= ph2; seq <= 3'd4; end
                3'd4: begin sacc <= sacc + sine_now; ph_sel <= ph3; seq <= 3'd5; end
                3'd5: begin sacc <= sacc + sine_now; seq <= 3'd6; end
                default: begin
                    // four voices of +/-16383 -> signed 16-bit mix
                    mix  <= sacc[17:2];
                    ph0  <= ph0_n; ph1 <= ph1_n; ph2 <= ph2_n; ph3 <= ph3_n;
                    left  <= {{4{mix[15]}}, mix[15:0], 4'h0};
                    right <= {{4{mix[15]}}, mix[15:0], 4'h0};

                    dec <= dec + 5'd1;
                    if (dec == 5'd31) begin
                        wav_ram[wptr] <= mix[15:8];
                        wptr <= (wptr == WAV_LEN - 1) ? 8'd0 : (wptr + 8'd1);
                    end
                    seq <= 3'd0;
                end
            endcase
        end
    end
endmodule
