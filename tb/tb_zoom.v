//=============================================================================
// tb_zoom.v -- wall_zoom_calc: one uniform step per window, plus drawn size
//
//   sx = (96<<16)/cw   sy = (72<<16)/chh   step = max(sx, sy)
//   dw = (96<<16)/step dh = (72<<16)/step
//
// step is what makes the zoom proportional (both axes consume samples at the
// same rate); dw/dh tell the scene how big to draw the picture so it can centre
// it and leave black bars on the spare axis.
//=============================================================================
`timescale 1ns/1ps

module tb_zoom;
    reg clk = 0;
    always #20 clk = ~clk;

    reg rst = 1;
    reg start = 0;
    reg [255:0] tbl;

    wire [71:0] zstep, zdw, zdh;

    integer errors = 0;

    wall_zoom_calc u_dut (
        .clk(clk), .rst(rst), .start(start), .tbl(tbl),
        .zstep(zstep), .zdw(zdw), .zdh(zdh)
    );

    task set_size(input integer ww, input integer hh);
        integer i;
        reg [63:0] rec;
        begin
            rec = 64'd0;
            rec[11:0]  = 12'd24;
            rec[23:12] = 12'd24;
            rec[33:24] = ww[9:0];
            rec[43:34] = hh[9:0];
            for (i = 0; i < 4; i = i + 1) tbl[i*64 +: 64] = rec;
        end
    endtask

    task check(input integer ww, input integer hh);
        integer cw, chh, sx, sy, st, dw, dh;
        begin
            set_size(ww, hh);
            @(posedge clk); start = 1;
            @(posedge clk); start = 0;
            repeat (900) @(posedge clk);      // 5 divides x 25 clocks x 4 windows

            cw  = ww - 4;
            chh = hh - 16;
            sx  = (96 << 16) / cw;
            sy  = (72 << 16) / chh;
            st  = (sx > sy) ? sx : sy;
            dw  = (96 << 16) / st;
            dh  = (72 << 16) / st;

            $display("%0dx%0d: step=%0d (want %0d) dw=%0d (want %0d) dh=%0d (want %0d)",
                     ww, hh, zstep[17:0], st, zdw[11:0], dw, zdh[11:0], dh);
            if (zstep[17:0] !== st[17:0]) begin
                errors = errors + 1;
                $display("FAIL: step for %0dx%0d", ww, hh);
            end
            if (zdw[11:0] !== dw[11:0]) begin
                errors = errors + 1;
                $display("FAIL: dw for %0dx%0d", ww, hh);
            end
            if (zdh[11:0] !== dh[11:0]) begin
                errors = errors + 1;
                $display("FAIL: dh for %0dx%0d", ww, hh);
            end
            if (zstep[53:36] !== zstep[17:0] || zdw[23:12] !== zdw[11:0]) begin
                errors = errors + 1;
                $display("FAIL: windows disagree");
            end
        end
    endtask

    // different windows in one table must produce different steps -- a
    // registered window index made window N use window N-1's size instead
    task check_mixed;
        begin
            tbl = 256'd0;
            tbl[33:24]   = 10'd300; tbl[43:34]   = 10'd210;
            tbl[97:88]   = 10'd600; tbl[107:98]  = 10'd420;
            tbl[161:152] = 10'd40;  tbl[171:162] = 10'd40;
            tbl[225:216] = 10'd640; tbl[235:226] = 10'd480;
            @(posedge clk); start = 1;
            @(posedge clk); start = 0;
            repeat (900) @(posedge clk);

            $display("mixed: w0=%0d w1=%0d w2=%0d w3=%0d",
                     zstep[17:0], zstep[35:18], zstep[53:36], zstep[71:54]);
            if (zstep[17:0]  !== 18'd24322)  begin errors = errors + 1; $display("FAIL: w0 step"); end
            if (zstep[35:18] !== 18'd11679)  begin errors = errors + 1; $display("FAIL: w1 step"); end
            if (zstep[53:36] !== 18'd196608) begin errors = errors + 1; $display("FAIL: w2 step"); end
            if (zstep[71:54] !== 18'd10169)  begin errors = errors + 1; $display("FAIL: w3 step"); end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        check(300, 210);
        check(600, 420);
        check(40,  40);
        check(640, 480);
        check_mixed;

        if (errors == 0) $display("TB_ZOOM PASS");
        else             $display("TB_ZOOM FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
