//=============================================================================
// wall_pic_line.v -- SDRAM -> line buffer for the picture windows
//
// Four windows, each with a two-bank ping-pong line buffer, 640 x 16 bit.
// The 150 MHz side fills one bank with an SDRAM burst while the 25 MHz side
// reads the other.
//
// C3 (album mode) made the row 640 words wide instead of 192 because a
// FRAMELESS window (record bit 58) shows a 640x480 1:1 copy in SDRAM, one
// source pixel per screen pixel.  A request now carries
//   * the burst start address (base + row * stride), computed in the 25 MHz
//     domain where there is slack -- the 150 MHz burst loop used to compute it
//     from the row register, and the 150 MHz domain historically has only
//     +0.1..+0.5 ns, so no multiplier belongs there;
//   * the last column (191 for a 192-wide thumbnail, 639 for the 1:1 copy).
// The stride is 640 for both, so the column index alone selects the word and
// the buffer layout is uniform: word = bank*640 + window*640 + column.
//
// C9: there are now FOUR 1:1 copies (CAM1..CAM4) at HIB + idx*HI_STRIDE, and the
// frameless record's [60:59] field says which one this window shows.  The index
// is latched together with the request (like the burst base), so the 150 MHz
// side still only muxes registers.
//
// THE BANK SWAP HAPPENS AT THE LINE BOUNDARY, not when the fill finishes.
// The first version flipped the read pointer on the fill-complete ack, which
// tore every line as soon as a burst finished mid-line: the top of the display
// line showed the old source row and the bottom the new one, and because the
// finish time drifts the tear moved every frame -- on the board that is a
// flickering, still-soft picture.  Now:
//   * `prime` (frame start) may request row 0 without swapping;
//   * `line_tick` (start of each active line) swaps rd_bank for every window
//     that has a finished fill, then requests the NEXT line's row into the bank
//     that just became free;
//   * a window whose fill has not finished by the line tick simply keeps
//     showing the previous row for another line (a one-line vertical hold),
//     which is far less objectionable than a tear.
// The request carries the target bank, so the 150 MHz side never keeps its own
// copy of the read pointer and the two sides cannot drift apart.
//
// `nxt_valid[w]` comes from wall_pic_prefetch and marks the windows that
// actually show picture content on the target line; invisible windows are not
// fetched, which is what keeps four bursts out of every line.
//=============================================================================
`timescale 1ns/1ps

module wall_pic_line #(
    parameter integer NWIN = 4,
    // Row capacity per window.  640 words covers both the 192-wide thumbnail
    // (only the first 192 are ever written/read) and the 640-wide album row, so
    // one uniform stride serves both and the burst length is what differs.
    parameter integer LINE = 640,
    parameter integer PIC0       = 1848320,
    parameter integer PIC_STRIDE = 62208,     // 288x216 slot between thumbnails
    parameter integer HIB        = 619520,    // first of the 640x480 1:1 copies
    parameter integer HI_STRIDE  = 307200     // 640x480 words: the gap between them
)(
    // ---- 25 MHz domain ----------------------------------------------------
    input  wire        clk25,
    input  wire        rst25,
    input  wire        prime,         // frame start: request row 0, no swap
    input  wire        line_tick,     // start of an active line: swap + request
    input  wire [35:0] nxt_rows,      // 4 x 9-bit row for the line after this one
    input  wire [3:0]  nxt_valid,     // 4 x "this window needs a row"
    input  wire [3:0]  nxt_hi,        // 4 x "this window reads a 640x480 copy"
    input  wire [7:0]  nxt_idx,       // 4 x 2-bit: which copy (0..3 = CAM1..4)
    input  wire [39:0] nxt_c1,        // 4 x 10-bit: last column this node can show
    input  wire [2:0]  rd_win,        // {frameless, window} whose bank is being read
    input  wire [9:0]  rd_col,        // 0..191 thumbnail, 0..639 full resolution
    output reg  [15:0] rd_data,       // RGB565, one cycle after rd_win/rd_col
    // ---- carousel (轮播) --------------------------------------------------
    // Picture index offset, 0..3, advanced every 64 frames.  Window w shows
    // picture (w + car_cyc) mod 4, so with car_cyc = 0 the mapping is exactly
    // the original "window i shows picture i".  Both nodes derive this from the
    // SAME source (A: frame_cnt, B: the seq byte mirrored in the STATE frame),
    // so the two halves of the wall never disagree about what to display.
    //
    // ⚠ The offset has to be in the FETCH ADDRESS (`sch + car_l` below), not
    // only in the invalidation: the C3 rewrite of this module dropped it from
    // `req_addr` and kept only `car_chg`, so from C3 to C9 the phase advanced,
    // the fade pulsed and the brightness table rotated -- but every window kept
    // showing the SAME picture.  Symptom on the board: auto-rotation and the
    // VIEW-mode KEY3 single step did nothing visible.  `tb_carousel` is the
    // test for exactly this and must pass (it failed from C3 until this fix).
    input  wire [1:0]  car_cyc,
    // Diagnostic (C9-R2/R3): number of line ticks in the last frame at which a
    // VISIBLE window had to show a stale source row because its burst had not
    // landed yet.  0 = the read port keeps up; a large value is exactly the
    // judder the operator sees while a picture is moved up/down.  `late_msk`
    // says WHICH windows starved, so "only PIC3" can be told apart from "all".
    output reg  [7:0]  late_cnt,
    output reg  [3:0]  late_msk,
    // ---- 150 MHz SDRAM client --------------------------------------------
    input  wire        clk150,
    input  wire        rst150,
    output reg         rd_valid,
    output reg  [20:0] rd_addr,
    input  wire        rd_ready,
    input  wire        rvalid,
    input  wire [31:0] rdata,
    // High while a row burst is in progress.  The picture pusher uses this to
    // stay out of the SDRAM read port while the line buffer is filling: the
    // cached adapter holds ONE 4-word group, so a single foreign read between
    // two group words evicts it and turns the burst's 3-of-4 hits into misses.
    output wire        busy
);
    // SDRAM word address of row 0 of a source
    //   hi = 0 : thumbnail `pic`  (C9-R1: pic = window + carousel phase, mod 4)
    //   hi = 1 : 1:1 copy `idx`,   HIB  + idx*HI_STRIDE
    function [20:0] pic_base;
        input        hi;
        input [1:0]  idx;
        input [1:0]  pic;
        begin
            // 307200 = 2^18+2^15+2^13+2^12: a shift-and-add of a 2-bit index,
            // i.e. two adders, not a multiplier.
            if (hi) pic_base = HIB[20:0] + ({19'd0, idx} << 18) + ({19'd0, idx} << 15)
                                        + ({19'd0, idx} << 13) + ({19'd0, idx} << 12);
            else    pic_base = PIC0[20:0] + pic * PIC_STRIDE;
        end
    endfunction

    // ---- line buffer: NWIN x 2 ping-pong x LINE x 16 bit ------------------
    // bank index = bank*NWIN + win (3 bits); address = (bank*NWIN+win)*LINE +
    // column.  Declared 8192 deep on purpose: the used depth is 8*640 = 5120,
    // which TD narrows to the 13 address bits it can prove, so it still infers
    // real BRAM (a shallower array makes TD pick distributed LUTRAM, which blew
    // the 150 MHz domain up to 3938 endpoints and -1.4 ns).
    // No reset on the array: unread banks are never exposed, and a reset-free
    // array is what lets TD infer embedded RAM.
    (* ram_style = "block", ramstyle = "M9K" *) reg [15:0] lb [0:8191];

    // ---- 25 MHz side -------------------------------------------------------
    reg [3:0]  rd_bank;              // bank the scene reads, per window
    reg [3:0]  filled;               // fill finished, awaiting the line tick
    reg [3:0]  pend;                 // request in flight, per window
    reg [3:0]  req_tgl;              // request toggle, per window
    reg [8:0]  last_row [0:3];       // last row requested per window (row reuse)
    reg [3:0]  ack_s1, ack_s2;       // ack_tgl synchroniser
    wire [3:0] ack_tgl;              // from the 150 MHz side
    wire [3:0] ack_edge = ack_s2 ^ ack_s1;
    reg [1:0]  car_cyc_q;            // previous carousel phase

    // burst start / last column per window, latched with the request
    reg [20:0] req_base [0:3];
    reg [9:0]  req_last [0:3];
    reg [3:0]  req_bank_r;           // bank to fill, per window

    wire [2:0] rd_bank3 = {rd_bank[rd_win[1:0]], rd_win[1:0]};
    wire [12:0] lb_rd_addr = (rd_bank3 * LINE) + {3'd0, rd_col};

    // Row reuse: at 192x144 the source row only changes on ~74% of display
    // lines (144 source rows over 194 drawn rows), so re-fetching the same row
    // is pure waste on an already tight SDRAM read port.
    genvar gr;
    wire [3:0] row_chg;
    generate
        for (gr = 0; gr < 4; gr = gr + 1) begin : g_chg
            assign row_chg[gr] = (nxt_rows[gr*9 +: 9] != last_row[gr]);
        end
    endgenerate

    // swap decision (line boundary only) and the request decision
    wire [3:0] swap_vec = line_tick ? (filled & ~pend) : 4'd0;
    wire [3:0] nb       = rd_bank ^ swap_vec;          // read bank after the tick
    wire [3:0] want_req = {4{(prime | line_tick)}} & nxt_valid & ~pend
                          & ~(filled & ~swap_vec) & row_chg;
    wire [3:0] fill_sel = ~nb;                         // never the bank being read

    // 4-cycle request scan (one window per cycle)
    reg [1:0]  sch;
    reg        sch_run;
    reg [3:0]  req_vec_l;
    reg [35:0] rows_l;
    reg [7:0]  idx_l;
    reg [39:0] c1_l;             // last column per window, latched with the scan
    reg [1:0]  car_l;            // carousel phase, latched with the scan
    reg [3:0]  hi_l;
    reg [3:0]  banks_l;

    wire [3:0] issue_vec = (sch_run && req_vec_l[sch]) ? (4'd1 << sch) : 4'd0;

    // Every window now holds a DIFFERENT picture after a carousel step, so the
    // rows cached for the old picture are worthless: drop `filled` and force
    // row_chg (last_row = all-ones) so the very next scan refetches.  Only step
    // when nothing is in flight, otherwise a request issued with the old
    // picture index would land in the bank we are about to display.
    wire car_chg = (car_cyc != car_cyc_q) && (pend == 4'd0);

    // A frameless (album) window is fed from one of the four 640x480 copies: a
    // 640-word burst of 640-wide rows; everything else is a 192-word burst.
    wire [3:0]  hi_use  = nxt_hi;               // latched with the request scan
    wire [7:0]  idx_use = nxt_idx;              // ditto: 2 bits per window
    wire [39:0] c1_use  = nxt_c1;               // ditto: last column per window

    // burst start address of window `s` for row `rows_l[s]`
    function [20:0] req_addr;
        input        hi;            // 1 = a 1:1 copy, 0 = a thumbnail
        input [1:0]  idx;           // which copy (only used when hi)
        input [1:0]  pic;           // which thumbnail (window + carousel phase)
        input [8:0]  row;
        reg   [20:0] rowoff;
        begin
            // 640 = 512+128, 192 = 128+64: shifts only, no multiplier
            rowoff  = hi ? (({12'd0, row} << 9) + ({12'd0, row} << 7))
                         : (({12'd0, row} << 7) + ({12'd0, row} << 6));
            req_addr = pic_base(hi, idx, pic) + rowoff;
        end
    endfunction

    integer s;
    always @(posedge clk25) begin
        if (rst25) begin
            rd_bank <= 4'd0; filled <= 4'd0; pend <= 4'd0; req_tgl <= 4'd0;
            req_bank_r <= 4'd0;
            for (s = 0; s < 4; s = s + 1) begin
                last_row[s] <= 9'h1FF;              // pattern never seen -> first fetch happens
                req_base[s] <= 21'd0;
                req_last[s] <= 10'd191;
            end
            ack_s1 <= 4'd0; ack_s2 <= 4'd0;
            sch <= 2'd0; sch_run <= 1'b0; req_vec_l <= 4'd0;
            rows_l <= 36'd0; idx_l <= 8'd0; c1_l <= 40'd0; car_l <= 2'd0; hi_l <= 4'd0; banks_l <= 4'd0;
            car_cyc_q <= 2'd0; late_cnt <= 8'd0; late_msk <= 4'd0;
        end else begin
            ack_s1 <= ack_tgl;
            ack_s2 <= ack_s1;

            // bank swap at the line boundary
            rd_bank <= nb;
            filled  <= (filled & ~swap_vec) | ack_edge;
            pend    <= (pend & ~ack_edge) | issue_vec;

            // diagnostic (C9-R2/R3): a fill that was issued at the previous line
            // tick and is STILL in flight now means the burst did not finish in
            // one line, so this window has to keep the old row -- exactly the
            // judder the operator sees while a picture is moved up/down.
            // `late_msk` keeps the per-window picture, which is what tells
            // "only the lowest-priority window starves" from "the port is short".
            if (prime) begin
                late_cnt <= 8'd0;
                late_msk <= 4'd0;
            end else begin
                if (line_tick && (|(nxt_valid & pend)))
                    late_cnt <= (late_cnt == 8'hFF) ? 8'hFF : (late_cnt + 8'd1);
                late_msk <= late_msk | (line_tick ? (nxt_valid & pend) : 4'd0);
            end

            // start a request scan at every tick
            if (prime | line_tick) begin
                sch       <= 2'd0;
                sch_run   <= 1'b1;
                req_vec_l <= want_req;
                rows_l    <= nxt_rows;
                idx_l     <= idx_use;
                c1_l      <= c1_use;
                car_l     <= car_cyc;          // whole scan uses one phase
                hi_l      <= hi_use;
                banks_l   <= fill_sel;
            end else if (sch_run) begin
                if (sch == 2'd3) sch_run <= 1'b0;
                else             sch     <= sch + 2'd1;
            end

            // issue one request this cycle
            if (sch_run && req_vec_l[sch]) begin
                last_row[sch]  <= rows_l[sch*9 +: 9];
                req_bank_r[sch] <= banks_l[sch];
                req_base[sch]   <= req_addr(hi_l[sch], idx_l[sch*2 +: 2],
                                            sch[1:0] + car_l,
                                            rows_l[sch*9 +: 9]);
                req_last[sch]   <= c1_l[sch*10 +: 10];
                req_tgl[sch]    <= ~req_tgl[sch];
            end

            // Carousel step: the cached rows belong to the previous picture, so
            // drop them and force a refetch on the next scan.  This sits AFTER
            // the normal assignments on purpose -- a later non-blocking assign
            // to the same bits wins, so the invalidation overrides them.
            // car_cyc_q advances ONLY here: updating it unconditionally lost the
            // step whenever a request happened to be in flight on that clock
            // (pend != 0), which is why node B could sit on one picture while
            // node A rotated.
            if (car_chg) begin
                car_cyc_q <= car_cyc;
                filled    <= 4'd0;
                for (s = 0; s < 4; s = s + 1) last_row[s] <= 9'h1FF;
            end
        end
    end

    always @(posedge clk25) begin
        rd_data <= lb[lb_rd_addr];
    end

    // ---- 150 MHz burst side ------------------------------------------------
    reg [3:0] req_s1, req_s2;        // req_tgl synchroniser
    reg [3:0] ack_tgl_r;             // -> ack_tgl

    assign ack_tgl = ack_tgl_r;

    localparam [1:0] B_IDLE = 2'd0, B_ADDR = 2'd1, B_REQ = 2'd2, B_WAIT = 2'd3;

    reg [1:0]  bst;
    reg [1:0]  wr_win;
    reg        wr_bank;               // bank to fill (from the request)
    reg [9:0]  wr_col;
    reg [20:0] wr_base;               // burst start address (from the request)
    reg [9:0]  wr_last;               // last column of the burst

    // busy for the whole burst: B_ADDR / B_REQ / B_WAIT all mean a word is still
    // in flight, so the pusher keeps off the port for the whole time.
    assign busy = (bst != B_IDLE);

    wire [3:0]  pend_150 = req_s2 ^ ack_tgl_r;
    wire [1:0]  next_win = pend_150[0] ? 2'd0 : pend_150[1] ? 2'd1 :
                           pend_150[2] ? 2'd2 : 2'd3;
    wire [2:0]  wr_bank3 = {wr_bank, wr_win};
    wire [12:0] lb_wr_addr = (wr_bank3 * LINE) + {3'd0, wr_col};

    always @(posedge clk150) begin
        if (rst150) begin
            req_s1 <= 4'd0; req_s2 <= 4'd0; ack_tgl_r <= 4'd0;
            bst <= B_IDLE; wr_win <= 2'd0; wr_bank <= 1'b0; wr_col <= 10'd0;
            wr_base <= 21'd0; wr_last <= 10'd191;
            rd_valid <= 1'b0; rd_addr <= 21'd0;
        end else begin
            req_s1 <= req_tgl;
            req_s2 <= req_s1;

            rd_valid <= 1'b0;

            case (bst)
                B_IDLE: begin
                    if (pend_150 != 4'd0) begin
                        // Only 4-way muxes from registers here: the address math
                        // itself already happened in the 25 MHz domain.
                        wr_win  <= next_win;
                        wr_bank <= req_bank_r[next_win];
                        wr_col  <= 10'd0;
                        wr_base <= req_base[next_win];
                        wr_last <= req_last[next_win];
                        bst     <= B_ADDR;
                    end
                end
                B_ADDR: begin
                    rd_addr  <= wr_base;
                    rd_valid <= 1'b1;
                    bst      <= B_REQ;
                end
                B_REQ: begin
                    if (rd_ready) begin
                        rd_valid <= 1'b0;
                        bst <= B_WAIT;
                    end else begin
                        rd_valid <= 1'b1;   // hold the request until accepted
                    end
                end
                B_WAIT: begin
                    if (rvalid) begin
                        lb[lb_wr_addr] <= rdata[15:0];
                        if (wr_col == wr_last) begin
                            ack_tgl_r[wr_win] <= req_s2[wr_win];
                            bst <= B_IDLE;
                        end else begin
                            wr_col  <= wr_col + 10'd1;
                            rd_addr <= rd_addr + 21'd1;
                            rd_valid <= 1'b1;
                            bst <= B_REQ;
                        end
                    end
                end
                default: bst <= B_IDLE;
            endcase
        end
    end

endmodule
