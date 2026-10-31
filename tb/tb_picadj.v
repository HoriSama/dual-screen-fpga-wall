//=============================================================================
// tb_picadj.v -- brightness/contrast arithmetic, exhaustively
//
// For a grid of (contrast, brightness, fade) it checks the per-frame gain/off
// table and then sweeps every 8-bit input value 0..255 through the pixel
// arithmetic:
//
//     out = clip( (in * gain) >> 8 + off )
//     gain = (c * (fade+1)) >> 7 ,  off = ((b-128) * (fade+1)) >> 8
//
// In particular:
//   * c=0x80 b=0x80 fade=255 is the identity (out == in for all 256 values);
//   * fade=0 gives 0 for EVERY input and EVERY setting (the carousel fades to
//     true black even with brightness cranked up);
//   * c=0x80 with fade=255 reduces to clip((in*c)>>7 + b-128), the plain
//     adjustment with no fade in the loop.
//
//   vsim -c -do "run -all; quit -f" tb_picadj
//=============================================================================
`timescale 1ns/1ps

module tb_picadj;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rst   = 1'b1;
    reg         frame = 1'b0;
    reg  [63:0] tbl   = 64'd0;
    reg  [7:0]  fade  = 8'd255;

    wire [39:0] gain, off;

    wall_picadj u_dut (
        .clk(clk), .rst(rst), .frame(frame), .tbl(tbl), .fade(fade),
        .gain(gain), .off(off));

    // picture 0 channel under test
    wire [9:0] g0 = gain[0 +: 10];
    wire [9:0] o0 = off[0 +: 10];
    reg  [7:0] din = 8'd0;
    wire [7:0] dout;

    wall_adj8 u_adj (.in(din), .gain(g0), .off(o0), .out(dout));

    integer errors = 0, checks = 0;
    integer c, b, f, v, f1, g_exp, o_exp, out_exp;
    integer ci, bi, fi, vi;

    task load_and_run(input integer cc, input integer bb, input integer ff);
        begin
            tbl[7:0]   = bb[7:0];
            tbl[15:8]  = cc[7:0];
            fade       = ff[7:0];
            @(posedge clk);
            frame = 1'b1;
            @(posedge clk);
            frame = 1'b0;
            repeat (10) @(posedge clk);
            #1;
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // power-up must be "no adjustment"
        if (gain[0 +: 10] !== 10'd256 || off[0 +: 10] !== 10'd0) begin
            $display("POWER-UP FAIL: gain=%0d off=%0d", gain[0 +: 10], off[0 +: 10]);
            errors = errors + 1;
        end

        for (fi = 0; fi < 3; fi = fi + 1) begin
            f = (fi == 0) ? 0 : (fi == 1) ? 128 : 255;
            for (ci = 0; ci < 5; ci = ci + 1) begin
                c = (ci == 0) ? 8'h20 : (ci == 1) ? 8'h40 : (ci == 2) ? 8'h80 :
                    (ci == 3) ? 8'hC0 : 8'hFF;
                for (bi = 0; bi < 5; bi = bi + 1) begin
                    b = (bi == 0) ? 8'h00 : (bi == 1) ? 8'h40 : (bi == 2) ? 8'h80 :
                        (bi == 3) ? 8'hC8 : 8'hFF;
                    load_and_run(c, b, f);

                    // ---- gain / offset table ----
                    f1    = f + 1;
                    g_exp = (c * f1) >> 7;
                    // arithmetic shift: (b-128) is negative for the low half, and
                    // a logical >> would turn -1 into 0x00FFFFFF
                    o_exp = $signed(b - 128) * $signed(f1);
                    o_exp = o_exp >>> 8;
                    if (g0 !== g_exp[9:0] || o0 !== o_exp[9:0]) begin
                        $display("TABLE FAIL c=%02h b=%02h f=%0d: gain=%0d (want %0d) off=%0d (want %0d)",
                                 c, b, f, g0, g_exp, $signed(o0), o_exp);
                        errors = errors + 1;
                    end

                    // ---- 256 input values ----
                    for (vi = 0; vi < 256; vi = vi + 1) begin
                        v   = vi;
                        din = v[7:0];
                        #1;
                        out_exp = ((v * g_exp) >> 8) + o_exp;
                        if (out_exp < 0)   out_exp = 0;
                        if (out_exp > 255) out_exp = 255;
                        if (dout !== out_exp[7:0]) begin
                            if (errors < 10)
                                $display("PIX FAIL c=%02h b=%02h f=%0d in=%0d: got %0d want %0d",
                                         c, b, f, v, dout, out_exp);
                            errors = errors + 1;
                        end
                        checks = checks + 1;
                    end
                end
            end
        end

        // ---- the two properties in words --------------------------------
        load_and_run(8'h80, 8'h80, 8'd255);            // identity
        for (vi = 0; vi < 256; vi = vi + 1) begin
            din = vi[7:0]; #1;
            if (dout !== vi[7:0]) begin
                $display("IDENTITY FAIL in=%0d got %0d", vi, dout);
                errors = errors + 1;
            end
        end

        load_and_run(8'hFF, 8'hFF, 8'd0);              // fade to black
        for (vi = 0; vi < 256; vi = vi + 1) begin
            din = vi[7:0]; #1;
            if (dout !== 8'd0) begin
                $display("BLACK FAIL (maximum brightness, fade=0) in=%0d got %0d", vi, dout);
                errors = errors + 1;
            end
        end

        $display("picadj: %0d pixel values checked, %0d errors", checks, errors);
        if (errors == 0) $display("TB_PICADJ PASS");
        else             $display("TB_PICADJ FAIL (%0d)", errors);
        $finish;
    end
endmodule
