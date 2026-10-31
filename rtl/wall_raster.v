//=============================================================================
// wall_raster.v -- 640x480@60 25 MHz timing generator (P1-05A geometry)
//
// The APUG092 HDMI wrapper keeps its own timing authority through the
// hdmi_official_baseline_source-compatible signals that wall_node_top
// registers.  This module only produces counters, so the scene function can
// be purely combinational on (x,y) in the same cycle as `de`.
//
// align: 1-cycle pulse from the link frame sync (node B).  When it arrives
// while the raster is inside vertical blanking, the frame is restarted at
// (0,0); that is the genlock.  If it arrives during active video it is
// ignored (and counted) to avoid tearing the visible frame.
//=============================================================================
`timescale 1ns/1ps

module wall_raster #(
    parameter integer HACTIVE = 640,
    parameter integer HFP     = 16,
    parameter integer HSA     = 96,
    parameter integer HBP     = 48,
    parameter integer VACTIVE = 480,
    parameter integer VFP     = 10,
    parameter integer VSA     = 2,
    parameter integer VBP     = 33
)(
    input  wire       clk_pix,
    input  wire       rst,        // high active, synchronous
    input  wire       align,      // 1-cycle pulse (already in clk_pix domain)
    output wire [9:0] x_c,        // 0..HACTIVE-1 when active
    output wire [8:0] y_c,
    output wire       de_c,       // active video
    output wire       sof_c,      // 1 cycle at (h=0,v=0) == frame boundary
    output wire       last_c,     // last active pixel of a line
    // PRE_LEN clocks before the first active pixel of an active line.  Exists
    // because the compositor's output register means the FIRST visible pixel of
    // a line is composed during blanking, and the line buffer's data is one
    // clock deeper than that: the sample for column 0 must be selected ~3 clocks
    // before `de` rises.  Swapping the ping-pong bank on de's rising edge left
    // column 0 showing the PREVIOUS row -- invisible on node A (world x = 0, the
    // far left of the wall) but a visible one-column seam break on node B
    // (world x = 640).  See wall_pic_line's line_tick.
    output wire       pre_de,
    output wire       align_ok,   // last align pulse landed in vblank
    output reg  [7:0] align_bad,  // saturated count of mis-timed align pulses
    output wire [7:0] no_align_o  // frames since the last successful align
);

    localparam integer HTOTAL  = HACTIVE + HFP + HSA + HBP;
    localparam integer VTOTAL  = VACTIVE + VFP + VSA + VBP;
    localparam integer HBLANK  = HTOTAL - HACTIVE;
    localparam integer VBLANK  = VTOTAL - VACTIVE;

    reg [10:0] hc;
    reg [9:0]  vc;

    // vc counts 0..VTOTAL-1; rows [0,VBLANK) are blanking and [VBLANK,VTOTAL)
    // carry active video.  Getting this comparison backwards was the first
    // hardware bug in the genlock: the align pulse landed in the last 45 active
    // lines and yanked the frame mid-picture.
    wire in_vblank = (vc < VBLANK);
    wire at_origin = (hc == 11'd0) && (vc == 10'd0);
    // Align on EVERY pulse, including mid-frame.  Guarding on vertical
    // blanking looked safer but deadlocks when the two boards sit at a static
    // phase offset: the pulse never lands in vblank, so it is never accepted
    // (observed on hardware: 255 rejected pulses, sync never locked).
    // Restarting the frame once costs a single torn frame and locks at once.
    wire do_align  = align;

    reg [7:0] no_align;   // frames since the last successful align

    always @(posedge clk_pix) begin
        if (rst) begin
            hc        <= 11'd0;
            vc        <= 10'd0;
            no_align  <= 8'd0;
            align_bad <= 8'd0;
        end else if (do_align) begin
            hc        <= 11'd0;
            vc        <= 10'd0;
            no_align  <= 8'd0;
        end else begin
            if (hc == HTOTAL - 1) begin
                hc <= 11'd0;
                if (vc == VTOTAL - 1) vc <= 10'd0;
                else                  vc <= vc + 10'd1;
            end else begin
                hc <= hc + 11'd1;
            end
            if (at_origin && (no_align != 8'hFF)) no_align <= no_align + 8'd1;
            if (align && !in_vblank && !at_origin) begin
                if (align_bad != 8'hFF) align_bad <= align_bad + 8'd1;
            end
        end
    end

    // "Locked" means an align has landed inside blanking recently, not that one
    // is happening right now: the peer clock is free-running and only needs a
    // correction every few frames.
    assign align_ok  = (no_align < 8'd30);
    assign no_align_o = no_align;

    assign x_c    = hc - HBLANK;
    assign y_c    = vc[8:0] - VBLANK[8:0];
    assign de_c   = (hc >= HBLANK) && (vc >= VBLANK);
    assign sof_c  = at_origin;
    assign last_c = de_c && (hc == HTOTAL - 1);

    // ---- line-start lookahead (see the pre_de port comment) ----------------
    // 3 clocks: scene output register (1) + wall_top's AXIS register (1) means
    // column 0 is composed 2 clocks before the first active pixel, using line
    // buffer data addressed one clock before that.
    localparam integer PRE_LEN = 3;
    assign pre_de = (hc + PRE_LEN == HBLANK) && (vc >= VBLANK);

endmodule
