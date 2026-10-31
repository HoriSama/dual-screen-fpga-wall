//=============================================================================
// wall_img_push.v -- carousel A's pictures to B over the 4-bit link
//
// Only node A has a TF card, but the wall is drawn by two boards.  A loads
// FOUR 192x144 RGB565 pictures plus FOUR 640x480 RGB565 1:1 copies into its own
// SDRAM, then walks the whole 83,712-block region forever, 16 words per frame,
// and B overwrites its SDRAM.  A full pass takes ~1.5 s, so any dropped block is
// repaired on the next pass and B's picture converges without an
// acknowledgement channel.
//
// The C4 extension (album mode): the 640x480 copy that wall_tf_load writes at
// HI_BASE must reach node B too, otherwise B's half of an album window would
// only have the 192x144 thumbnail to show.  C9 grew that from one copy to four
// (one per picture, so the album can page through all of them): 4 x 19,200 more
// 16-word blocks, i.e. 12.8x the old traffic, and the wire still has room (one
// block takes ~12.5 us of a 16.7 ms frame).
//
// Region map (see docs/10_album_plan.md, C9):
//   region 0..3 : the four 192x144 pictures, 1728 blocks each  @ PIC0
//   region 4..7 : the four 640x480 1:1 copies, 19200 blocks each
//                 @ HIB + n*307200   (C9: was a single region 4)
//
// The picture words live in SDRAM, so this module reads them through a toggle
// mailbox (one 32-bit word per handshake), 16 words per block.
//
// Frame layout (mirror: wall_img_recv):
//   byte 0     : {5'b0, region[2:0]}   0..3 = thumbnail, 4..7 = 1:1 copy
//   byte 1     : block[7:0]           block index INSIDE the region
//   byte 2     : block[15:8]          (was {4'b0, block[11:8]}; the 640x480
//                                      copy needs 15 bits, and byte 2 had the
//                                      room, so the field is now full width)
//   bytes 3..34: 16 words, low byte then high byte (RGB565, 16 bits each)
//=============================================================================
`timescale 1ns/1ps

module wall_img_push #(
    parameter integer BLK_PER_BANK = 1728,     // 27648 / 16  (192x144 RGB565)
    parameter integer BLK_HI       = 19200,    // 307200 / 16 (640x480 RGB565)
    parameter integer HI_N         = 4,        // C9: one 1:1 copy per picture
    parameter integer PIC0         = 1848320,  // SDRAM word address of picture 0
    parameter integer PIC_STRIDE   = 62208,    // 288x216 slot between pictures (only 192x144 used)
    parameter integer HIB          = 619520    // SDRAM word address of HI0
)(
    input  wire         clk,          // 25 MHz
    input  wire         rst,
    input  wire         allow,        // mid-frame window: the link wire is free
    input  wire         tx_busy,
    output reg          start_tog,    // -> wall_link_tx.start_tog
    output reg  [279:0] pay,          // -> wall_link_tx.ipay (latched)
    output reg  [16:0]  cur_blk,      // diagnostic (global block index 0..83,711)
    output reg  [15:0]  blocks,       // frames sent since reset
    output wire  [7:0]  dbg,          // {rst150, clk150_tog, rreq_s1, rreq_s2, rd_req_tgl, rd_ack_tgl_r, rd_pend, rd_valid}
    // ---- 150 MHz SDRAM read client ----------------------------------------
    input  wire         clk150,
    input  wire         rst150,
    output reg          rd_valid,
    output reg  [20:0]  rd_addr,
    input  wire         rd_ready,
    input  wire         rvalid,
    input  wire [31:0]  rdata
);
    localparam integer BLK_4PIC = 4 * BLK_PER_BANK;
    localparam integer BLK_ALL  = BLK_4PIC + HI_N * BLK_HI;
    localparam [16:0]  CUR_LAST = BLK_ALL - 1;

    // SDRAM word address of block 0 of a region (0..3 = thumbnail, 4..7 = 1:1)
    function [20:0] pic_base;
        input [2:0] b;
        begin
            if (b >= 3'd4)
                pic_base = HIB[20:0] + ({18'd0, (b - 3'd4)} * 21'd307200);
            else
                pic_base = PIC0[20:0] + b * PIC_STRIDE;
        end
    endfunction

    localparam [2:0] S_IDLE = 3'd0, S_READ = 3'd1, S_SEND = 3'd2,
                     S_HI   = 3'd3, S_LO   = 3'd4;

    reg [2:0]  st;
    reg [15:0] stg [0:15];
    reg [2:0]  region;
    reg [15:0] block;          // 0..19199 inside the region
    reg [3:0]  rcnt;           // 0..15 word being read

    // region decode from the rolling block counter: one comparison per boundary
    // (a divide-by-1728 would be far more logic for the same answer)
    wire [2:0] reg_n = (cur_blk >= 3*BLK_PER_BANK) ? 3'd3 :
                       (cur_blk >= 2*BLK_PER_BANK) ? 3'd2 :
                       (cur_blk >=   BLK_PER_BANK) ? 3'd1 : 3'd0;
    reg  [15:0] blk_in;
    always @(*) begin
        case (reg_n)
            3'd0:    blk_in = cur_blk;
            3'd1:    blk_in = cur_blk - BLK_PER_BANK;
            3'd2:    blk_in = cur_blk - 2*BLK_PER_BANK;
            default: blk_in = cur_blk - 3*BLK_PER_BANK;
        endcase
    end

    // C9: regions 4..7 are the four 1:1 copies (19,200 blocks each).  Same trick
    // as above -- three comparisons instead of a divide by 19,200.
    wire [16:0] hi_off = cur_blk - BLK_4PIC;
    wire [2:0]  hi_n   = (hi_off < BLK_HI)     ? 3'd0 :
                         (hi_off < 2*BLK_HI)   ? 3'd1 :
                         (hi_off < 3*BLK_HI)   ? 3'd2 : 3'd3;
    wire [2:0]  region_n = (cur_blk >= BLK_4PIC) ? (3'd4 + hi_n) : reg_n;

    // block index INSIDE region 4..7 (0..19199)
    reg  [15:0] hi_blk_in;
    always @(*) begin
        case (hi_n)
            2'd0:    hi_blk_in = hi_off - 0;
            2'd1:    hi_blk_in = hi_off - BLK_HI;
            2'd2:    hi_blk_in = hi_off - 2*BLK_HI;
            default: hi_blk_in = hi_off - 3*BLK_HI;
        endcase
    end

    wire [15:0] blk_sel = (region_n >= 3'd4) ? hi_blk_in : blk_in;

    // ---- read mailbox (25 MHz side) ----------------------------------------
    // The ack sync and the burst FSM share ONE always block: rd_req_tgl and
    // rd_wait are driven only there (two always blocks driving them made TD
    // stop node A with "net rd_req_tgl is constantly driven from multiple
    // places" while node B, which has no pusher, built fine).
    reg        rd_req_tgl;              // -> 150 MHz
    reg        rd_ack_s1, rd_ack_s2;    // <- 150 MHz
    reg        rd_wait;                 // a word is in flight
    reg [20:0] rd_addr_hold;            // held across the toggle
    wire       rd_ack_tgl;              // from 150 MHz
    wire [15:0] rdata_sync;             // from 150 MHz

    // start a read of word `rcnt` of the current block.
    // The 21-bit widening on block is REQUIRED: `block << 4` alone is evaluated
    // at block's own width (16 bit) and the full-resolution blocks need 18.
    wire [20:0] want_addr = pic_base(region) + ({5'd0, block} << 4) + {20'd0, rcnt};

    integer k;
    reg [279:0] pay_c;
    always @(*) begin
        pay_c = 280'd0;
        pay_c[7:0]   = {5'd0, region};
        pay_c[15:8]  = block[7:0];
        pay_c[23:16] = block[15:8];
        for (k = 0; k < 16; k = k + 1) begin
            pay_c[8*(3+2*k) + 7 -: 8] = stg[k][7:0];
            pay_c[8*(4+2*k) + 7 -: 8] = stg[k][15:8];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; rcnt <= 4'd0; start_tog <= 1'b0; pay <= 280'd0;
            cur_blk <= 17'd0; blocks <= 16'd0; region <= 3'd0; block <= 16'd0;
            rd_req_tgl <= 1'b0; rd_ack_s1 <= 1'b0; rd_ack_s2 <= 1'b0;
            rd_wait <= 1'b0; rd_addr_hold <= 21'd0;
            for (k = 0; k < 16; k = k + 1) stg[k] <= 16'd0;
        end else begin
            // mailbox ack synchroniser + "word landed" flag
            rd_ack_s1 <= rd_ack_tgl;
            rd_ack_s2 <= rd_ack_s1;
            if (rd_wait && (rd_ack_s2 == rd_req_tgl)) rd_wait <= 1'b0;
            case (st)
                S_IDLE: begin
                    rcnt  <= 4'd0;
                    region <= region_n;
                    block <= blk_sel;
                    rd_addr_hold <= pic_base(region_n) + ({5'd0, blk_sel} << 4);
                    rd_req_tgl <= ~rd_req_tgl;
                    rd_wait <= 1'b1;
                    st <= S_READ;
                end
                S_READ: begin
                    if (rd_wait && (rd_ack_s2 == rd_req_tgl)) begin
                        stg[rcnt] <= rdata_sync;
                        rd_wait <= 1'b0;
                        if (rcnt == 4'd15) begin
                            st <= S_SEND;
                        end else begin
                            rcnt <= rcnt + 4'd1;
                            rd_addr_hold <= want_addr + 21'd1;
                            rd_req_tgl <= ~rd_req_tgl;
                            rd_wait <= 1'b1;
                        end
                    end
                end
                S_SEND: begin
                    if (allow && !tx_busy) begin
                        pay       <= pay_c;
                        start_tog <= ~start_tog;
                        blocks    <= blocks + 16'd1;
                        st        <= S_HI;
                    end
                end
                S_HI: if (tx_busy) st <= S_LO;
                default: begin
                    if (!tx_busy) begin
                        cur_blk <= (cur_blk == CUR_LAST) ? 17'd0 : (cur_blk + 17'd1);
                        st      <= S_IDLE;
                    end
                end
            endcase
        end
    end

    // ---- 150 MHz read side -------------------------------------------------
    wire [31:0] rdata_hold;
    reg         rreq_s1, rreq_s2;
    reg         rd_pend;
    reg  [20:0] rd_addr_q;
    reg  [31:0] rdata_hold_r;
    reg         rd_ack_tgl_r;

    assign rd_ack_tgl = rd_ack_tgl_r;
    assign rdata_hold = rdata_hold_r;

    always @(posedge clk150) begin
        if (rst150) begin
            rreq_s1 <= 1'b0; rreq_s2 <= 1'b0; rd_ack_tgl_r <= 1'b0;
            rd_pend <= 1'b0; rd_addr_q <= 21'd0; rdata_hold_r <= 32'd0;
            rd_valid <= 1'b0; rd_addr <= 21'd0;
        end else begin
            rreq_s1 <= rd_req_tgl;
            rreq_s2 <= rreq_s1;
            if (!rd_pend && (rreq_s2 != rd_ack_tgl_r)) begin
                rd_addr_q <= rd_addr_hold;   // held stable across the toggle
                rd_pend   <= 1'b1;
                rd_valid  <= 1'b1;
                rd_addr   <= rd_addr_hold;
            end
            if (rd_pend && rd_valid && rd_ready) rd_valid <= 1'b0;
            if (rd_pend && rvalid) begin
                rdata_hold_r <= rdata;
                rd_ack_tgl_r <= rreq_s2;
                rd_pend      <= 1'b0;
            end
        end
    end

    // read data returned by the 150 MHz side (2FF into the pixel domain)
    reg [31:0] rdata_s1, rdata_s2;
    always @(posedge clk) begin
        rdata_s1 <= rdata_hold;
        rdata_s2 <= rdata_s1;
    end
    assign rdata_sync = rdata_s2[15:0];

    // on-board probe: {st[2:0], rd_valid, rd_ready, rvalid, rd_wait}
    // free-running 150 MHz toggle: proves the clock runs even under reset
    reg clk150_tog;
    always @(posedge clk150) clk150_tog <= ~clk150_tog;

    assign dbg = {rst150, clk150_tog, rreq_s1, rreq_s2, rd_req_tgl, rd_ack_tgl_r, rd_pend, rd_valid};
endmodule
