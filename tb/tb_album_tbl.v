//=============================================================================
// tb_album_tbl.v -- album mode's window-table swap and restore (C3 + C5)
//
// Wall_album_seq is the only thing that ever sets the FRAMELESS bit (record bit
// 58), and it does so by rewriting all four records through the same
// single-index port the operator's keys use.  That makes the whole feature a
// property of the table, which is exactly what lets node B follow along in the
// STATE frame it already receives.
//
// This test proves:
//   1. entering album mode leaves ONE frameless record in slot 0 (z = top, the
//      other three blanked to w = h = 0 so the prefetch asks for nothing);
//   2. a node-B-style state (SNAP_DEPTH2 = 0) fed with the same writes ends up
//      with a bit-identical table;
//   3. leaving album mode restores the operator's table exactly;
//   4. C5: the swap only ever happens at the BLACK point of the fade, the fade
//      takes ~16 frames each way, and the level returns to full afterwards.
//
//   vsim -c -do "run -all; quit -f" tb_album_tbl
//=============================================================================
`timescale 1ns/1ps

module tb_album_tbl;
    reg clk = 1'b0;
    always #20 clk = ~clk;
    reg rst = 1'b1;

    reg          album = 1'b0;
    reg          nxt   = 1'b0;     // C9 page pulses
    reg          prv   = 1'b0;
    wire         set_tbl;
    wire [1:0]   set_idx;
    wire [63:0]  set_data;
    wire [4:0]   level;
    wire [1:0]   pic_idx;
    reg          commit = 1'b0;
    reg          frame  = 1'b0;

    wire [255:0] cur_a, snap_a;
    wire [1:0]   sel_a;
    wire [4:0]   anim_a;

    // ---- node A: two-frame pipeline (what is drawn) ------------------------
    wall_state #(.SEL_INIT(2'd0), .SNAP_DEPTH2(1)) u_state_a (
        .clk(clk), .rst(rst), .commit(commit),
        .set_tbl(set_tbl), .set_idx(set_idx), .set_data(set_data),
        .set_sel(1'b0), .sel_in(2'd0),
        .set_anim(1'b0), .anim_in(5'd0),
        .rd_idx(2'd0), .rd_word(),
        .cur_tbl(cur_a), .cur_sel(sel_a), .cur_anim(anim_a),
        .snap_tbl(snap_a), .snap_sel(), .snap_anim()
    );

    // ---- node B: one-frame pipeline, same writes ---------------------------
    wire [255:0] cur_b;
    wall_state #(.SEL_INIT(2'd0), .SNAP_DEPTH2(0)) u_state_b (
        .clk(clk), .rst(rst), .commit(commit),
        .set_tbl(set_tbl), .set_idx(set_idx), .set_data(set_data),
        .set_sel(1'b0), .sel_in(2'd0),
        .set_anim(1'b0), .anim_in(5'd0),
        .rd_idx(2'd0), .rd_word(),
        .cur_tbl(cur_b), .cur_sel(), .cur_anim(),
        .snap_tbl(), .snap_sel(), .snap_anim()
    );

    wall_album_seq u_seq (
        .clk(clk), .rst(rst), .frame(frame), .album(album), .nxt(nxt), .prv(prv),
        .cur_tbl(cur_a),
        .set_tbl(set_tbl), .set_idx(set_idx), .set_data(set_data),
        .level(level), .pic_idx(pic_idx)
    );

    // ---- fade / swap monitor ----------------------------------------------
    reg     saw_zero = 1'b0;      // the fade reached full black
    reg     saw_swap = 1'b0;
    reg     swap_ok  = 1'b1;      // every table write happened while black
    reg     falling  = 1'b0;
    integer frames_out = 0;       // frames spent fading down
    always @(posedge clk) begin
        if (level == 5'd0) saw_zero <= 1'b1;
        if (set_tbl) begin
            saw_swap <= 1'b1;
            if (level != 5'd0) swap_ok <= 1'b0;
        end
        // count only the fade-DOWN frames: once black is reached the fade-in
        // frames also have level != 0, so stop at the first black
        if (falling && frame && (level != 5'd0) && !saw_zero) frames_out <= frames_out + 1;
    end

    // ---- helpers -----------------------------------------------------------
    task do_frame;
        begin
            @(posedge clk); #1; commit = 1'b1; frame = 1'b1;
            @(posedge clk); #1; commit = 1'b0; frame = 1'b0;
        end
    endtask

    task settle(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) do_frame;
        end
    endtask

    // C9: one-clock page pulse, like wall_input's KEY4/KEY3 edge
    task one_pulse_nxt;
        begin
            @(posedge clk); #1; nxt = 1'b1;
            @(posedge clk); #1; nxt = 1'b0;
        end
    endtask
    task one_pulse_prv;
        begin
            @(posedge clk); #1; prv = 1'b1;
            @(posedge clk); #1; prv = 1'b0;
        end
    endtask

    function [11:0] gx_of;   input [255:0] t; input integer w; begin gx_of = t[w*64 +: 12]; end endfunction
    function [11:0] gy_of;   input [255:0] t; input integer w; begin gy_of = t[w*64+12 +: 12]; end endfunction
    function [9:0]  w_of;    input [255:0] t; input integer w; begin w_of  = t[w*64+24 +: 10]; end endfunction
    function [9:0]  h_of;    input [255:0] t; input integer w; begin h_of  = t[w*64+34 +: 10]; end endfunction
    function [1:0]  z_of;    input [255:0] t; input integer w; begin z_of  = t[w*64+48 +: 2];  end endfunction
    function          fw_of; input [255:0] t; input integer w; begin fw_of = t[w*64+58];      end endfunction
    function [1:0]  pg_of;   input [255:0] t; input integer w; begin pg_of = t[w*64+59 +: 2]; end endfunction

    reg [255:0] before;
    reg [255:0] before_alb;          // C9: the album table before paging
    integer errors = 0, i;

    initial begin
        $display("=== tb_album_tbl");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        settle(4);

        before = cur_a;
        if (level !== 5'd16) begin
            $display("FAIL: idle level = %0d (want 16 = passthrough)", level);
            errors = errors + 1;
        end

        // ---- 1. enter album mode (fade out -> swap -> fade in) ------------
        falling = 1'b1;
        album   = 1'b1;
        settle(40);
        falling = 1'b0;

        if (!saw_zero) begin
            $display("FAIL: the fade never reached black");
            errors = errors + 1;
        end
        if (!saw_swap) begin
            $display("FAIL: the table was never swapped");
            errors = errors + 1;
        end
        if (!swap_ok) begin
            $display("FAIL: the table was written while the screen was NOT black");
            errors = errors + 1;
        end
        if (frames_out < 14 || frames_out > 18) begin
            $display("FAIL: fade-out took %0d frames (want 16)", frames_out);
            errors = errors + 1;
        end
        $display("  fade-out = %0d frames, swap only at black, level back to %0d",
                 frames_out, level);

        if (level !== 5'd16) begin
            $display("FAIL: level after entering = %0d (want 16)", level);
            errors = errors + 1;
        end
        if (!fw_of(cur_a, 0)) begin
            $display("FAIL: slot 0 is not frameless after entering album mode");
            errors = errors + 1;
        end
        if (h_of(cur_a, 0) !== 10'd480 || w_of(cur_a, 0) !== 10'd1023) begin
            $display("FAIL: album record h/w = %0d/%0d (want 480/1023)",
                     h_of(cur_a,0), w_of(cur_a,0));
            errors = errors + 1;
        end
        if (z_of(cur_a, 0) !== 2'd3) begin
            $display("FAIL: album record z = %0d (want 3)", z_of(cur_a, 0));
            errors = errors + 1;
        end
        if (pg_of(cur_a, 0) !== 2'd0) begin
            $display("FAIL: album page on entry = %0d (want 0)", pg_of(cur_a, 0));
            errors = errors + 1;
        end
        for (i = 1; i < 4; i = i + 1) begin
            if (w_of(cur_a, i) !== 10'd0 || h_of(cur_a, i) !== 10'd0) begin
                $display("FAIL: slot %0d not blanked (%0d x %0d)", i,
                         w_of(cur_a, i), h_of(cur_a, i));
                errors = errors + 1;
            end
            if (fw_of(cur_a, i)) begin
                $display("FAIL: slot %0d is frameless (only slot 0 may be)", i);
                errors = errors + 1;
            end
        end
        if (cur_b !== cur_a) begin
            $display("FAIL: peer table differs after entering album mode");
            $display("   A = %064h", cur_a);
            $display("   B = %064h", cur_b);
            errors = errors + 1;
        end
        $display("  album cur_tbl = %064h", cur_a);

        // snapshot the album table: paging may only touch slot0 [60:59]
        before_alb = cur_a;

        // ---- 1b. C9: paging rewrites slot 0 only --------------------------
        // KEY4 twice: page 0 -> 1 -> 2.  The pulse is one clock wide and the
        // sequencer only acts in S_ALBUM, which is where we are now.
        one_pulse_nxt;
        settle(40);   // C9-R2: a page change fades like a mode change
        one_pulse_nxt;
        settle(40);   // C9-R2: a page change fades like a mode change
        if (pg_of(cur_a, 0) !== 2'd2) begin
            $display("FAIL: two NEXT pulses gave page %0d (want 2)", pg_of(cur_a, 0));
            errors = errors + 1;
        end
        if (pic_idx !== 2'd2) begin
            $display("FAIL: pic_idx output = %0d (want 2)", pic_idx);
            errors = errors + 1;
        end
        // everything except bits [60:59] of slot 0 must be untouched
        for (i = 0; i < 64; i = i + 1) begin
            if ((i != 59) && (i != 60) && (cur_a[i] !== before_alb[i])) begin
                $display("FAIL: paging changed slot0 bit %0d", i);
                errors = errors + 1;
            end
        end
        for (i = 1; i < 4; i = i + 1) begin
            if (cur_a[i*64 +: 64] !== before_alb[i*64 +: 64]) begin
                $display("FAIL: paging changed slot %0d", i);
                errors = errors + 1;
            end
        end
        if (cur_b !== cur_a) begin
            $display("FAIL: peer did not follow the page change");
            errors = errors + 1;
        end
        // PREV once: page 2 -> 1; PREV three more: 1 -> 0 -> 3 -> 2 (wrap)
        one_pulse_prv;
        settle(40);
        if (pg_of(cur_a, 0) !== 2'd1) begin
            $display("FAIL: PREV gave page %0d (want 1)", pg_of(cur_a, 0));
            errors = errors + 1;
        end
        one_pulse_prv;  settle(40);
        one_pulse_prv;  settle(40);
        if (pg_of(cur_a, 0) !== 2'd3) begin
            $display("FAIL: wrap below zero gave page %0d (want 3)", pg_of(cur_a, 0));
            errors = errors + 1;
        end
        one_pulse_nxt;  settle(40);
        if (pg_of(cur_a, 0) !== 2'd0) begin
            $display("FAIL: wrap above three gave page %0d (want 0)", pg_of(cur_a, 0));
            errors = errors + 1;
        end
        $display("  paging: 0->1->2, prev 2->1->0->3, next 3->0 OK");

        // ---- 2. leave album mode ------------------------------------------
        album = 1'b0;
        settle(40);

        if (cur_a !== before) begin
            $display("FAIL: table not restored");
            $display("   before = %064h", before);
            $display("   after  = %064h", cur_a);
            errors = errors + 1;
        end
        if (cur_b !== before) begin
            $display("FAIL: peer table not restored");
            errors = errors + 1;
        end
        if (level !== 5'd16) begin
            $display("FAIL: level after leaving = %0d (want 16)", level);
            errors = errors + 1;
        end

        // ---- 3. a second round must behave the same ----------------------
        album = 1'b1;
        settle(40);
        if (!fw_of(cur_a, 0)) begin
            $display("FAIL: second entry did not set frameless again");
            errors = errors + 1;
        end
        album = 1'b0;
        settle(40);
        if (cur_a !== before) begin
            $display("FAIL: second leave did not restore the table");
            errors = errors + 1;
        end

        if (errors == 0) $display("TB_ALBUM_TBL PASS");
        else             $display("TB_ALBUM_TBL FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
