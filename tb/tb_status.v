`timescale 1ns/1ps
module tb_status;
    reg clk = 0, rst = 1;
    always #10 clk = ~clk;

    wire tx;
    wall_status_tx #(.TICK_CYC(2000), .NODE_CH(8'h41)) u (
        .clk(clk), .rst(rst),
        .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0), .dragging(1'b0),
        .sel(2'd1), .gx(12'h123), .ok_cnt(16'h0ABC), .err_cnt(16'h0001),
        .uart_tx(tx));

    integer n = 0;
    always @(posedge clk) begin
        if (u.go) begin
            n = n + 1;
            if (n <= 30) $display("go[%0d] data=%02h t=%0t busy=%b sending=%b bi=%0d",
                                  n, u.byte_now, $time, u.busy, u.sending, u.bi);
        end
    end

    initial begin
        #2000 rst = 0;
        #4_000_000;
        $display("total go pulses = %0d", n);
        $finish;
    end
endmodule
