//=============================================================================
// tb_pic_line.v -- wall_pic_line: burst, line-boundary swap, no mid-line tear
//
// A behavioural SDRAM answers every read with rdata = its address (low 16
// bits), so the buffer content is a deterministic function of the address.
//
// The test is built around the bug that showed up on the board: the first
// version flipped the read bank on the fill-complete ack, so a burst finishing
// mid-line tore the display line and made the picture flicker.  Here the row is
// re-read WHILE its successor is being fetched, and every read must still return
// the CURRENT row until the next line tick.
//
// C3 adds the ALBUM burst: a frameless window (nxt_hi = 1) fetches 640 words
// from a 640x480 1:1 copy instead of 192 from a thumbnail, with the row stride
// 640 instead of 192.  That path is checked word for word too.
//
// C9 adds the PAGE: there are four 1:1 copies at HIB + idx*307200 and the record
// field [60:59] (nxt_idx) says which one.  The last section drives idx = 2 and
// proves the burst really comes from the third copy, row by row -- including a
// deep row, so a wrong stride cannot pass by accident.
//
//   vsim -c -do "run -all; quit -f" tb_pic_line
//=============================================================================
`timescale 1ns/1ps

module tb_pic_line;
    reg clk25 = 1'b0;
    always #20 clk25 = ~clk25;          // 25 MHz
    reg clk150 = 1'b0;
    always #3.333 clk150 = ~clk150;     // ~150 MHz (not phase-locked to clk25)

    reg rst25 = 1'b1, rst150 = 1'b1;

    reg        prime     = 1'b0;
    reg        line_tick = 1'b0;
    reg  [35:0] nxt_rows  = 36'd0;
    reg  [3:0]  nxt_valid = 4'd0;
    reg  [3:0]  nxt_hi    = 4'd0;
    reg  [7:0]  nxt_idx   = 8'd0;
    reg  [39:0] nxt_c1    = {10'd191, 10'd191, 10'd191, 10'd191};
    reg  [2:0]  rd_win    = 3'd0;
    reg  [9:0]  rd_col    = 10'd0;
    wire [15:0] rd_data;

    wire        rd_valid;
    wire [20:0] rd_addr;
    reg         rd_ready;
    reg         rvalid;
    reg  [31:0] rdata;

    wall_pic_line u_dut (
        .clk25(clk25), .rst25(rst25),
        .car_cyc(2'd0), .prime(prime), .line_tick(line_tick),
        .nxt_rows(nxt_rows), .nxt_valid(nxt_valid), .nxt_hi(nxt_hi), .nxt_idx(nxt_idx), .nxt_c1(nxt_c1),
        .rd_win(rd_win), .rd_col(rd_col), .rd_data(rd_data),
        .clk150(clk150), .rst150(rst150),
        .rd_valid(rd_valid), .rd_addr(rd_addr), .rd_ready(rd_ready),
        .rvalid(rvalid), .rdata(rdata), .busy(), .late_cnt(), .late_msk()
    );

    // ---- behavioural SDRAM: always ready, 2-cycle response, data = address --
    reg [20:0] ap0, ap1;
    reg        v0, v1;
    always @(posedge clk150) begin
        if (rst150) begin ap0 <= 21'd0; ap1 <= 21'd0; v0 <= 1'b0; v1 <= 1'b0; end
        else        begin ap0 <= rd_addr; ap1 <= ap0; v0 <= rd_valid; v1 <= v0; end
    end
    always @(*) rd_ready = rd_valid;
    always @(*) rvalid   = v1;
    always @(*) rdata    = {11'd0, ap1};

    // C9 memory map (must match rtl/wall_pic_line.v)
    localparam integer PIC0      = 1848320;
    localparam integer HIB       = 619520;
    localparam integer HI_STRIDE = 307200;

    function [20:0] pic_base;
        input [1:0] w;
        begin
            case (w)
                2'd0: pic_base = 21'd1848320;
                2'd1: pic_base = 21'd1910528;
                2'd2: pic_base = 21'd1972736;
                default: pic_base = 21'd2034944;
            endcase
        end
    endfunction
    // thumbnail row: 192 words, stride 192
    function [15:0] want_word;
        input [1:0] w;
        input [8:0] row;
        input [9:0] col;
        reg [20:0] a;
        begin
            a = pic_base(w) + ({12'd0, row} << 7) + ({12'd0, row} << 6) + {11'd0, col};
            want_word = a[15:0];
        end
    endfunction
    // 1:1 copy row: 640 words, stride 640 (row*640 = row<<9 + row<<7)
    function [15:0] want_hi;
        input [1:0] idx;
        input [8:0] row;
        input [9:0] col;
        reg [20:0] a;
        begin
            a = HIB[20:0] + ({19'd0, idx} * 21'd307200)
                          + ({12'd0, row} << 9) + ({12'd0, row} << 7) + {11'd0, col};
            want_hi = a[15:0];
        end
    endfunction

    // ---- accepted-read tracer ----------------------------------------------
    reg  [20:0] seen [0:1023];
    integer     nseen = 0;
    integer     i;
    always @(posedge clk150) begin
        if (rd_valid && rd_ready) begin
            if (nseen < 1024) begin
                seen[nseen] = rd_addr;
                nseen = nseen + 1;
            end
        end
    end

    // C9-R3: the DUT now takes the last column from the prefetch; this TB drives
    // nxt_hi directly, so mirror it (thumbnails 0..191, the 1:1 copy 0..639).
    integer gi;
    always @(*) begin
        for (gi = 0; gi < 4; gi = gi + 1)
            nxt_c1[gi*10 +: 10] = nxt_hi[gi] ? 10'd639 : 10'd191;
    end

    integer errors = 0, c;
    reg [15:0] got;

    task read_col(input [9:0] col, output [15:0] d);
        begin
            rd_win <= 3'd0; rd_col <= col;
            @(posedge clk25);
            #1;
            d = rd_data;
        end
    endtask

    task read_col_hi(input [9:0] col, output [15:0] d);
        begin
            rd_win <= 3'b100; rd_col <= col;
            @(posedge clk25);
            #1;
            d = rd_data;
        end
    endtask

    // check the whole row the scene should see for the CURRENT bank
    task check_row(input [8:0] row, input integer cols);
        integer k;
        reg [15:0] d;
        begin
            for (k = 0; k < cols; k = k + 1) begin
                read_col(k[9:0], d);
                if (d !== want_word(2'd0, row, k[9:0])) begin
                    if (errors < 6)
                        $display("  row %0d col %0d got %04X want %04X",
                                 row, k, d, want_word(2'd0, row, k[9:0]));
                    errors = errors + 1;
                end
            end
        end
    endtask

    task check_row_hi(input [1:0] idx, input [8:0] row, input integer cols);
        integer k;
        reg [15:0] d;
        begin
            for (k = 0; k < cols; k = k + 1) begin
                read_col_hi(k[9:0], d);
                if (d !== want_hi(idx, row, k[9:0])) begin
                    if (errors < 6)
                        $display("  HI%0d row %0d col %0d got %04X want %04X",
                                 idx, row, k, d, want_hi(idx, row, k[9:0]));
                    errors = errors + 1;
                end
            end
        end
    endtask

    // one 640-word album burst of `row` from copy `idx`
    task album_burst(input [1:0] idx, input [8:0] row);
        begin
            nseen = 0;
            nxt_valid    = 4'b0001;
            nxt_hi       = 4'b0001;
            nxt_idx[1:0] = idx;
            nxt_rows[8:0] = row;
            @(posedge clk25); prime = 1'b1;
            @(posedge clk25); prime = 1'b0;
            repeat (4000) @(posedge clk150);
            if (nseen != 640) begin
                $display("FAIL: album idx=%0d row=%0d burst accepted %0d reads (want 640)",
                         idx, row, nseen);
                errors = errors + 1;
            end
            if (seen[0] !== (HIB + idx*HI_STRIDE + row*640)) begin
                $display("FAIL: album idx=%0d row=%0d burst start %0d (want %0d)",
                         idx, row, seen[0], HIB + idx*HI_STRIDE + row*640);
                errors = errors + 1;
            end
            if (seen[639] !== (HIB + idx*HI_STRIDE + row*640 + 639)) begin
                $display("FAIL: album idx=%0d row=%0d burst end %0d (want %0d)",
                         idx, row, seen[639], HIB + idx*HI_STRIDE + row*640 + 639);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("=== tb_pic_line");
        repeat (8) @(posedge clk25);
        rst25  = 1'b0;
        rst150 = 1'b0;
        repeat (8) @(posedge clk25);

        // ---- prime row 0 (no swap) --------------------------------------
        nxt_valid = 4'b0001; nxt_hi = 4'b0000; nxt_rows[8:0] = 9'd0;
        @(posedge clk25); prime = 1'b1;
        @(posedge clk25); prime = 1'b0;
        repeat (1500) @(posedge clk150);
        if (nseen != 192) begin
            $display("FAIL: prime burst accepted %0d reads (want 192)", nseen);
            errors = errors + 1;
        end

        // ---- line tick: swap to the freshly filled bank, fetch row 5 ----
        nseen = 0;
        nxt_rows[8:0] = 9'd5;
        @(posedge clk25); line_tick = 1'b1;
        @(posedge clk25); line_tick = 1'b0;

        // the scene must now see row 0, and MUST KEEP seeing row 0 while the
        // row-5 burst is still running (this is the anti-tear guarantee)
        check_row(8'd0, 8);
        repeat (300) @(posedge clk150);      // burst of row 5 in flight
        check_row(8'd0, 8);                   // still row 0 -- no mid-line tear
        repeat (1500) @(posedge clk150);      // let row 5 finish
        check_row(8'd0, 8);                   // still row 0 until the next tick

        // ---- next line tick: swap to row 5, fetch row 10 ----------------
        nxt_rows[8:0] = 9'd10;
        @(posedge clk25); line_tick = 1'b1;
        @(posedge clk25); line_tick = 1'b0;
        check_row(8'd5, 8);
        repeat (1500) @(posedge clk150);

        // ---- invisible window: nxt_valid=0 must not start a burst -------
        nseen = 0;
        nxt_valid = 4'b0000;
        @(posedge clk25); line_tick = 1'b1;
        @(posedge clk25); line_tick = 1'b0;
        repeat (1500) @(posedge clk150);
        if (nseen != 0) begin
            $display("FAIL: invisible window still fetched %0d words", nseen);
            errors = errors + 1;
        end

        // ==================================================================
        // ALBUM burst: 640 words, row stride 640, from HIB + idx*307200
        // ==================================================================
        album_burst(2'd0, 9'd7);

        // swap it in without refetching (same row -> row_chg = 0)
        nxt_valid = 4'b0000;
        @(posedge clk25); line_tick = 1'b1;
        @(posedge clk25); line_tick = 1'b0;
        check_row_hi(2'd0, 8'd7, 640);

        // and a deeper row to prove the stride, not just row 7
        nseen = 0;
        nxt_valid = 4'b0001;
        nxt_rows[8:0] = 9'd479;
        @(posedge clk25); line_tick = 1'b1;
        @(posedge clk25); line_tick = 1'b0;
        repeat (4000) @(posedge clk150);
        nxt_valid = 4'b0000;
        @(posedge clk25); line_tick = 1'b1;
        @(posedge clk25); line_tick = 1'b0;
        check_row_hi(2'd0, 9'd479, 640);
        if (seen[639] !== (HIB + 21'd479*640 + 21'd639)) begin
            $display("FAIL: album row 479 end address %0d", seen[639]);
            errors = errors + 1;
        end

        // ==================================================================
        // C9: page 2 (CAM3) must come from the THIRD 1:1 copy
        // ==================================================================
        album_burst(2'd2, 9'd9);
        nxt_valid = 4'b0000;
        @(posedge clk25); line_tick = 1'b1;
        @(posedge clk25); line_tick = 1'b0;
        check_row_hi(2'd2, 8'd9, 640);

        // page 3, a deep row: catches a stride/offset slip on the last copy
        album_burst(2'd3, 9'd300);
        nxt_valid = 4'b0000;
        @(posedge clk25); line_tick = 1'b1;
        @(posedge clk25); line_tick = 1'b0;
        check_row_hi(2'd3, 9'd300, 640);

        nxt_hi  = 4'b0000;
        nxt_idx = 8'd0;

        if (errors == 0) $display("TB_PIC_LINE PASS");
        else             $display("TB_PIC_LINE FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
