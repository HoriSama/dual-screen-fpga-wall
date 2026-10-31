//=============================================================================
// tb_link_probe.v -- the raw link pair, no image staging involved
//
// Drives wall_link_tx (KIND 2) with a constant 35-byte payload and counts what
// wall_link_rx accepts.  Any mismatch here is the link itself, not the pusher.
//
//   vsim -c -do "run -all; quit -f" tb_link_probe
//=============================================================================
`timescale 1ns/1ps

module tb_link_probe;
    reg clk = 1'b0;
    always #20 clk = ~clk;

    reg rst = 1'b1;
    reg start = 1'b0;
    reg [279:0] pay;
    wire vld;
    wire [3:0] d;
    wire busy;

    function [11:0] pat;
        input [14:0] a;
        begin
            pat = {a[11:0]} ^ {a[7:0], 4'h5};
        end
    endfunction

    integer i;
    integer blk;
    // payload of one image block: bank 0, block `blk`, 16 words pat(blk*16+i)
    task mk_pay;
        input integer b;
        integer k;
        begin
            pay = 280'd0;
            pay[7:0]   = 8'd0;
            pay[15:8]  = b[7:0];
            pay[23:16] = {7'd0, b[8]};
            for (k = 0; k < 16; k = k + 1) begin
                pay[8*(3+2*k) +: 8] = pat(b*16 + k)[7:0];
                pay[8*(4+2*k) +: 8] = {4'd0, pat(b*16 + k)[11:8]};
            end
        end
    endtask

    initial begin
        mk_pay(18);
    end

    wall_link_tx #(.FRAME_TYPE(8'h03), .KIND(2)) u_tx (
        .clk(clk), .rst(rst), .en(1'b1), .start_tog(start),
        .seq(8'd0), .anim(5'd0), .sel(2'd0), .tbl(256'd0),
        .p0(8'd0), .p1(8'd0), .p2(8'd0), .ipay(pay),
        .o_vld(vld), .o_d(d), .busy(busy)
    );

    wire        frame;
    wire [7:0]  t, len;
    wire [319:0] p;
    wire [15:0] ecnt, ocnt;

    wall_link_rx u_rx (
        .clk(~clk), .rst(rst), .en(1'b1),
        .i_d(d), .i_vld(vld),
        .frame(frame), .f_type(t), .f_len(len),
        .payload(p), .err_cnt(ecnt), .ok_cnt(ocnt)
    );

    integer sent = 0, bad = 0;
    always @(posedge clk) if (frame) begin
        if (t != 8'h03 || len != 8'd35 || p !== pay) begin
            bad = bad + 1;
            if (bad < 5) $display("  frame mismatch: type=%02h len=%0d payload_ok=%0d", t, len, p === pay);
        end
    end

    integer n;
    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);
        for (n = 0; n < 400; n = n + 1) begin
            start = ~start;
            sent  = sent + 1;
            repeat (140) @(posedge clk);
        end
        repeat (300) @(posedge clk);
        $display("sent=%0d accepted=%0d err=%0d payload_mismatch=%0d", sent, ocnt, ecnt, bad);
        if (ocnt == sent && bad == 0) $display("TB_LINK_PROBE PASS");
        else                          $display("TB_LINK_PROBE FAIL");
        $finish;
    end
endmodule
