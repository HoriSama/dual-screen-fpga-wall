`timescale 1ns/1ps
module tb_status2;
    reg clk = 0, rst = 1;
    always #10 clk = ~clk;   // 50 MHz
    wire tx;
    wall_status_tx u (
        .clk(clk), .rst(rst), .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0),
        .dragging(1'b0), .owner(1'b0), .sel(2'd0), .gx(12'h18),
        .ok_cnt(16'd0), .err_cnt(16'd0), .no_align(8'd0), .align_bad(8'd0),
        .video_locked(1'b1), .video_ready(1'b1), .sup_state(2'd2), .rec_cnt(8'd0),
        .uart_tx(tx));
    integer starts = 0;
    always @(posedge clk) if (u.go && u.bi == 4'd0) starts = starts + 1;
    integer starts2 = 0;
    always @(posedge clk) if (u.start) starts2 = starts2 + 1;
    reg [22:0] tickmax = 0;
    always @(posedge clk) if (u.tick > tickmax) tickmax = u.tick;
    initial begin
        #1000 rst = 0;
        #250_000_000;   // 250 ms
        $display("frames started: %0d, start pulses: %0d, max tick: %0d", starts, starts2, tickmax);
        $finish;
    end
endmodule
