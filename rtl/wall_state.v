//=============================================================================
// wall_state.v -- authoritative window table with the 2-frame pipeline
//
//   stage  : edited by the input FSM (node A) or the frame deserializer (B)
//   snap   : latched at a frame start; this is what node A TRANSMITS
//   cur    : latched one frame later; this is what the renderer DRAWS
//
// A frame N commit does:  snap <= stage ; cur <= snap(previous)
// so what A sends at frame N is exactly what both nodes draw at frame N+1.
// That removes the "receiver is one frame behind" seam glitch without any
// shared clock: A simply announces its next frame instead of the current one.
//=============================================================================
`timescale 1ns/1ps

module wall_state #(
    // Default layout.  NOTE: the picture is fitted to the window's CONTENT area,
    // which is (w - 4) x (h - 16) -- 2 px border each side plus a 14 px title bar
    // (see wall_scene: cw = ww - 4, chh = h - 16).  The stored picture is
    // 192 x 144 (4:3), so the window must be 264 x 211 for its content area to be
    // 260 x 195 = 4:3.  Making the WINDOW 4:3 instead (e.g. 264 x 198) leaves a
    // 260 x 182 content area, and the fit then letterboxes ~9 px each side.
    parameter [255:0] TBL_INIT = 256'h00C733E93C0323A2008223E93C0AA2080041134D0802C1580008034D08018018,
    parameter [1:0]   SEL_INIT = 2'd0,
    // 1 = render two frames behind stage (node A: it sends the NEXT frame's
    // table, so its own render must wait one more commit to stay in step with
    // the peer).  0 = render what was just committed (node B).
    parameter integer SNAP_DEPTH2 = 1
)(
    input  wire         clk,
    input  wire         rst,          // high active, synchronous
    input  wire         commit,       // frame start pulse
    input  wire         set_tbl,
    input  wire [1:0]   set_idx,
    input  wire [63:0]  set_data,
    input  wire         set_sel,
    input  wire [1:0]   sel_in,
    input  wire         set_anim,
    input  wire [4:0]   anim_in,
    input  wire [1:0]   rd_idx,
    output wire [63:0]  rd_word,      // stage[] read port for the FSM
    output wire [255:0] cur_tbl,
    output wire [1:0]   cur_sel,
    output wire [4:0]   cur_anim,
    output wire [255:0] snap_tbl,
    output wire [1:0]   snap_sel,
    output wire [4:0]   snap_anim
);
    reg [63:0] w0, w1, w2, w3;   // stage
    reg [63:0] s0, s1, s2, s3;   // snap
    reg [63:0] c0, c1, c2, c3;   // cur
    reg [1:0]  wsel, ssel, csel;
    reg [4:0]  wanim, sanim, canim;

    always @(posedge clk) begin
        if (rst) begin
            {w3, w2, w1, w0} <= TBL_INIT;
            {s3, s2, s1, s0} <= TBL_INIT;
            {c3, c2, c1, c0} <= TBL_INIT;
            wsel <= SEL_INIT; ssel <= SEL_INIT; csel <= SEL_INIT;
            wanim <= 5'd0;    sanim <= 5'd0;    canim <= 5'd0;
        end else begin
            if (set_tbl) begin
                case (set_idx)
                    2'd0: w0 <= set_data;
                    2'd1: w1 <= set_data;
                    2'd2: w2 <= set_data;
                    default: w3 <= set_data;
                endcase
            end
            if (set_sel)  wsel  <= sel_in;
            if (set_anim) wanim <= anim_in;

            if (commit) begin
                s0 <= w0; s1 <= w1; s2 <= w2; s3 <= w3;
                ssel <= wsel; sanim <= wanim;
                if (SNAP_DEPTH2 != 0) begin
                    c0 <= s0; c1 <= s1; c2 <= s2; c3 <= s3;
                end else begin
                    c0 <= w0; c1 <= w1; c2 <= w2; c3 <= w3;
                end
                csel <= (SNAP_DEPTH2 != 0) ? ssel  : wsel;
                canim <= (SNAP_DEPTH2 != 0) ? sanim : wanim;
            end
        end
    end

    assign rd_word  = (rd_idx == 2'd0) ? w0 :
                      (rd_idx == 2'd1) ? w1 :
                      (rd_idx == 2'd2) ? w2 : w3;
    assign cur_tbl  = {c3, c2, c1, c0};
    assign cur_sel  = csel;
    assign cur_anim = canim;
    assign snap_tbl = {s3, s2, s1, s0};
    assign snap_sel = ssel;
    assign snap_anim = sanim;
endmodule
