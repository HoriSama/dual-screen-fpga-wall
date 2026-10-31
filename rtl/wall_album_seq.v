//=============================================================================
// wall_album_seq.v -- owns the window table while the operator is in album mode
//
// SW1 + SW2 + SW3 up = album: the whole wall shows one 640x480 photograph at
// one source pixel per screen pixel.  Nothing about the picture path is switched
// here -- this module only parks a FRAMELESS record (bit 58) in slot 0, which
// wall_window_eval treats as "the whole 1280x480 world, no border, no title",
// and blanks the other three records to w = h = 0 so the prefetch does not
// fetch three invisible thumbnail rows behind it on every line.
//
// C5: the swap is a FADE-THROUGH-BLACK transition, not a hard cut.
// There is no framebuffer in this design, so a true cross-dissolve is
// impossible (you cannot mix the previous frame with the current one); a
// fade-to-black only needs a colour the compositor can already output.
//   16 frames fade out (level 16 -> 0)   ~267 ms
//   4 clocks table swap, while black      (invisible)
//   2 frames settle                       (stage -> snap -> cur pipeline)
//   16 frames fade in  (level 0 -> 16)   ~267 ms
// 533 ms in total, the same cadence wall_carousel uses when it changes picture,
// so the two transitions feel like the same gesture.
//
// `level` is the 0..16 transition level; wall_scene's dimmer takes it as
// {level, 4'b0000} = 0..256 (256 = passthrough).  Node A applies its own level
// and BROADCASTS it (STATE byte 4 bits 6:2) so node B dims in step -- without
// that, B would cut abruptly one frame after A while A was already at black.
//
// The snapshot comes from cur_tbl -- the table actually ON SCREEN -- because
// stage is two frames ahead of it, and restoring what the operator was looking
// at is what he expects.  It is taken the moment the transition starts, while
// the old table is still displayed.
//
// Writes go through the same single-index port wall_input uses, so wall_state,
// the STATE broadcast and the 2-frame pipeline are untouched: the whole table is
// rebuilt in four back-to-back clocks at the black point, and the peer picks the
// new table up from the STATE frame it already receives every frame.
//
// C9 -- paging.  The album now shows ONE OF FOUR 640x480 copies (CAM1..CAM4),
// chosen by record bits [60:59].  KEY4 = next, KEY3 = previous are delivered as
// single-cycle pulses (`nxt` / `prv`) and only act in S_ALBUM, i.e. once the
// fade-in has finished.
//
// C9-R2: a page change uses the SAME fade-through-black as entering/leaving the
// album (operator's request) -- fade out, rewrite SLOT 0 only, settle, fade in.
// The only difference from an enter/leave is that one record is written instead
// of four (`paging`), so the three blank records stay blank and nothing else in
// the table moves.  Total ~34 frames (~567 ms), the same gesture as the mode
// change.  The page survives entering/leaving album mode, and key presses that
// arrive during a fade are ignored (the sequencer is not in S_ALBUM).
//=============================================================================
`timescale 1ns/1ps

module wall_album_seq #(
    parameter integer FADE_FRAMES = 16     // frames per direction (~267 ms @ 60 Hz)
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         frame,        // sof pulse: one transition step per frame
    input  wire         album,        // debounced switch level
    input  wire         nxt,          // 1-cycle pulse: next picture (KEY4)
    input  wire         prv,          // 1-cycle pulse: previous picture (KEY3)
    input  wire [255:0] cur_tbl,      // the table being displayed
    output reg          set_tbl,
    output reg  [1:0]   set_idx,
    output reg  [63:0]  set_data,
    output reg  [4:0]   level,        // 0 = black, 16 = full
    output wire [1:0]   pic_idx       // current page, for the HUD/status (C9)
);
    localparam [4:0] LVL_FULL = 5'd16;

    // The album record: gx = gy = 0, z = top, bit 58 set, [60:59] = page.
    // w/h are unused for a frameless window (the geometry is always the whole
    // world); 1023 is simply the largest value the 10-bit field can hold, so the
    // status frame shows the window at its maximum instead of a misleading zero.
    function [63:0] album_rec;
        input [1:0] p;
        begin
            album_rec = {3'b0, p, 1'b1,  // [63:61] rsv, [60:59] page, [58] FRAMELESS
                         4'd0,           // [57:54] id = 0 (line-buffer slot)
                         3'd0,           // [53:51] flags
                         1'b0,           // [50]    owner = A
                         2'd3,           // [49:48] z = top
                         4'd0,           // [47:44] src (unused)
                         10'd480,        // [43:34] h (unused)
                         10'd1023,       // [33:24] w (unused)
                         12'd0,          // [23:12] gy
                         12'd0};         // [11:0]  gx
        end
    endfunction

    function [63:0] blank_rec;          // invisible: w = h = 0, z = 0
        input [1:0] i;
        begin
            blank_rec = {5'b0, 1'b0, 2'b00, i, 3'd0, 1'b0, 2'd0, 4'd0,
                         10'd0, 10'd0, 12'd0, 12'd0};
        end
    endfunction

    localparam [5:0] S_IDLE   = 6'd0,   // waiting for a switch edge
                     S_FADE_O = 6'd1,   // dimming to black
                     S_SWAP   = 6'd2,   // write the 4 records (screen is black)
                     S_SETTLE = 6'd3,   // let stage -> snap -> cur catch up
                     S_FADE_I = 6'd4,   // brightening back to full
                     S_ALBUM  = 6'd5;   // album is on screen, waiting for release

    reg [5:0]  st;
    reg        album_d;
    reg        leaving;                 // 1 = the pending swap restores the snapshot
    reg        paging;                  // 1 = the pending swap changes slot 0 only
    reg [1:0]  swi;                     // record index during the swap
    reg [1:0]  scnt;                    // commits waited for after the swap
    reg [1:0]  idx;                     // C9: which 1:1 copy (0..3 = CAM1..4)
    reg [1:0]  idx_pend;                // C9-R2: the page the running fade will land on
    reg [63:0] sav0, sav1, sav2, sav3;

    assign pic_idx = idx;

    // C9: wrap-around page step
    wire [1:0] idx_nxt = nxt ? ((idx == 2'd3) ? 2'd0 : (idx + 2'd1)) :
                         prv ? ((idx == 2'd0) ? 2'd3 : (idx - 2'd1)) : idx;

    // the page the swap writes: the pending one during a page change
    wire [1:0] swap_pic = paging ? idx_pend : idx;

    wire [63:0] swap_data = leaving ?
        ((swi == 2'd0) ? sav0 : (swi == 2'd1) ? sav1 :
         (swi == 2'd2) ? sav2 : sav3) :
        ((swi == 2'd0) ? album_rec(swap_pic) : blank_rec(swi));

    always @(posedge clk) begin
        if (rst) begin
            st       <= S_IDLE;
            album_d  <= 1'b0;
            leaving  <= 1'b0;
            paging   <= 1'b0;
            swi      <= 2'd0;
            scnt     <= 2'd0;
            idx      <= 2'd0;
            idx_pend <= 2'd0;
            level    <= LVL_FULL;
            set_tbl  <= 1'b0;
            set_idx  <= 2'd0;
            set_data <= 64'd0;
            sav0 <= 64'd0; sav1 <= 64'd0; sav2 <= 64'd0; sav3 <= 64'd0;
        end else begin
            album_d <= album;
            set_tbl <= 1'b0;
            case (st)
                // ---- idle: arm on the rising edge ---------------------------
                S_IDLE: begin
                    level <= LVL_FULL;
                    if (album && !album_d) begin
                        // snapshot while the OLD table is still on screen
                        sav0    <= cur_tbl[63:0];
                        sav1    <= cur_tbl[127:64];
                        sav2    <= cur_tbl[191:128];
                        sav3    <= cur_tbl[255:192];
                        leaving <= 1'b0;
                        st      <= S_FADE_O;
                    end
                end
                // ---- fade out, one step per frame --------------------------
                S_FADE_O: if (frame) begin
                    if (level == 5'd1) begin
                        level <= 5'd0;
                        swi   <= 2'd0;
                        st    <= S_SWAP;
                    end else begin
                        level <= level - 5'd1;
                    end
                end
                // ---- swap the table while the screen is black --------------
                S_SWAP: begin
                    set_tbl  <= 1'b1;
                    set_idx  <= swi;
                    set_data <= swap_data;
                    if (paging) begin
                        // C9-R2: only slot 0 changes; slots 1..3 stay blanked
                        idx    <= idx_pend;
                        paging <= 1'b0;
                        scnt   <= 2'd0;
                        st     <= S_SETTLE;
                    end else if (swi == 2'd3) begin
                        swi  <= 2'd0;
                        scnt <= 2'd0;
                        st   <= S_SETTLE;
                    end else begin
                        swi <= swi + 2'd1;
                    end
                end
                // ---- the swap needs two commits before cur shows it --------
                // (both nodes apply the new table at the same black point, so the
                //  fade-in always starts from a screen that is already black)
                S_SETTLE: if (frame) begin
                    if (scnt == 2'd1) begin
                        scnt <= 2'd0;
                        if (!album && !leaving) begin
                            // released during the swap: go straight back out, the
                            // screen is black so this costs no visible time
                            leaving <= 1'b1;
                            st      <= S_FADE_O;
                        end else begin
                            st <= S_FADE_I;
                        end
                    end else begin
                        scnt <= scnt + 2'd1;
                    end
                end
                // ---- fade in -------------------------------------------------
                S_FADE_I: if (frame) begin
                    if (level == LVL_FULL - 5'd1) begin
                        level <= LVL_FULL;
                        st    <= leaving ? S_IDLE : S_ALBUM;
                    end else begin
                        level <= level + 5'd1;
                    end
                end
                // ---- album on screen: wait for the release or a page key --
                S_ALBUM: begin
                    if (nxt || prv) begin
                        // C9-R2: fade the page change exactly like a mode change
                        // (fade out -> one-record swap at black -> settle -> fade
                        // in).  Only slot 0 is rewritten, so the three blanked
                        // records -- and everything else in the table -- stay put.
                        paging   <= 1'b1;
                        idx_pend <= idx_nxt;
                        st       <= S_FADE_O;
                    end else if (!album) begin
                        leaving <= 1'b1;
                        st      <= S_FADE_O;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
