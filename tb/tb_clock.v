//=============================================================================
// tb_clock.v -- wall_clock carry chain over a full 100-minute wrap
//
// 360,000 ticks = 6,000 seconds = 100 minutes, which exercises every carry:
//   09 -> 10, 59 -> 00 (into minutes), 59:59 -> 00:00, 99:59 -> 00:00 (wrap).
// The expected value is computed in the TB from a plain integer pair, and the
// BCD output is compared as {tens, units} decimal digits.
//
//   vsim -c -do "run -all; quit -f" tb_clock
//=============================================================================
`timescale 1ns/1ps

module tb_clock;
    reg clk = 1'b0;
    always #5 clk = ~clk;              // 100 MHz: this test is only about logic

    reg rst = 1'b1;
    reg tick = 1'b0;
    wire [7:0] sec, min;

    wall_clock u_dut (.clk(clk), .rst(rst), .tick(tick), .sec(sec), .min(min));

    integer errors = 0, checked = 0;
    integer s, m, n, carries, wraps, fcnt;

    // BCD byte for a decimal value 0..99
    function [7:0] bcd;
        input integer v;
        reg [3:0] t, u;
        begin
            t = v / 10;
            u = v % 10;
            bcd = {t, u};
        end
    endfunction

    initial begin
        repeat (2) @(posedge clk);
        rst = 1'b0;
        s = 0; m = 0; carries = 0; wraps = 0; fcnt = 0;
        @(posedge clk);

        for (n = 0; n < 360000; n = n + 1) begin
            tick = 1'b1;
            @(posedge clk);
            tick = 1'b0;
            #1;

            // one DUT tick = one frame; 60 frames = one second
            if (fcnt == 59) begin
                fcnt = 0;
                if (s == 59) begin s = 0; m = m + 1; carries = carries + 1;
                                if (m == 100) begin m = 0; wraps = wraps + 1; end
                end else s = s + 1;
            end else begin
                fcnt = fcnt + 1;
            end

            if ({sec, min} !== {bcd(s), bcd(m)}) begin
                if (errors < 8)
                    $display("  tick %0d: got %02h:%02h want %02h:%02h (BCD digits %0d%0d:%0d%0d)",
                             n, min, sec, bcd(m), bcd(s),
                             min[7:4], min[3:0], sec[7:4], sec[3:0]);
                errors = errors + 1;
            end
            checked = checked + 1;

            // spot-check a few interesting points
            if (n == 59)   $display("  after 60 ticks : %0d%0d:%0d%0d (want 00:01)",
                                    min[7:4], min[3:0], sec[7:4], sec[3:0]);
            if (n == 599)  $display("  after 600 ticks: %0d%0d:%0d%0d (want 00:10)",
                                    min[7:4], min[3:0], sec[7:4], sec[3:0]);
            if (n == 3599) $display("  after 3600 tc : %0d%0d:%0d%0d (want 01:00)",
                                    min[7:4], min[3:0], sec[7:4], sec[3:0]);
        end

        $display("clock: %0d ticks checked, %0d minute carries, %0d 100-min wraps, %0d errors",
                 checked, carries, wraps, errors);
        if (carries != 100) begin $display("CARRY COUNT FAIL (want 100 minutes)"); errors = errors + 1; end
        if (wraps  != 1)    begin $display("WRAP COUNT FAIL (want 1)");            errors = errors + 1; end
        if (errors == 0) $display("TB_CLOCK PASS");
        else             $display("TB_CLOCK FAIL (%0d)", errors);
        $finish;
    end
endmodule
