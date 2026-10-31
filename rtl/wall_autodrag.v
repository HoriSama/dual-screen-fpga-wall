//=============================================================================
// wall_autodrag.v -- host-verification helper: drive a synthetic drag
//
// ENABLE=0 (default build) -> no logic.
// ENABLE=1 -> after START_CYC it latches SW2 (direction keys on), locks the
//             selected window with KEY2, walks it right with KEY4 presses at
//             STEP_CYC cycles per pixel, and finally latches SW1 to view mode
//             once the window is past x=760 (which is what hands the window to
//             the other node, since ownership follows the centre).
//
// It exists so the whole cross-node move + ownership hand-off can be exercised
// on hardware while a host only reads the two status UARTs.
//
// SW1/SW2 are latched buttons: a low pulse at least as long as the debounce
// window toggles the mode bit.
//=============================================================================
`timescale 1ns/1ps

module wall_autodrag #(
    parameter integer ENABLE     = 0,
    parameter integer START_CYC  = 25_000_000,
    parameter integer STEP_CYC   = 207_999,
    parameter integer SW_HOLD    = 400         // low-pulse width for SW1/SW2
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [11:0] gx,
    output reg  [3:0]  press
);
    generate
        if (ENABLE != 0) begin : g_on
            localparam [2:0] P_WAIT = 3'd0, P_SW2 = 3'd1, P_LOCK = 3'd2,
                             P_MOVE = 3'd3, P_SW1 = 3'd4, P_DONE = 3'd5;

            reg [2:0]  ph;
            reg [24:0] acnt;
            reg [17:0] rep;
            reg [9:0]  hold;

            always @(posedge clk) begin
                if (rst) begin
                    ph    <= P_WAIT;
                    acnt  <= 25'd0;
                    rep   <= 18'd0;
                    hold  <= 10'd0;
                    press <= 4'd0;
                end else begin
                    press <= 4'd0;
                    case (ph)
                        P_WAIT: begin
                            acnt <= acnt + 25'd1;
                            if (acnt >= START_CYC[24:0]) begin
                                acnt <= 25'd0;
                                ph   <= P_SW2;
                            end
                        end
                        P_SW2: begin
                            // SW1..SW4 are slide switches: assert the level and
                            // leave it asserted for the whole move.
                            hold    <= hold + 10'd1;
                            if (hold >= SW_HOLD[9:0]) begin
                                hold <= 10'd0;
                                ph   <= P_LOCK;
                            end
                        end
                        P_LOCK: begin
                            press[1] <= 1'b1;          // KEY2: lock the window
                            ph       <= P_MOVE;
                        end
                        P_MOVE: begin
                            if (gx >= 12'd760) begin
                                ph <= P_SW1;
                            end else if (rep == STEP_CYC[17:0]) begin
                                rep      <= 18'd0;
                                press[3] <= 1'b1;      // KEY4: 1 px right
                            end else begin
                                rep <= rep + 18'd1;
                            end
                        end
                        P_SW1: begin
                            // release SW2 first, then KEY2 unlocks: ownership is
                            // decided by the window centre at that moment
                            hold <= hold + 10'd1;
                            if (hold == (SW_HOLD[9:0] >> 1)) press[1] <= 1'b1;
                            if (hold >= SW_HOLD[9:0]) begin
                                hold <= 10'd0;
                                ph   <= P_DONE;
                            end
                        end
                        default: ;
                    endcase
                end
            end
        end else begin : g_off
            always @(*) begin
                press = 4'd0;
            end
        end
    endgenerate
endmodule
