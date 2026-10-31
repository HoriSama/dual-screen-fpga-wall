//=============================================================================
// tb_img_link.v -- A's SDRAM pictures -> link -> B's SDRAM, word for word
//
// Models A's SDRAM picture block (2-cycle read, always ready, and a picture
// line-buffer burst that hogs the shared read port ~30% of the time), the real
// wall_link_tx / wall_link_rx pair (KIND-2 frames) and B's receiver writing
// straight into B's SDRAM.
//
// C4 added a FIFTH SDRAM region -- the 640x480 1:1 copy that album mode
// displays -- and widened the on-wire block index from 12 to 15 bits.  C9 grew
// that to EIGHT regions: 0..3 thumbnails, 4..7 one 640x480 copy per picture
// (83,712 blocks in total).  This test therefore walks every region boundary
// instead of one region: it steers the pusher's rolling block counter
// (hierarchically) to just before each boundary, so 0->1, 1->2, 2->3, 3->4,
// 4->5, 5->6, 6->7 and the wrap from the last block back to 0 are all exercised
// at the REAL geometry (1728 blocks per thumbnail, 19200 per 1:1 copy).
//
// Every block sent is remembered, and at the end every one of its 16 words must
// be in the right place with the right value -- and nothing else may have been
// written anywhere.
//
//   vsim -c -do "run -all; quit -f" tb_img_link
//=============================================================================
`timescale 1ns/1ps

module tb_img_link;
    localparam integer BLK_PER_BANK = 1728;      // 27648 / 16
    localparam integer BLK_HI       = 19200;     // 307200 / 16
    localparam integer BLK_4PIC     = 4 * BLK_PER_BANK;
    localparam integer HI_N         = 4;         // C9: one 1:1 copy per picture
    localparam integer BLK_ALL      = BLK_4PIC + HI_N * BLK_HI;   // 83712
    localparam integer PIC0         = 1848320;
    localparam integer PIC_STRIDE   = 62208;     // documented slot spacing (288x216)
    localparam integer HIB          = 619520;
    localparam integer HI_STRIDE    = 307200;

    reg clk = 1'b0;
    always #20 clk = ~clk;              // 25 MHz
    reg clk150 = 1'b0;
    always #3.333 clk150 = ~clk150;     // ~150 MHz

    reg rst = 1'b1;
    wire rx_clk = ~clk;                 // B samples with its forwarded clock

    // realistic nibble enable: 1/4 duty like the real 6.25 MHz link clock
    reg [1:0] ncnt = 2'd0;
    always @(posedge clk) ncnt <= ncnt + 2'd1;
    wire en_tx = (ncnt == 2'd2);
    wire en_rx = (ncnt == 2'd0);        // mid-nibble sample

    function [20:0] base_of;
        input integer r;
        begin
            if (r >= 4) base_of = HIB + (r - 4) * HI_STRIDE;
            else        base_of = PIC0 + r * PIC_STRIDE;
        end
    endfunction

    function [15:0] pat;
        input [20:0] a;
        begin
            pat = (a[15:0] ^ {a[11:0], 4'h5}) + 16'h1111;
        end
    endfunction

    // ---- push side --------------------------------------------------------
    wire         push_start_tog, push_tx_busy;
    wire [279:0] ipay;
    wire [16:0]  cur_blk;
    wire [15:0]  blocks;
    wire         p_rd_valid, p_rd_ready, p_rvalid;
    wire [20:0]  p_rd_addr;
    wire [31:0]  p_rdata;
    // declared before the pacer that reads them (Verilog needs the net first)
    wire [16:0]  r_got;
    wire [4:0]   r_step;
    wire         push_allow;

    wall_img_push #(
        .BLK_PER_BANK(BLK_PER_BANK), .BLK_HI(BLK_HI), .HI_N(HI_N),
        .PIC0(PIC0), .PIC_STRIDE(PIC_STRIDE), .HIB(HIB)
    ) u_push (
        .clk(clk), .rst(rst),
        .allow(push_allow),
        .tx_busy(push_tx_busy), .start_tog(push_start_tog), .pay(ipay),
        .cur_blk(cur_blk), .blocks(blocks), .dbg(),
        .clk150(clk150), .rst150(rst),
        .rd_valid(p_rd_valid), .rd_addr(p_rd_addr), .rd_ready(p_rd_ready),
        .rvalid(p_rvalid), .rdata(p_rdata)
    );

    // Pace the wire: the receiver holds exactly one block, so the next frame may
    // only start once it has been received AND written (the real design just
    // re-sends a dropped block on the next pass; here we must not drop any).
    wire push_allow_p = (blocks == r_got) && (r_step == 5'd0) && !rst;
    assign push_allow = push_allow_p;

    // A-SDRAM read model: 2-cycle response, shared port partly hogged by the
    // picture line-buffer burst (this is what the real arbiter looks like).
    reg [20:0] ap0, ap1;
    reg        v0, v1;
    reg [6:0]  hog_cnt = 7'd0;
    wire       hog_busy = (hog_cnt < 7'd38);
    always @(posedge clk150) hog_cnt <= (hog_cnt == 7'd126) ? 7'd0 : hog_cnt + 7'd1;
    always @(posedge clk150) begin
        if (rst) begin ap0 <= 21'd0; ap1 <= 21'd0; v0 <= 1'b0; v1 <= 1'b0; end
        else begin
            if (p_rd_valid && p_rd_ready) ap0 <= p_rd_addr;
            ap1 <= ap0;
            v0  <= p_rd_valid && p_rd_ready;
            v1  <= v0;
        end
    end
    assign p_rd_ready = p_rd_valid && !hog_busy;
    assign p_rvalid   = v1;
    assign p_rdata    = {16'd0, pat(ap1)};

    // ---- link -------------------------------------------------------------
    wire       tx_vld;
    wire [3:0] tx_d;
    wall_link_tx #(.FRAME_TYPE(8'h03), .KIND(2)) u_tx (
        .clk(clk), .rst(rst), .en(en_tx), .start_tog(push_start_tog),
        .seq(8'd0), .anim(5'd0), .sel(2'd0), .tbl(256'd0), .t_tlvl(5'd0), .t_osd(1'b1), .t_mute(1'b0), .t_marq(1'b0), .t_mp8(1'b0),
        .p0(8'd0), .p1(8'd0), .p2(8'd0), .ipay(ipay),
        .o_vld(tx_vld), .o_d(tx_d), .busy(push_tx_busy)
    );

    // ---- B's receiver + SDRAM write ---------------------------------------
    wire         rx_frame;
    wire [7:0]   rx_type, rx_len;
    wire [319:0] rx_payload;
    wire [15:0]  rx_err, rx_ok;

    wall_link_rx u_rx (
        .clk(clk), .rst(rst), .en(en_rx),
        .i_d(tx_d), .i_vld(tx_vld),
        .frame(rx_frame), .f_type(rx_type), .f_len(rx_len),
        .payload(rx_payload), .err_cnt(rx_err), .ok_cnt(rx_ok)
    );

    wire        r_wr_valid, r_wr_ready;
    wire [20:0] r_wr_addr;
    wire [31:0] r_wr_data;

    wall_img_recv #(
        .BLK_PER_BANK(BLK_PER_BANK), .PIC0(PIC0),
        .PIC_STRIDE(PIC_STRIDE), .HIB(HIB)
    ) u_recv (
        .lclk(rx_clk), .lrst(rst),
        .frame(rx_frame), .f_type(rx_type), .payload(rx_payload),
        .pclk(clk), .prst(rst),
        .got(r_got), .step(r_step),
        .clk150(clk150), .rst150(rst),
        .wr_valid(r_wr_valid), .wr_addr(r_wr_addr),
        .wr_data(r_wr_data), .wr_ready(r_wr_ready)
    );

    // ---- B-SDRAM write log: what landed where ------------------------------
    localparam integer OFF = 600000;                   // covers 0.60M .. 2.10M
    localparam integer DEP = 1500000;

    reg [15:0] sink [0:DEP-1];
    reg        wrote[0:DEP-1];
    integer    nwr = 0;
    integer    nstray = 0;

    assign r_wr_ready = !rst;
    always @(posedge clk150) begin
        if (!rst && r_wr_valid && r_wr_ready) begin
            nwr = nwr + 1;
            if ((r_wr_addr >= OFF) && (r_wr_addr < OFF + DEP)) begin
                sink [r_wr_addr - OFF] <= r_wr_data[15:0];
                wrote[r_wr_addr - OFF] <= 1'b1;
            end else nstray = nstray + 1;
        end
    end

    // ---- bookkeeping -------------------------------------------------------
    integer sent_r [0:127];
    integer sent_b [0:127];
    integer nsent = 0;
    integer errors = 0;
    integer i, j, k, dup;

    task note_block(input integer r, input integer b);
        begin
            if (nsent < 128) begin sent_r[nsent] = r; sent_b[nsent] = b; end
            nsent = nsent + 1;
        end
    endtask

    // wait for one completed block frame; `region`/`block` are latched at S_IDLE
    // and stay valid until the next one, so sampling them just after the send
    // identifies exactly this block.
    task wait_block;
        reg [15:0] b0;
        begin
            b0 = blocks;
            while (blocks == b0) begin @(posedge clk); #1; end
            note_block(u_push.region, u_push.block);
        end
    endtask

    // steer the walker while it cannot be writing cur_blk (S_READ / S_SEND)
    task jump_to(input integer blk);
        begin
            while ((u_push.st !== 3'd1) && (u_push.st !== 3'd2)) @(posedge clk);
            u_push.cur_blk = blk[16:0];
        end
    endtask

    // ---- main --------------------------------------------------------------
    integer blk, r, last_r;
    initial begin
        $display("=== tb_img_link  BLK_ALL=%0d", BLK_ALL);
        nwr = 0;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // Jump just before every region boundary, plus the wrap point.  The
        // block after the jump is the first one of the new region.
        for (k = 0; k < 9; k = k + 1) begin
            case (k)
                0: blk = 0;                            // region 0 start (no jump)
                1: blk = BLK_PER_BANK - 1;             // 0 -> 1
                2: blk = 2*BLK_PER_BANK - 1;           // 1 -> 2
                3: blk = 3*BLK_PER_BANK - 1;           // 2 -> 3
                4: blk = BLK_4PIC - 1;                 // 3 -> 4 (CAM1 1:1 copy)
                5: blk = BLK_4PIC +   BLK_HI - 1;      // 4 -> 5 (CAM2)
                6: blk = BLK_4PIC + 2*BLK_HI - 1;      // 5 -> 6 (CAM3)
                7: blk = BLK_4PIC + 3*BLK_HI - 1;      // 6 -> 7 (CAM4)
                default: blk = BLK_ALL - 2;            // wrap back to 0
            endcase
            if (blk > 0) jump_to(blk - 1);
            repeat (3) wait_block;
            repeat (40) @(posedge clk);
        end

        repeat (400) @(posedge clk);              // let the last write drain

        $display("  sent=%0d received=%0d words=%0d link(ok=%0d err=%0d)",
                 nsent, r_got, nwr, rx_ok, rx_err);
        if (r_got != nsent) begin
            $display("FAIL: receiver saw %0d of %0d blocks", r_got, nsent);
            errors = errors + 1;
        end
        if (rx_err != 16'd0) begin
            $display("FAIL: link error counter = %0d (frame format / CRC)", rx_err);
            errors = errors + 1;
        end
        if (nstray != 0) begin
            $display("FAIL: %0d writes outside the modelled address window", nstray);
            errors = errors + 1;
        end

        // every word of every UNIQUE sent block
        for (i = 0; i < nsent && i < 128; i = i + 1) begin
            dup = 0;
            for (j = 0; j < i; j = j + 1)
                if ((sent_r[j] == sent_r[i]) && (sent_b[j] == sent_b[i])) dup = 1;
            if (!dup) begin
                r = sent_r[i];
                for (j = 0; j < 16; j = j + 1) begin
                    k = base_of(r) + sent_b[i]*16 + j;
                    if (!wrote[k - OFF]) begin
                        $display("FAIL: r%0d blk %0d word %0d (addr %0d) never written",
                                 r, sent_b[i], j, k);
                        errors = errors + 1;
                    end else if (sink[k - OFF] !== pat(k[20:0])) begin
                        $display("FAIL: r%0d blk %0d word %0d addr %0d: %04h != %04h",
                                 r, sent_b[i], j, k, sink[k - OFF], pat(k[20:0]));
                        errors = errors + 1;
                    end
                    wrote[k - OFF] = 1'b0;
                end
            end
        end

        // and no stray write anywhere else in the window
        last_r = 0;
        for (i = 0; i < DEP; i = i + 1) begin
            if (wrote[i]) begin
                if (last_r < 8) $display("FAIL: stray write at address %0d", i + OFF);
                last_r = last_r + 1;
                errors = errors + 1;
                wrote[i] = 1'b0;
            end
        end

        // the documented real geometry must be what the RTL actually uses
        $display("  bases: %0d %0d %0d %0d %0d %0d %0d %0d",
                 base_of(0), base_of(1), base_of(2), base_of(3),
                 base_of(4), base_of(5), base_of(6), base_of(7));
        $display("  rtl  : %0d %0d %0d %0d %0d %0d %0d %0d",
                 u_recv.pic_base(3'd0), u_recv.pic_base(3'd1), u_recv.pic_base(3'd2),
                 u_recv.pic_base(3'd3), u_recv.pic_base(3'd4), u_recv.pic_base(3'd5),
                 u_recv.pic_base(3'd6), u_recv.pic_base(3'd7));
        for (k = 0; k < 8; k = k + 1) begin
            if (base_of(k) != u_recv.pic_base(k[2:0])) begin
                $display("FAIL: region %0d base %0d in RTL, %0d expected",
                         k, u_recv.pic_base(k[2:0]), base_of(k));
                errors = errors + 1;
            end
        end
        if ((base_of(0) != 1848320) || (base_of(1) != 1910528) ||
            (base_of(2) != 1972736) || (base_of(3) != 2034944) ||
            (base_of(4) != 619520)  || (base_of(5) != 926720) ||
            (base_of(6) != 1233920) || (base_of(7) != 1541120)) begin
            $display("FAIL: region bases moved");
            errors = errors + 1;
        end

        if (errors == 0) $display("TB_IMG_LINK PASS (%0d blocks, %0d words)", nsent, nwr);
        else             $display("TB_IMG_LINK FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TB_IMG_LINK TIMEOUT (sent %0d, got %0d, blk %0d)",
                 nsent, r_got, cur_blk);
        $finish;
    end
endmodule
