//=============================================================================
// wall_input.v -- debounced keys/buttons + the operator state machine (node A)
//
// Three slide switches select what the four keys do.  Everything needs SW1 up
// (operate mode); the modes are mutually exclusive:
//
//   SW1  SW2  SW3  SW4   mode              KEY4        KEY3        KEY2        KEY1
//   0    x    x    x     VIEW (keys are    auto-rot    single step UI on/off   mute
//                        view-only)        toggle      (carousel)
//   1    x    x    1     FULL SCREEN       next pic    prev pic    --          --
//                        (album, C3/C9)    (C9 page keys; the table itself is
//                                          owned by wall_album_seq)
//   1    1    1    0     BRIGHTNESS/CONTR    brt +     brt -       con +       con -
//   1    1    0    0     MOVE   (locked)   up          down        left        right
//   1    0    1    0     ZOOM   (locked)   zoom in     zoom out    zoom in+    zoom out+
//   1    0    0    0     SELECT (base)     select      confirm     to front    to back
//
// C7: SW4 and SW1+SW2+SW3 were SWAPPED by the operator's request -- SW4 is now
// the full-screen album and the brightness/contrast overlay moved to all three
// of SW1/SW2/SW3 up.  SW4 wins over everything (it is a dedicated switch).
//
// "confirm" locks the picture (raises selected+dragging so the border blinks);
// pressing it again releases it.
//
// The key row is mounted KEY4..KEY1 from the operator's left, hence the
// direction order above ("reversed" from the raw pin numbering).
//
// Movement: one step per press, then auto-repeat at ~30 Hz; a step is 1 px and
// grows to 4 px once the key has been held for 0.5 s (acc_thr clock cycles).
// Zoom keeps the window centred and the 4:3 picture aspect: 16x12 px per press
// (64x48 for the fast pair).  Depth is the table's 2-bit z field.
//
// The FSM only edits `stage`; wall_state commits it at frame boundaries, so a
// key press never tears a frame.
//=============================================================================
`timescale 1ns/1ps

module wall_input #(
    parameter integer WORLD_W = 1280,
    parameter integer WORLD_H = 480,
    parameter integer SEAM_X  = 640,
    // The auto-drag demo build needs the direction keys without a hand on SW2.
    parameter integer FORCE_DIRS = 0
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [3:0]  key_n,        // active low: KEY1..KEY4
    input  wire [3:0]  sw_n,         // active low: SW1..SW4
    input  wire [3:0]  remote_press, // 1-cycle pulses from the peer
    input  wire        commit,       // do not edit in the commit cycle
    input  wire [16:0] db_cyc,       // debounce length in clk cycles
    input  wire [19:0] rep_cyc,      // auto-repeat period in clk cycles
    input  wire [23:0] acc_thr,      // held-time threshold for the 4 px step
    input  wire [1:0]  cur_sel,
    input  wire [63:0] stage_word,
    output wire [1:0]  rd_idx,
    output reg         set_tbl,
    output reg  [1:0]  set_idx,
    output reg  [63:0] set_data,
    output reg         set_sel,
    output reg  [1:0]  sel_out,
    output reg  [3:0]  local_press,
    output reg         evt_valid,
    output reg  [11:0] evt_gx,
    output wire [3:0]  dbg_mode,        // {sw4, sw3, sw2, locked}
    output wire [2:0]  mode_out,        // {sw3, sw2, sw1} for the OSD captions
    output reg         mute,            // reserved (not wired on the bench yet)
    output reg         osd_en,          // reserved (not wired on the bench yet)
    // VIEW-mode carousel control.  KEY4 toggles auto-rotation, KEY3 advances
    // one picture when auto is off.  Both are single-cycle pulses on the key
    // press edge (ev[] is a level while the key is held, so an edge is needed
    // or one press would fire every clock).
    output reg         car_toggle,
    output reg         car_step,
    // ADJUST mode (SW4 up, W3.5): brightness/contrast of the picture shown in
    // the selected window.  One pulse per step, same key-repeat as MOVE/ZOOM.
    output reg         adj_ev,
    output reg         adj_rst_b,       // long-press chord: reset brightness
    output reg         adj_rst_c,       // long-press chord: reset contrast
    output reg         adj_con,         // 1 = contrast, 0 = brightness
    output reg         adj_up,          // 1 = increase
    output wire        adj_on,          // the mode is active (for the HUD)
    // ALBUM mode (C3): SW1 + SW4 up.  The window table belongs to the album
    // sequencer in wall_top, but the PAGE keys live here (C9): KEY4 = next
    // picture, KEY3 = previous, each a single-cycle pulse on the press edge.
    // Nothing in that branch may write the table -- the sequencer owns it.
    // C10: bottom marquee on/off.  VIEW mode: SHORT press of KEY2 = UI on/off,
    // LONG press (>=1 s) = marquee on/off -- the same 1 s chord the ADJUST layer
    // already uses for its resets.
    output reg         marquee_on,
    output reg         alb_next,
    output reg         alb_prev,
    output wire        album_out
);
    //-------------------------------------------------------------------------
    // Synchronise + debounce
    //-------------------------------------------------------------------------
    reg [3:0] k0, k1, kd;
    reg [3:0] s0, s1, sd;
    reg [16:0] dcnt0, dcnt1, dcnt2, dcnt3;
    reg [16:0] scnt0, scnt1, scnt2, scnt3;
    reg [3:0] press;

    always @(posedge clk) begin
        k0 <= key_n;
        k1 <= k0;
        s0 <= sw_n;
        s1 <= s0;
    end

    always @(posedge clk) begin
        if (rst) begin
            kd <= 4'hF;
            sd <= 4'h0;
            dcnt0 <= 17'd0; dcnt1 <= 17'd0; dcnt2 <= 17'd0; dcnt3 <= 17'd0;
            scnt0 <= 17'd0; scnt1 <= 17'd0; scnt2 <= 17'd0; scnt3 <= 17'd0;
            press <= 4'd0;
            local_press <= 4'd0;
        end else begin
            press <= 4'd0;

            if (k1[0] != kd[0]) begin
                if (dcnt0 == db_cyc - 17'd1) begin
                    dcnt0 <= 17'd0;
                    kd[0] <= k1[0];
                    if (!k1[0]) press[0] <= 1'b1;
                end else dcnt0 <= dcnt0 + 17'd1;
            end else dcnt0 <= 17'd0;

            if (k1[1] != kd[1]) begin
                if (dcnt1 == db_cyc - 17'd1) begin
                    dcnt1 <= 17'd0;
                    kd[1] <= k1[1];
                    if (!k1[1]) press[1] <= 1'b1;
                end else dcnt1 <= dcnt1 + 17'd1;
            end else dcnt1 <= 17'd0;

            if (k1[2] != kd[2]) begin
                if (dcnt2 == db_cyc - 17'd1) begin
                    dcnt2 <= 17'd0;
                    kd[2] <= k1[2];
                    if (!k1[2]) press[2] <= 1'b1;
                end else dcnt2 <= dcnt2 + 17'd1;
            end else dcnt2 <= 17'd0;

            if (k1[3] != kd[3]) begin
                if (dcnt3 == db_cyc - 17'd1) begin
                    dcnt3 <= 17'd0;
                    kd[3] <= k1[3];
                    if (!k1[3]) press[3] <= 1'b1;
                end else dcnt3 <= dcnt3 + 17'd1;
            end else dcnt3 <= 17'd0;

            // ---- SW1..SW4: slide switches, only the level matters ----------
            if (s1[0] != sd[0]) begin
                if (scnt0 == db_cyc - 17'd1) begin scnt0 <= 17'd0; sd[0] <= s1[0]; end
                else scnt0 <= scnt0 + 17'd1;
            end else scnt0 <= 17'd0;

            if (s1[1] != sd[1]) begin
                if (scnt1 == db_cyc - 17'd1) begin scnt1 <= 17'd0; sd[1] <= s1[1]; end
                else scnt1 <= scnt1 + 17'd1;
            end else scnt1 <= 17'd0;

            if (s1[2] != sd[2]) begin
                if (scnt2 == db_cyc - 17'd1) begin scnt2 <= 17'd0; sd[2] <= s1[2]; end
                else scnt2 <= scnt2 + 17'd1;
            end else scnt2 <= 17'd0;

            if (s1[3] != sd[3]) begin
                if (scnt3 == db_cyc - 17'd1) begin scnt3 <= 17'd0; sd[3] <= s1[3]; end
                else scnt3 <= scnt3 + 17'd1;
            end else scnt3 <= 17'd0;

            local_press <= press;
        end
    end

    wire [3:0] ev    = press | remote_press;
    wire [3:0] level = ~kd;          // 1 = pressed

    // sw_n is presented active HIGH by wall_top (1 = switch up)
    wire [3:0] sw_lvl = sd;
    wire       sw1 = sw_lvl[0];
    wire       sw2 = sw_lvl[1] | (FORCE_DIRS != 0);
    wire       sw3 = sw_lvl[2];
    wire       sw4 = sw_lvl[3];

    // ---- FULL-SCREEN (album) mode: SW4 up ---------------------------------
    // C7: the operator asked to SWAP the two modes.  SW4 used to be the
    // brightness/contrast overlay; it now selects the full-screen album, and the
    // adjust overlay moved to SW1+SW2+SW3 together.
    // Decode order is SW4 -> SW2&SW3 -> SW2 -> SW3, and the modes are mutually
    // exclusive by construction below, so no priority chain is needed.
    wire       album = sw1 && sw4;
    assign album_out = album;

    //-------------------------------------------------------------------------
    // Operator FSM
    //-------------------------------------------------------------------------
    reg [1:0]  sel;
    reg        ev3_d, ev2_d, ev1_d, ev0_d;
    // C10: KEY2 short/long discrimination (VIEW mode)
    reg        lvl1_d;
    reg        mp_done;
    reg [24:0] mp_acc;
    reg        locked;
    reg [19:0] rcnt;
    reg [23:0] acc;

    wire [11:0] gx, gy;
    wire [9:0]  ww, hh;
    wire [3:0]  src;
    wire [1:0]  z;
    wire        owner;
    wire [2:0]  flags;
    wire [3:0]  wid;

    assign gx    = stage_word[11:0];
    assign gy    = stage_word[23:12];
    assign ww    = stage_word[33:24];
    assign hh    = stage_word[43:34];
    assign src   = stage_word[47:44];
    assign z     = stage_word[49:48];
    assign owner = stage_word[50];
    assign flags = stage_word[53:51];
    assign wid   = stage_word[57:54];

    assign rd_idx   = sel;
    assign dbg_mode = {sw4, sw3, sw2, locked};
    assign mode_out = {sw3, sw2, sw1};

    // Explicit-width constants: bit-selecting an integer parameter behaves
    // differently between ModelSim and TD synthesis (suspected cause of the
    // always-owner-B symptom on hardware).
    localparam [11:0] WORLD_W12 = 12'd1280;
    localparam [11:0] WORLD_H12 = 12'd480;
    localparam [11:0] SEAM12    = 12'd640;
    wire [11:0] w12     = {2'b00, ww};
    wire [11:0] h12     = {2'b00, hh};
    wire [11:0] gx_max  = WORLD_W12 - w12;
    wire [11:0] gy_max  = WORLD_H12 - h12;
    wire [11:0] centre  = gx + {2'b00, ww[9:1]};

    // C7 mode decode (priority: SW4 -> SW2&SW3 -> SW2 -> SW3 -> base layer)
    //   SW1 up, SW4 up              : FULL SCREEN (album)      -- was ADJUST
    //   SW1 up, SW2+SW3 up          : brightness/contrast      -- was ALBUM
    //   SW1 up, SW2 up, SW3 down    : MOVE
    //   SW1 up, SW3 up, SW2 down    : ZOOM
    // adj uses the REAL switch pins (not FORCE_DIRS), so the auto-drag demo build
    // cannot land in the adjust overlay from one forced switch.
    wire adj_mode  = sw1 && sw_lvl[1] && sw_lvl[2] && !album;
    wire move_mode = sw1 && sw2 && !sw3 && locked && !album && !adj_mode;
    wire zoom_mode = sw1 && sw3 && !sw2 && locked && !move_mode && !album && !adj_mode;
    assign adj_on  = adj_mode;

    // ---- long-press chords in ADJUST: both keys of a pair = reset ----------
    // The step is 8 and the range is 0x20..0xFF, so walking back by hand takes
    // up to 28 presses.  Hold the two keys of one pair together for a second
    // and that pair goes back to 0x80.  While both are down the individual
    // +/- events are suppressed (otherwise the repeats would fight the reset).
    wire adj_pair_b = level[3] & level[2];      // brighter + dimmer
    wire adj_pair_c = level[1] & level[0];      // more + less contrast
    localparam [24:0] RST_THR = 25'd25_000_000; // 1 s @ 25 MHz

    reg [24:0] rst_acc;
    reg        rst_done;
    always @(posedge clk) begin
        if (rst || !adj_mode) begin
            rst_acc       <= 25'd0;
            rst_done      <= 1'b0;
            adj_rst_b     <= 1'b0;
            adj_rst_c     <= 1'b0;
        end else begin
            adj_rst_b <= 1'b0;
            adj_rst_c <= 1'b0;
            if (adj_pair_b || adj_pair_c) begin
                if (!rst_done) begin
                    rst_acc <= rst_acc + 25'd1;
                    if (rst_acc >= RST_THR) begin
                        rst_done  <= 1'b1;
                        adj_rst_b <= adj_pair_b;
                        adj_rst_c <= adj_pair_c;
                    end
                end
            end else begin
                rst_acc  <= 25'd0;
                rst_done <= 1'b0;
            end
        end
    end

    wire any_dir = level[0] | level[1] | level[2] | level[3];

    // one step per press, then auto-repeat; 4 px once held for acc_thr cycles
    wire [11:0] stp    = (acc >= acc_thr) ? 12'd4 : 12'd1;
    wire repeat_tick   = (rcnt == 20'd1);
    wire t_key4 = ev[3] || (repeat_tick && level[3]);
    wire t_key3 = ev[2] || (repeat_tick && level[2]);
    wire t_key2 = ev[1] || (repeat_tick && level[1]);
    wire t_key1 = ev[0] || (repeat_tick && level[0]);

    // ---- zoom: keep the centre, keep the 4:3 picture aspect ---------------
    localparam [9:0] W_MIN = 10'd40,  W_MAX = 10'd640;
    localparam [9:0] H_MIN = 10'd40,  H_MAX = 10'd480;
    localparam [9:0] W_STP = 10'd16,  H_STP = 10'd12;    // slow pair
    localparam [9:0] W_FST = 10'd64,  H_FST = 10'd48;    // fast pair

    reg [9:0] w_z, h_z;
    reg       zoom_in;
    always @(*) begin
        zoom_in = 1'b1;
        w_z = ww;
        h_z = hh;
        if (t_key4) begin                 // KEY4: zoom in, slow
            zoom_in = 1'b1;
            w_z = (ww + W_STP > W_MAX) ? W_MAX : (ww + W_STP);
            h_z = (hh + H_STP > H_MAX) ? H_MAX : (hh + H_STP);
        end else if (t_key3) begin        // KEY3: zoom out, slow
            zoom_in = 1'b0;
            w_z = (ww < W_MIN + W_STP) ? W_MIN : (ww - W_STP);
            h_z = (hh < H_MIN + H_STP) ? H_MIN : (hh - H_STP);
        end else if (t_key2) begin        // KEY2: zoom in, fast
            zoom_in = 1'b1;
            w_z = (ww + W_FST > W_MAX) ? W_MAX : (ww + W_FST);
            h_z = (hh + H_FST > H_MAX) ? H_MAX : (hh + H_FST);
        end else if (t_key1) begin        // KEY1: zoom out, fast
            zoom_in = 1'b0;
            w_z = (ww < W_MIN + W_FST) ? W_MIN : (ww - W_FST);
            h_z = (hh < H_MIN + H_FST) ? H_MIN : (hh - H_FST);
        end
    end

    // Grow/shrink about the centre.  Growing is only allowed while the window
    // still fits: once a side touches the world edge the zoom key is ignored
    // rather than clamped -- the old clamp had to slide gx/gy to stay inside,
    // and at the limit the window ended up off-screen ("zoom in at the edge
    // and the picture disappears").
    wire [9:0]  w_d   = (w_z > ww) ? (w_z - ww) : (ww - w_z);
    wire [9:0]  h_d   = (h_z > hh) ? (h_z - hh) : (hh - h_z);
    wire [11:0] w_z12 = {2'b00, w_z};
    wire [11:0] h_z12 = {2'b00, h_z};
    wire [11:0] w_h   = {2'b00, w_d[9:1]};      // half the width delta
    wire [11:0] h_h   = {2'b00, h_d[9:1]};      // half the height delta
    wire [11:0] gx_z  = zoom_in ? (gx - w_h) : (gx + w_h);
    wire [11:0] gy_z  = zoom_in ? (gy - h_h) : (gy + h_h);
    wire grow_ok = (gx >= w_h) && (gy >= h_h) &&
                   (gx + w_z12 - w_h <= WORLD_W12) &&
                   (gy + h_z12 - h_h <= WORLD_H12);
    wire [11:0] gx_zc = gx_z;
    wire [11:0] gy_zc = gy_z;
    wire        zoom_go = zoom_in ? grow_ok : 1'b1;

    // ---- movement (keys are mounted KEY4..KEY1, hence this order) ----------
    reg [11:0] gx_n, gy_n;
    reg        mv, mv_up, mv_dn, mv_lf, mv_rt;
    always @(*) begin
        mv_up = move_mode && t_key4 && (gy != 12'd0);
        mv_dn = move_mode && t_key3 && (gy < gy_max);
        mv_lf = move_mode && t_key2 && (gx != 12'd0);
        mv_rt = move_mode && t_key1 && (gx < gx_max);
        mv    = mv_up | mv_dn | mv_lf | mv_rt;

        gx_n = gx;
        gy_n = gy;
        if (mv_up)      gy_n = (gy >= stp) ? (gy - stp) : 12'd0;
        else if (mv_dn) gy_n = (gy + stp > gy_max) ? gy_max : (gy + stp);
        else if (mv_lf) gx_n = (gx >= stp) ? (gx - stp) : 12'd0;
        else if (mv_rt) gx_n = (gx + stp > gx_max) ? gx_max : (gx + stp);
    end



    always @(posedge clk) begin
        if (rst) begin
            sel       <= 2'd0;
            locked    <= 1'b0;
            rcnt      <= 20'd0;
            acc       <= 24'd0;
            set_tbl    <= 1'b0;
            set_sel    <= 1'b0;
            evt_valid  <= 1'b0;
            car_toggle <= 1'b0;
            car_step   <= 1'b0;
            adj_ev     <= 1'b0;
            adj_con    <= 1'b0;
            adj_up     <= 1'b1;
            set_idx   <= 2'd0;
            set_data  <= 64'd0;
            sel_out   <= 2'd0;
            mute      <= 1'b0;
            osd_en    <= 1'b1;
            ev3_d     <= 1'b0;
            ev2_d     <= 1'b0;
            ev1_d     <= 1'b0;
            ev0_d     <= 1'b0;
            alb_next  <= 1'b0;
            alb_prev  <= 1'b0;
            marquee_on <= 1'b0;
            mp_acc    <= 25'd0;
            mp_done   <= 1'b0;
            lvl1_d    <= 1'b0;
        end else begin
            set_tbl    <= 1'b0;
            set_sel    <= 1'b0;
            evt_valid  <= 1'b0;
            car_toggle <= 1'b0;
            car_step   <= 1'b0;
            adj_ev     <= 1'b0;
            alb_next   <= 1'b0;
            alb_prev   <= 1'b0;

            // ---- view mode: drop the lock, keys drive view-only toggles ------
            if (!sw1) begin
                // ---- VIEW key map -------------------------------------
                //   KEY4 = carousel auto-rotate on/off
                //   KEY3 = single step (only while auto is off)
                //   KEY2 = UI on/off  (whole HUD incl. the WALL A/B label, plus
                //          the audio level meter -- everything the operator sees
                //          except the pictures)
                //   KEY1 = audio mute (card WAV and the on-chip synth)
                // ev[] is a level while the key is down, so take an edge: one
                // press = one toggle (otherwise it flips every clock and the
                // state ends up unreachable).
                ev3_d <= ev[3];
                ev2_d <= ev[2];
                ev1_d <= ev[1];
                ev0_d <= ev[0];
                lvl1_d <= level[1];
                if (ev[3] && !ev3_d) car_toggle <= 1'b1;
                if (ev[2] && !ev2_d) car_step   <= 1'b1;
                // KEY2 (C10): short press = UI on/off, LONG press (>= 1 s) = the
                // bottom marquee.  The short action fires on RELEASE, otherwise a
                // long press would toggle the UI first and the marquee second.
                if (level[1]) begin
                    if (!mp_done) begin
                        if (mp_acc == RST_THR) begin
                            mp_done    <= 1'b1;
                            marquee_on <= ~marquee_on;
                        end else begin
                            mp_acc <= mp_acc + 25'd1;
                        end
                    end
                end else begin
                    mp_acc <= 25'd0;
                    if (mp_done)        mp_done <= 1'b0;   // the long press already acted
                    else if (lvl1_d)    osd_en  <= ~osd_en; // plain short press
                end
                if (ev[0] && !ev0_d) mute       <= ~mute;     // KEY1: mute
                if (locked) begin
                    locked   <= 1'b0;
                    set_tbl  <= 1'b1;
                    set_idx  <= sel;
                    set_data <= {6'd0, wid, (flags & 3'b100), (centre >= SEAM12),
                                 z, src, hh, ww, gy, gx};
                end
                rcnt <= 20'd0;
                acc  <= 24'd0;
            end else if (album) begin
                // C10: leaving VIEW mode must not leave a half-finished chord
                mp_acc  <= 25'd0;
                mp_done <= 1'b0;
                // ---- ALBUM: the window table is owned by the sequencer ------
                // Nothing here may call set_tbl (the album record lives in the
                // same stage word the sequencer writes).  C9: the two middle keys
                // page through the four 1:1 copies -- KEY4 = next, KEY3 =
                // previous, edge-detected exactly like the VIEW keys above, and
                // consumed by wall_album_seq, which only acts in its S_ALBUM
                // state (so presses during the fade are simply ignored).
                ev3_d <= ev[3];
                ev2_d <= ev[2];
                if (ev[3] && !ev3_d) alb_next <= 1'b1;
                if (ev[2] && !ev2_d) alb_prev <= 1'b1;
                rcnt <= 20'd0;
                acc  <= 24'd0;
            end else begin
                // ---- acceleration timer ------------------------------------
                if ((move_mode || zoom_mode) && any_dir) begin
                    if (acc != acc_thr) acc <= acc + 24'd1;
                end else begin
                    acc <= 24'd0;
                end

                if (!commit) begin
                    if (move_mode) begin
                        rcnt <= (rcnt == 20'd0) ? 20'd0 : (rcnt - 20'd1);
                        if (mv) begin
                            rcnt     <= rep_cyc;
                            set_tbl  <= 1'b1;
                            set_idx  <= sel;
                            set_data <= {6'd0, wid, flags, owner, z, src,
                                         hh, ww, gy_n, gx_n};
                        end
                    end else if (zoom_mode) begin
                        rcnt <= (rcnt == 20'd0) ? 20'd0 : (rcnt - 20'd1);
                        if ((t_key4 || t_key3 || t_key2 || t_key1) && zoom_go) begin
                            rcnt     <= rep_cyc;
                            set_tbl  <= 1'b1;
                            set_idx  <= sel;
                            set_data <= {6'd0, wid, flags, owner, z, src,
                                         h_z, w_z, gy_zc, gx_zc};
                        end
                    end else if (adj_mode) begin
                        // ---- ADJUST (SW4 up): KEY4/KEY3 = brightness -/+
                        //      (KEY4 = brighter), KEY2/KEY1 = contrast -/+
                        //      (KEY2 = more contrast).  Same repeat as MOVE/ZOOM.
                        //      Holding BOTH keys of a pair for 1 s = reset that
                        //      pair to neutral (0x80) -- the only way back that
                        //      does not mean counting 16 presses.
                        rcnt <= (rcnt == 20'd0) ? 20'd0 : (rcnt - 20'd1);
                        if (!adj_pair_b && !adj_pair_c &&
                            (t_key4 || t_key3 || t_key2 || t_key1)) begin
                            rcnt    <= rep_cyc;
                            adj_ev  <= 1'b1;
                            adj_con <= t_key2 || t_key1;
                            adj_up  <= t_key4 || t_key2;
                        end
                    end else begin
                        // ---- base layer: KEY4 select, KEY3 confirm,
                        //      KEY2 bring to front, KEY1 send to back --------
                        rcnt <= 20'd0;
                        if (!locked && ev[3]) begin          // KEY4: next picture
                            sel     <= sel + 2'd1;
                            set_sel <= 1'b1;
                            sel_out <= sel + 2'd1;
                        end
                        if (ev[2]) begin                     // KEY3: confirm
                            locked   <= ~locked;
                            set_tbl  <= 1'b1;
                            set_idx  <= sel;
                            // confirming raises selected+dragging (the border
                            // then blinks); releasing drops them and decides the
                            // owner from the window centre.
                            set_data <= {6'd0, wid,
                                         locked ? (flags & 3'b100) : (flags | 3'b011),
                                         locked ? owner : (centre >= SEAM12),
                                         z, src, hh, ww, gy, gx};
                        end else if (ev[1]) begin            // KEY2: to front
                            set_tbl  <= 1'b1;
                            set_idx  <= sel;
                            set_data <= {6'd0, wid, flags, owner, 2'd3, src,
                                         hh, ww, gy, gx};
                        end else if (ev[0]) begin            // KEY1: to back
                            set_tbl  <= 1'b1;
                            set_idx  <= sel;
                            set_data <= {6'd0, wid, flags, owner, 2'd0, src,
                                         hh, ww, gy, gx};
                        end
                    end
                end
            end
        end
    end
endmodule
