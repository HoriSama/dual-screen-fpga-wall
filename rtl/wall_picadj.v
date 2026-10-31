//=============================================================================
// wall_picadj.v -- per-picture brightness/contrast, combined with the fade
//
// Pixel arithmetic (one instance per colour channel, wall_adj8):
//
//     out = clip( (in * gain) >> 8 + off )
//
// with, for picture i and the CURRENT frame:
//
//     gain_i = ( contrast_i * (fade+1) ) >> 7      1.7 fixed, 256 = 1.0
//     off_i  = ( (brightness_i - 128) * (fade+1) ) >> 8
//
//   contrast_i   0x80 = 1.0 exactly (0x20 = 0.25x, 0xFF = 1.99x)
//   brightness_i 0x80 = neutral (saturating +-8 steps from the UI)
//   fade         255 = full picture; 0 = black
//
// Two choices worth knowing:
//
//  * (fade+1) instead of fade: 255 then makes the whole stage EXACTLY
//    transparent (gain = 256 -> out = in), which is also what makes the stage
//    collapse to the plain adjustment clip((in*c)>>7 + b-128) when there is no
//    fade.  With a bare 255/256 the default picture would be 0.4% dim.
//
//  * The fade is folded into the gain/offset instead of being a second
//    multiplier per pixel: one MULT18 is 3.56 ns of the 40 ns budget, and two
//    in series in the picture path would not close at 25 MHz.  So the products
//    are computed ONCE PER FRAME (60 Hz) by a single shared multiplier that
//    walks the four pictures in eight cycles.  The pixel path keeps exactly one
//    multiplier per channel, and its gain/offset are plain registers.
//
// Offsets are applied BEFORE the fade in effect (off also scales with fade), so
// a fade to black really reaches black even when brightness is cranked up.
//=============================================================================
`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// One 8-bit channel: out = clip((in*gain)>>8 + off)
//-----------------------------------------------------------------------------
module wall_adj8 (
    input  wire [7:0]   in,
    input  wire [9:0]   gain,     // 1.7 fixed: 256 = 1.0, max ~510
    input  wire [9:0]   off,      // signed, -128..127
    output wire [7:0]   out
);
    wire [17:0]        prod = in * gain;                    // 8 x 10
    wire signed [11:0] sum  = $signed({2'b00, prod[17:8]}) + $signed(off);
    assign out = sum[11] ? 8'd0 : (sum > 12'sd255) ? 8'd255 : sum[7:0];
endmodule

//-----------------------------------------------------------------------------
// Per-frame gain/offset table for the four pictures.
//-----------------------------------------------------------------------------
module wall_picadj (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame,       // sof: recompute against the new fade
    input  wire [63:0] tbl,         // 4 x {brightness[7:0], contrast[7:0]}
    input  wire [7:0]  fade,
    output reg  [39:0] gain,        // 4 x 10 bit
    output reg  [39:0] off          // 4 x 10 bit signed
);
    localparam [9:0] G_ONE = 10'd256;      // 1.0

    // Power-up value so the very first sweep starts at picture 0 (FPGA flops come
    // up at 0 anyway; the initialiser also keeps simulation from running on x,
    // which matters because the scene has no reset of its own).
    reg [2:0] s = 3'd0;   // 0..3 = gain pass for picture s, 4..7 = offset pass

    wire [1:0] pi   = s[1:0];
    wire       ph   = s[2];                       // 0 = gain, 1 = offset
    wire [7:0] c_b  = tbl[{pi, 4'b0000} +: 8];    // brightness
    wire [7:0] c_c  = tbl[{pi, 4'b0000} + 8 +: 8];// contrast

    // One shared 8x10 multiplier: contrast*(fade+1) for the gain pass,
    // brightness*(fade+1) for the offset pass.
    wire [7:0] mul_a = ph ? c_b : c_c;
    wire [9:0] f1    = {2'b00, fade} + 10'd1;     // 1..256
    wire [17:0] prod = mul_a * f1;                // 8 x 10

    // off = ((b-128)*f1)>>8, computed as (b*f1 - 128*f1)>>8 so the same
    // unsigned multiplier serves both passes.
    wire signed [18:0] off_raw = $signed({1'b0, prod}) - $signed({1'b0, f1, 7'b0});

    // The sweep FREE-RUNS: one picture every eight cycles, forever.  That keeps
    // the table valid with no "have we computed it yet" state (important in
    // simulation, where the scene has no reset), and a setting change or a new
    // fade is picked up within 320 ns.  `frame` only re-syncs the sweep to the
    // start of the frame so a fade reaches all four pictures inside one vblank.
    always @(posedge clk) begin
        if (rst) begin
            s    <= 3'd0;
            gain <= {4{G_ONE}};                   // power-up = no adjustment
            off  <= 40'd0;
        end else if (frame) begin
            s <= 3'd0;
        end else begin
            // 10-bit fields, so the stride is pi*10 (NOT an 8-bit stride)
            if (ph) off [pi*10 +: 10] <= off_raw[17:8];
            else    gain[pi*10 +: 10] <= prod[16:7];
            s <= s + 3'd1;
        end
    end
endmodule
