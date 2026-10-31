`timescale 1ns/1ps
module tb_link_dbg;
    reg clk = 0;
    always #20 clk = ~clk;
    reg rst = 1, start_tog = 0;
    reg [7:0] seq = 8'h5A;
    reg [4:0] anim = 5'd3;
    reg [1:0] sel = 2'd2;
    reg [255:0] tbl = 256'h00C733E94A0323A2008223E9540AA208004113492C02C158000803492C018018;
    wire tx_vld; wire [3:0] tx_d;
    wire frame; wire [7:0] f_type, f_len; wire [319:0] payload; wire [15:0] err_cnt, ok_cnt;

    wall_link_tx #(.FRAME_TYPE(8'h01), .KIND(0)) u_tx (
        .clk(clk), .rst(rst), .en(1'b1), .start_tog(start_tog),
        .seq(seq), .anim(anim), .sel(sel), .tbl(tbl),
        .p0(8'h00), .p1(8'h00), .p2(8'h00),
        .o_vld(tx_vld), .o_d(tx_d), .busy());

    wall_link_rx u_rx (
        .clk(clk), .rst(rst), .en(1'b1), .i_d(tx_d), .i_vld(tx_vld),
        .frame(frame), .f_type(f_type), .f_len(f_len),
        .payload(payload), .err_cnt(err_cnt), .ok_cnt(ok_cnt));

    integer n = 0;
    always @(posedge clk) begin
        if (!rst && tx_vld) begin
            n = n + 1;
            if (n <= 90)
                $display("t=%0t nib=%h  txbi=%0d half=%b | rx st=%0d bi=%0d half=%b crc=%02h fr=%b",
                         $time, tx_d, u_tx.bi, u_tx.half, u_rx.st, u_rx.bi, u_rx.half,
                         u_rx.crc, frame);
        end
    end

    initial begin
        #100 rst = 0;
        #100 @(posedge clk); #1 start_tog = ~start_tog;
        #8000;
        $display("done ok=%0d err=%0d frame_type=%02h len=%0d", ok_cnt, err_cnt, f_type, f_len);
        $finish;
    end
endmodule
