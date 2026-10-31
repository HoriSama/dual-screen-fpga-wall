//-----------------------------------------------------------------------------
// HUD: fixed text lines.  SEL / OWN / GX / LINK / SYNC are dynamic, and the
// operator-state captions (SW1/SW2/SW3 ON-OFF and the picked picture) were
// added when the console grew a mode switch -- they are the on-screen
// subtitles for "what does the board think the switches are doing".
//
// W3 added two 12-char status lines under that block (Y0 = 120 and 136):
//   "  CAR AUTO  " / "  CAR STOP  "  -- carousel auto-advance state (both nodes)
//   "TIME mm ss"                     -- wall clock since power-on (node A only)
//-----------------------------------------------------------------------------
module wall_hud #(
    parameter integer NODE_ID = 0
)(
    input  wire [10:0] x,
    input  wire [8:0]  y,
    input  wire [1:0]  sel,
    input  wire        owner,
    input  wire [11:0] gx_sel,
    input  wire        link_ok,
    input  wire        sync_ok,
    input  wire        frozen,
    input  wire        dragging,
    input  wire [2:0]  mode_sw,        // {sw3, sw2, sw1}
    input  wire        locked,         // the sel-th record carries the lock bit
    input  wire        en,            // static captions on/off (KEY3 in VIEW)
    input  wire        mute,          // audio muted (KEY4 in VIEW)
    input  wire        music_ok,      // card MUSIC.WAV loaded into SDRAM
    input  wire [7:0]  aud_level,    // live audio level (diagnostic)
    input  wire        show_music,   // show the MUSIC caption line
    input  wire [20:0] music_frames,  // stereo frames loaded (0 = none)
    input  wire [7:0]  ld_err,        // wall_tf_load error code
    // W3: wall clock (node A) and the carousel auto-advance flag
    input  wire [7:0]  time_min,      // 0..99, wraps
    input  wire [7:0]  time_sec,      // 0..59
    input  wire        car_auto,      // carousel: auto-advance is on
    // W3.5: brightness/contrast of the picture in the selected window
    input  wire [7:0]  brt_sel,
    input  wire [7:0]  con_sel,
    input  wire        adj_on,        // operator is in ADJUST mode (SW4 up)
    // C10: bottom scrolling notice board.  It scrolls on the WORLD grid, so it
    // needs wx (0..1279), not x (this node's local 0..639 slice): feeding it the
    // local x makes each node start its text at 0, i.e. two independent copies
    // instead of one line crossing the seam.
    input  wire [11:0] wx,           // C10: world x
    input  wire        m_on,         // C10: marquee enabled (gated by !album upstream)
    input  wire [8:0]  m_phase,      // C10: shared 9-bit scroll phase
    output wire        hit,
    output wire [23:0] rgb
);
    localparam [5:0] CH_SP = 6'd0,  CH_0 = 6'd1;
    localparam [5:0] CH_1  = 6'd2,  CH_2 = 6'd3,  CH_3 = 6'd4;
    localparam [5:0] CH_A  = 6'd11, CH_B = 6'd12, CH_C = 6'd13;
    localparam [5:0] CH_D  = 6'd14, CH_E = 6'd15, CH_F = 6'd16;
    localparam [5:0] CH_G  = 6'd17, CH_H = 6'd18, CH_I = 6'd19, CH_J = 6'd20, CH_K = 6'd21;
    localparam [5:0] CH_L  = 6'd22, CH_N = 6'd24, CH_O = 6'd25;
    localparam [5:0] CH_P  = 6'd26, CH_R = 6'd28, CH_S = 6'd29;
    localparam [5:0] CH_M  = 6'd23, CH_T = 6'd30, CH_U = 6'd31, CH_W = 6'd33;
    localparam [5:0] CH_X  = 6'd34, CH_Y = 6'd35;
    localparam [5:0] CH_Z  = 6'd36;

    localparam [23:0] C_BOX   = 24'h080A0E;
    localparam [23:0] C_TEXT  = 24'hE2ECFA;
    localparam [23:0] C_DIM   = 24'h8C98AA;
    localparam [23:0] C_ALERT = 24'hFF5A5A;
    localparam [23:0] C_OWN_A = 24'h33D6FF;
    localparam [23:0] C_OWN_B = 24'hFF9A3C;
    localparam [23:0] C_ON    = 24'h7CFF9E;
    localparam [23:0] C_TRACK = 24'h1A2230;   // unfilled part of a level bar
    localparam [23:0] C_BAR_C = 24'hFFD166;   // contrast bar, so the two differ at a glance

    function [5:0] hexch;
        input [3:0] d;
        begin
            hexch = (d < 4'd10) ? (CH_0 + {2'b00, d}) : (CH_A + {2'b00, d} - 6'd10);
        end
    endfunction

    // "WALL A" / "WALL B"
    wire [5:0] nd = (NODE_ID == 0) ? CH_A : CH_B;
    wire [6*6-1:0] v0 = {CH_W, CH_A, CH_L, CH_L, CH_SP, nd};

    // "SEL n OWN x" (11 chars)
    wire [5:0] sel_ch = CH_0 + {4'b0000, sel};
    wire [5:0] own_ch = owner ? CH_B : CH_A;
    wire [11*6-1:0] v1 = {CH_S, CH_E, CH_L, CH_SP, sel_ch, CH_SP,
                          CH_O, CH_W, CH_N, CH_SP, own_ch};

    // "GX hhh" (6 chars, 12-bit gx)
    wire [6*6-1:0] v2 = {CH_G, CH_X, CH_SP,
                         hexch(gx_sel[11:8]), hexch(gx_sel[7:4]), hexch(gx_sel[3:0])};

    // "LINK OK  " / "LINK LOST" (9 chars)
    wire [9*6-1:0] v3 = link_ok ?
        {CH_L, CH_I, CH_N, CH_K, CH_SP, CH_O, CH_K, CH_SP, CH_SP} :
        {CH_L, CH_I, CH_N, CH_K, CH_SP, CH_L, CH_O, CH_S, CH_T};

    // bottom-right: DRAG while a drag is active, else the genlock state
    wire [9*6-1:0] v4 = dragging ?
        {CH_D, CH_R, CH_A, CH_G, CH_SP, CH_SP, CH_SP, CH_SP, CH_SP} :
        (sync_ok ?
        {CH_S, CH_Y, CH_N, CH_C, CH_SP, CH_O, CH_K, CH_SP, CH_SP} :
        {CH_N, CH_O, CH_SP, CH_S, CH_Y, CH_N, CH_C, CH_SP, CH_SP});

    // 'FROZEN' only exists while the link is lost.
    wire [6*6-1:0] v5 = {CH_F, CH_R, CH_O, CH_Z, CH_E, CH_N};

    // ---- which MODE is active ---------------------------------------------
    // The switches are not independent: exactly one mode is in force at a
    // time, and the caption shows THAT mode as ON.
    //   SW1 down                -> VIEW   (keys ignored)
    //   SW1 up, SW2 up, locked  -> MOVE   (SW2 wins over SW3)
    //   SW1 up, SW3 up, locked  -> ZOOM
    //   otherwise               -> SELECT (pick / confirm / depth)
    wire m_view   = !mode_sw[0];
    // C7: the captions must follow the NEW decode -- MOVE needs SW2 alone (SW3 down),
    // ZOOM needs SW3 alone, and SW2+SW3 together is the BRIGHTNESS/CONTR overlay
    // (that one is not in mode_sw, it arrives as adj_on from the master).
    wire m_adj    = m_view ? 1'b0 : adj_on;
    wire m_move   = mode_sw[0] && mode_sw[1] && !mode_sw[2] && locked && !m_adj;
    wire m_zoom   = mode_sw[0] && !mode_sw[1] && mode_sw[2] && locked && !m_adj;
    wire m_select = !m_view && !m_move && !m_zoom && !m_adj;

    localparam [5:0] CH_V = 6'd32;

    wire [5*6-1:0] on3  = {CH_O, CH_N, CH_SP};
    wire [5*6-1:0] off3 = {CH_O, CH_F, CH_F};

    wire [12*6-1:0] v6 = {CH_SP, CH_SP, CH_V, CH_I, CH_E, CH_W, CH_SP, CH_SP,
                          m_view   ? on3 : off3, CH_SP};
    // The SELECT line doubles as the ADJUST caption: SW4 up switches the mode
    // without consuming a line of its own (the block is full at y = 24..114).
    wire [12*6-1:0] v7 = {CH_SP, CH_SP,
                          m_adj ? {CH_A, CH_D, CH_J, CH_U, CH_S, CH_T}
                                 : {CH_S, CH_E, CH_L, CH_E, CH_C, CH_T},
                          (m_select | m_adj) ? on3 : off3, CH_SP};
    wire [12*6-1:0] v8 = {CH_SP, CH_SP, CH_M, CH_O, CH_V, CH_E, CH_SP, CH_SP,
                          m_move   ? on3 : off3, CH_SP};
    wire [12*6-1:0] v9 = {CH_SP, CH_SP, CH_Z, CH_O, CH_O, CH_M, CH_SP, CH_SP,
                          m_zoom   ? on3 : off3, CH_SP};
    // "PIC n LOCKED" / "PIC n FREE  " (12 chars)
    wire [5:0] pick_ch = CH_0 + 6'd1 + {4'b0000, sel};      // '1'..'4'
    wire [6*6-1:0] lock_w = {CH_L, CH_O, CH_C, CH_K, CH_E, CH_D};
    wire [6*6-1:0] free_w = {CH_F, CH_R, CH_E, CH_E, CH_SP, CH_SP};
    wire [12*6-1:0] v10 = {CH_SP, CH_SP, CH_P, CH_I, CH_C, CH_SP, pick_ch,
                          locked ? lock_w : free_w};

    // "MUSIC CARD  " when the card file loaded, "MUSIC SYNTH " when the board
    // fell back to the on-chip synth, "MUSIC ERR n " with the loader's code.
    // Deliberately no hex digits: six 4-bit muxes cost ~0.5 ns of the 25 MHz
    // budget on node A (SWNS went negative with them in).
    // MUTE wins over the source caption: KEY1 in VIEW mode, so the operator can
    // still see WHY there is no sound (the caption is hidden with the rest of
    // the UI when KEY2 hides it).
    wire [12*6-1:0] v11 = mute ?
        {CH_M, CH_U, CH_S, CH_I, CH_C, CH_SP, CH_M, CH_U, CH_T, CH_E, CH_SP, CH_SP} :
        music_ok ?
        {CH_M, CH_U, CH_S, CH_I, CH_C, CH_SP, CH_C, CH_A, CH_R, CH_D, CH_SP, CH_SP} :
        (ld_err != 8'd0 ?
        {CH_M, CH_U, CH_S, CH_I, CH_C, CH_SP, CH_E, CH_R, CH_R, CH_SP, CH_SP,
         hexch(ld_err[3:0])} :
        {CH_M, CH_U, CH_S, CH_I, CH_C, CH_SP, CH_S, CH_Y, CH_N, CH_T, CH_H, CH_SP});

    // ---- W3 additions: carousel caption + wall clock -----------------------
    // Both lines sit under the MODE block (last one was Y0 = 104).
    //   CAR  : both nodes.  car_auto is broadcast in the STATE frame now, so the
    //          two halves of the wall caption the same state.
    //   TIME : node A only (B would show its own boot time, which is not the
    //          wall's time; the slot deliberately stays empty there).
    wire show_car  = 1'b1;
    wire show_time = (NODE_ID == 0);

    // "  CAR AUTO  " / "  CAR STOP  " (12 chars)
    wire [12*6-1:0] v12 = {CH_SP, CH_SP, CH_C, CH_A, CH_R, CH_SP,
                           car_auto ? {CH_A, CH_U, CH_T, CH_O}
                                    : {CH_S, CH_T, CH_O, CH_P},
                           CH_SP, CH_SP};

    // "TIME mm ss" (12 chars).  hexch() renders 0..9 as plain digits, and
    // time_min/time_sec arrive as BCD (see wall_top), so each nibble is exactly
    // one decimal digit -- min <= 99 and sec <= 59, no hex letters possible.
    wire [12*6-1:0] v13 = {CH_T, CH_I, CH_M, CH_E, CH_SP,
                           hexch(time_min[7:4]), hexch(time_min[3:0]), CH_SP,
                           hexch(time_sec[7:4]), hexch(time_sec[3:0]),
                           CH_SP, CH_SP};

    // "BRT hh CON hh" (13 chars): brightness/contrast of the picture that the
    // selected window shows.  0x80/0x80 is the neutral setting.
    wire [13*6-1:0] v14 = {CH_B, CH_R, CH_T, CH_SP,
                           hexch(brt_sel[7:4]), hexch(brt_sel[3:0]), CH_SP,
                           CH_C, CH_O, CH_N, CH_SP,
                           hexch(con_sel[7:4]), hexch(con_sel[3:0])};

    wire h0, h1, h2, h3, h4, h5;
    wire [5:0] c0, c1, c2, c3, c4;
    wire [2:0] r0, r1, r2, r3, r4;
    wire [2:0] l0, l1, l2, l3, l4;

    wall_textbox #(.X0(8),   .Y0(8),   .LEN(6))  t0 (
        .x(x), .y(y), .chars(v0), .hit(h0), .ch(c0), .row(r0), .col(l0));
    wall_textbox #(.X0(8),   .Y0(440), .LEN(11)) t1 (
        .x(x), .y(y), .chars(v1), .hit(h1), .ch(c1), .row(r1), .col(l1));
    wall_textbox #(.X0(8),   .Y0(456), .LEN(6))  t2 (
        .x(x), .y(y), .chars(v2), .hit(h2), .ch(c2), .row(r2), .col(l2));
    wall_textbox #(.X0(560), .Y0(440), .LEN(9))  t3 (
        .x(x), .y(y), .chars(v3), .hit(h3), .ch(c3), .row(r3), .col(l3));
    wall_textbox #(.X0(560), .Y0(456), .LEN(9))  t4 (
        .x(x), .y(y), .chars(v4), .hit(h4), .ch(c4), .row(r4), .col(l4));
    wire [5:0] c5; wire [2:0] r5, l5;
    wall_textbox #(.X0(560), .Y0(8), .LEN(6))   t5 (
        .x(x), .y(y), .chars(v5), .hit(h5), .ch(c5), .row(r5), .col(l5));
    wire h5g = h5 & frozen;

    // caption block, top-left under "WALL A"
    // caption block, top-left under "WALL A": five 12-char lines
    wire h6, h7, h8, h9, h10, h11;
    wire [5:0] c6, c7, c8, c9, c10, c11;
    wire [2:0] r6, r7, r8, r9, r10, r11;
    wire [2:0] l6, l7, l8, l9, l10, l11;

    wall_textbox #(.X0(8), .Y0(24), .LEN(12)) t6 (
        .x(x), .y(y), .chars(v6), .hit(h6), .ch(c6), .row(r6), .col(l6));
    wall_textbox #(.X0(8), .Y0(40), .LEN(12)) t7 (
        .x(x), .y(y), .chars(v7), .hit(h7), .ch(c7), .row(r7), .col(l7));
    wall_textbox #(.X0(8), .Y0(56), .LEN(12)) t8 (
        .x(x), .y(y), .chars(v8), .hit(h8), .ch(c8), .row(r8), .col(l8));
    wall_textbox #(.X0(8), .Y0(72), .LEN(12)) t9 (
        .x(x), .y(y), .chars(v9), .hit(h9), .ch(c9), .row(r9), .col(l9));
    wall_textbox #(.X0(8), .Y0(88), .LEN(12)) t10 (
        .x(x), .y(y), .chars(v10), .hit(h10), .ch(c10), .row(r10), .col(l10));

    wall_textbox #(.X0(8), .Y0(104), .LEN(12)) t11 (
        .x(x), .y(y), .chars(v11), .hit(h11), .ch(c11), .row(r11), .col(l11));

    wire h12, h13;
    wire [5:0] c12, c13;
    wire [2:0] r12, r13, l12, l13;

    wall_textbox #(.X0(8), .Y0(120), .LEN(12)) t12 (
        .x(x), .y(y), .chars(v12), .hit(h12), .ch(c12), .row(r12), .col(l12));
    wall_textbox #(.X0(8), .Y0(136), .LEN(12)) t13 (
        .x(x), .y(y), .chars(v13), .hit(h13), .ch(c13), .row(r13), .col(l13));

    wire h14;
    wire [5:0] c14;
    wire [2:0] r14, l14;
    wall_textbox #(.X0(8), .Y0(152), .LEN(13)) t14 (
        .x(x), .y(y), .chars(v14), .hit(h14), .ch(c14), .row(r14), .col(l14));

    // ---- level bars next to BRT/CON --------------------------------------
    // 16 cells of 4 x 10 px on the BRT/CON row, one cell per step of the high
    // nibble, so 0x80 (neutral) lights exactly half the scale.  The keys step by
    // 8, i.e. half a cell; the two hex digits stay the precise read-out.
    wire        bar_row = (y >= 9'd152) && (y < 9'd162);
    wire        in_brt  = bar_row && (x >= 11'd124) && (x < 11'd188);
    wire        in_con  = bar_row && (x >= 11'd196) && (x < 11'd260);
    wire [9:0]  bx_b    = x - 11'd124;
    wire [9:0]  bx_c    = x - 11'd196;
    wire [3:0]  cell_b  = bx_b[5:2];
    wire [3:0]  cell_c  = bx_c[5:2];
    wire        lit_b   = in_brt && (cell_b < brt_sel[7:4]);
    wire        lit_c   = in_con && (cell_c < con_sel[7:4]);
    wire        in_bar  = in_brt | in_con;

    wire h11g = h11 & show_music;
    wire h12g = h12 & show_car;
    wire h13g = h13 & show_time;
    wire h14g = h14;                       // both nodes: it is picture state
    // `en` is the caption master switch: album mode (a frameless window filling
    // the wall) drops the whole overlay so nothing is painted over the photo.
    // ---- C10: bottom scrolling notice board --------------------------------
    // A 28-line dark strip at y = 452..479 carrying one line of 16x16 CJK
    // glyphs, scrolled by the phase both nodes share.  It has its own switch
    // (long press of KEY2 in VIEW mode); wall_scene kills it in album mode.
    wire        mq_hit;
    wire [23:0] mq_rgb;
    wall_marquee u_marquee (
        .x(wx[10:0]), .y(y), .en(m_on), .phase(m_phase),
        .hit(mq_hit), .rgb(mq_rgb)
    );

    assign hit = mq_hit || (en & (h0 | h1 | h2 | h3 | h4 | h5g | h6 | h7 | h8 | h9 | h10 | h11g |
                       h12g | h13g | h14g | in_bar));

    // ---- output selection -------------------------------------------------
    // This used to be a ternary CHAIN: one mux level per caption line.  At 15
    // lines that chain alone was ~15 LUT levels, and with the two W3 rows added
    // it became the 25 MHz critical path (0.06 ns of slack left).  The boxes are
    // PAIRWISE DISJOINT, so a flat OR of the one-hot terms is equivalent to the
    // priority chain and only two LUT levels deep.  Keep the boxes disjoint if
    // more lines are ever added -- overlapping boxes would now mix, not win by
    // priority.
    //
    // row and col need no mux at all: every wall_textbox drives row = y[2:0] and
    // col = (x - X0) & 7, and both X0 values (8, 560) are multiples of 8, so col
    // is simply x[2:0] for every line.
    wire [5:0] ch = (h0  ? c0  : 6'd0) | (h1  ? c1  : 6'd0) |
                    (h2  ? c2  : 6'd0) | (h3  ? c3  : 6'd0) |
                    (h4  ? c4  : 6'd0) | (h5g ? c5  : 6'd0) |
                    (h6  ? c6  : 6'd0) | (h7  ? c7  : 6'd0) |
                    (h8  ? c8  : 6'd0) | (h9  ? c9  : 6'd0) |
                    (h10 ? c10 : 6'd0) | (h11g ? c11 : 6'd0) |
                    (h12g ? c12 : 6'd0) | (h13g ? c13 : 6'd0) |
                    (h14g ? c14 : 6'd0);
    wire [2:0] row = y[2:0];
    wire [2:0] col = x[2:0];
    wire [7:0] bits;
    wall_font_rom u_rom (.ch(ch), .row(row), .bits(bits));

    wire [2:0] inv = 3'd7 - col;
    wire on = bits[{1'b0, inv}];

    // Colour: grouped by class instead of one mux level per line.  The classes
    // are mutually exclusive by construction, and each term is one AND on top of
    // the (already shallow) hit signals.
    wire sel_own   = h0;
    wire sel_on    = (h6  &  m_view)   | (h7  & (m_select | m_adj)) |
                     (h8  &  m_move)   | (h9  &  m_zoom)   |
                     (h11g & music_ok) | (h12g & car_auto) |
                     (h14g & adj_on);
    wire sel_alert = (h3  & !link_ok)  | h5g | (h11g & (!music_ok | mute));
    wire sel_dim   = h2 | h4 |
                     (h6  & !m_view)   | (h7  & !(m_select | m_adj)) |
                     (h8  & !m_move)   | (h9  & !m_zoom)   |
                     (h10 & !locked)   | (h12g & !car_auto);

    wire [23:0] tcol = sel_own   ? ((NODE_ID == 0) ? C_OWN_A : C_OWN_B) :
                       sel_on    ? C_ON :
                       sel_alert ? C_ALERT :
                       sel_dim   ? C_DIM   : C_TEXT;

    assign rgb = mq_hit ? mq_rgb
                        : (in_bar ? ((lit_b | lit_c) ? (lit_c ? C_BAR_C : C_ON) : C_TRACK)
                        : (hit ? (on ? tcol : C_BOX) : 24'h000000));
endmodule
