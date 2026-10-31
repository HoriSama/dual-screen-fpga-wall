//=============================================================================
// wall_scene.v -- global-coordinate window compositor (no framebuffer)
//
// Everything here is a pure function of (world_x, world_y, window table,
// anim phase).  Node A and node B run the SAME logic with a different
// NODE_X0, so a window crossing the seam is drawn from identical inputs on
// both sides and cannot disagree by a pixel.
//
// One 64-bit window record (see docs/01_spec.md):
//   [11:0] gx  [23:12] gy  [33:24] w  [43:34] h
//   [47:44] src [49:48] z  [50] owner [53:51] flags [57:54] id [63:58] rsv
//
// C3 uses bit 58 (the first reserved bit) as FRAMELESS: no 2 px border, no
// 14 px title bar, and the window is the whole 1280x480 world (album mode).
// Such a window reads the 640x480 full-resolution copy at HI_BASE instead of a
// 192x144 thumbnail, so a screen pixel is exactly one source pixel.
//
// ONE PIXEL OF PIPELINE AT THE OUTPUT (W3 step 1): the final RGB mux is
// registered on clk.  Everything upstream (window eval, z pick, content, HUD,
// carousel fade) is a pure function of x and stays combinational, but the
// register now separates it from the AXIS input register in wall_top instead
// of the two sharing one 40 ns period.
//
// The register costs one clock of latency, so the module composes the pixel
// that the raster column x+1 will show -- the integrator feeds x+1 during
// active pixels (wall_top) and x=0 while blanking, which makes the last
// blanking cycle compose column 0.  The line-buffer column is unchanged
// (clx+1 on active pixels): the buffer output is registered, so the address
// presented while composing column C is already the sample for C.  Net
// effect on screen: identical pixels, no shift, nothing duplicated.
//=============================================================================
`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// One window record evaluated against one global pixel.
//-----------------------------------------------------------------------------
module wall_window_eval (
    input  wire [63:0] rec,
    input  wire [11:0] wx,
    input  wire [11:0] wy,
    output wire        hit,
    output wire [1:0]  z,
    output wire [11:0] lx,
    output wire [11:0] ly,
    output wire [9:0]  w,
    output wire [9:0]  h,
    output wire [3:0]  src,
    output wire        owner,
    output wire [2:0]  flags,
    output wire [3:0]  wid,
    output wire        frameless
);
    wire [11:0] gx = rec[11:0];
    wire [11:0] gy = rec[23:12];
    assign w      = rec[33:24];
    assign h      = rec[43:34];
    assign src    = rec[47:44];
    assign z      = rec[49:48];
    assign owner  = rec[50];
    assign flags  = rec[53:51];
    assign wid    = rec[57:54];
    assign frameless = rec[58];

    assign lx  = wx - gx;
    assign ly  = wy - gy;
    // Interval rule is `>=` and `<` everywhere (never `<=`), so a window edge
    // sitting exactly on the seam can neither be drawn twice nor dropped.
    // A frameless window is BY DEFINITION the whole world: its w/h fields are
    // not used for geometry (they can only hold 1023, and the wall is 1280 wide),
    // so it always hits.  Only the album sequencer ever sets bit 58.
    assign hit = frameless ? 1'b1 :
                 ((wx >= gx) && (wx < gx + {2'b00, w}) &&
                  (wy >= gy) && (wy < gy + {2'b00, h}));
endmodule

//-----------------------------------------------------------------------------
// Procedural window content.  cx/cy are content-local (border/title removed).
// The animation phase is broadcast in the state packet, so both nodes draw
// identical content for the same frame.
//-----------------------------------------------------------------------------
module wall_paint (
    input  wire [3:0]  src,
    input  wire [9:0]  cx,
    input  wire [9:0]  cy,
    input  wire [9:0]  cw,
    input  wire [9:0]  ch,
    input  wire [4:0]  anim,
    output reg  [23:0] rgb
);
    localparam [23:0] C_BARS0  = 24'hEBEBEB;
    localparam [23:0] C_BARS1  = 24'hEBD228;
    localparam [23:0] C_BARS2  = 24'h28D2D2;
    localparam [23:0] C_BARS3  = 24'h28C83C;
    localparam [23:0] C_BARS4  = 24'hDC3CBE;
    localparam [23:0] C_CHK0   = 24'h2A2E38;
    localparam [23:0] C_CHK1   = 24'h3A4050;
    localparam [23:0] C_STRIPE = 24'h8FA0B8;
    localparam [23:0] C_WHITE  = 24'hFFFFFF;
    localparam [23:0] C_GREEN  = 24'h3CDC78;
    localparam [23:0] C_NAVY   = 24'h0A0E12;
    localparam [23:0] C_SCAN   = 24'h46505F;

    wire [23:0] bars_sel = (cx[8:6] == 3'd0) ? C_BARS0 :
                           (cx[8:6] == 3'd1) ? C_BARS1 :
                           (cx[8:6] == 3'd2) ? C_BARS2 :
                           (cx[8:6] == 3'd3) ? C_BARS3 : C_BARS4;

    wire [9:0]  stripe_phase = cx + cy + {anim, 3'b000};
    wire        stripe_on    = (stripe_phase[5:0] < 6'd3);

    // src 2: horizontal gradient (x2 shift, no divider) + 45-degree marker
    wire signed [11:0] g_diag = $signed({2'b00, cx}) - $signed({1'b0, cy, 1'b0});
    wire        diag_on = (g_diag < 12'sd3) && (g_diag > -12'sd3);

    // src 3: nav display, centre crosshair + square range ring
    wire signed [11:0] ndx = $signed({2'b00, cx}) - $signed({2'b00, cw[9:1]});
    wire signed [11:0] ndy = $signed({2'b00, cy}) - $signed({2'b00, ch[9:1]});
    wire [9:0] nav_r = (cw < ch) ? (cw >> 2) : (ch >> 2);
    wire [9:0] adx = ndx[11] ? (~ndx[9:0] + 10'd1) : ndx[9:0];
    wire [9:0] ady = ndy[11] ? (~ndy[9:0] + 10'd1) : ndy[9:0];
    wire nav_cross = (adx < 10'd1) || (ady < 10'd1);
    wire nav_ring  = ((adx + 10'd2 >= nav_r) && (adx <= nav_r)) ||
                     ((ady + 10'd2 >= nav_r) && (ady <= nav_r));

    // Repeating scan highlight (same phase on both nodes).
    wire [9:0] scan_phase = cy + {anim, 3'b000};
    wire       scan_on    = (scan_phase[5:0] < 6'd2);

    always @(*) begin
        case (src[1:0])
            2'd0:    rgb = bars_sel;
            2'd1:    rgb = stripe_on ? C_STRIPE :
                            (((cx[4] ^ cy[4]) == 1'b0) ? C_CHK0 : C_CHK1);
            2'd2:    rgb = diag_on ? C_WHITE : {cx[6:0], 1'b0, cy[6:0], 1'b0, 8'h80};
            default: rgb = (nav_cross || nav_ring) ? C_GREEN : C_NAVY;
        endcase
        if (scan_on) rgb = C_SCAN;
    end
endmodule

//-----------------------------------------------------------------------------
// 8x8 text box renderer: 2 px dark padding around the glyph area.
//-----------------------------------------------------------------------------
module wall_textbox #(
    parameter integer X0  = 8,
    parameter integer Y0  = 8,
    parameter integer LEN = 8
)(
    input  wire [10:0] x,
    input  wire [8:0] y,
    input  wire [LEN*6-1:0] chars,
    output wire       hit,
    output wire [5:0] ch,
    output wire [2:0] row,
    output wire [2:0] col
);
    localparam integer W = LEN * 8;

    wire in_box  = (x >= X0 - 2) && (x < X0 + W + 2) &&
                   (y >= Y0 - 2) && (y < Y0 + 10);
    wire in_text = (x >= X0) && (x < X0 + W) &&
                   (y >= Y0) && (y < Y0 + 8);
    wire [3:0] ci = (x[10:0] - X0[10:0]) >> 3;

    assign hit = in_box;
    assign ch  = in_text ? chars[((LEN-1) - ci)*6 +: 6] : 6'd0;
    assign row = y[2:0];
    assign col = (x[10:0] - X0[10:0]) & 3'b111;
endmodule


//-----------------------------------------------------------------------------
// Scene: desktop background + z-sorted windows + HUD.
//-----------------------------------------------------------------------------
module wall_scene #(
    parameter integer NODE_X0 = 0,
    parameter integer HUD_EN  = 1,
    parameter integer DITHER_EN = 1,   // 0 = TB reference model without dither
    parameter integer NODE_ID = 0
)(
    input  wire         clk,         // pixel clock: final RGB pipeline stage
    input  wire [10:0]  x,
    input  wire         de,          // 0 while blanking: address priming
    input  wire [8:0]   y,
    input  wire [255:0] tbl,
    input  wire [71:0]  zstep,        // 4 x Q16 uniform step (wall_zoom_calc)
    input  wire [47:0]  zdw,          // 4 x drawn width  in pixels
    input  wire [47:0]  zdh,          // 4 x drawn height in pixels
    input  wire [2:0]   mode_sw,      // {sw3, sw2, sw1} for the OSD captions
    input  wire         osd_en,       // static captions on/off
    input  wire         mute,         // audio muted
    input  wire         music_ok,     // card MUSIC.WAV loaded
    input  wire [20:0]  music_frames,
    input  wire [7:0]   ld_err,       // loader error code
    input  wire [7:0]   time_min,     // wall clock, 0..99 (node A counts it)
    input  wire [7:0]   time_sec,     // wall clock, 0..59
    input  wire         car_auto,     // carousel auto-advance is on
    // W3.5: per-picture brightness/contrast + the picture the HUD reports
    input  wire [1:0]   car_cyc,      // window w shows picture (w + car_cyc)
    input  wire         m_on,         // C10: bottom marquee enabled (false in album)
    input  wire [8:0]   m_phase,      // C10: shared 9-bit scroll phase
    input  wire [63:0]  bc_tbl,       // 4 x {brightness[7:0], contrast[7:0]}
    input  wire         adj_on,       // the operator is in ADJUST mode
    input  wire         frame,        // sof: rebuild the gain/offset table
    input  wire [7:0]   wav_base,     // audio scope: oldest ring entry
    output wire [7:0]   wav_addr,     // audio scope: sample for this column
    input  wire [7:0]   wav_data,
    input  wire [7:0]   aud_level,  // |sample| of the local audio source
    input  wire         meter_en,   // draw the level meter at all (node A only)
    input  wire         show_music, // draw the MUSIC caption line (node A only)
    input  wire [4:0]   anim,
    input  wire [1:0]   sel,
    input  wire         link_ok,
    input  wire         sync_ok,
    input  wire         frozen,
    input  wire         blink,
    input  wire [15:0]  pic_rgb565,   // wall_pic_line data (1 cycle old)
    // Carousel fade-to-black: 256-scale gain, 255 = full, 0 = black.  Applied
    // per channel on the EXPANDED RGB888 -- this is the version verified on the
    // boards.  (Dimming the RGB565 word before expansion is cheaper but tints
    // the picture green/blue, so it is not used.)
    input  wire [7:0]   fade_gain,
    output wire [2:0]   lb_rd_win,    // {frameless, window}: whose buffer is read
    output wire [9:0]   lb_rd_col,    // column for the NEXT pixel (0..191 / 0..639)
    input  wire [4:0]   pic_valid,    // per-window: picture loaded in SDRAM (bit 4 = 640x480 copy)
    // C5: global mode-transition level, 0 = black .. 16 = passthrough.
    // Driven by wall_album_seq (16 frames out, 16 frames in = 533 ms).
    input  wire [4:0]   tlevel,
    output wire [23:0]  rgb
);
    localparam [23:0] C_BG      = 24'h10141C;
    localparam [23:0] C_GRID    = 24'h1C2430;
    localparam [23:0] C_GRIDMAJ = 24'h283444;
    localparam [23:0] C_TITLE   = 24'h202838;
    localparam [23:0] C_OWN_A   = 24'h33D6FF;
    localparam [23:0] C_OWN_B   = 24'hFF9A3C;
    localparam [23:0] C_SEL     = 24'hFFFFFF;
    localparam [23:0] C_DRAG    = 24'hFFC020;   // amber: selected AND being dragged

    wire [11:0] wx = NODE_X0[11:0] + {1'b0, x};

    // Album mode is a whole-screen state, not a per-pixel one: bit 58 of any
    // record means the album sequencer has taken the table over, so the HUD and
    // the audio meter must get out of the way of the photograph.
    wire album_now = tbl[58] | tbl[122] | tbl[186] | tbl[250];

    wire h0, h1, h2, h3;
    wire [1:0] z0, z1, z2, z3;
    wire [11:0] lx0, lx1, lx2, lx3, ly0, ly1, ly2, ly3;
    wire [9:0] w0, w1, w2, w3, hh0, hh1, hh2, hh3;
    wire [3:0] s0, s1, s2, s3;
    wire o0, o1, o2, o3;
    wire [2:0] f0, f1, f2, f3;
    wire [3:0] i0, i1, i2, i3;
    wire fw0, fw1, fw2, fw3;

    wall_window_eval e0 (tbl[63:0],    wx, {3'b000, y}, h0, z0, lx0, ly0, w0, hh0, s0, o0, f0, i0, fw0);
    wall_window_eval e1 (tbl[127:64],  wx, {3'b000, y}, h1, z1, lx1, ly1, w1, hh1, s1, o1, f1, i1, fw1);
    wall_window_eval e2 (tbl[191:128], wx, {3'b000, y}, h2, z2, lx2, ly2, w2, hh2, s2, o2, f2, i2, fw2);
    wall_window_eval e3 (tbl[255:192], wx, {3'b000, y}, h3, z3, lx3, ly3, w3, hh3, s3, o3, f3, i3, fw3);

    // Highest z wins; equal z keeps the lower window id (stable, order-free).
    reg        any_win;
    reg [1:0]  zsel;
    reg [1:0]  best_z;
    always @(*) begin
        any_win = h0;
        zsel    = 2'd0;
        best_z  = z0;
        if (h1 && (!any_win || (z1 >= best_z))) begin
            any_win = 1'b1; zsel = 2'd1; best_z = z1;
        end
        if (h2 && (!any_win || (z2 >= best_z))) begin
            any_win = 1'b1; zsel = 2'd2; best_z = z2;
        end
        if (h3 && (!any_win || (z3 >= best_z))) begin
            any_win = 1'b1; zsel = 2'd3; best_z = z3;
        end
    end

    reg [11:0] lx, ly;
    reg [9:0]  ww, wh;
    reg [3:0]  src;
    reg        owner;
    reg [2:0]  flags;
    reg [3:0]  id;
    reg        fw;            // frameless: whole-world, 640x480 source, no chrome
    always @(*) begin
        case (zsel)
            2'd0: begin lx=lx0; ly=ly0; ww=w0; wh=hh0; src=s0; owner=o0; flags=f0; id=i0; fw=fw0; end
            2'd1: begin lx=lx1; ly=ly1; ww=w1; wh=hh1; src=s1; owner=o1; flags=f1; id=i1; fw=fw1; end
            2'd2: begin lx=lx2; ly=ly2; ww=w2; wh=hh2; src=s2; owner=o2; flags=f2; id=i2; fw=fw2; end
            default: begin lx=lx3; ly=ly3; ww=w3; wh=hh3; src=s3; owner=o3; flags=f3; id=i3; fw=fw3; end
        endcase
    end

    // Selection is a global field (broadcast in every STATE frame), not a
    // per-record flag: the highlight must follow KEY1 on both nodes at once.
    wire selected = (id == sel);

    // A frameless window is the whole 1280x480 world with no border and no
    // title, so its content area is the full screen and the 640x480 source lands
    // centred with 320 px of black on each side -- exactly 1 source pixel per
    // screen pixel (wall_zoom_calc hands it a 640/480-based step of 65536).
    localparam [11:0] WORLD_W12 = 12'd1280;
    localparam [11:0] WORLD_H12 = 12'd480;

    wire [11:0] ww12 = fw ? WORLD_W12 : {2'b00, ww};
    wire [11:0] wh12 = fw ? WORLD_H12 : {2'b00, wh};
    wire border = !fw && ((lx < 12'd2) || (lx >= ww12 - 12'd2) ||
                          (ly < 12'd2) || (ly >= wh12 - 12'd2));
    wire title  = !fw && (ly < 12'd14);
    wire [11:0] clx = fw ? lx : (lx - 12'd2);
    wire [11:0] cly = fw ? ly : (ly - 12'd16);
    wire [11:0] cw  = fw ? WORLD_W12 : (ww12 - 12'd4);
    wire [11:0] chh = fw ? WORLD_H12 : (wh12 - 12'd16);

    // KEY2 (drag mode) used to be invisible: it only set a table flag.  While
    // dragging, the border now blinks white/amber at ~7 Hz on BOTH screens.
    wire sel_drag = selected && flags[1];
    wire [23:0] sel_col = sel_drag ? (blink ? C_SEL : C_DRAG) : C_SEL;
    wire [23:0] border_rgb = selected ? sel_col : (owner ? C_OWN_B : C_OWN_A);
    // Title bar badge: the window number (1..4) rendered from the same font, so
    // every picture is numbered on screen; the selected one is drawn bright.
    wire [5:0] badge_ch  = 6'd2 + {4'b0000, id};   // '1'..'4' in wall_font_rom
    wire [7:0] badge_bits;
    wall_font_rom u_badge (.ch(badge_ch), .row(ly[2:0]), .bits(badge_bits));
    wire badge_on = (lx < 12'd8) && (ly < 12'd8) && badge_bits[3'd7 - lx[2:0]];
    wire badge_sel = (id == sel);
    wire [23:0] badge_col = badge_sel ? C_SEL : (owner ? C_OWN_B : C_OWN_A);
    wire [23:0] title_rgb = (lx < 12'd8) ? (badge_on ? badge_col : C_TITLE)
                                        : C_TITLE;

    // Window content comes from the SDRAM picture library through the line
    // buffer (wall_pic_line).  The buffer holds one 288-wide source row per
    // window, so the read address is {top window, source column}; the source
    // ROW is chosen by the prefetch and is not on this per-pixel path.
    // The column is presented one pixel ahead (x+1) because the line buffer
    // output is registered, exactly like the old picture BRAM.
    // wall_zoom_calc still gives one Q16 step for both axes plus the drawn
    // size, so the picture keeps its 4:3 shape: it is centred in the content
    // area and the spare axis is filled with black.  The 288-wide source is
    // exactly 3x the 96-wide source, so the sampled column is 3x the 96-based
    // column -- dw/dh and the letterbox are unchanged.
    // id*18 / id*12: plain constant multiplies are unambiguous; the
    // concatenation form ({id,4'b0} + {id,1'b0}) mis-sliced in ModelSim.
    wire [17:0] zst = zstep[id[1:0] * 18 +: 18];
    wire [11:0] zdw_w = zdw[id[1:0] * 12 +: 12];
    wire [11:0] zdh_w = zdh[id[1:0] * 12 +: 12];
    wire [11:0] cw12  = cw;
    wire [11:0] chh12 = chh;
    wire [11:0] ox    = (cw12  > zdw_w) ? ((cw12  - zdw_w) >> 1) : 12'd0;
    wire [11:0] oy    = (chh12 > zdh_w) ? ((chh12 - zdh_w) >> 1) : 12'd0;
    wire [11:0] px    = (clx >= ox) ? (clx - ox) : 12'd0;
    wire [11:0] py    = (cly >= oy) ? (cly - oy) : 12'd0;
    wire        in_pic = (clx >= ox) && (clx < ox + zdw_w) &&
                         (cly >= oy) && (cly < oy + zdh_w);
    // +1 only during active pixels: the line buffer output is registered, so
    // the address presented while composing column x must already be the
    // sample for column x+1.  Everything is derived from the NEXT column.
    // (x here is the column being composed, which wall_top drives one ahead of
    // the raster counter -- see the pipeline note at the top of this file.  The
    // rule itself is unchanged: it is still x+1, not x+2.)
    wire [11:0] cx_n = de ? (clx + 12'd1) : clx;
    wire [11:0] px_n = (cx_n >= ox) ? (cx_n - ox) : 12'd0;
    // Scale BEFORE the multiply.  zst is the 96/72-based Q16 step, so it maps a
    // drawn pixel to 0..95; multiplying its RESULT by 2/3 only renames that
    // 96-wide grid (the first hires build looked exactly as soft as the old
    // 96x72 one for that reason).  (2*px_n) x zst >> 16 is the true 192-column
    // coordinate, and 2*px_n still fits the 18x18 multiplier.
    // NOTE: this MUST be a plain x<<1.  An earlier version used
    // ({1'b0,px_n} + ({1'b0,px_n} << 1)), which is 3*px_n: the source column
    // then ran 0..287, saturated at the 191 clamp two thirds of the way across
    // the window, and the right of every picture came out stretched.
    // C3: the frameless window's source is already 640 wide and its step is
    // 640-based, so it needs NO doubling -- (px * step) >> 16 is the source
    // column directly, and at the 1280x480 album geometry step = 65536 makes it
    // exactly px (one source pixel per screen pixel).
    wire [12:0] px2   = fw ? {1'b0, px_n} : ({1'b0, px_n} << 1);
    wire [30:0] icx2  = px2 * zst;
    wire [14:0] sxraw = icx2[30:16];
    wire [9:0]  sxlim = fw ? 10'd639 : 10'd191;
    wire [9:0]  sx3   = (sxraw > {5'd0, sxlim}) ? sxlim : sxraw[9:0];
    assign lb_rd_win = {fw, id[1:0]};
    assign lb_rd_col = sx3;

    // Procedural content: the fallback while a window holds no picture yet (no
    // card, or the loader has not reached that window).
    wire [23:0] content_rgb;
    wall_paint u_paint (
        .src(src), .cx(clx[9:0]), .cy(cly[9:0]),
        .cw(cw[9:0]), .ch(chh[9:0]), .anim(anim), .rgb(content_rgb)
    );

    // ---- per-picture brightness / contrast (combined with the fade) --------
    // The gain/offset table is rebuilt once per frame by wall_picadj, which
    // folds the carousel fade into it (see that module for the arithmetic).
    // A window shows picture (wid + car_cyc) -- exactly what wall_pic_line
    // fetches -- so the adjustment index is the same expression.
    wire [39:0] pic_gain, pic_off;
    wall_picadj u_picadj (
        .clk(clk), .rst(1'b0), .frame(frame),
        .tbl(bc_tbl), .fade(fade_gain), .gain(pic_gain), .off(pic_off));

    wire [1:0]  pic_idx = fw ? 2'd0 : (id[1:0] + car_cyc);
    wire [9:0]  adj_g   = pic_gain[pic_idx*10 +: 10];
    wire [9:0]  adj_o   = pic_off [pic_idx*10 +: 10];

    // RGB565 -> RGB888 by bit replication, then brightness/contrast/fade.
    wire [15:0] pr = pic_rgb565;
    wire [23:0] pic_rgb = {pr[15:11], pr[15:13],
                           pr[10:5],  pr[10:9],
                           pr[4:0],   pr[4:2]};
    wire [23:0] pic_rgb_f;
    wall_adj8 u_adj_r (.in(pic_rgb[23:16]), .gain(adj_g), .off(adj_o), .out(pic_rgb_f[23:16]));
    wall_adj8 u_adj_g (.in(pic_rgb[15:8]),  .gain(adj_g), .off(adj_o), .out(pic_rgb_f[15:8]));
    wall_adj8 u_adj_b (.in(pic_rgb[7:0]),   .gain(adj_g), .off(adj_o), .out(pic_rgb_f[7:0]));

    // ---- 4x4 ordered dither on the expanded picture ----------------------
    // The source is RGB565, so each channel only has 32/64 real levels; the bit
    // replication above turns every step into a flat 8-code band, and a contrast
    // boost makes those bands obvious.  Adding a 4x4 Bayer value in the low 3
    // bits spreads each step edge into a fine pattern instead of a hard line.
    // The amplitude is one 565 step (8 of 255, ~3%), so it reads as a little
    // film grain rather than noise.  Applied AFTER gain/offset on purpose:
    // dithering before it would be multiplied by the contrast setting.
    reg [2:0] dith;
    always @(*) begin
        case ({y[1:0], x[1:0]})            // Bayer 4x4, (matrix value) >> 1
            4'h0: dith = 3'd0;  4'h1: dith = 3'd4;  4'h2: dith = 3'd1;  4'h3: dith = 3'd5;
            4'h4: dith = 3'd6;  4'h5: dith = 3'd2;  4'h6: dith = 3'd7;  4'h7: dith = 3'd3;
            4'h8: dith = 3'd1;  4'h9: dith = 3'd5;  4'ha: dith = 3'd0;  4'hb: dith = 3'd4;
            4'hc: dith = 3'd7;  4'hd: dith = 3'd3;  4'he: dith = 3'd6;
            default: dith = 3'd2;
        endcase
    end

    function [7:0] dadd;                   // saturating v + dither
        input [7:0] v;
        input [2:0] d;
        reg [8:0] s;
        begin
            s    = {1'b0, v} + {6'd0, d};
            dadd = s[8] ? 8'hFF : s[7:0];
        end
    endfunction

    wire [2:0]  dith_use = (DITHER_EN != 0) ? dith : 3'd0;
    wire [23:0] pic_rgb_d = {dadd(pic_rgb_f[23:16], dith_use),
                             dadd(pic_rgb_f[15:8],  dith_use),
                             dadd(pic_rgb_f[7:0],   dith_use)};

    // Values for the HUD status line: the picture shown in the selected window.
    // The album picture never rotates, so the frameless window is always slot 0.
    wire [1:0] sel_pic = sel + car_cyc;
    wire [7:0] sel_brt = bc_tbl[{sel_pic, 4'b0000} +: 8];
    wire [7:0] sel_con = bc_tbl[{sel_pic, 4'b0000} + 8 +: 8];

    // Outside the drawn picture rect the content area is black (letterbox);
    // a window with no photo yet still shows the procedural pattern.  The
    // frameless window reads pic_valid[4] -- the 640x480 copy, not a thumbnail.
    wire        pic_ok = fw ? pic_valid[4] : pic_valid[id[1:0]];
    wire [23:0] content_pick = pic_ok ? (in_pic ? pic_rgb_d : 24'h000000)
                                      : content_rgb;

    wire in_content = !border && !title && (clx < cw) && (cly < chh);
    wire [23:0] win_rgb = border ? border_rgb :
                          title  ? title_rgb  :
                          in_content ? content_pick : C_TITLE;

    // Desktop background: pure function of world coordinates.
    wire bg_major = (wx[6:0] == 7'd0) || (y[6:0] == 7'd0);
    wire bg_minor = (wx[4:0] == 5'd0) || (y[4:0] == 5'd0);
    wire [23:0] bg_rgb = bg_major ? C_GRIDMAJ : (bg_minor ? C_GRID : C_BG);

    wire [23:0] base_rgb = any_win ? win_rgb : bg_rgb;

    // Selected window drives the HUD readout (gx straight from the record).
    reg [11:0] sel_gx;
    reg        sel_owner;
    always @(*) begin
        sel_gx    = 12'd0;
        sel_owner = 1'b0;
        if (i0 == sel)      begin sel_gx = tbl[11:0];    sel_owner = o0; end
        else if (i1 == sel) begin sel_gx = tbl[75:64];   sel_owner = o1; end
        else if (i2 == sel) begin sel_gx = tbl[139:128]; sel_owner = o2; end
        else if (i3 == sel) begin sel_gx = tbl[203:192]; sel_owner = o3; end
    end

    wire        hud_hit;
    wire [23:0] hud_rgb;

    generate
        if (HUD_EN != 0) begin : g_hud
            // the sel-th record carries the operator-confirmed bit (flags[1])
    wire sel_locked = tbl[{sel,6'b000000} + 6'd52];

    wall_hud #(.NODE_ID(NODE_ID)) u_hud (
                .x(x), .y(y),
                .sel(sel),
                .owner(sel_owner),
                .gx_sel(sel_gx),
                .link_ok(link_ok), .sync_ok(sync_ok), .frozen(frozen), .dragging(sel_drag),
                .mode_sw(mode_sw), .en(osd_en && !album_now), .mute(mute), .music_ok(music_ok), .aud_level(aud_level), .show_music(show_music),
        .music_frames(music_frames), .ld_err(ld_err), .locked(sel_locked),
        .time_min(time_min), .time_sec(time_sec), .car_auto(car_auto),
        .brt_sel(sel_brt), .con_sel(sel_con), .adj_on(adj_on), .m_on(m_on && !album_now), .m_phase(m_phase), .wx(wx),
                .hit(hud_hit), .rgb(hud_rgb)
            );
        end else begin : g_nohud
            assign hud_hit = 1'b0;
            assign hud_rgb = 24'h000000;
        end
    endgenerate

    // ---- audio level meter: a long box to the right of "GX hhh" ------------
    // Same height as that text line (12 px), 240 px wide, drawn on top of the
    // windows like the HUD.  It used to show a waveform, but the source is
    // either a slow pad (synth) or music the sink attenuates, so a level meter
    // is what actually reads as "moving with the sound".
    localparam [11:0] SC_X0 = 12'd68, SC_X1 = 12'd308;
    localparam [11:0] SC_Y0 = 12'd454, SC_Y1 = 12'd466;

    // Album mode owns the whole screen, so the meter must not paint over the
    // photograph (it sits at y 454..466, right across the bottom of it).
    // The level meter is part of the UI, so KEY2 (VIEW mode) hides it too.
    wire in_scope  = (HUD_EN != 0) && meter_en && !album_now && osd_en &&
                     (x >= SC_X0) && (x < SC_X1) &&
                     (y >= SC_Y0) && (y < SC_Y1);
    wire sc_border = in_scope && ((x == SC_X0) || (x == SC_X1 - 12'd1) ||
                                  (y == SC_Y0) || (y == SC_Y1 - 12'd1));
    wire [7:0]  sc_col = x[7:0] - SC_X0[7:0];
    // The card audio only occupies the bottom few counts of the top byte, so
    // the meter needs a big display gain: >>3 means level 8 already fills the
    // bar, which makes the movement obvious without touching the volume.
    wire [15:0] sc_fill16 = ({8'd0, aud_level} * 16'd236) >> 3;
    wire [7:0]  sc_fill  = (sc_fill16 > 16'd236) ? 8'd236 : sc_fill16[7:0];
    wire        sc_bar   = in_scope && !sc_border && (sc_col < sc_fill);
    // a faint tick every 24 columns keeps the box readable when quiet
    wire        sc_tick  = in_scope && !sc_border && (sc_col[4:0] == 5'd0) && (sc_col < 8'd236);

    localparam [23:0] C_SCOPE_BG     = 24'h04121A;
    localparam [23:0] C_SCOPE_BORDER = 24'h2A6E86;
    localparam [23:0] C_SCOPE_BAR    = 24'h5CFFC4;
    localparam [23:0] C_SCOPE_TICK   = 24'h17323C;

    assign wav_addr = wav_base + sc_col;

    wire [23:0] scope_rgb = sc_border ? C_SCOPE_BORDER :
                            sc_bar    ? C_SCOPE_BAR    :
                            sc_tick   ? C_SCOPE_TICK   : C_SCOPE_BG;

    wire [23:0] rgb_c = hud_hit ? hud_rgb : (in_scope ? scope_rgb : base_rgb);

    // ---- mode-transition fade (C5) ----------------------------------------
    // One global 0..256 dimmer applied to the FINAL composite, so the desktop
    // grid, the window borders/titles, the pictures and the HUD all fade
    // together -- that is what makes enter/leave album mode look like one
     // transition instead of a hard cut.  Level 16 is EXACT passthrough
    // ((c*16)>>4 == c), so every pixel-exact testbench can keep tlevel at 16
    // and compare against the un-dimmed reference.
    // This is a real multiply, not a shift chain: the ramp is in 16 steps of a
    // 256-wide scale, and masking off low bits would step visibly.
    //
    // WHERE it sits matters.  Putting the multiply in front of the output
    // register (rgb_c -> mul -> rgb_r) drove node A's 25 MHz domain to
    // SWNS -0.263 ns: that x -> window eval -> z pick -> content/HUD cone had
    // only +0.24 ns to spare and the multipliers ate all of it.  So the dimmer
    // is a COMBINATIONAL TAIL on the already-registered rgb_r instead: the
    // 8x9 multiplies now sit in the rgb_r -> wall_top/AXIS-register path, which
    // has a whole 40 ns period, and the picture latency is unchanged (still
    // exactly one clock), which is what keeps the x+1 compensation and every
    // pixel-exact testbench valid.
    reg [23:0] rgb_r;

    // 8x5 multiply: level is 0..16, so c*level is 12 bits and >>4 gives the
    // dimmed 8-bit channel back exactly (level 16 -> identity).  An 8x9
    // multiply using {level,4'b0000} was 60% bigger for the same 17 levels.
    wire [12:0] tf_r = rgb_r[23:16] * tlevel;
    wire [12:0] tf_g = rgb_r[15:8]  * tlevel;
    wire [12:0] tf_b = rgb_r[7:0]   * tlevel;

    // ---- output pipeline stage (W3 step 1) --------------------------------
    // Everything above is the same combinational cone as before; only the last
    // 24-bit mux is now captured on the pixel clock.  When the compositor is
    // instantiated with a visible window, the cone x -> window eval -> z pick
    // -> content/HUD -> rgb was the tail of a 25 MHz path sitting in front of
    // wall_top's AXIS register.  Registering here splits that path in two.
    // (rgb_r itself is declared above, because the transition dimmer taps it.)
    always @(posedge clk) rgb_r <= rgb_c;
    assign rgb = {tf_r[11:4], tf_g[11:4], tf_b[11:4]};
endmodule
