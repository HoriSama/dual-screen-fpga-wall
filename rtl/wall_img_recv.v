//=============================================================================
// wall_img_recv.v -- rebuild A's pictures on B from KIND-2 link frames
//
// Mirror of wall_img_push: B has no card, so the only way its SDRAM gets the
// 192x144 RGB565 thumbnails (regions 0..3) and the four 640x480 1:1 copies
// (regions 4..7, the album-mode sources) is this path.  A seam-crossing window
// then shows the same photo on both halves.
//
// Two clock domains, same handshake the STATE frame already uses:
//   * link domain: on a 0x03 frame unpack the 16 words + (region, block) tag
//     into a holding register and flip i_tog;
//   * pixel domain: 2FF-sync i_tog, copy the holding register, then write the
//     16 words into SDRAM through a toggle mailbox (one 32-bit word at a time).
//
// Frame layout (see wall_img_push):
//   byte 0     : {5'b0, region[2:0]}  0..3 thumbnail, 4..7 1:1 copy
//   byte 1     : block[7:0]
//   byte 2     : block[15:8]
//   bytes 3..34: 16 words, low byte then high byte (RGB565, 16 bits each)
//=============================================================================
`timescale 1ns/1ps

module wall_img_recv #(
    parameter integer BLK_PER_BANK = 1728,     // must match wall_img_push
    parameter integer PIC0         = 1848320,  // must match wall_img_push
    parameter integer PIC_STRIDE   = 62208,    // must match wall_img_push
    parameter integer HIB          = 619520    // must match wall_img_push
)(
    // ---- link clock domain ------------------------------------------------
    input  wire         lclk,
    input  wire         lrst,
    input  wire         frame,        // 1-cycle pulse from wall_link_rx
    input  wire [7:0]   f_type,
    input  wire [319:0] payload,
    // ---- pixel clock domain -----------------------------------------------
    input  wire         pclk,
    input  wire         prst,
    output reg  [16:0]  got,          // blocks received (17 bit: a full pass is 83,712)
    output reg  [4:0]   step,         // 0 idle, 1..16 writing
    // ---- 150 MHz SDRAM write client ---------------------------------------
    input  wire         clk150,
    input  wire         rst150,
    output reg          wr_valid,
    output reg  [20:0]  wr_addr,
    output reg  [31:0]  wr_data,
    input  wire         wr_ready
);
    localparam [7:0] T_IMG = 8'h03;

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

    // ---- link domain: unpack one block ------------------------------------
    reg [15:0] w [0:15];
    integer i;
    always @(*) begin
        for (i = 0; i < 16; i = i + 1)
            w[i] = {payload[8*(4+2*i) +: 8], payload[8*(3+2*i) +: 8]};
    end

    reg [255:0] iw;
    reg [2:0]   ireg;
    reg [15:0]  iblk;
    reg         i_tog;

    always @(posedge lclk) begin
        if (lrst) begin
            iw    <= 256'd0;
            ireg  <= 3'd0;
            iblk  <= 16'd0;
            i_tog <= 1'b0;
        end else if (frame && (f_type == T_IMG)) begin
            for (i = 0; i < 16; i = i + 1) iw[16*i +: 16] <= w[i];
            ireg <= payload[2:0];
            iblk <= {payload[23:16], payload[15:8]};
            i_tog <= ~i_tog;
        end
    end

    // ---- pixel domain: write the block to SDRAM ---------------------------
    reg [2:0]   t_sync;
    reg         t_seen;
    reg [255:0] lw;

    // write mailbox
    reg        wr_req_tgl;
    reg        wr_ack_s1, wr_ack_s2;
    reg        wr_wait;
    reg [20:0] wr_addr_hold;
    reg [31:0] wr_data_hold;
    wire       wr_ack_tgl;             // from 150 MHz

    always @(posedge pclk) begin
        if (prst) begin
            t_sync <= 3'd0; t_seen <= 1'b0;
            got <= 17'd0; step <= 5'd0;
            lw <= 256'd0;
            wr_req_tgl <= 1'b0; wr_ack_s1 <= 1'b0; wr_ack_s2 <= 1'b0;
            wr_wait <= 1'b0; wr_addr_hold <= 21'd0; wr_data_hold <= 32'd0;
        end else begin
            wr_ack_s1 <= wr_ack_tgl;
            wr_ack_s2 <= wr_ack_s1;
            if (wr_wait && (wr_ack_s2 == wr_req_tgl)) wr_wait <= 1'b0;

            t_sync <= {t_sync[1:0], i_tog};
            if (t_sync[2] != t_seen) begin
                t_seen <= t_sync[2];
                lw     <= iw;
                step   <= 5'd1;
                got    <= got + 17'd1;
                // start writing word 0
                wr_addr_hold <= pic_base(ireg) + ({5'd0, iblk} << 4);
                wr_data_hold <= {16'd0, iw[15:0]};
                wr_req_tgl <= ~wr_req_tgl;
                wr_wait <= 1'b1;
            end else if (step != 5'd0) begin
                if (wr_wait && (wr_ack_s2 == wr_req_tgl)) begin
                    wr_wait <= 1'b0;
                    if (step == 5'd16) begin
                        step <= 5'd0;
                    end else begin
                        wr_addr_hold <= wr_addr_hold + 21'd1;
                        wr_data_hold <= {16'd0, lw[16*step +: 16]};
                        wr_req_tgl <= ~wr_req_tgl;
                        wr_wait <= 1'b1;
                        step <= step + 5'd1;
                    end
                end
            end
        end
    end

    // ---- 150 MHz write side ------------------------------------------------
    reg        wreq_s1, wreq_s2;
    reg        w_pend;
    reg [20:0] w_addr_q;
    reg [31:0] w_data_q;
    reg        wr_ack_tgl_r;

    assign wr_ack_tgl = wr_ack_tgl_r;

    always @(posedge clk150) begin
        if (rst150) begin
            wreq_s1 <= 1'b0; wreq_s2 <= 1'b0; wr_ack_tgl_r <= 1'b0;
            w_pend <= 1'b0; w_addr_q <= 21'd0; w_data_q <= 32'd0;
            wr_valid <= 1'b0; wr_addr <= 21'd0; wr_data <= 32'd0;
        end else begin
            wreq_s1 <= wr_req_tgl;
            wreq_s2 <= wreq_s1;
            if (!w_pend && (wreq_s2 != wr_ack_tgl_r)) begin
                w_addr_q <= wr_addr_hold;
                w_data_q <= wr_data_hold;
                w_pend   <= 1'b1;
                wr_valid <= 1'b1;
                wr_addr  <= wr_addr_hold;
                wr_data  <= wr_data_hold;
            end
            if (w_pend && wr_valid && wr_ready) begin
                wr_valid    <= 1'b0;
                w_pend      <= 1'b0;
                wr_ack_tgl_r <= wreq_s2;
            end
        end
    end
endmodule
