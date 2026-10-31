//=============================================================================
// wall_status_tx.v -- 34-byte binary status frame over the CH340 UART
//
// Frame (115200 8N1), one frame every 100 ms, fixed byte positions:
//
//   idx  field      meaning
//   ---  ---------  -----------------------------------------------------------
//    0   'W'        0x57  frame magic
//    1   'L'        0x4C
//    2   node       'A' (0x41) / 'B' (0x42)
//    3   flags      bit0 link_ok, bit1 sync_ok (genlocked), bit2 frozen,
//                   bit3 dragging
//    4   sel        selected window 0..3
//    5   gx_hi      committed (rendered) gx[11:8]
//    6   gx_lo
//    7   ok_hi      link frames accepted [15:8]
//    8   ok_lo
//    9   er_hi      link frames rejected [15:8]
//   10   er_lo
//   11   sd_sec_bytes  TF loader: bytes of the sector being read (saturating)
//   12   sd_flags   high nibble = bank_ok (banks whose picture is complete),
//                   low nibble = found (CAM1..4.BMP present in the root dir)
//   13   video      {2'b0, sup_state[1:0], 2'b0, video_ready, video_locked}
//   14   rec_cnt    HDMI supervisor recovery count
//   15   clk_ss     wall clock seconds, BCD (was the PLL retry count, always 0)
//   16   stage_hi   staged (unquantised) gx[11:8]
//   17   stage_lo
//   18   clk_mm     wall clock minutes, BCD (was the pixel reset count, always 1)
//   19   alb        C9: {5'b0, album page[1:0], hi_ready}.  Was the picture-RAM
//                   self-check (always 0 since W3).  page = which of the four
//                   1:1 copies the album is showing, hi_ready = all four are in
//                   SDRAM.  So "the album is blank" is distinguishable from
//                   "the loader has not finished".
//   20   sd_phase   TF loader phase: 0 idle 1 boot 2 root 3 pick 4 chain
//                   5 data 6 done 15 error
//   21   fcnt_hi    frame counter [15:8]
//   22   fcnt_lo
//   23   sd_err     TF loader error code (0 = none, see rtl/wall_tf_load.v)
//   24   winw_hi    selected window width[9:8]
//   25   winw_lo
//   26   winh_hi    selected window height[9:8]
//   27   winh_lo
//   28   sdram_er_lo  SDRAM self-test error count[7:0]
//   29   sdram_er_hi  [15:8]
//   30   sdram      bit0 self-test done, bit1 self-test failed,
//                   bit2 picture-RAM fill+check done
//   31   'Z'        0x5A  end-of-payload marker
//   32   0x0D
//   33   0x0A
//
// The host reads both COM ports and can therefore prove, without looking at
// the screens, that both nodes agree on sel/gx and that the link is healthy.
// A human can still see 'W','L','A' at the start of every line.
// tools/read_status.ps1 decodes exactly this layout.
//=============================================================================
`timescale 1ns/1ps

module wall_status_tx #(
    parameter integer TICK_CYC  = 5_000_000,   // 100 ms @ 50 MHz
    parameter [7:0]   NODE_CH   = 8'h41        // 'A'
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        link_ok,
    input  wire        sync_ok,
    input  wire        frozen,
    input  wire        dragging,
    input  wire        owner,
    input  wire [1:0]  sel,
    input  wire [11:0] gx,
    input  wire [11:0] stage_gx,
    input  wire [7:0]  rst_cnt,
    // C10-R1: the wall clock BCD counters, so a wrong TIME display can be told
    // apart from a clock that really is at that value, without a camera.
    input  wire [7:0]  dbg_sec,
    input  wire [7:0]  dbg_min,
    input  wire [3:0]  key_pressed,
    input  wire [3:0]  remote_press,
    input  wire [15:0] frame_cnt,
    input  wire [3:0]  sd_phase,
    input  wire [7:0]  sd_err,
    input  wire [9:0]  win_w,
    input  wire [9:0]  win_h,
    input  wire        sdram_done,
    input  wire        sdram_failed,
    input  wire [15:0] sdram_errors,
    input  wire [7:0]  pll_rst_cnt,
    input  wire [15:0] ok_cnt,
    input  wire [15:0] err_cnt,
    input  wire [7:0]  sd_sec_bytes,
    input  wire [7:0]  music_cnt,      // SDRAM reads completed by the music player
    input  wire [4:0]  ld_state,      // wall_tf_load state (16/17 = the WAV pass)
    input  wire [1:0]  music_slot,    // {bank_ok[4], found[4]}
    input  wire [7:0]  ld_ent_cnt,    // root-directory entries processed
    input  wire [31:0] ld_ent4,       // first 4 name bytes of entry #4
    input  wire [7:0]  dump_byte,     // root-directory byte at dump_idx
    input  wire [7:0]  sd_flags,
    input  wire [7:0]  img_chk_err,
    input  wire        img_chk_done,
    input  wire        video_locked,
    input  wire        video_ready,
    input  wire [1:0]  sup_state,
    input  wire [7:0]  rec_cnt,
    output wire        uart_tx,
    input  wire [8:0]  dump_idx      // which root byte is being streamed
);
    localparam integer NLEN = 34;

    reg [22:0] tick;
    reg        start;
    always @(posedge clk) begin
        if (rst) begin
            tick  <= 23'd0;
            start <= 1'b0;
        end else if (tick == TICK_CYC - 1) begin
            tick  <= 23'd0;
            start <= 1'b1;
        end else begin
            tick  <= tick + 23'd1;
            start <= 1'b0;
        end
    end

    reg [5:0] bi;   // 34 bytes: 6 bits
    reg       sending;
    reg       seen_busy;
    wire      busy;
    reg       go;
    reg [7:0] byte_now;

    always @(*) begin
        case (bi)
            6'd0:    byte_now = 8'h57;                                            // 'W'
            6'd1:    byte_now = 8'h4C;                                            // 'L'
            6'd2:    byte_now = NODE_CH;
            6'd3:    byte_now = {3'b000, owner, dragging, frozen, sync_ok, link_ok};
            6'd4:    byte_now = {6'b000000, sel};
            6'd5:    byte_now = {4'b0000, gx[11:8]};                               // rendered gx
            6'd6:    byte_now = gx[7:0];
            6'd7:    byte_now = ok_cnt[15:8];
            6'd8:    byte_now = ok_cnt[7:0];
            6'd9:    byte_now = err_cnt[15:8];
            6'd10:   byte_now = err_cnt[7:0];
            6'd11:   byte_now = sd_sec_bytes;
            6'd12:   byte_now = sd_flags;
            6'd13:   byte_now = {2'b00, sup_state, 2'b00, video_ready, video_locked};
            6'd14:   byte_now = rec_cnt;
            6'd15:   byte_now = dbg_sec;      // was pll_rst_cnt (always 0)
            6'd16:   byte_now = {4'b0000, stage_gx[11:8]};                          // staged gx
            6'd17:   byte_now = stage_gx[7:0];
            6'd18:   byte_now = dbg_min;      // was rst_cnt (always 1)
            6'd19:   byte_now = img_chk_err;                                        // picture-RAM self-check
            6'd20:   byte_now = {4'b0000, sd_phase};
            6'd21:   byte_now = frame_cnt[15:8];
            6'd22:   byte_now = frame_cnt[7:0];
            6'd23:   byte_now = sd_err;                                             // loader error
            6'd24:   byte_now = {6'b000000, win_w[9:8]};
            6'd25:   byte_now = win_w[7:0];
            6'd26:   byte_now = {6'b000000, win_h[9:8]};
            6'd27:   byte_now = win_h[7:0];
            6'd28:   byte_now = sdram_errors[7:0];
            6'd29:   byte_now = sdram_errors[15:8];
            6'd30:   byte_now = {5'b00000, img_chk_done, sdram_failed, sdram_done};
            6'd31:   byte_now = 8'h5A;
            6'd32:   byte_now = 8'h0D;
            default: byte_now = 8'h0A;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            sending <= 1'b0;
            bi      <= 4'd0;
            go      <= 1'b0;
            seen_busy <= 1'b0;
        end else begin
            go <= 1'b0;
            if (!sending) begin
                if (start) begin
                    sending   <= 1'b1;
                    bi        <= 5'd0;
                    go        <= 1'b1;
                    seen_busy <= 1'b0;
                end
            end else if (!seen_busy) begin
                // The UART registers busy one cycle after go.  Wait for it,
                // otherwise the FSM advances twice and drops a byte (that bug
                // ate every 'L' in the first board bring-up).
                if (busy) seen_busy <= 1'b1;
            end else if (!busy) begin
                seen_busy <= 1'b0;
                if (bi == NLEN - 1) begin
                    sending <= 1'b0;
                end else begin
                    bi <= bi + 5'd1;
                    go <= 1'b1;
                end
            end
        end
    end

    wall_uart_tx u_tx (
        .clk(clk), .go(go), .data(byte_now), .tx(uart_tx), .busy(busy)
    );
endmodule
