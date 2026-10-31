//=============================================================================
// wall_carousel.v -- carousel phase + fade envelope (node A owns it)
//
// One picture per HOLD+FADE_OUT+FADE_IN frames:
//   HOLD      frames at full brightness (gain 255)
//   FADE_OUT  frames 255 -> 0
//   (the phase steps on the last fade-out frame, i.e. exactly at black)
//   FADE_IN   frames 0 -> 255
//
// `auto_on` = KEY4 style toggle: press once for manual, again for auto.  In
// manual mode the gain stays at 255 and `step` advances the phase immediately
// (no fade: the operator is looking at the screen and wants the click to land).
//
// The phase and the gain are both meant to be BROADCAST to the peer node (the
// fade now has its own byte in the STATE frame), so both halves of the wall
// dim and switch on the same frame -- a fade computed independently on node B
// cannot work: B sees the new phase one frame late, and the seam tears.
//
// Kept in its own module so the envelope, the step-at-black rule and the auto
// toggle can be simulated without a raster, a link or an SDRAM (tb_carousel_ctrl).
//=============================================================================
`timescale 1ns/1ps

module wall_carousel #(
    parameter integer HOLD_FRAMES = 224,
    parameter integer FADE_FRAMES = 16
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       frame,      // 1 = start of a frame (sof)
    input  wire       toggle,     // auto on/off request, already latched to frame
    input  wire       step,       // manual step request, already latched to frame
    output reg  [1:0] cyc,        // which picture each window shows
    output reg        auto_on,
    output reg  [7:0] gain        // 255 = full, 0 = black
);
    // 16 steps of 17 cover 0..255 exactly (last value = 15*17 = 255)
    localparam integer G_STEP = 255 / (FADE_FRAMES - 1);

    localparam [1:0] S_HOLD = 2'd0, S_OUT = 2'd1, S_IN = 2'd2;

    reg [1:0] st;
    reg [7:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            cyc     <= 2'd0;
            auto_on <= 1'b1;          // power-on: keep rotating, like W1
            st      <= S_HOLD;
            cnt     <= 8'd0;
            gain    <= 8'hFF;
        end else if (frame) begin
            if (toggle) auto_on <= ~auto_on;

            if (!auto_on) begin
                // manual: no fade, step on request
                st   <= S_HOLD;
                cnt  <= 8'd0;
                gain <= 8'hFF;
                if (step) cyc <= cyc + 2'd1;
            end else begin
                case (st)
                    S_HOLD: begin
                        gain <= 8'hFF;
                        if (cnt == HOLD_FRAMES - 1) begin
                            cnt <= 8'd0;
                            st  <= S_OUT;
                        end else begin
                            cnt <= cnt + 8'd1;
                        end
                    end
                    S_OUT: begin
                        gain <= 8'd255 - (cnt * G_STEP);   // 255,238,...,0
                        if (cnt == FADE_FRAMES - 1) begin
                            cyc <= cyc + 2'd1;             // switch while black
                            cnt <= 8'd0;
                            st  <= S_IN;
                        end else begin
                            cnt <= cnt + 8'd1;
                        end
                    end
                    default: begin
                        gain <= cnt * G_STEP;              // 0,17,...,255
                        if (cnt == FADE_FRAMES - 1) begin
                            cnt <= 8'd0;
                            st  <= S_HOLD;
                        end else begin
                            cnt <= cnt + 8'd1;
                        end
                    end
                endcase
            end
        end
    end
endmodule
