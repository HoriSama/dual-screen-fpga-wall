//=============================================================================
// wall_top.v -- monitoring-wall node (A = table master, B = mirror)
//
// Node A: raster master, owns the window table, broadcasts a STATE frame at
//         every frame start, receives B's INPUT frames.
// Node B: renders the same world with NODE_X0 = 640, receives STATE frames and
//         genlocks its raster to A's link_sync pulse.
//
// W1 has no SDRAM and no TF: window content is procedural, so the whole design
// stays inside the 50/25 MHz domains and cannot disturb the validated 150 MHz
// framebuffer timing closure.
//=============================================================================
`timescale 1ns/1ps

module wall_node_a #(
    parameter integer AUTODRAG = 0
)(
    input  wire clk,
    input  wire [3:0] key_n,
    input  wire [3:0] sw_n,          // active low: SW1..SW4 (C8/C7/C6/C5)
    output wire [3:0] led,
    output wire uart_tx,
    output wire sd_ncs,
    output wire sd_sclk,
    output wire sd_mosi,
    input  wire sd_miso,
    output wire HDMI_D0_P,
    output wire HDMI_D1_P,
    output wire HDMI_D2_P,
    output wire HDMI_CLK_P,
    output wire HDMI_DDC_SCL,
    inout  wire HDMI_DDC_SDA,
    output wire link_clk,
    output wire link_sync,
    output wire link_vld,
    output wire [3:0] link_d,
    input  wire link_bvld,
    input  wire [3:0] link_bd
);
    wall_core #(.IS_MASTER(1), .NODE_ID(0), .AUTODRAG(AUTODRAG)) u_core (
        .clk50(clk), .key_n(key_n), .sw_n(sw_n), .led(led), .uart_tx(uart_tx),
        .sd_ncs(sd_ncs), .sd_sclk(sd_sclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .HDMI_D0_P(HDMI_D0_P), .HDMI_D1_P(HDMI_D1_P),
        .HDMI_D2_P(HDMI_D2_P), .HDMI_CLK_P(HDMI_CLK_P),
        .HDMI_DDC_SCL(HDMI_DDC_SCL), .HDMI_DDC_SDA(HDMI_DDC_SDA),
        .o_link_clk(link_clk), .o_link_sync(link_sync),
        .o_link_vld(link_vld), .o_link_d(link_d),
        .i_link_bvld(link_bvld), .i_link_bd(link_bd),
        .i_link_clk(1'b0), .i_link_sync(1'b0), .i_link_vld(1'b0), .i_link_d(4'h0),
        .o_link_bvld(), .o_link_bd()
    );
endmodule

module wall_node_b #(
    parameter integer AUTODRAG = 0
)(
    input  wire clk,
    input  wire [3:0] key_n,
    input  wire [3:0] sw_n,          // active low: SW1..SW4 (C8/C7/C6/C5)
    output wire [3:0] led,
    output wire uart_tx,
    output wire sd_ncs,
    output wire sd_sclk,
    output wire sd_mosi,
    input  wire sd_miso,
    output wire HDMI_D0_P,
    output wire HDMI_D1_P,
    output wire HDMI_D2_P,
    output wire HDMI_CLK_P,
    output wire HDMI_DDC_SCL,
    inout  wire HDMI_DDC_SDA,
    input  wire link_clk,
    input  wire link_sync,
    input  wire link_vld,
    input  wire [3:0] link_d,
    output wire link_bvld,
    output wire [3:0] link_bd
);
    wall_core #(.IS_MASTER(0), .NODE_ID(1), .AUTODRAG(AUTODRAG)) u_core (
        .clk50(clk), .key_n(key_n), .sw_n(sw_n), .led(led), .uart_tx(uart_tx),
        .sd_ncs(sd_ncs), .sd_sclk(sd_sclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .HDMI_D0_P(HDMI_D0_P), .HDMI_D1_P(HDMI_D1_P),
        .HDMI_D2_P(HDMI_D2_P), .HDMI_CLK_P(HDMI_CLK_P),
        .HDMI_DDC_SCL(HDMI_DDC_SCL), .HDMI_DDC_SDA(HDMI_DDC_SDA),
        .o_link_clk(), .o_link_sync(), .o_link_vld(), .o_link_d(),
        .i_link_bvld(1'b0), .i_link_bd(4'h0),
        .i_link_clk(link_clk), .i_link_sync(link_sync),
        .i_link_vld(link_vld), .i_link_d(link_d),
        .o_link_bvld(link_bvld), .o_link_bd(link_bd)
    );
endmodule

//-----------------------------------------------------------------------------
// Shared core
//-----------------------------------------------------------------------------
module wall_core #(
    parameter integer IS_MASTER = 1,
    parameter integer NODE_ID   = 0,
    parameter integer HACTIVE   = 640,
    parameter integer VACTIVE   = 480,
    parameter integer HFP       = 16,
    parameter integer HSA       = 96,
    parameter integer HBP       = 48,
    parameter integer VFP       = 10,
    parameter integer VSA       = 2,
    parameter integer VBP       = 33,
    parameter integer DB_CYC    = 125000,
    parameter integer REP_CYC   = 833333,
    parameter integer POR_BITS  = 23,
    parameter integer AUTODRAG  = 0,
    parameter integer AUTO_START = 25_000_000,
    parameter integer AUTO_STEP  = 207_999
)(
    input  wire       clk50,
    input  wire [3:0] key_n,
    input  wire [3:0] sw_n,          // active low: SW1..SW4 (C8/C7/C6/C5)
    output wire [3:0] led,
    output wire uart_tx,
    output wire sd_ncs,
    output wire sd_sclk,
    output wire sd_mosi,
    input  wire sd_miso,
    output wire HDMI_D0_P,
    output wire HDMI_D1_P,
    output wire HDMI_D2_P,
    output wire HDMI_CLK_P,
    output wire HDMI_DDC_SCL,
    inout  wire HDMI_DDC_SDA,
    output wire       o_link_clk,
    output wire       o_link_sync,
    output wire       o_link_vld,
    output wire [3:0] o_link_d,
    input  wire       i_link_bvld,
    input  wire [3:0] i_link_bd,
    input  wire       i_link_clk,
    input  wire       i_link_sync,
    input  wire       i_link_vld,
    input  wire [3:0] i_link_d,
    output wire       o_link_bvld,
    output wire [3:0] o_link_bd
);
    localparam integer NODE_X0 = (NODE_ID == 0) ? 0 : 640;

    //=========================================================================
    // Clocks and reset
    //=========================================================================
    wire pixel_clk, serial_clk, pll_lock;

    reg [23:0] por = 24'd0;
    always @(posedge clk50) if (!por[POR_BITS]) por <= por + 24'd1;

    // PLL self-recovery: if extlock stays low, pulse the PLL reset and retry.
    // Repeated JTAG reconfiguration can leave the EG_PHY_PLL unlocked; the HDMI
    // supervisor then correctly refuses to start, but nothing would ever retry
    // the PLL itself.  This closes that loop without a power cycle.
    reg        pll_reset = 1'b1;
    reg [23:0] pll_wait  = 24'd0;
    reg [7:0]  pll_rst_cnt;
    always @(posedge clk50) begin
        if (!por[POR_BITS]) begin
            pll_reset   <= 1'b1;
            pll_wait    <= 24'd0;
            pll_rst_cnt <= 8'd0;
        end else if (pll_reset) begin
            if (pll_wait == 24'd200) begin        // 4 us reset pulse
                pll_reset <= 1'b0;
                pll_wait  <= 24'd0;
            end else begin
                pll_wait <= pll_wait + 24'd1;
            end
        end else if (!pll_lock) begin
            if (pll_wait >= 24'd2_500_000) begin  // retry every 50 ms
                pll_reset   <= 1'b1;
                pll_wait    <= 24'd0;
                pll_rst_cnt <= pll_rst_cnt + 8'd1;
            end else begin
                pll_wait <= pll_wait + 24'd1;
            end
        end else begin
            pll_wait <= 24'd0;
        end
    end

    p1_hdmi_pll_50m_25_125 u_pll (
        .refclk_50m(clk50),
        .reset     (pll_reset),
        .lock      (pll_lock),
        .pixel_clk (pixel_clk),
        .serial_clk(serial_clk)
    );

    wire por_done = por[POR_BITS];

    // The APUG092 needs the board-proven reset/retry loop: hold reset, wait for
    // O_video_locked, and re-run the sequence if it never locks (or unlocks for
    // longer than 20 ms).  Without this a bad power-on leaves TMDS silent.
    wire hdmi_rst;
    wire hdmi_video_locked;
    wire hdmi_ready;
    wire [1:0] hdmi_sup_state;
    wire [7:0] hdmi_rec_cnt;
    wire video_locked_ip;
    wall_hdmi_supervisor #(
        .RESET_HOLD_CYCLES   (1_000_000),
        .LOCK_WAIT_CYCLES    (10_000_000),
        .UNLOCK_FILTER_CYCLES(1_000_000)
    ) u_hdmi_sup (
        .clk(clk50),
        .ext_rst_n(por_done),
        .pll_lock(pll_lock),
        .video_locked_async(video_locked_ip),
        .hdmi_rst(hdmi_rst),
        .video_locked_sync(hdmi_video_locked),
        .video_ready(hdmi_ready),
        .recovery_pulse(),
        .sup_state(hdmi_sup_state),
        .rec_cnt(hdmi_rec_cnt)
    );

    // Two independent pixel-domain reset trees.
    //
    //   logic_rst : power-on only.  Owns the window table, the key FSM, the
    //               link frame logic and the status counters.  The HDMI retry
    //               loop must NEVER reset these, otherwise every APUG092 retry
    //               wipes the distributed state and the two boards disagree.
    //   vid_rst   : power-on plus every HDMI supervisor retry.  Owns the
    //               raster, the AXIS registers, EDID and the transmitter.
    //
    // Both are asynchronous-assert / two-flop synchronous-release in the pixel
    // domain (a bare 50 MHz reset level here is what TD flags as recovery).
    // C10-R1: the power-on reset used to be `!por_done` only, i.e. it relied on
    // the 24-bit counter below coming up with por[POR_BITS] == 0.  It does not:
    // after a JTAG / configuration-flash reload the flops come up with values this
    // flow does not initialise, and once por[23] happens to be 1 the design never
    // sees a reset at all -- the window table is not the default layout and the
    // HUD clock started at "41:28" (the board's uptime) instead of 00:00.
    // Adding the PLL lock makes it a REAL power-on reset: the PLL is unlocked for
    // milliseconds after every configuration, so por_rst is asserted then and is
    // released (through the two-flop synchroniser below) once the clock is real.
    wire por_rst = !por_done | ~pll_lock;

    reg [1:0] lprst;
    always @(posedge pixel_clk or posedge por_rst) begin
        if (por_rst) lprst <= 2'b11;
        else         lprst <= {lprst[0], 1'b0};
    end
    wire logic_rst = lprst[1];

    // Diagnostic: how many times the logic plane has been reset since power-on.
    reg [7:0] rst_cnt_pix;
    reg       logic_rst_d;
    always @(posedge pixel_clk) begin
        logic_rst_d <= logic_rst;
        if (logic_rst & ~logic_rst_d) rst_cnt_pix <= rst_cnt_pix + 8'd1;
    end

    reg [1:0] vprst;
    always @(posedge pixel_clk or posedge hdmi_rst) begin
        if (hdmi_rst) vprst <= 2'b11;
        else          vprst <= {vprst[0], 1'b0};
    end
    wire vid_rst = vprst[1];

    //=========================================================================
    // Raster (B genlocks to A's sync pulse)
    //=========================================================================
    wire [9:0] x_c;
    wire [8:0] y_c;
    wire de_c, sof_c, last_c;
    wire line_tick;              // 3 clocks before each active line (see below)
    wire align_ok;
    wire [7:0] align_bad;
    wire [7:0] raster_no_align;
    wire align_pix;

    wall_raster #(
        .HACTIVE(HACTIVE), .HFP(HFP), .HSA(HSA), .HBP(HBP),
        .VACTIVE(VACTIVE), .VFP(VFP), .VSA(VSA), .VBP(VBP)
    ) u_raster (
        .clk_pix(pixel_clk), .rst(vid_rst), .align(align_pix),
        .x_c(x_c), .y_c(y_c), .de_c(de_c), .sof_c(sof_c),
        .last_c(last_c), .pre_de(line_tick),
        .align_ok(align_ok), .align_bad(align_bad), .no_align_o(raster_no_align)
    );

    //=========================================================================
    // Window state
    //=========================================================================
    wire [255:0] cur_tbl, snap_tbl;
    wire [1:0]   cur_sel, snap_sel;
    wire [4:0]   cur_anim, snap_anim;
    wire [63:0]  stage_word;

    wire         a_set_tbl, a_set_sel, a_set_anim;
    wire [1:0]   a_set_idx, a_sel_in;
    wire [63:0]  a_set_data;
    wire [4:0]   a_anim_in;

    reg          b_set_tbl, b_set_sel, b_set_anim;
    reg  [1:0]   b_set_idx, b_sel_in;
    reg  [63:0]  b_set_data;
    reg  [4:0]   b_anim_in;

    wire         st_set_tbl, st_set_sel, st_set_anim;
    wire [1:0]   st_set_idx, st_sel_in;
    wire [63:0]  st_set_data;
    wire [4:0]   st_anim_in;
    wire [1:0]   rd_idx;

    // ---- album sequencer outputs (C3) --------------------------------------
    // Declared here because the master branch's write mux (g_st_a) is generated
    // before the sequencer itself.  It only ever ORs into the write strobe, so
    // a zero here is the ordinary "the operator's key wrote the table" case.
    // These are NETS: wall_album_seq drives them from its own always block, and
    // TD rejects a concurrent assignment to a reg (HDL-8007).
    wire         alb_set_tbl;
    wire [1:0]   alb_set_idx;
    wire [63:0]  alb_set_data;
    wire         album_a;          // wall_input's album switch state (master only)
    wire         album = (IS_MASTER != 0) ? album_a : 1'b0;
    // C9: album page keys (KEY4 = next, KEY3 = previous).  Driven by wall_input on
    // node A, tied low on node B (which has no keys and no sequencer).
    // C10: bottom scrolling marquee.  The switch lives on node A (long press of
    // KEY2 in VIEW mode) and rides to B in the STATE frame; the scroll phase is
    // frame_cnt[8:0] on A and {phase[8], seq} on B, i.e. the SAME value -- two
    // different phases would tear the text apart exactly at the seam.
    wire         m_on_loc;
    wire         alb_next, alb_prev;
    wire [1:0]   alb_pic_idx;      // page currently selected (for the status frame)

    generate
        if (IS_MASTER != 0) begin : g_st_a
            assign st_set_tbl  = a_set_tbl | alb_set_tbl;
            assign st_set_idx  = alb_set_tbl ? alb_set_idx : a_set_idx;
            assign st_set_data = alb_set_tbl ? alb_set_data : a_set_data;
            assign st_set_sel  = a_set_sel;
            assign st_sel_in   = a_sel_in;
            assign st_set_anim = a_set_anim;
            assign st_anim_in  = a_anim_in;
        end else begin : g_st_b
            assign st_set_tbl  = b_set_tbl;
            assign st_set_idx  = b_set_idx;
            assign st_set_data = b_set_data;
            assign st_set_sel  = b_set_sel;
            assign st_sel_in   = b_sel_in;
            assign st_set_anim = b_set_anim;
            assign st_anim_in  = b_anim_in;
        end
    endgenerate

    // The stage read port follows the FSM selection on node A and the committed
    // selection on node B (which has no input FSM).
    wire [1:0] rd_idx_use = (IS_MASTER != 0) ? rd_idx : cur_sel;

    wall_state #(.SEL_INIT(2'd0), .SNAP_DEPTH2((IS_MASTER != 0) ? 1 : 0)) u_state (
        .clk(pixel_clk), .rst(logic_rst), .commit(sof_c),
        .set_tbl(st_set_tbl), .set_idx(st_set_idx), .set_data(st_set_data),
        .set_sel(st_set_sel), .sel_in(st_sel_in),
        .set_anim(st_set_anim), .anim_in(st_anim_in),
        .rd_idx(rd_idx_use), .rd_word(stage_word),
        .cur_tbl(cur_tbl), .cur_sel(cur_sel), .cur_anim(cur_anim),
        .snap_tbl(snap_tbl), .snap_sel(snap_sel), .snap_anim(snap_anim)
    );

    //=========================================================================
    // ALBUM MODE sequencer (C3) -- see wall_album_seq
    //
    // SW1 + SW2 + SW3 up = album: the whole wall shows the 640x480 photograph
    // at one source pixel per screen pixel.  The sequencer swaps the window
    // table for a single FRAMELESS record and puts it back when the switches are
    // released.  It writes through the same single-index port wall_input uses,
    // so wall_state, the STATE broadcast and the 2-frame pipeline are untouched,
    // and node B simply receives the new table in the STATE frame it already
    // gets every frame.
    //=========================================================================
    wire [4:0] alb_level;          // 0 = black .. 16 = full (C5 transition level)
    wall_album_seq u_album (
        .clk(pixel_clk), .rst(logic_rst), .frame(sof_c),
        .album(album), .nxt(alb_next), .prv(alb_prev), .cur_tbl(cur_tbl),
        .set_tbl(alb_set_tbl), .set_idx(alb_set_idx), .set_data(alb_set_data),
        .level(alb_level), .pic_idx(alb_pic_idx)
    );

    // ---- the one global dimmer both nodes use (C5) --------------------------
    // Node A: its own sequencer level.  Node B: the mirrored level from the STATE
    // frame, so its half dims on the same frame instead of cutting one frame
    // late while A is already black.  Level 0 = black, 16 = passthrough.
    reg  [4:0] copy_tlvl;
    wire [4:0] tlvl_use = (IS_MASTER != 0) ? alb_level : copy_tlvl;


    // Album mode hides the overlay and must not let the carousel fade dim the
    // photograph (the album picture is a still; fade_gain would pulse it).
    // fade_use itself is declared next to the scene, because fade_gain is
    // declared further down inside the per-role branch.
    wire        album_cur = cur_tbl[58];

    // Frame counter on A's timeline (B locks to the same cadence via genlock).
    reg [15:0] frame_cnt = 16'd0;    // C10-R1: explicit init, see wall_clock.v
    always @(posedge pixel_clk) begin
        if (logic_rst) frame_cnt <= 16'd0;
        else if (sof_c) frame_cnt <= frame_cnt + 16'd1;
    end

    // ---- wall clock (W3 step 2): 60 frames = 1 s, 60 s = 1 min, wraps at 99 --
    // One tick per frame, i.e. the same cadence frame_cnt counts, so the number
    // on screen cannot drift from the carousel / blink phase.  Both nodes count
    // (they run the same RTL), but only node A draws the TIME line.
    // The counters are BCD so the HUD can feed the nibbles straight into
    // hexch() and still show decimal digits (see wall_clock.v).
    // C10-R1: the clock is additionally held at 00:00 until the card loader has
    // finished (tf_phase == 6, ~6 s after configuration).  `logic_rst` alone is
    // not enough on this board: it comes from a power-on counter whose flops are
    // not initialised by this flow, so after a JTAG / flash reconfiguration it
    // often never pulses and the HUD clock started at the board's uptime
    // ("41:28").  The loader FSM, on the other hand, restarts reliably on every
    // configuration, so its DONE state is a dependable zero point.  Node B never
    // runs the loader, but it never draws the TIME line either.
    wire [7:0] time_sec, time_min;
    // tf_phase is declared here (it used to live next to the loader) because the
    // clock below needs it; an undeclared name would become a silent 1-bit net.
    wire [3:0] tf_phase;
    wire       clk_rst = logic_rst | (tf_phase != 4'd6);
    wall_clock u_clock (
        .clk(pixel_clk), .rst(clk_rst), .tick(sof_c),
        .sec(time_sec), .min(time_min)
    );

    // Carousel auto-advance flag, exported from the master branch so the HUD can
    // caption it -- it used to be a register buried inside g_master.  Node B has
    // no way to know it (it follows the phase A broadcasts), so it drives 0 and
    // simply does not draw the CAR line (see wall_hud.show_stat).
    wire car_auto_w;

    // Selected window fields straight out of the committed table (bits 50/51 are
    // the owner and dragging flags).  Used by the status uart.
    wire [7:0]  sel_off      = {cur_sel, 6'b000000};
    wire [11:0] sel_gx_stat  = cur_tbl[sel_off +: 12];
    wire        sel_drag_stat = cur_tbl[sel_off + 52];   // flags[1] = dragging
wire        sel_own_stat  = cur_tbl[sel_off + 50];   // owner
wire [9:0]  sel_w_stat    = cur_tbl[sel_off + 24 +: 10];
wire [9:0]  sel_h_stat    = cur_tbl[sel_off + 34 +: 10];


    reg sof_d;
    always @(posedge pixel_clk) sof_d <= sof_c && !logic_rst;

    //=========================================================================
    // Role-specific link + input
    //=========================================================================
    localparam [16:0] DB_CYC17  = DB_CYC;
    localparam [19:0] REP_CYC20 = REP_CYC;
    wire [16:0] db_cyc_w  = DB_CYC17;
    wire [19:0] rep_cyc_w = REP_CYC20;
    wire [3:0]  remote_press;
    wire       link_ok;
    wire       sync_ok = (NODE_ID == 0) ? 1'b1 : align_ok;
    wire       b_align;
    wire [15:0] stat_ok, stat_err;
    wire        frozen_w;
    wire [3:0]  auto_press;
    wire        a_evt_valid;
    wire [11:0] a_evt_gx;
    wire        a_evt_valid_w = (IS_MASTER != 0) ? a_evt_valid : 1'b0;
    wire [3:0]  key_pressed_w = ~key_n;
    reg  [3:0]  remote_press_q;
    always @(posedge pixel_clk) remote_press_q <= remote_press;

    // ---- picture carousel plumbing (driven inside the per-role branches) ---
    // The carousel moved to SDRAM, so there is no picture-RAM read port any
    // more: node A pushes its own SDRAM pictures to node B, which writes them
    // straight into B's SDRAM.  B's received-block counter feeds the status
    // frame, so it still has to be a module-scope wire.
    // Temporary on-board diagnostics: the push block counter on A and the
    // received block counter on B, both surfaced in the status frame so the
    // A->B picture carousel can be measured without a scope.
    wire [15:0] push_blocks;
    wire [16:0] push_cur_blk;
    wire [7:0]  push_dbg;
    // ---- carousel (轮播) ---------------------------------------------------
    // Window w shows picture (w + car_cyc) mod 4.  Node A owns the phase; node B
    // receives it plus the fade gain in a dedicated FRAME_TYPE 0x04 frame, so
    // the two halves of the wall can never drift apart (a manual step makes any
    // "derive it from the frame counter" scheme wrong).
    // 256-frame cycle: 224 frames hold, 16 fade out, 16 fade in.  car_cyc steps
    // at the black point, so the picture swap is never seen.
    wire [1:0]  car_cyc;      // A: wall_carousel, B: mirrored from the STATE frame
    wire [7:0]  fade_gain;    // same split: A runs the envelope, B mirrors it
    // per-picture brightness/contrast: A owns the table, B mirrors it
    wire [63:0] bc_tbl;
    wire        adj_on;                    // ADJUST mode is a node-A thing
    wire        adj_ev, adj_con, adj_up;   // ADJUST-mode key events from wall_input
    wire        adj_rst_b, adj_rst_c;      // long-press chord: reset that pair to 0x80

    // round-robin broadcast of one picture's {brightness, contrast} per frame
    // (declared here: the STATE transmitter above is instantiated before the
    // carousel block that fills them)
    reg  [1:0]  bc_rr;
    reg  [7:0]  tx_bc_b, tx_bc_c;
    reg  [1:0]  tx_bc_id;
    wire        car_toggle, car_step;   // VIEW-mode key pulses from wall_input
    // node B's copy of the carousel state, captured in the link domain
    reg         copy_mok;             // B: "peer has a card WAV loaded"
    reg  [2:0]  copy_lvl;             // B: A's audio level, for an identical meter
    reg  [1:0]  copy_car_cyc;         // B: mirrored carousel phase
    reg  [7:0]  copy_fade;            // B: mirrored fade gain
    reg         copy_car;             // B: mirrored car_auto (for the CAR caption)
    reg         copy_adj;             // B: mirrored ADJUST-mode flag (lights its caption)
    reg         copy_osd, copy_mute;  // B: mirrored UI-visible / muted flags (C6)
    reg         copy_marq, copy_mp8;  // B: mirrored marquee switch + phase[8] (C10)
    reg  [63:0] bc_tbl_b;             // B: mirrored brightness/contrast table
    wire        mute_in, osd_in;      // driven by wall_input on node A only

    // Hold the two flags in registers with an explicit power-up value: reading
    // wall_input's outputs combinationally let node A come up with osd_loc = X
    // when the master generate block was still settling, and X on the HUD's
    // enable masks every caption (the board showed no OSD on half A).
    reg         mute_r, osd_r;
    always @(posedge pixel_clk) begin
        if (logic_rst) begin
            mute_r <= 1'b0;           // not muted
            osd_r  <= 1'b1;           // captions visible
        end else if (IS_MASTER != 0) begin
            mute_r <= mute_in;
            osd_r  <= osd_in;
        end
    end
    wire        mute_loc   = mute_r;
    wire        osd_loc    = osd_r;
    // C6: node B mirrors both flags from the STATE frame, so the two halves hide
    // the overlay and fall silent together -- whichever board's keys were pressed.
    wire        mute_use   = (IS_MASTER != 0) ? mute_loc : copy_mute;
    wire        osd_use    = (IS_MASTER != 0) ? osd_loc  : copy_osd;
    wire [2:0]  mode_sw;       // {sw3, sw2, sw1}: local on A, received on B
    wire        aud_vld;
    wire [23:0] aud_l, aud_r;
    wire [7:0]  wav_base, wav_addr, wav_data;
    wire [7:0]  aud_level;
    // MUSIC.WAV playback (wall_tf_load -> SDRAM -> HDMI audio)
    wire        mus_ld_vld, mus_ld_rdy, mus_vld, mus_playing;
    wire [20:0] mus_ld_addr, mus_frames;
    wire [31:0] mus_ld_data;
    wire [23:0] mus_l, mus_r;
    wire        mw_vld, mw_rdy;  wire [20:0] mw_addr, mus_wr_addr, mus_rd_addr;
    wire [31:0] mw_data, mus_wr_data;
    wire        mus_wr_valid, mus_rd_valid;
    wire [7:0]  scope_level;     // audio level driving the on-screen meter
    // node B shows the same bar as node A by using the broadcast level
    // 3-bit level, identical on both nodes: A truncates its own value and
    // broadcasts those bits, so B draws exactly the same bar length.
    wire [2:0]  lvl3 = (scope_level > 8'd7) ? 3'd7 : scope_level[2:0];
    wire [7:0]  meter_level = {(IS_MASTER != 0) ? lvl3 : copy_lvl, 5'b0};
    wire        music_ok;
    wire [4:0]  ld_state_w;
    wire [7:0]  ld_ent_cnt;
    wire [31:0] ld_ent4;
    // one root-directory byte per ~100 ms, driven straight off frame_cnt so it
    // cannot be stopped by the status module's send interlock
    wire [8:0]  ld_dump_addr = frame_cnt[12:4];
    wire [7:0]  ld_dump_byte;
    wire [7:0]  mus_rd_cnt;
    reg  [7:0]  b_seq;         // B: A's frame_cnt low byte (blink phase)
    reg  [2:0]  copy_mode;
    // 17 bit since C9: one full pass is 83,712 blocks (8 x 19,200 + 6,912) and a
    // 16-bit counter would wrap at 65,536, leaving b_hi_ready waiting forever.
    wire [16:0] img_rx_got;

    // SDRAM clients used by the picture carousel.  Node A pushes its pictures
    // to node B, so A needs a read client and B needs a write client.  Both are
    // declared here (before the per-role generate) because the SDRAM mux that
    // lives after it has to see them.
    wire        push_rd_valid, push_rd_ready, push_rvalid;
    wire [20:0] push_rd_addr;
    wire [31:0] push_rdata;
    wire        recv_wr_valid, recv_wr_ready;
    wire [20:0] recv_wr_addr;
    wire [31:0] recv_wr_data;

    // 150 MHz SDRAM domain.  These MUST be declared before the generate blocks:
    // the picture pusher (g_master) and the picture receiver (g_slave) take
    // their clk150/rst150 from them.  While the declarations sat ~400 lines
    // BELOW the generate blocks, Verilog quietly created implicit undriven nets
    // for those uses, so both modules ran their 150 MHz half with NO CLOCK and a
    // stuck reset.  Symptom: node A pushed exactly zero picture blocks and node
    // B never had a picture, while everything else (video, link, SDRAM
    // self-test, music) worked.  Simulation never caught it because the
    // testbenches instantiate wall_img_push / wall_img_recv directly and wire
    // the clocks themselves.
    wire sdr_clk_150m, sdr_clk_150m_shift, sdr_clk_unused, sdr_pll_lock;
    wire sdr_rst_n;

    generate
    //=========================================================================
    if (IS_MASTER != 0) begin : g_master
    //=========================================================================
        assign o_link_bvld = 1'b0;
        assign o_link_bd   = 4'h0;
        assign b_align     = 1'b0;
        assign frozen_w    = 1'b0;
        assign img_rx_got  = 17'd0;
        // (push_blocks/push_cur_blk are driven by the pusher above)

        // 6.25 MHz nibble clock derived from the 25 MHz pixel clock
        // The nibble clock must free-run from power-up: node B derives its own
        // link-domain reset by sampling logic_rst with this clock, so gating it
        // during reset would leave B's link logic permanently unreset.
        reg [1:0] ncnt  = 2'd0;
        reg       lclk_r = 1'b0;
        always @(posedge pixel_clk) begin
            ncnt   <= ncnt + 2'd1;
            lclk_r <= ~ncnt[1];
        end
        wire en_tx = (ncnt == 2'd2);
        wire en_rx = (ncnt == 2'd3);
        assign o_link_clk = lclk_r;

        // Frame-sync pulse for node B (2 link clocks wide, edge-detected there)
        reg [3:0] sync_cnt;
        always @(posedge pixel_clk) begin
            if (logic_rst)           sync_cnt <= 4'd0;
            else if (sof_c)        sync_cnt <= 4'd8;
            else if (sync_cnt != 4'd0) sync_cnt <= sync_cnt - 4'd1;
        end
        assign o_link_sync = (sync_cnt != 4'd0);

        // STATE broadcast
        reg tx_tog;
        always @(posedge pixel_clk) begin
            if (logic_rst) tx_tog <= 1'b0;
            else if (sof_c) tx_tog <= ~tx_tog;
        end

        wire       tx_vld;
        wire [3:0] tx_d;
        wire       tx_busy;     // STATE frame in flight
        wall_link_tx #(.FRAME_TYPE(8'h01), .KIND(0)) u_tx (
            .clk(pixel_clk), .rst(logic_rst), .en(en_tx),
            .start_tog(tx_tog),
            .seq(frame_cnt[7:0]), .car_cyc(car_cyc),
            .t_fade(fade_gain), .t_car(car_auto_w), .t_adj(adj_on), .t_tlvl(alb_level),
            .t_bc_id(tx_bc_id), .t_bc_b(tx_bc_b), .t_bc_c(tx_bc_c),
            .t_osd(osd_loc), .t_mute(mute_loc), .t_marq(m_on_loc), .t_mp8(frame_cnt[8]),
            .anim(snap_anim), .sel(snap_sel), .mode(mode_sw), .tbl(snap_tbl),
        .t_mok(music_ok), .t_lvl(lvl3),
            .p0(8'h00), .p1(8'h00), .p2(8'h00), .ipay(280'd0),
            .o_vld(tx_vld), .o_d(tx_d), .busy(tx_busy)
        );

        // ---- picture push: only A has a card ------------------------------
        // The 288x216 RGB565 words live in A's SDRAM; every 16-word block is
        // shipped as one KIND-2 frame, so a window that crosses the seam shows
        // the same photo on both halves.  `allow` keeps the image frames out of
        // the line where the STATE frame goes out -- they share the wire.
        wire         img_start, img_tx_busy, img_vld;
        wire [3:0]   img_tx_d;
        wire [279:0] img_pay;
        localparam IMG_PUSH_EN = 1'b1;
        wall_img_push u_push (
            .clk(pixel_clk), .rst(logic_rst),
            .allow(IMG_PUSH_EN && (y_c >= 11'd4) && (y_c <= 11'd472) && !tx_busy),
            .tx_busy(img_tx_busy), .start_tog(img_start), .pay(img_pay),
            .cur_blk(push_cur_blk), .blocks(push_blocks), .dbg(push_dbg),
            .clk150(sdr_clk_150m), .rst150(~sdr_rst_n),
            .rd_valid(push_rd_valid), .rd_addr(push_rd_addr), .rd_ready(push_rd_ready),
            .rvalid(push_rvalid), .rdata(push_rdata)
        );
        // node A has no receiver: keep B's write client quiet
        assign recv_wr_valid = 1'b0;
        assign recv_wr_addr  = 21'd0;
        assign recv_wr_data  = 32'd0;
        wall_link_tx #(.FRAME_TYPE(8'h03), .KIND(2)) u_tx_img (
            .clk(pixel_clk), .rst(logic_rst), .en(en_tx),
            .start_tog(img_start),
            .seq(8'd0), .anim(5'd0), .sel(2'd0), .tbl(256'd0), .t_tlvl(5'd0),
            .t_osd(1'b1), .t_mute(1'b0), .t_marq(1'b0), .t_mp8(1'b0),
            .p0(8'd0), .p1(8'd0), .p2(8'd0), .ipay(img_pay),
            .o_vld(img_vld), .o_d(img_tx_d), .busy(img_tx_busy)
        );

        // The STATE frame wins the wire: it is what keeps the two nodes in
        // step, and an image block that gets clipped is simply re-sent on the
        // next carousel pass.
        assign o_link_vld = tx_vld | img_vld;
        assign o_link_d   = tx_vld ? tx_d : img_tx_d;

        // INPUT receiver
        wire        rx_frame;
        wire [7:0]  rx_type, rx_len;
        wire [319:0] rx_payload;
        wall_link_rx u_rx (
            .clk(pixel_clk), .rst(logic_rst), .en(en_rx),
            .i_d(i_link_bd), .i_vld(i_link_bvld),
            .frame(rx_frame), .f_type(rx_type), .f_len(rx_len),
            .payload(rx_payload), .err_cnt(stat_err), .ok_cnt(stat_ok)
        );

        reg [3:0]  rpress;
        reg [15:0] age;
        always @(posedge pixel_clk) begin
            if (logic_rst) begin
                rpress <= 4'd0;
                age    <= 16'hFFFF;
            end else begin
                rpress <= 4'd0;
                if (rx_frame && rx_type == 8'h02) begin
                    rpress <= rx_payload[11:8];      // byte1 = press pulses
                    age    <= 16'd0;
                end else if (sof_c) begin
                    if (age != 16'hFFFF) age <= age + 16'd1;
                end
            end
        end
        assign remote_press = rpress | auto_press;
        assign link_ok = (age < 16'd12) && !logic_rst;

        wire [3:0] local_press;
        // Which switch position counts as 1.  The board's SW1..SW4 short the pin
        // to GND in one position, so flip this if ??/?? come out swapped.
        localparam SW_INV = 1'b1;   // bench-verified: both switches read inverted

        // Held-time threshold for the 4 px step: 0.5 s of the 25 MHz pixel clock.
        localparam [23:0] ACC_THR = 24'd12500000;

        // mute_in/osd_in are declared at MODULE scope (see above): wall_input
        // drives them here, and the mute_r/osd_r registers at module scope read
        // them.  A second declaration here would make TD and ModelSim disagree
        // about which net the module-scope readers see (that exact mistake made
        // node B's fade gain 0 -> black pictures).

    wall_input #(.FORCE_DIRS((IS_MASTER != 0) ? AUTODRAG : 0)) u_in (
            .clk(pixel_clk), .rst(logic_rst), .key_n(key_n), .sw_n((~sw_n) ^ {4{SW_INV}}),
            .remote_press(remote_press), .commit(sof_c), .db_cyc(db_cyc_w), .rep_cyc(rep_cyc_w),
            .acc_thr(ACC_THR),
            .cur_sel(cur_sel), .stage_word(stage_word), .rd_idx(rd_idx),
            .set_tbl(a_set_tbl), .set_idx(a_set_idx), .set_data(a_set_data),
            .set_sel(a_set_sel), .sel_out(a_sel_in),
            .local_press(local_press), .evt_valid(a_evt_valid), .evt_gx(a_evt_gx),
            .dbg_mode(), .mode_out(mode_sw),
            .mute(mute_in), .osd_en(osd_in),
            .car_toggle(car_toggle), .car_step(car_step),
            .adj_ev(adj_ev), .adj_con(adj_con), .adj_up(adj_up), .adj_on(adj_on),
        .adj_rst_b(adj_rst_b), .adj_rst_c(adj_rst_c),
        .alb_next(alb_next), .alb_prev(alb_prev), .marquee_on(m_on_loc), .album_out(album_a)
        );
        assign a_set_anim = sof_d;
        assign a_anim_in  = frame_cnt[9:5];

        // ---- carousel phase + fade (node A owns it) -------------------------
        // 256-frame cycle: 224 frames hold, 16 fade out, 16 fade in; the picture
        // index steps at the black point.  KEY4 (VIEW mode) toggles auto, KEY3
        // steps one picture while auto is off.  The envelope lives in
        // wall_carousel so it can be simulated on its own; the phase, the gain
        // and the auto flag are all broadcast (STATE bytes 2/3/4), which is what
        // lets B dim and switch on exactly the same frame -- a fade computed on B
        // alone cannot work, because B learns the new phase one frame late.
        // A key pulse lasts ONE pixel clock and the carousel only looks at
        // sof_c, so the two would essentially never coincide (1 in 350k).  Latch
        // each press here and let the frame boundary consume it.
        reg       car_tog_l, car_step_l;

        always @(posedge pixel_clk) begin
            if (logic_rst) begin
                car_tog_l <= 1'b0; car_step_l <= 1'b0;
            end else begin
                if (car_toggle) car_tog_l  <= 1'b1;
                else if (sof_c) car_tog_l  <= 1'b0;
                if (car_step)   car_step_l <= 1'b1;
                else if (sof_c) car_step_l <= 1'b0;
            end
        end

        wall_carousel u_car (
            .clk(pixel_clk), .rst(logic_rst), .frame(sof_c),
            .toggle(car_tog_l), .step(car_step_l),
            .cyc(car_cyc), .auto_on(car_auto_w), .gain(fade_gain)
        );

        // ---- per-picture brightness/contrast (W3.5) ------------------------
        // 4 pictures x {brightness, contrast}, 0x80/0x80 = neutral.  The keys
        // adjust the picture that the SELECTED window shows right now
        // (slot + carousel phase), so a setting follows the photograph through
        // the rotation instead of sticking to a window.  The peer gets one
        // picture per frame (round robin below), so it converges in 4 frames.
        reg [63:0] bc_tbl_a;
        wire [1:0] adj_pic   = cur_sel + car_cyc;
        wire [7:0] adj_b_cur = bc_tbl_a[{adj_pic, 4'b0000} +: 8];
        wire [7:0] adj_c_cur = bc_tbl_a[{adj_pic, 4'b0000} + 8 +: 8];

        always @(posedge pixel_clk) begin
            if (logic_rst) begin
                bc_tbl_a <= 64'h8080_8080_8080_8080;
            end else if (adj_rst_b) begin
                // KEY3+KEY4 held for a second: this picture back to neutral
                bc_tbl_a[{adj_pic, 4'b0000} +: 8] <= 8'h80;
            end else if (adj_rst_c) begin
                // KEY1+KEY2 held for a second
                bc_tbl_a[{adj_pic, 4'b0000} + 8 +: 8] <= 8'h80;
            end else if (adj_ev) begin
                if (adj_con) begin
                    bc_tbl_a[{adj_pic, 4'b0000} + 8 +: 8] <=
                        adj_up ? ((adj_c_cur > 8'hF7) ? 8'hFF : (adj_c_cur + 8'h08))
                               : ((adj_c_cur < 8'h28) ? 8'h20 : (adj_c_cur - 8'h08));
                end else begin
                    bc_tbl_a[{adj_pic, 4'b0000} +: 8] <=
                        adj_up ? ((adj_b_cur > 8'hF7) ? 8'hFF : (adj_b_cur + 8'h08))
                               : ((adj_b_cur < 8'h08) ? 8'h00 : (adj_b_cur - 8'h08));
                end
            end
        end

        // round-robin broadcast: latch one picture's pair at each frame start so
        // the value cannot change in the middle of a frame's transmission
        always @(posedge pixel_clk) begin
            if (logic_rst) begin
                bc_rr    <= 2'd0;
                tx_bc_b  <= 8'h80;
                tx_bc_c  <= 8'h80;
                tx_bc_id <= 2'd0;
            end else if (sof_c) begin
                tx_bc_b  <= bc_tbl_a[{bc_rr, 4'b0000} +: 8];
                tx_bc_c  <= bc_tbl_a[{bc_rr, 4'b0000} + 8 +: 8];
                tx_bc_id <= bc_rr;
                bc_rr    <= bc_rr + 2'd1;
            end
        end

        assign bc_tbl  = bc_tbl_a;

    end
    //=========================================================================
    else begin : g_slave
    //=========================================================================
        assign o_link_clk  = 1'b0;
        assign o_link_sync = 1'b0;
        assign o_link_vld  = 1'b0;
        assign o_link_d    = 4'h0;
        // B mirrors A's phase, fade gain and auto flag from the STATE frame, so
        // both halves of the wall dim and switch on the same frame.
        assign car_cyc     = copy_car_cyc;
        assign fade_gain   = copy_fade;
        assign car_auto_w  = copy_car;
        assign bc_tbl      = bc_tbl_b;
        assign adj_on      = copy_adj;   // mirrored so B's caption lights too
        assign remote_press = 4'd0;       // the slave has no INPUT receiver (keeps TD's log clean)
        // B has no switches and no album sequencer: the album record reaches it
        // in the STATE frame's window table like every other record.
        assign album_a      = 1'b0;
        assign alb_next     = 1'b0;
        assign alb_prev     = 1'b0;

        // carousel phase: captured from the STATE payload byte that also carries
        // mode/sel (see the copy_idx == 2 branch below).
        assign mode_sw  = copy_mode;

        // Link-domain reset: 2FF of the pixel-domain reset.
        reg [2:0] lrst;
        always @(posedge i_link_clk) lrst <= {lrst[1:0], logic_rst};
        wire link_rst = lrst[2] | lrst[1];

        // ---- STATE receiver (link domain) --------------------------------
        wire         s_frame;
        wire [7:0]   s_type, s_len;
        wire [319:0] s_payload;

        wall_link_rx u_rx (
            .clk(i_link_clk), .rst(link_rst), .en(1'b1),
            .i_d(i_link_d), .i_vld(i_link_vld),
            .frame(s_frame), .f_type(s_type), .f_len(s_len),
            .payload(s_payload), .err_cnt(stat_err), .ok_cnt(stat_ok)
        );

        // The toggle doubles as the buffer index: the buffer just written is
        // ~rx_tog, so the pixel domain only has to synchronise one bit.
        reg [319:0] rxb [0:1];
        reg         rx_tog;
        always @(posedge i_link_clk) begin
            if (link_rst) begin
                rxb[0] <= 320'd0;
                rxb[1] <= 320'd0;
                rx_tog <= 1'b0;
                // Uninitialised here means 0 on the FPGA, and a fade gain of 0
                // multiplies every picture to black (that is exactly what node B
                // did).  Default to full brightness / phase 0.
            end else if (s_frame && s_type == 8'h01) begin
                rxb[rx_tog] <= s_payload;
                rx_tog      <= ~rx_tog;
                b_seq       <= s_payload[7:0];   // A's frame_cnt: blink phase
            end
        end

        // ---- picture receiver: A owns the card, B writes its own SDRAM -----
        // B has no SD card, so the only way its 288x216 pictures arrive is this
        // path.  The receiver writes straight into B's SDRAM picture blocks.
        wall_img_recv u_img_rx (
            .lclk(i_link_clk), .lrst(link_rst),
            .frame(s_frame), .f_type(s_type), .payload(s_payload),
            .pclk(pixel_clk), .prst(logic_rst),
            .got(img_rx_got), .step(),
            .clk150(sdr_clk_150m), .rst150(~sdr_rst_n),
            .wr_valid(recv_wr_valid), .wr_addr(recv_wr_addr),
            .wr_data(recv_wr_data), .wr_ready(recv_wr_ready)
        );
        // node B has no pusher: keep A's read client quiet
        assign push_rd_valid = 1'b0;
        assign push_rd_addr  = 21'd0;
        assign push_blocks   = 16'd0;
        assign push_cur_blk  = 17'd0;
        assign push_dbg      = 8'h00;

        // ---- INPUT transmitter (link domain) -----------------------------
        reg         in_tog;          // owned by the pixel domain
        reg  [23:0] in_payload;
        reg  [2:0]  in_sync;
        reg         in_seen;
        reg         tx_start;
        reg  [23:0] tx_pay;

        always @(posedge i_link_clk) begin
            if (link_rst) begin
                in_sync  <= 3'd0;
                in_seen  <= 1'b0;
                tx_start <= 1'b0;
                tx_pay   <= 24'd0;
            end else begin
                in_sync <= {in_sync[1:0], in_tog};
                if (in_sync[2] != in_seen) begin
                    in_seen  <= in_sync[2];
                    tx_start <= ~tx_start;
                    tx_pay   <= in_payload;
                end
            end
        end

        wire       btx_vld;
        wire [3:0] btx_d;
        wall_link_tx #(.FRAME_TYPE(8'h02), .KIND(1)) u_tx (
            .clk(i_link_clk), .rst(link_rst), .en(1'b1),
            .start_tog(tx_start),
            .seq(8'd0), .anim(5'd0), .car_cyc(2'd0), .sel(2'd0), .tbl(256'd0), .t_tlvl(5'd0),
            .t_osd(1'b1), .t_mute(1'b0), .t_marq(1'b0), .t_mp8(1'b0),
            .p0(tx_pay[7:0]), .p1(tx_pay[15:8]), .p2(tx_pay[23:16]),
            .o_vld(btx_vld), .o_d(btx_d), .busy()
        );
        assign o_link_bvld = btx_vld;
        assign o_link_bd   = btx_d;

        // ---- Frame sync (link -> pixel) ----------------------------------
        reg s1, s2, s3;
        always @(posedge pixel_clk) begin
            s1 <= i_link_sync;
            s2 <= s1;
            s3 <= s2;
        end
        assign b_align = s2 & ~s3;

        // ---- Keys (pixel domain) -----------------------------------------
        reg [3:0]  k0, k1, kd;
        reg [16:0] dc0, dc1, dc2, dc3;
        reg [3:0]  press, levels;
        always @(posedge pixel_clk) begin
            if (logic_rst) begin
                k0 <= 4'hF; k1 <= 4'hF; kd <= 4'hF;
                dc0 <= 17'd0; dc1 <= 17'd0; dc2 <= 17'd0; dc3 <= 17'd0;
                press <= 4'd0;
                levels <= 4'd0;
            end else begin
                k0 <= key_n;
                k1 <= k0;
                press <= 4'd0;
                if (k1[0] != kd[0]) begin
                    if (dc0 == DB_CYC[16:0] - 17'd1) begin dc0 <= 17'd0; kd[0] <= k1[0]; if (!k1[0]) press[0] <= 1'b1; end
                    else dc0 <= dc0 + 17'd1;
                end else dc0 <= 17'd0;
                if (k1[1] != kd[1]) begin
                    if (dc1 == DB_CYC[16:0] - 17'd1) begin dc1 <= 17'd0; kd[1] <= k1[1]; if (!k1[1]) press[1] <= 1'b1; end
                    else dc1 <= dc1 + 17'd1;
                end else dc1 <= 17'd0;
                if (k1[2] != kd[2]) begin
                    if (dc2 == DB_CYC[16:0] - 17'd1) begin dc2 <= 17'd0; kd[2] <= k1[2]; if (!k1[2]) press[2] <= 1'b1; end
                    else dc2 <= dc2 + 17'd1;
                end else dc2 <= 17'd0;
                if (k1[3] != kd[3]) begin
                    if (dc3 == DB_CYC[16:0] - 17'd1) begin dc3 <= 17'd0; kd[3] <= k1[3]; if (!k1[3]) press[3] <= 1'b1; end
                    else dc3 <= dc3 + 17'd1;
                end else dc3 <= 17'd0;
                levels <= ~kd;
            end
        end

        reg [3:0] press_acc;
        always @(posedge pixel_clk) begin
            if (logic_rst) begin
                press_acc  <= 4'd0;
                in_payload <= 24'd0;
                in_tog     <= 1'b0;
            end else if (sof_c) begin
                in_payload <= {frame_cnt[7:0], {4'b0000, (press_acc | press)}, {4'b0000, levels}};
                in_tog     <= ~in_tog;
                press_acc  <= 4'd0;
            end else begin
                press_acc <= press_acc | press;
            end
        end

        // ---- STATE copy (link -> pixel) ----------------------------------
        // Mirrors the TX payload layout documented in wall_link.v: byte 1 anim,
        // byte 2 mode/sel/cyc, byte 3 fade gain, byte 4 car_auto, bytes 5..36 the
        // window table.  Byte 0 (seq) is used by the link-domain capture above.
        reg        rx_t1, rx_t2, rx_seen;
        reg        copy_act;
        reg [5:0]  copy_idx;
        reg [5:0]  copy_left;
        reg [1:0]  copy_sel;
        reg [4:0]  copy_anim;
        // copy_car_cyc/copy_fade/copy_car are declared at MODULE scope on
        // purpose: they are driven here but consumed by the `assign car_cyc /
        // fade_gain / car_auto_w` lines above.  Declaring them twice (once here,
        // once at module scope) made TD bind those assigns to the undriven
        // outer copies while ModelSim used the inner ones -- simulation passed
        // and the board ran with fade=0 and car_cyc=0 on node B (black
        // pictures, carousel out of step).  Keep exactly one declaration.
        reg [7:0]  bc_b_r, bc_c_r;     // brightness/contrast byte being assembled
        reg [63:0] copy_w0, copy_w1, copy_w2, copy_w3;
        reg [9:0]  b_age;
        reg        red_clear;
        reg [1:0]  wr_phase;

        wire [7:0] cpb = rxb[~rx_t2][{copy_idx, 3'b000} +: 8];

        always @(posedge pixel_clk) begin
            if (logic_rst) begin
                rx_t1 <= 1'b0; rx_t2 <= 1'b0; rx_seen <= 1'b0;
                copy_act <= 1'b0; copy_idx <= 6'd0; copy_left <= 6'd0;
                copy_sel <= 2'd0; copy_anim <= 5'd0;
                copy_car_cyc <= 2'd0; copy_fade <= 8'hFF; copy_car <= 1'b0;
                copy_adj <= 1'b0;
                copy_osd <= 1'b1;      // UI visible until the peer says otherwise
                copy_mute <= 1'b0;
                // before the first STATE frame arrives the peer must NOT be
                // blacked out, so start the transition dimmer at full
                copy_tlvl <= 5'd16;
                bc_tbl_b <= 64'h8080_8080_8080_8080; bc_b_r <= 8'h80; bc_c_r <= 8'h80;
                copy_w0 <= 64'd0; copy_w1 <= 64'd0;
                copy_w2 <= 64'd0; copy_w3 <= 64'd0;
                b_age <= 10'd1023; wr_phase <= 2'd0;
                b_set_tbl <= 1'b0; b_set_idx <= 2'd0; b_set_data <= 64'd0;
                b_set_sel <= 1'b0; b_sel_in <= 2'd0;
                b_set_anim <= 1'b0; b_anim_in <= 5'd0;
            end else begin
                rx_t1 <= rx_tog;
                rx_t2 <= rx_t1;

                b_set_tbl  <= 1'b0;
                b_set_sel  <= 1'b0;
                b_set_anim <= 1'b0;
                red_clear  <= 1'b0;

                if (rx_t2 != rx_seen) begin
                    rx_seen  <= rx_t2;
                    b_age    <= 10'd0;
                    copy_act <= 1'b1;
                    copy_idx <= 6'd0;
                end else if (sof_c && b_age != 10'd1023) begin
                    b_age <= b_age + 10'd1;
                end

                if (copy_act) begin
                    if (copy_idx == 6'd0) begin
                        copy_idx <= 6'd1;
                    end else if (copy_idx == 6'd1) begin
                        copy_anim <= cpb[4:0];
                        copy_lvl  <= cpb[7:5];      // peer's audio level (same byte)
                        copy_idx  <= 6'd2;
                    end else if (copy_idx == 6'd2) begin
                        copy_sel <= cpb[1:0];
                        // bits 7:6 of THIS byte are the carousel phase (the TX puts
                        // {car_cyc, t_mok, mode, sel} here).  Reading them from
                        // s_payload with a hand-counted index was wrong: payload
                        // byte N is sent at bi = N+3, so [47:46] was a table byte.
                        copy_car_cyc <= cpb[7:6];
                        copy_mode    <= cpb[4:2];
                        copy_mok     <= cpb[5];
                        copy_idx     <= 6'd3;
                    end else if (copy_idx == 6'd3) begin
                        copy_fade <= cpb;          // byte 3: fade gain
                        copy_idx  <= 6'd4;
                    end else if (copy_idx == 6'd4) begin
                        copy_car  <= cpb[0];       // byte 4: car_auto
                        copy_adj  <= cpb[1];       // byte 4: the master is in ADJUST mode
                        copy_tlvl <= cpb[6:2];     // byte 4: C5 transition level (0..16)
                        copy_mp8  <= cpb[7];       // byte 4 bit7: marquee phase bit 8
                        copy_idx  <= 6'd5;
                    end else if (copy_idx <= 6'd36) begin
                        // payload byte 5..36 -> table bytes 0..31 (little endian)
                        case ((copy_idx - 6'd5) >> 3)
                            2'd0: copy_w0[((copy_idx - 6'd5) & 6'd7)*8 +: 8] <= cpb;
                            2'd1: copy_w1[((copy_idx - 6'd5) & 6'd7)*8 +: 8] <= cpb;
                            2'd2: copy_w2[((copy_idx - 6'd5) & 6'd7)*8 +: 8] <= cpb;
                            default: copy_w3[((copy_idx - 6'd5) & 6'd7)*8 +: 8] <= cpb;
                        endcase
                        copy_idx <= copy_idx + 6'd1;
                    end else if (copy_idx == 6'd37) begin
                        bc_b_r   <= cpb;               // brightness of this picture
                        copy_idx <= 6'd38;
                    end else if (copy_idx == 6'd38) begin
                        bc_c_r   <= cpb;               // contrast of this picture
                        copy_idx <= 6'd39;
                    end else if (copy_idx == 6'd39) begin
                        // byte 39 says which picture these two bytes belong to;
                        // C6 puts the UI-visible and muted flags in its spare bits
                        bc_tbl_b[{cpb[1:0], 4'b0000} +: 8]      <= bc_b_r;
                        bc_tbl_b[{cpb[1:0], 4'b0000} + 8 +: 8] <= bc_c_r;
                        copy_osd  <= cpb[2];
                        copy_mute <= cpb[3];
                        copy_marq <= cpb[4];       // byte 39 bit4: marquee on/off
                        copy_idx <= 6'd40;
                    end else begin
                        copy_act <= 1'b0;
                        wr_phase <= 2'd1;
                        b_set_tbl  <= 1'b1; b_set_idx <= 2'd0; b_set_data <= copy_w0;
                        b_set_sel  <= 1'b1; b_sel_in  <= copy_sel;
                        b_set_anim <= 1'b1; b_anim_in <= copy_anim;
                        red_clear  <= 1'b1;
                    end
                end else if (wr_phase != 2'd0) begin
                    b_set_tbl  <= 1'b1;
                    b_set_idx  <= wr_phase;
                    b_set_data <= (wr_phase == 2'd1) ? copy_w1 :
                                  (wr_phase == 2'd2) ? copy_w2 : copy_w3;
                    wr_phase   <= (wr_phase == 2'd3) ? 2'd0 : (wr_phase + 2'd1);
                end
            end
        end

        // A new STATE frame every 16.7 ms; six missed frames means link down.
        assign link_ok = (b_age < 10'd6) && !logic_rst;

        // Sticky FROZEN badge: raised when the peer stops sending, cleared
        // by the first good table copy after the link returns.
        reg frozen_r;
        always @(posedge pixel_clk) begin
            if (logic_rst) frozen_r <= 1'b0;
            else if (sof_c && !link_ok) frozen_r <= 1'b1;
            else if (red_clear) frozen_r <= 1'b0;
        end
        assign frozen_w = frozen_r;
    end
    endgenerate

    assign align_pix = (IS_MASTER != 0) ? 1'b0 : b_align;

    // Drag-end event snapshot: retired.  The owner-after-drag bug it was built
    // to chase (docs/02_bringup_log.md 9) only ever reproduced under the
    // autodrag stimulus, and the two status bytes it used now carry the SD
    // probe (sd_state / sd_b0).  wall_input keeps producing evt_valid/evt_gx
    // for the next debugger; they are simply not exported any more.

    //=========================================================================
    // SDRAM subsystem (APUG011 hard macro) -- W2 image library foundation
    //
    // The whole 150 MHz domain is the board-proven P1-05A chain, unchanged:
    //   sdram_arbiter -> p1_sdram_cached_adapter -> apug011_core_wrapper
    //   -> EG_PHY_SDRAM_2M_32
    // Right now the only client is a power-on read/write self-test so the
    // memory path can be validated over the status UART before any media logic
    // depends on it.
    //=========================================================================
    // 150 MHz SDRAM clock tree (the wire declarations live ABOVE the generate
    // blocks -- see the note next to push_rd_valid).
    //=========================================================================
    clk_pll u_sdram_pll (
        .refclk  (pixel_clk),
        .reset   (!pll_lock),
        .extlock (sdr_pll_lock),
        .clk0_out(sdr_clk_unused),
        .clk1_out(sdr_clk_150m),
        .clk2_out(sdr_clk_150m_shift)
    );

    assign sdr_rst_n = sdr_pll_lock && pll_lock && por_done;

    wire        sdr_mem_rd_valid, sdr_mem_rd_ready, sdr_mem_rvalid;
    wire [20:0] sdr_mem_rd_addr;
    wire [31:0] sdr_mem_rdata;
    wire        sdr_mem_wr_valid, sdr_mem_wr_ready;
    wire [20:0] sdr_mem_wr_addr;
    wire [31:0] sdr_mem_wr_data;

    wire        t_wr_valid, t_wr_ready, t_rd_valid, t_rd_ready, t_rvalid;
    wire [20:0] t_wr_addr, t_rd_addr;
    wire [31:0] t_wr_data, t_rdata;

    // self-test results (declared here: the client mux below needs them)
    wire        sdram_test_done, sdram_test_failed;
    wire [15:0] sdram_test_errors, sdram_test_checked;

    // The arbiter has one read client: the power-on self-test owns it until it
    // completes, four clients share the port:
    //   reads : picture line-buffer burst (A and B) > picture push (A only) >
    //           music single word
    //   writes: MUSIC.WAV loader words (A only) / received picture blocks (B only)
    // The picture burst wins whenever it wants the port; the push and the music
    // word slip into the burst's response gaps, so a burst is delayed by only
    // ~one word per 48 kHz tick / per pushed block.
    wire        c_wr_valid, c_wr_ready, c_rd_valid, c_rd_ready, c_rvalid;
    wire [20:0] c_wr_addr, c_rd_addr;
    wire [31:0] c_wr_data, c_rdata;

    // read clients: picture line buffer, picture push, music
    wire        pic_rd_valid, pic_rd_ready, pic_rvalid;
    wire        pic_busy;   // line-buffer burst in progress (see the priority note)
    wire [20:0] pic_rd_addr;
    wire [31:0] pic_rdata;
    wire        mus_rd_ready, mus_rvalid;
    wire        mus_wr_ready;
    // 1 = pic, 2 = push, 3 = music (the outstanding read's owner)
    reg  [1:0]  rd_owner;

    // Priority: the line-buffer burst wins outright, and the pusher is confined
    // to the blanking interval.  This is not about fairness: the cached adapter
    // holds ONE 4-word group, so a single foreign read between two words of a
    // group evicts the cache and turns the burst's 3-of-4 hits into misses.
    // While the pusher interleaved freely, a row burst took several times longer
    // than one line; the bank swap then missed its deadline where 2-3 windows
    // are visible at once (the upper screen) and those windows visibly jittered.
    //
    // The gate is registered in the 150 MHz domain on purpose: feeding de_c
    // combinationally into the read mux opened a 25 MHz -> 150 MHz path into the
    // adapter's address capture and A fell to SWNS -1.29 ns.
    reg  [1:0] de_150_sync;
    always @(posedge sdr_clk_150m or negedge sdr_rst_n) begin
        if (!sdr_rst_n) de_150_sync <= 2'b11;
        else            de_150_sync <= {de_150_sync[0], de_c};
    end
    // Split this path with a register: de_150_sync -> the read mux -> the adapter's
    // cache-compare capture was 6.427 ns of a 6.666 ns budget (SWNS -0.113 ns).
    reg  push_gate;
    always @(posedge sdr_clk_150m or negedge sdr_rst_n) begin
        if (!sdr_rst_n) push_gate <= 1'b0;
        else            push_gate <= ~de_150_sync[1];   // 1 = blanking, port free
    end

    wire pic_req  = pic_rd_valid;
    // The pusher must ALSO defer to the line buffer in the ready path, not just
    // in the valid path.  With "push_req = push_gate && push_rd_valid" the two
    // clients could request in the same cycle: the arbiter then read the LINE
    // BUFFER's address (pic wins) while push_rd_ready still pulsed 1, so the
    // pusher dropped rd_valid, never saw its response (rd_owner routed it to the
    // pic) and deadlocked forever.  Symptom: the push block counter froze a few
    // dozen blocks after power-on and node B never completed a carousel pass.
    wire push_req = push_gate && push_rd_valid && !pic_rd_valid;
    wire mus_req  = !pic_req && !push_req && mus_rd_valid;

    assign c_wr_valid = sdram_test_done ? (mus_wr_valid | recv_wr_valid) : t_wr_valid;
    assign c_wr_addr  = sdram_test_done ? (mus_wr_valid ? mus_wr_addr : recv_wr_addr) : t_wr_addr;
    assign c_wr_data  = sdram_test_done ? (mus_wr_valid ? mus_wr_data : recv_wr_data) : t_wr_data;
    assign c_rd_valid = sdram_test_done ? (pic_req | push_req | mus_req) : t_rd_valid;
    assign c_rd_addr  = sdram_test_done ? (pic_req ? pic_rd_addr :
                                           push_req ? push_rd_addr : mus_rd_addr) : t_rd_addr;

    assign pic_rd_ready  = sdram_test_done ? (pic_req  ? c_rd_ready : 1'b0) : 1'b0;
    assign push_rd_ready = sdram_test_done ? (push_req ? c_rd_ready : 1'b0) : 1'b0;
    assign mus_rd_ready  = sdram_test_done ? (mus_req  ? c_rd_ready : 1'b0) : 1'b0;
    assign mus_wr_ready  = sdram_test_done ? (mus_wr_valid ? c_wr_ready : 1'b0) : 1'b0;
    assign recv_wr_ready = sdram_test_done ? (recv_wr_valid ? c_wr_ready : 1'b0) : 1'b0;

    assign pic_rvalid  = sdram_test_done ? ((rd_owner == 2'd1) ? c_rvalid : 1'b0) : 1'b0;
    assign push_rvalid = sdram_test_done ? ((rd_owner == 2'd2) ? c_rvalid : 1'b0) : 1'b0;
    assign mus_rvalid  = sdram_test_done ? ((rd_owner == 2'd3) ? c_rvalid : 1'b0) : 1'b0;
    assign pic_rdata   = c_rdata;
    assign push_rdata  = c_rdata;
    assign t_wr_ready = sdram_test_done ? 1'b0 : c_wr_ready;
    assign t_rd_ready = sdram_test_done ? 1'b0 : c_rd_ready;
    assign t_rvalid   = sdram_test_done ? 1'b0 : c_rvalid;
    assign t_rdata    = c_rdata;

    // Remember whose request was accepted so the response is routed back to the
    // right client (the response arrives several cycles after the request).
    always @(posedge sdr_clk_150m or negedge sdr_rst_n) begin
        if (!sdr_rst_n) rd_owner <= 2'd0;
        else if (sdram_test_done && c_rd_valid && c_rd_ready)
            rd_owner <= pic_req ? 2'd1 : push_req ? 2'd2 : 2'd3;
    end

    wire        arb_protocol_error;
    sdram_arbiter u_sdram_arbiter (
        .clk                     (sdr_clk_150m),
        .rst_n                   (sdr_rst_n),
        .wr_valid                (c_wr_valid),
        .wr_addr                 (c_wr_addr),
        .wr_data                 (c_wr_data),
        .wr_ready                (c_wr_ready),
        .rd_valid                (c_rd_valid),
        .rd_addr                 (c_rd_addr),
        .rd_ready                (c_rd_ready),
        .rd_rvalid               (c_rvalid),
        .rd_rdata                (c_rdata),
        .mem_wr_valid            (sdr_mem_wr_valid),
        .mem_wr_addr             (sdr_mem_wr_addr),
        .mem_wr_data             (sdr_mem_wr_data),
        .mem_wr_ready            (sdr_mem_wr_ready),
        .mem_rd_valid            (sdr_mem_rd_valid),
        .mem_rd_addr             (sdr_mem_rd_addr),
        .mem_rd_ready            (sdr_mem_rd_ready),
        .mem_rvalid              (sdr_mem_rvalid),
        .mem_rdata               (sdr_mem_rdata),
        .protocol_error          (arb_protocol_error),
        .contention_seen         (),
        .rd_outstanding_debug    (),
        .read_accept_count_debug (),
        .write_accept_count_debug()
    );

    wire        sdram_init_done, sdram_init_ref_vld, sdram_busy, app_ref_req;
    wire        app_wr_en, app_rd_en, sdr_rd_en;
    wire [20:0] app_wr_addr, app_rd_addr;
    wire [31:0] app_wr_din;
    wire [3:0]  app_wr_dm;
    wire [31:0] sdr_rd_dout;
    wire        sdram_ready_for_traffic, sdram_adapter_idle;
    wire        adapter_protocol_error, adapter_provider_fault;

    p1_sdram_cached_adapter #(.ENABLE_RUNTIME_DIAGNOSTICS(0)) u_sdram_adapter (
        .clk                     (sdr_clk_150m),
        .rst_n                   (sdr_rst_n),
        .mem_wr_valid            (sdr_mem_wr_valid),
        .mem_wr_addr             (sdr_mem_wr_addr),
        .mem_wr_data             (sdr_mem_wr_data),
        .mem_wr_ready            (sdr_mem_wr_ready),
        .mem_rd_valid            (sdr_mem_rd_valid),
        .mem_rd_addr             (sdr_mem_rd_addr),
        .mem_rd_ready            (sdr_mem_rd_ready),
        .mem_rvalid              (sdr_mem_rvalid),
        .mem_rdata               (sdr_mem_rdata),
        .App_wr_en               (app_wr_en),
        .App_wr_addr             (app_wr_addr),
        .App_wr_din              (app_wr_din),
        .App_wr_dm               (app_wr_dm),
        .App_rd_en               (app_rd_en),
        .App_rd_addr             (app_rd_addr),
        .Sdr_rd_en               (sdr_rd_en),
        .Sdr_rd_dout             (sdr_rd_dout),
        .Sdr_init_done           (sdram_init_done),
        .Sdr_init_ref_vld        (sdram_init_ref_vld),
        .Sdr_busy                (sdram_busy),
        .App_ref_req             (app_ref_req),
        .ready_for_traffic       (sdram_ready_for_traffic),
        .adapter_idle            (sdram_adapter_idle),
        .protocol_error          (adapter_protocol_error),
        .provider_fault          (adapter_provider_fault),
        .contention_seen         (),
        .read_outstanding_debug  (),
        .read_accept_count_debug (),
        .write_accept_count_debug(),
        .app_read_word_count_debug (),
        .app_write_word_count_debug()
    );

    wire        SDRAM_CLK, SDR_RAS, SDR_CAS, SDR_WE;
    wire [1:0]  SDR_BA;
    wire [10:0] SDR_ADDR_O;
    wire [3:0]  SDR_DM;
    wire [31:0] SDR_DQ;

    apug011_core_wrapper u_apug011 (
        .Sdr_clk          (sdr_clk_150m),
        .Sdr_clk_sft      (sdr_clk_150m_shift),
        .rst_n            (sdr_rst_n),
        .Sdr_init_done    (sdram_init_done),
        .Sdr_init_ref_vld (sdram_init_ref_vld),
        .Sdr_busy         (sdram_busy),
        .App_ref_req      (app_ref_req),
        .App_wr_en        (app_wr_en),
        .App_wr_addr      (app_wr_addr),
        .App_wr_dm        (app_wr_dm),
        .App_wr_din       (app_wr_din),
        .App_rd_en        (app_rd_en),
        .App_rd_addr      (app_rd_addr),
        .Sdr_rd_en        (sdr_rd_en),
        .Sdr_rd_dout      (sdr_rd_dout),
        .SDRAM_CLK        (SDRAM_CLK),
        .SDR_RAS          (SDR_RAS),
        .SDR_CAS          (SDR_CAS),
        .SDR_WE           (SDR_WE),
        .SDR_BA           (SDR_BA),
        .SDR_ADDR         (SDR_ADDR_O),
        .SDR_DM           (SDR_DM),
        .SDR_DQ           (SDR_DQ)
    );

    EG_PHY_SDRAM_2M_32 u_internal_sdram (
        .clk   (SDRAM_CLK),
        .ras_n (SDR_RAS),
        .cas_n (SDR_CAS),
        .we_n  (SDR_WE),
        .addr  (SDR_ADDR_O),
        .ba    (SDR_BA),
        .dq    (SDR_DQ),
        .cs_n  (1'b0),
        .dm0   (SDR_DM[0]),
        .dm1   (SDR_DM[1]),
        .dm2   (SDR_DM[2]),
        .dm3   (SDR_DM[3]),
        .cke   (1'b1)
    );

    // Self-test kick: wait ~7 ms after the SDRAM reset releases, then run once.
    reg [19:0] sdr_wait;
    reg        sdram_test_started;
    wire       sdram_test_start = (sdr_wait == 20'hFFFFF) && !sdram_test_started;
    always @(posedge sdr_clk_150m) begin
        if (!sdr_rst_n) begin
            sdr_wait           <= 20'd0;
            sdram_test_started <= 1'b0;
        end else if (!sdram_test_started) begin
            if (sdr_wait == 20'hFFFFF) sdram_test_started <= 1'b1;
            else                       sdr_wait <= sdr_wait + 20'd1;
        end
    end


    wall_sdram_test u_sdram_test (
        .clk(sdr_clk_150m), .rst_n(sdr_rst_n), .start(sdram_test_start),
        .wr_valid(t_wr_valid), .wr_addr(t_wr_addr), .wr_data(t_wr_data), .wr_ready(t_wr_ready),
        .rd_valid(t_rd_valid), .rd_addr(t_rd_addr), .rd_ready(t_rd_ready),
        .rvalid(t_rvalid), .rdata(t_rdata),
        .done(sdram_test_done), .failed(sdram_test_failed),
        .errors(sdram_test_errors), .checked(sdram_test_checked)
    );

    // The test results live in the 150 MHz domain.  They are static once the
    // sweep finishes, so capture them ONCE on a synchronised "done" edge instead
    // of letting the status mux reach across the clock boundary (that CDC cost
    // 3 ns of setup at 150 MHz).
    reg [2:0]  sdr_done_sync;
    reg [15:0] sdr_err_50;
    reg        sdr_done_50, sdr_failed_50;
    always @(posedge clk50) begin
        sdr_done_sync <= {sdr_done_sync[1:0], sdram_test_done};
        if (sdr_done_sync[1] && !sdr_done_sync[2]) begin
            sdr_err_50    <= sdram_test_errors;
            sdr_failed_50 <= sdram_test_failed;
            sdr_done_50   <= 1'b1;
        end
    end
    //=========================================================================
    // SD card probe: vendor stack (sd_card_top), byte-identical to the copy
    // that reads the four 640x480 BMPs in fpga_media_player (see
    // docs/02_bringup_log.md 16).  Reads sector 0 once, after init.
    //
    // Handshake required by rtl/sd/sd_card_sec_read_write.v:
    //   * sd_sec_read is a LEVEL that is sampled only in S_WAIT_READ_WRITE,
    //     i.e. after CMD0/CMD8/CMD55/ACMD41/CMD16 have all been answered;
    //   * if the level is still high on the cycle sd_sec_read_end pulses, the
    //     stack starts the NEXT sector read immediately.  That is exactly how
    //     the BMP loader streams a whole file: hold the level, update
    //     sd_sec_read_addr on the read_end cycle, drop the level when done;
    //   * sd_sec_read_addr is latched in S_WAIT_READ_WRITE together with the
    //     request, so it must be stable at least one cycle before the level
    //     is seen (a registered request and a registered address are safe);
    //   * sd_sec_read_data_valid is one cycle per byte, 512 of them per sector,
    //     all strictly between the request and sd_sec_read_end.
    //
    // This probe wants exactly ONE sector, so the request is a single-cycle
    // pulse instead of a held level.  A pulse can be missed (it only counts
    // while the stack sits in S_WAIT_READ_WRITE), so the FSM re-arms every
    // ~20 ms and the re-arm count is visible in the status frame; without
    // that, one lost pulse would leave the probe stuck in silence forever.
    //=========================================================================
    localparam [8:0]  SD_GAP_CYC = 9'd100;       // init_done -> first request
    localparam [20:0] SD_TMO_CYC = 21'd500_000;  // ~20 ms @ 25 MHz

    // Driven inside g_card (master) / tied low inside g_nocard (slave), but read
    // outside both by wall_status_tx, so they live at module scope.
    // (tf_phase is declared next to wall_clock now -- C10-R1)
    wire [7:0]  tf_err;
    wire [4:0]  tf_found, tf_bank_ok;
    wire [7:0]  tf_sec_bytes;

    wire        sd_init_done;
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire [7:0]  sd_sec_read_data;
    wire        sd_sec_read_valid;
    wire        sd_sec_read_end;

    //=========================================================================
    // Card stack + FAT32 loader + WAV player -- MASTER ONLY.
    //
    // Node B has no card in its slot and never touches one: its pictures arrive
    // over the link and its audio comes from A.  Instantiating this stack in the
    // slave cost 1.9k LUTs and 1.7k flops on the board that is short of room
    // (B was at 74% and a build failed to route), so the slave ties its outputs
    // low instead.  Anything still consumed outside this block must be listed in
    // g_nocard below -- TD errors out on a signal that nothing drives.
    //=========================================================================
    generate
    if (IS_MASTER != 0) begin : g_card

    // SPI_HIGH_SPEED_DIV selects the clock used for the data phase:
    //   divide = ((DIV + 2) * 2), so 0 -> 6.25 MHz, 16 -> ~0.7 MHz.
    // The 6.25 MHz read on the current card came back as all 0x00, and re-running
    // the same probe at ~0.7 MHz gave byte-identical zeros, so the data phase is
    // NOT speed limited -- the card's LBA 0 really is zeroed
    // (docs/02_bringup_log.md 16).  Keep the fast clock: the loader will read
    // megabytes and needs it.
    sd_card_top #(.SPI_LOW_SPEED_DIV(248), .SPI_HIGH_SPEED_DIV(0)) u_sd (
        .clk  (pixel_clk),
        .rst  (logic_rst),
        .SD_nCS (sd_ncs),
        .SD_DCLK(sd_sclk),
        .SD_MOSI(sd_mosi),
        .SD_MISO(sd_miso),
        .sd_init_done          (sd_init_done),
        .sd_sec_read           (sd_sec_read),
        .sd_sec_read_addr      (sd_sec_read_addr),
        .sd_sec_read_data      (sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_valid),
        .sd_sec_read_end       (sd_sec_read_end),
        .sd_sec_write          (1'b0),
        .sd_sec_write_addr     (32'd0),
        .sd_sec_write_data     (8'd0),
        .sd_sec_write_data_req (),
        .sd_sec_write_end      ()
    );

    //=========================================================================
    // W2.2 TF loader: FAT32 -> BMP -> the four picture banks.
    //
    // It owns the sector request path (the single-read probe it replaces is gone):
    // the first thing it reads is LBA 0, so wall_sd_dump still captures the boot
    // sector for the host.  Everything is in the 25 MHz pixel domain.
    //
    // On a card whose LBA 0 is not a FAT32 boot sector -- the current A-board card,
    // 128 x 0x00, see docs/02_bringup_log.md 19 -- it stops at phase=ERR / err=3
    // and leaves the pattern pictures untouched.
    //
    // phase: 0 idle 1 boot 2 root 3 pick 4 chain 5 data 6 done 15 err
    //=========================================================================
    // (declared at module scope, above, because the status frame reads them on
    // both nodes)
    wall_tf_load u_tf (
        .clk           (pixel_clk),
        .rst           (logic_rst),
        .wav_en        (1'b1),
        .mw_vld        (mw_vld),
        .mw_addr       (mw_addr),
        .mw_data       (mw_data),
        .mw_rdy        (mw_rdy),
        .music_frames  (mus_frames),
        .music_ok      (music_ok),
        .sd_init_done  (sd_init_done),
        .sd_req        (sd_sec_read),
        .sd_lba        (sd_sec_read_addr),
        .sd_valid      (sd_sec_read_valid),
        .sd_data       (sd_sec_read_data),
        .sd_end        (sd_sec_read_end),
        .phase         (tf_phase),
        .err           (tf_err),
        .found         (tf_found),
        .bank_ok       (tf_bank_ok),
        .sec_bytes     (tf_sec_bytes),
        .dbg_state     (ld_state_w),
        .dbg_ent_cnt   (ld_ent_cnt),
        .dbg_ent4      (ld_ent4),
        .dump_addr     (ld_dump_addr),
        .dump_byte     (ld_dump_byte)
    );


    // Background music, synthesised in the FPGA (no processor, no file).
    // MUSIC.WAV: the loader pushes words in at 25 MHz, the 150 MHz side does the
    // SDRAM transactions, and the output is one stereo frame per 48 kHz tick.
    // Falls back to the synth (music_playing = 0) when the card has no usable file.
    wall_music u_music (
        .clk25(pixel_clk), .rst25(logic_rst),
        .ld_vld(mw_vld), .ld_addr(mw_addr), .ld_data(mw_data), .ld_rdy(mw_rdy),
        .tick(aud_vld), .frames(mus_frames),
        .left(mus_l), .right(mus_r), .out_vld(mus_vld), .playing(mus_playing),
        .rd_cnt(mus_rd_cnt),

        .clk150(sdr_clk_150m), .rst150(~sdr_rst_n),
        .wr_valid(mus_wr_valid), .wr_addr(mus_wr_addr), .wr_data(mus_wr_data), .wr_ready(mus_wr_ready),
        .rd_valid(mus_rd_valid), .rd_addr(mus_rd_addr), .rd_ready(mus_rd_ready),
        .rvalid(mus_rvalid), .rdata(c_rdata)
    );

    end else begin : g_nocard
        // Node B: no card stack at all.  Every output of g_card that something
        // outside the block reads is tied off here.
        assign sd_ncs        = 1'b1;      // card deselected, clock idle
        assign sd_sclk       = 1'b0;
        assign sd_mosi       = 1'b1;
        assign sd_init_done  = 1'b0;
        assign tf_phase      = 4'd0;
        assign tf_err        = 8'd0;
        assign tf_found      = 5'd0;
        assign tf_bank_ok    = 5'd0;
        assign tf_sec_bytes  = 8'd0;
        assign ld_state_w    = 5'd0;
        assign ld_ent_cnt    = 8'd0;
        assign ld_ent4       = 32'd0;
        assign ld_dump_byte  = 8'd0;
        assign mus_frames    = 21'd0;
        assign music_ok      = 1'b0;
        assign mus_playing   = 1'b0;
        assign mus_vld       = 1'b0;
        assign mus_l         = 24'sd0;
        assign mus_r         = 24'sd0;
        assign mus_rd_cnt    = 8'd0;
        assign mus_wr_valid  = 1'b0;
        assign mus_wr_addr   = 21'd0;
        assign mus_wr_data   = 32'd0;
        assign mus_rd_valid  = 1'b0;
        assign mus_rd_addr   = 21'd0;
    end
    endgenerate

    //=========================================================================
    // Rendering
    //=========================================================================
    // The pictures live in SDRAM (288x216 RGB565, four blocks from word
    // 1,700,000); the line buffer + prefetch below feed the scene one source
    // row at a time.  The old 96x72 RGB444 BRAM library is gone: it was the
    // single largest EMB consumer (~43 blocks) and, once the scene switched to
    // the line buffer, nothing displayed it any more.

    // Clamp x to the first active column while blanking so the picture RAM
    // address is primed for the first pixel of the line (see wall_scene).
    //
    // +1 while active: wall_scene now registers its RGB output (W3 step 1), so
    // the pixel it composes this cycle is the one the raster column shows one
    // clock later.  Feeding x+1 during active pixels, and 0 while blanking (so
    // the last blanking cycle composes column 0 and that lands in the first
    // active pixel), keeps the picture at its own column -- no 1-pixel shift,
    // no duplicated column, and no change to the line-buffer address rule
    // (wall_scene still presents the column for x+1 on active pixels).
    wire [10:0] x_scene = ({1'b0, x_c} + 11'd1) & {11{de_c}};

    // Audio mux: one 48 kHz frame, from the card if the loader found a WAV,
    // otherwise from the on-chip synth.  Both are registered in their own
    // domain and only one of them is playing at a time.
    // Only the master drives HDMI audio: one card file, one audio source, so the
    // two boards cannot drift apart.  The slave keeps its synth silent.
    wire        play_vld = (IS_MASTER != 0) ? (mus_playing ? mus_vld : aud_vld) : 1'b0;
    wire [23:0] play_l   = mus_playing ? mus_l   : aud_l;
    wire [23:0] play_r   = mus_playing ? mus_r   : aud_r;

    // Volume: the HDMI sink attenuates our 24-bit stream a lot, so apply a
    // saturating x4 here (one place, both sources).  Saturation rather than
    // wrap-around, so loud passages clip instead of turning into noise.
    // Volume: the HDMI sink attenuates our stream a lot.  SH = 3 means x8
    // (+18 dB); the sum saturates instead of wrapping, so loud passages clip
    // cleanly rather than turning into noise.  Change SH to 2 (+12 dB) or 4
    // (+24 dB) if this is too much / still too quiet.
    localparam integer VOL_SH = 6;   // x64 (+36 dB)

    function [23:0] vol_boost;
        input [23:0] v;
        reg [31:0] x;
        begin
            x = {{8{v[23]}}, v} << VOL_SH;                 // 32-bit signed, x64
            if (x[29:23] == 7'b0000000 || x[29:23] == 7'b1111111)
                vol_boost = x[23:0];                       // fits
            else
                vol_boost = v[23] ? 24'h800000 : 24'h7FFFFF; // clip
        end
    endfunction

    // The card audio needs a large boost (it arrives ~40 dB down), while the
    // on-chip synth is already full scale -- boosting both made the fallback
    // synth painfully loud.  So: card audio x64, synth untouched.
    wire [23:0] mus_l_vol = vol_boost(play_l);
    wire [23:0] mus_r_vol = vol_boost(play_r);
    // C6: mute silences the FINAL mix, so it covers the card WAV AND the on-chip
    // synth.  Gating only mus_*_vol left the fallback synth audible.
    wire [23:0] play_l_vol = mute_use ? 24'd0 : (mus_playing ? mus_l_vol : aud_l);
    wire [23:0] play_r_vol = mute_use ? 24'd0 : (mus_playing ? mus_r_vol : aud_r);

    // On-screen scope taps the muxed output, so it moves with whatever plays.
    // node A meters the card audio, node B meters its own synth (B is muted at
    // the HDMI port, so tapping play_vld there would freeze the meter at zero)
    wire        scope_vld = (IS_MASTER != 0) ? play_vld   : aud_vld;
    wire [23:0] scope_smp = (IS_MASTER != 0) ? play_l_vol : aud_l;

    wall_scope u_scope (
        .clk(pixel_clk), .rst(logic_rst),
        .tick(scope_vld), .sample(scope_smp),
        .wav_base(wav_base), .wav_addr(wav_addr), .wav_data(wav_data),
        .level(scope_level)
    );

    wall_audio u_audio (
        .clk(pixel_clk), .rst(logic_rst),
        .valid(aud_vld), .left(aud_l), .right(aud_r),
        .wav_base(), .wav_addr(8'd0), .wav_data(),
        .level(aud_level)
    );

    // Per-window Q16 steps, recomputed once per frame (see wall_zoom_calc).
    // A thumbnail is 192x144 (96/72 based step); a FRAMELESS window is the
    // 640x480 full-resolution copy and gets a 640/480 based step instead, so its
    // step comes out exactly 65536 = one source pixel per screen pixel.
    wire [71:0] zoom_step;
    wire [47:0] zoom_dw, zoom_dh;
    wall_zoom_calc u_zoom (
        .clk(pixel_clk), .rst(logic_rst), .start(sof_c),
        .tbl(cur_tbl), .zstep(zoom_step), .zdw(zoom_dw), .zdh(zoom_dh)
    );

    // ---- hires picture line buffer + prefetch ------------------------------
    // All four thumbnails count as ready only when every one is available, so the
    // prefetch (which fills all four windows together) and the scene gate on the
    // same signal and no window ever shows a half-filled line buffer.
    //   node A: the card loader completed all four banks.
    //   node B: the loader never runs (no card), so "ready" means one full
    //           carousel pass has been received from A and written to SDRAM.
    // The four 640x480 1:1 copies are tracked separately: there are 4 x 19,200 =
    // 76,800 of those blocks against 6,912 thumbnail blocks, so waiting for them
    // to gate the thumbnails would freeze the desktop for seconds after every
    // power-up.  Node A: all four banks completing is when wall_tf_load has
    // finished the 1:1 pass as well (C9: it copies EVERY picture, so bank_ok[n]
    // now means "thumbnail n AND copy n are complete").  Node B: a complete
    // 83,712-block pass.  NB the 17-bit counters: 83,712 > 65,535.
    localparam [16:0] B_PASS_BLOCKS = 17'd6912;    // 4 x 27648 / 16
    localparam [16:0] B_HI_BLOCKS   = 17'd83712;   // + 4 x 19200 1:1 copies
    reg b_pic_ready, b_hi_ready;
    always @(posedge pixel_clk) begin
        if (logic_rst) begin
            b_pic_ready <= 1'b0;
            b_hi_ready  <= 1'b0;
        end else begin
            if (img_rx_got >= B_PASS_BLOCKS) b_pic_ready <= 1'b1;
            if (img_rx_got >= B_HI_BLOCKS)   b_hi_ready  <= 1'b1;
        end
    end
    wire        pic_ready = (IS_MASTER != 0) ? (&tf_bank_ok[3:0]) : b_pic_ready;
    // C9: ALL FOUR copies must be in SDRAM before the album may show any page,
    // otherwise paging forward could display a region that is still empty.
    wire        hi_ready  = (IS_MASTER != 0) ? (&tf_bank_ok[3:0]) : b_hi_ready;
    wire [4:0]  pic_valid = {hi_ready, {4{pic_ready}}};

    // One prefetch round per line: prime row 0 at frame start, then fetch the
    // NEXT line's source rows at the start of each active line.
    //
    // `line_tick` comes from wall_raster's `pre_de`, i.e. PRE_LEN pixel clocks
    // BEFORE the first active pixel, and NOT from de's rising edge.
    // The compositor's output register means the first visible pixel of a line
    // is composed during blanking, from line-buffer data addressed one clock
    // before that, so the ping-pong bank swap has to happen ~3 clocks early.
    // Swapping on de's edge made the first column of every line show the
    // PREVIOUS row: invisible on node A (world x = 0, the far left of the wall)
    // but a visible one-column vertical break on node B, right at the seam
    // (world x = 640).  Reported by the operator as "only the column nearest the
    // seam is shifted down, the rest is fine", which is exactly this signature.
    wire [8:0]  y_next     = (y_c == 9'd479) ? 9'd0 : (y_c + 9'd1);
    wire [8:0]  prefetch_y = sof_c ? 9'd0 : y_next;

    // Register the prefetch's target line.  It only has to be valid at the line
    // tick, which is ~3 clocks before the line starts and well inside blanking,
    // so one clock of delay is free -- and it takes one heavy branch off the
    // raster's `y_c` fanout.  Node B's worst 25 MHz path used to run from the
    // prefetch's duplicated y_c driver into the scene's rgb mux (SWNS -0.112 ns);
    // this keeps that cone short.
    reg [8:0] prefetch_y_q;
    always @(posedge pixel_clk) begin
        if (logic_rst) prefetch_y_q <= 9'd0;
        else           prefetch_y_q <= prefetch_y;
    end

    wire [35:0] nxt_rows;
    wire [3:0]  nxt_valid;
    wire [3:0]  nxt_hi;
    wire [7:0]  nxt_idx;             // C9: 4 x 2-bit album page
    wire [39:0] nxt_c1;              // C9-R3: 4 x 10-bit last column this node shows
    wire [15:0] pic_rgb565;
    wire [2:0]  lb_rd_win;
    wire [9:0]  lb_rd_col;
    wire [7:0]  pic_late;            // C9-R2: starved line ticks in the last frame
    wire [3:0]  pic_late_msk;        // C9-R3: which windows starved in the last frame

    wall_pic_prefetch #(.NODE_X0(NODE_X0), .NODE_W(HACTIVE)) u_pic_prefetch (
        .y_target(prefetch_y_q), .tbl(cur_tbl), .zstep(zoom_step), .zdh(zoom_dh),
        .nxt_rows(nxt_rows), .nxt_valid(nxt_valid), .nxt_hi(nxt_hi), .nxt_idx(nxt_idx),
        .nxt_c1(nxt_c1)
    );

    // A window may only be fetched when ITS source is in SDRAM: the thumbnails
    // need all four banks, the frameless window needs the 640x480 copy.
    wire [3:0] fetch_ok = (nxt_hi & {4{hi_ready}}) | (~nxt_hi & {4{pic_ready}});

    wall_pic_line u_pic_line (
        .clk25(pixel_clk), .rst25(logic_rst),
        .prime(sof_c), .line_tick(line_tick), .car_cyc(car_cyc),
        .nxt_rows(nxt_rows), .nxt_valid(nxt_valid & fetch_ok), .nxt_hi(nxt_hi),
        .nxt_idx(nxt_idx), .nxt_c1(nxt_c1),
        .rd_win(lb_rd_win), .rd_col(lb_rd_col), .rd_data(pic_rgb565),
        .clk150(sdr_clk_150m), .rst150(~sdr_rst_n),
        .rd_valid(pic_rd_valid), .rd_addr(pic_rd_addr), .rd_ready(pic_rd_ready), .busy(pic_busy),
        .rvalid(pic_rvalid), .rdata(pic_rdata), .late_cnt(pic_late), .late_msk(pic_late_msk)
    );

    // ---- C9-R3 line-buffer starvation monitor ------------------------------
    // A per-frame counter is useless to a human: the frame that starved is gone
    // long before he presses "enter".  So keep a 4-second epoch (240 frames) and
    // latch the WORST frame of it plus the OR of the per-window starvation mask.
    // Status byte 11 carries the count, byte 19 bits [6:3] the mask -- so after
    // the operator has moved a picture around we can still see what happened.
    localparam [7:0] LATE_EPOCH = 8'd239;
    reg  [7:0] late_max, late_show, late_epoch;
    reg  [3:0] late_msk_all, late_msk_show;
    always @(posedge pixel_clk) begin
        if (logic_rst) begin
            late_max <= 8'd0; late_show <= 8'd0; late_epoch <= 8'd0;
            late_msk_all <= 4'd0; late_msk_show <= 4'd0;
        end else begin
            if (pic_late > late_max) late_max <= pic_late;
            late_msk_all <= late_msk_all | pic_late_msk;
            if (late_epoch == LATE_EPOCH) begin
                late_epoch    <= 8'd0;
                late_show     <= (pic_late > late_max) ? pic_late : late_max;
                late_msk_show <= late_msk_all | pic_late_msk;
                late_max      <= 8'd0;
                late_msk_all  <= 4'd0;
            end else begin
                late_epoch <= late_epoch + 8'd1;
            end
        end
    end

    // C10: the marquee switch and scroll phase, resolved per role.  Both nodes
    // must scroll with exactly the same phase or the text tears at the seam.
    wire        m_on_use = (IS_MASTER != 0) ? m_on_loc : copy_marq;
    wire [8:0]  m_phase  = (IS_MASTER != 0) ? frame_cnt[8:0] : {copy_mp8, b_seq};

    wire [23:0] scene_rgb;
    // A still photo must not be dimmed by the carousel envelope.
    wire [7:0]  fade_use = album_cur ? 8'hFF : fade_gain;
    wall_scene #(.NODE_X0(NODE_X0), .HUD_EN(1), .NODE_ID(NODE_ID)) u_scene (
        .clk(pixel_clk), .x(x_scene), .y(y_c), .tbl(cur_tbl), .anim(cur_anim), .sel(cur_sel),
        .zstep(zoom_step), .zdw(zoom_dw), .zdh(zoom_dh),
        .mode_sw(mode_sw), .osd_en(osd_use), .mute(mute_use), .music_ok(music_ok),
        .music_frames(mus_frames), .ld_err(tf_err), .aud_level(scope_level),
        .time_min(time_min), .time_sec(time_sec), .car_auto(car_auto_w),
        .car_cyc(car_cyc), .bc_tbl(bc_tbl), .adj_on(adj_on), .frame(sof_c),
        // the audio meter and the MUSIC caption live on node A only
        .meter_en(IS_MASTER != 0), .show_music(IS_MASTER != 0),
        .wav_base(wav_base), .wav_addr(wav_addr), .wav_data(wav_data),
        .de(de_c),
        .link_ok(link_ok), .sync_ok(sync_ok), .frozen(frozen_w),
        .pic_rgb565(pic_rgb565), .lb_rd_win(lb_rd_win), .lb_rd_col(lb_rd_col),
        .fade_gain(fade_use),

        .pic_valid(pic_valid), .tlevel(tlvl_use),
        .m_on(m_on_use), .m_phase(m_phase),
        .blink((IS_MASTER != 0) ? frame_cnt[3] : b_seq[3]), .rgb(scene_rgb)
    );


    //=========================================================================
    // 115200 status channel (CH340 on D12)
    //=========================================================================
    wire status_tx;
    wall_status_tx #(.NODE_CH((NODE_ID == 0) ? 8'h41 : 8'h42)) u_status (
        .clk(clk50),
        .rst(por_rst),
        .link_ok(link_ok),
        .sync_ok(sync_ok),
        .frozen(frozen_w),
        .dragging(sel_drag_stat),
        .owner(sel_own_stat),
        .sel(cur_sel),
        .gx(sel_gx_stat),
        .stage_gx(stage_word[11:0]),
        .rst_cnt(rst_cnt_pix),
        .dbg_sec(time_sec),
        .dbg_min(time_min),
        .key_pressed(key_pressed_w),
        .remote_press(remote_press_q),
        .frame_cnt(frame_cnt),
        .sd_phase(tf_phase),
        .sd_err(tf_err),
        .win_w(sel_w_stat),
        .win_h(sel_h_stat),
        .sdram_done(sdr_done_50),
        .sdram_failed(sdr_failed_50),
        .pll_rst_cnt(pll_rst_cnt),
        .ok_cnt(stat_ok),
        .err_cnt(stat_err),
        .sd_sec_bytes  ((tf_phase == 4'd6) ? late_show : tf_sec_bytes),  // byte 11: worst frame / 4 s
        .music_cnt   ((IS_MASTER != 0) ? mus_rd_cnt : 8'd0),
        .ld_state    (ld_state_w),
        .music_slot  ({tf_bank_ok[4], tf_found[4]}),
        .ld_ent_cnt  (ld_ent_cnt),
        .ld_ent4     (ld_ent4),

        .dump_byte   (ld_dump_byte),
        .dump_idx    (ld_dump_addr),
        .sd_flags({tf_bank_ok[3:0], tf_found[3:0]}),
        // C9: byte 19 was the picture-RAM self-check (always 0 since W3).  It now
        // carries {1'b0, starved-window mask[3:0], album page[1:0], hi_ready}:
        // "why is the album blank", "which page" and "which windows starved"
        // are all readable over the serial link.
        .img_chk_err({1'b0, late_msk_show, alb_pic_idx, hi_ready}),
        .img_chk_done(1'b0),
        .sdram_errors(sdr_err_50),
        .video_locked(hdmi_video_locked),
        .video_ready(hdmi_ready),
        .sup_state(hdmi_sup_state),
        .rec_cnt(hdmi_rec_cnt),
        .uart_tx(status_tx)
    );

    // Sector dump: the head of the sector the SD probe just read, on the same
    // pin.  While it is transmitting, the status frames are cut mid-frame; the
    // host resynchronises on the next 'W','L'.  See rtl/wall_sd_dump.v.
    wire sd_dump_active, sd_dump_tx;
    generate
    if (IS_MASTER != 0) begin : g_dump
    // The dump captures the *root directory* the loader scans (phase 2), not
    // LBA 0: on a partitioned card LBA 0 is a partition table whose first bytes
    // are usually zero, while the root directory shows the file names.
    wall_sd_dump #(.NBYTES(128), .START(256)) u_sd_dump (   // entries 8..11: where MUSIC.WAV actually lives
        .clk(pixel_clk), .rst(logic_rst),
        .sd_valid(sd_sec_read_valid), .sd_data(sd_sec_read_data),
        .sd_end(sd_sec_read_end),
        .cap_en(tf_phase == 4'd2),
        .active(sd_dump_active), .tx(sd_dump_tx)
    );
    end else begin : g_nodump
        // master-only debug aid (271 LUTs): the slave never shows a sector
        assign sd_dump_active = 1'b0;
        assign sd_dump_tx     = 1'b0;
    end
    endgenerate
    assign uart_tx = sd_dump_active ? sd_dump_tx : status_tx;

    wall_autodrag #(.ENABLE((IS_MASTER != 0) ? AUTODRAG : 0), .START_CYC(AUTO_START), .STEP_CYC(AUTO_STEP)) u_autodrag (
        .clk(pixel_clk), .rst(logic_rst), .gx(sel_gx_stat),
        .press(auto_press)
    );

    reg        axis_user, axis_valid, axis_last;
    reg [23:0] axis_data;
    always @(posedge pixel_clk) begin
        if (vid_rst) begin
            axis_user  <= 1'b0;
            axis_valid <= 1'b0;
            axis_last  <= 1'b0;
            axis_data  <= 24'd0;
        end else begin
            // APUG092 expects AXIS user on the FIRST ACTIVE PIXEL (the proven
            // hdmi_official_baseline_source asserts it at (v==VBLANK, h==HBLANK)).
            // Driving it at the frame origin instead was why O_video_locked never
            // asserted on hardware while simulation (stub IP) looked fine.
            axis_user  <= de_c && (x_c == 10'd0) && (y_c == 9'd0);
            axis_valid <= de_c;
            axis_last  <= last_c;
            axis_data  <= de_c ? scene_rgb : 24'd0;
        end
    end

    wire       axis_ready_unused;
    wire       edid_valid_unused;
    wire [7:0] edid_data_unused;

    // EDID read: exactly one pulse, 100k pixel clocks after each reset release.
    // Holding the trigger high (the first version did) makes the vendor core
    // either ignore it or re-read DDC forever, so count to the trigger and stop.
    reg [16:0] edid_cnt;
    reg        edid_trig;
    reg        edid_done;
    always @(posedge pixel_clk) begin
        if (vid_rst) begin
            edid_cnt  <= 17'd0;
            edid_trig <= 1'b0;
            edid_done <= 1'b0;
        end else begin
            edid_trig <= 1'b0;
            if (!edid_done) begin
                if (edid_cnt == 17'd100000) begin
                    edid_trig <= 1'b1;
                    edid_done <= 1'b1;
                end else begin
                    edid_cnt <= edid_cnt + 17'd1;
                end
            end
        end
    end

    apug092_tx_wrapper #(
        .HACTIVE(HACTIVE), .HFP(HFP), .HSA(HSA), .HBP(HBP),
        .VACTIVE(VACTIVE), .VFP(VFP), .VSA(VSA), .VBP(VBP),
        .VIDEO_VIC(1), .IIC_SCL_DIV(250)
    ) u_hdmi_tx (
        .pixel_clk       (pixel_clk),
        .serial_clk      (serial_clk),
        .rst             (hdmi_rst),
        .edid_read_trig  (edid_trig),
        .edid_read_valid (edid_valid_unused),
        .edid_read_data  (edid_data_unused),
        .axis_user       (axis_user),
        .axis_valid      (axis_valid),
        .axis_last       (axis_last),
        .axis_data       (axis_data),
        .axis_ready      (axis_ready_unused),
        .audio_valid     (play_vld),
        .audio_left_data (play_l_vol),
        .audio_right_data(play_r_vol),
        .acr_valid       (1'b1),
        .acr_cts         (20'd195312),
        .acr_n           (20'd48000),
        .video_locked    (video_locked_ip),
        .ddc_scl         (HDMI_DDC_SCL),
        .ddc_sda         (HDMI_DDC_SDA),
        .tmds_ch0_p      (HDMI_D0_P),
        .tmds_ch1_p      (HDMI_D1_P),
        .tmds_ch2_p      (HDMI_D2_P),
        .tmds_clk_p      (HDMI_CLK_P)
    );

    //=========================================================================
    // Board LEDs
    //
    // Every LED state is generated in the 50 MHz domain.  The two pixel-domain
    // status bits cross through two-flop synchronisers, so no LED path is a
    // 25 -> 50 MHz data path that STA has to close.
    //=========================================================================
    reg sof_tog;
    always @(posedge pixel_clk) begin
        if (logic_rst) sof_tog <= 1'b0;
        else if (sof_c) sof_tog <= ~sof_tog;
    end

    reg [2:0] ok_sync;      // link_ok
    reg [2:0] act_sync;     // sof_tog
    always @(posedge clk50) begin
        ok_sync  <= {ok_sync[1:0],  link_ok};
        act_sync <= {act_sync[1:0], sof_tog};
    end

    reg [24:0] hb;
    always @(posedge clk50) hb <= hb + 25'd1;

    reg led_act;
    reg [3:0] led_r;
    always @(posedge clk50) begin
        if (act_sync[2] ^ act_sync[1]) led_act <= ~led_act;
        led_r[0] <= ok_sync[2];        // link healthy
        led_r[1] <= hb[24];            // ~1.5 Hz heartbeat
        led_r[2] <= led_act;           // a frame is being rendered
        led_r[3] <= !ok_sync[2];       // link lost (or B not genlocked yet)
    end
    assign led = led_r;
    // ------------------------------------------------------------------

endmodule
