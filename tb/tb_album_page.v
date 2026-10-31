//=============================================================================
// tb_album_page.v -- C9 album paging: the sequencer's page counter
//
// wall_album_seq owns the album record, so it also owns the page number in
// record bits [60:59].  This test drives the two key pulses directly (no
// wall_input, no table pipeline) and proves the contract the operator sees:
//
//   1. entering album mode always starts from the page remembered from last
//      time (page 0 after reset, unchanged while the album is off);
//   2. KEY4 / KEY3 step the page 0->1->2->3->0 and 0->3 with wrap-around;
//   3. C9-R2: every page change is a FADE-THROUGH-BLACK like entering/leaving
//      the mode -- slot 0 is rewritten exactly once, at level == 0, and the
//      level returns to 16;
//   4. slots 1..3 are never written by a page change (they stay blanked);
//   5. pulses that arrive while the fade is running (any state except S_ALBUM)
//      are ignored -- no half-page swap in the middle of a transition;
//   6. the page survives leaving and re-entering album mode.
//
//   vsim -c -do "run -all; quit -f" tb_album_page
//=============================================================================
`timescale 1ns/1ps

module tb_album_page;
    reg clk = 1'b0;
    always #20 clk = ~clk;              // 25 MHz
    reg rst = 1'b1;

    reg          album  = 1'b0;
    reg          nxt    = 1'b0;
    reg          prv    = 1'b0;
    reg          frame  = 1'b0;
    wire         set_tbl;
    wire [1:0]   set_idx;
    wire [63:0]  set_data;
    wire [4:0]   level;
    wire [1:0]   pic_idx;

    // The sequencer only reads cur_tbl to snapshot the operator's table when the
    // album is entered; a constant non-frameless table is enough here.
    // 64-bit record fields: {rsv[63:58], wid[57:54], flags[53:51], owner[50],
    // z[49:48], src[47:44], h[43:34], w[33:24], gy[23:12], gx[11:0]}
    wire [63:0] one_rec  = {6'd0, 4'd0, 3'd0, 1'b0, 2'd1, 4'd0,
                            10'd240, 10'd320, 12'd40, 12'd40};
    wire [255:0] cur_tbl = {one_rec, one_rec, one_rec, one_rec};

    wall_album_seq u_seq (
        .clk(clk), .rst(rst), .frame(frame), .album(album), .nxt(nxt), .prv(prv),
        .cur_tbl(cur_tbl),
        .set_tbl(set_tbl), .set_idx(set_idx), .set_data(set_data),
        .level(level), .pic_idx(pic_idx)
    );

    // ---- record one clock's worth of the write port ------------------------
    integer wr_slot0 = 0, wr_other = 0;
    reg [1:0]  wr_page  = 2'd0;
    reg [4:0]  wr_level = 5'd0;     // the fade level when the last write happened
    reg [63:0] wr_last  = 64'd0;
    always @(posedge clk) begin
        if (set_tbl) begin
            if (set_idx == 2'd0) begin
                wr_slot0  = wr_slot0 + 1;
                wr_page   = set_data[60:59];
                wr_level  = level;
                wr_last   = set_data;
            end else begin
                wr_other  = wr_other + 1;
            end
        end
    end

    // ---- helpers -----------------------------------------------------------
    task do_frame;
        begin
            @(posedge clk); #1; frame = 1'b1;
            @(posedge clk); #1; frame = 1'b0;
        end
    endtask
    task settle(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) do_frame;
        end
    endtask
    task pulse_nxt;
        begin
            @(posedge clk); #1; nxt = 1'b1;
            @(posedge clk); #1; nxt = 1'b0;
            @(posedge clk); #1;
        end
    endtask
    task pulse_prv;
        begin
            @(posedge clk); #1; prv = 1'b1;
            @(posedge clk); #1; prv = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // page step + wait for the fade to finish (34 frames is enough: 16 out,
    // 4 swap clocks, 2 settle frames, 16 in)
    task step_next;
        begin pulse_nxt; settle(40); end
    endtask
    task step_prev;
        begin pulse_prv; settle(40); end
    endtask

    integer errors = 0;
    integer n0, n1, k;

    initial begin
        $display("=== tb_album_page");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        settle(3);

        if (pic_idx !== 2'd0 || level !== 5'd16) begin
            $display("FAIL: idle state pic_idx=%0d level=%0d (want 0/16)", pic_idx, level);
            errors = errors + 1;
        end

        // ---- 1. page pulses are inert while the album is OFF --------------
        n0 = wr_slot0;
        pulse_nxt;
        pulse_nxt;
        settle(40);
        if (pic_idx !== 2'd0 || wr_slot0 != n0) begin
            $display("FAIL: paging happened outside album mode (idx=%0d writes=%0d->%0d)",
                     pic_idx, n0, wr_slot0);
            errors = errors + 1;
        end

        // ---- 2. enter album mode ------------------------------------------
        album = 1'b1;
        do_frame;                            // first fade step
        n0 = wr_slot0;
        pulse_nxt;                           // during the fade: must be ignored
        if (pic_idx !== 2'd0) begin
            $display("FAIL: page pulse during the fade was honoured (idx=%0d)", pic_idx);
            errors = errors + 1;
        end
        settle(40);
        if (pic_idx !== 2'd0) begin
            $display("FAIL: entered album on page %0d (want 0)", pic_idx);
            errors = errors + 1;
        end
        if (wr_slot0 != n0 + 1) begin
            $display("FAIL: entering album wrote slot 0 %0d times (want 1)", wr_slot0 - n0);
            errors = errors + 1;
        end
        if (wr_page !== 2'd0 || wr_level !== 5'd0) begin
            $display("FAIL: entry wrote page %0d at level %0d (want 0 at 0)",
                     wr_page, wr_level);
            errors = errors + 1;
        end
        if (level !== 5'd16) begin
            $display("FAIL: level after entering = %0d (want 16)", level);
            errors = errors + 1;
        end

        // ---- 3. NEXT: 0 -> 1 -> 2 -> 3 -> 0, each step through black ------
        n0 = wr_slot0;
        n1 = wr_other;
        for (k = 0; k < 4; k = k + 1) begin
            step_next;
            if (pic_idx !== ((k + 1) % 4)) begin
                $display("FAIL: NEXT #%0d gave page %0d (want %0d)",
                         k + 1, pic_idx, (k + 1) % 4);
                errors = errors + 1;
            end
            if (wr_page !== ((k + 1) % 4)) begin
                $display("FAIL: NEXT #%0d wrote slot0 page %0d (want %0d)",
                         k + 1, wr_page, (k + 1) % 4);
                errors = errors + 1;
            end
            if (wr_level !== 5'd0) begin
                $display("FAIL: NEXT #%0d wrote the table at level %0d (not black)",
                         k + 1, wr_level);
                errors = errors + 1;
            end
            if (level !== 5'd16) begin
                $display("FAIL: NEXT #%0d left the level at %0d", k + 1, level);
                errors = errors + 1;
            end
        end
        if (wr_slot0 != n0 + 4) begin
            $display("FAIL: 4 NEXT steps produced %0d slot0 writes (want 4)",
                     wr_slot0 - n0);
            errors = errors + 1;
        end
        if (wr_other != n1) begin
            $display("FAIL: paging wrote %0d slots other than slot 0", wr_other - n1);
            errors = errors + 1;
        end
        if (wr_last[63:61] !== 3'b000 || wr_last[58] !== 1'b1 ||
            wr_last[43:34] !== 10'd480 || wr_last[33:24] !== 10'd1023 ||
            wr_last[49:48] !== 2'd3) begin
            $display("FAIL: paged record lost its album fields: %064h", wr_last);
            errors = errors + 1;
        end

        // ---- 4. PREV: 0 -> 3 (wrap below zero) ----------------------------
        step_prev;
        if (pic_idx !== 2'd3) begin
            $display("FAIL: PREV below zero gave page %0d (want 3)", pic_idx);
            errors = errors + 1;
        end
        step_next;
        if (pic_idx !== 2'd0) begin
            $display("FAIL: NEXT above three gave page %0d (want 0)", pic_idx);
            errors = errors + 1;
        end
        $display("  pages: next 0->1->2->3->0, prev 0->3 OK (fade + slot0 only)");

        // ---- 5. the page survives leaving and re-entering the album -------
        step_next;                           // page 1
        step_next;                           // page 2
        album = 1'b0;
        settle(40);                           // fade out, restore, fade in
        if (pic_idx !== 2'd2) begin
            $display("FAIL: leaving album mode changed the page to %0d", pic_idx);
            errors = errors + 1;
        end
        if (level !== 5'd16) begin
            $display("FAIL: level after leaving = %0d (want 16)", level);
            errors = errors + 1;
        end
        n0 = wr_slot0;
        album = 1'b1;
        settle(40);
        if (wr_page !== 2'd2) begin
            $display("FAIL: re-entered album mode on page %0d (want 2 kept)", wr_page);
            errors = errors + 1;
        end
        if (pic_idx !== 2'd2) begin
            $display("FAIL: pic_idx after re-entry = %0d (want 2)", pic_idx);
            errors = errors + 1;
        end
        if (wr_slot0 != n0 + 1) begin
            $display("FAIL: re-entry wrote slot 0 %0d times (want 1)", wr_slot0 - n0);
            errors = errors + 1;
        end
        album = 1'b0;
        settle(40);

        if (errors == 0) $display("TB_ALBUM_PAGE PASS");
        else             $display("TB_ALBUM_PAGE FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
