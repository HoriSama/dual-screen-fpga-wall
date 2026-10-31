//=============================================================================
// tb_drag.v -- key/switch move FSM: steps, acceleration, clamp, ownership
//
// Everything here is driven through the physical key/switch inputs, the same
// way an operator uses the console:
//   1. SW1 up + KEY2 locks the window; one short press of KEY4 = 1 px
//   2. holding KEY4 auto-repeats and the step grows to 4 px after acc_thr
//   3. the window cannot be pushed off the top of the world
//   4. SW1 down (view mode) drops the lock
//   5. moving the centre past the seam and unlocking hands the window to B
//=============================================================================
`timescale 1ns/1ps

module tb_drag;
    localparam integer COMMIT_CYC = 3672;      // one tiny-raster frame at 25 MHz
    localparam [23:0]  ACC_THR    = 24'd2000;  // short, so the test runs quickly
    localparam integer DB          = 100;      // debounce length in clocks
    localparam integer REP         = 400;      // auto-repeat period

    reg clk = 0;
    always #40 clk = ~clk;

    reg  rst = 1;
    reg  commit = 0;
    reg  [3:0] key_n = 4'hF;
    reg  [3:0] sw_n  = 4'b0001;      // wall_input convention: 1 = switch up
    reg  [3:0] remote_press = 4'd0;

    wire [1:0]   rd_idx;
    wire [63:0]  stage_word;
    wire         set_tbl, set_sel, set_anim;
    wire [1:0]   set_idx, sel_in;
    wire [63:0]  set_data;
    wire [4:0]   anim_in;
    wire [1:0]   cur_sel;
    wire [255:0] cur_tbl;

    wall_state u_state (
        .clk(clk), .rst(rst), .commit(commit),
        .set_tbl(set_tbl), .set_idx(set_idx), .set_data(set_data),
        .set_sel(set_sel), .sel_in(sel_in),
        .set_anim(set_anim), .anim_in(anim_in),
        .rd_idx(rd_idx), .rd_word(stage_word),
        .cur_tbl(cur_tbl), .cur_sel(cur_sel), .cur_anim(),
        .snap_tbl(), .snap_sel(), .snap_anim()
    );

    wall_input u_in (
        .clk(clk), .rst(rst), .key_n(key_n), .sw_n(sw_n),
        .remote_press(remote_press), .commit(commit),
        .db_cyc(DB), .rep_cyc(REP), .acc_thr(ACC_THR),
        .cur_sel(cur_sel), .stage_word(stage_word), .rd_idx(rd_idx),
        .set_tbl(set_tbl), .set_idx(set_idx), .set_data(set_data),
        .set_sel(set_sel), .sel_out(sel_in),
        .local_press(), .evt_valid(), .evt_gx(), .dbg_mode()
    );

    wire [11:0] gx_now = u_state.cur_tbl[11:0];
    wire [11:0] gy_now = u_state.cur_tbl[23:12];
    wire        locked = u_state.cur_tbl[52];
    wire        owner  = u_state.cur_tbl[50];

    initial begin
        forever begin
            repeat (COMMIT_CYC - 1) @(posedge clk);
            commit <= 1'b1;
            @(posedge clk);
            commit <= 1'b0;
        end
    end

    // press and release a physical key, holding it `cycles` clocks
    task press(input integer k, input integer cycles);
        begin
            key_n[k] = 1'b0;
            repeat (cycles) @(posedge clk);
            key_n[k] = 1'b1;
            repeat (DB * 3) @(posedge clk);
        end
    endtask

    task frames(input integer n);
        begin
            repeat (COMMIT_CYC * n) @(posedge clk);
        end
    endtask

    integer errors = 0;
    integer gx0, gy0, gx1, gy1;

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        frames(1);

        // ---- lock the selected window ------------------------------------
        press(2, DB * 3);               // KEY3 = confirm
        frames(2);
        if (locked !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL: KEY2 did not lock (flags=%b)", cur_tbl[53:51]);
        end
        sw_n[1] = 1'b1;                 // SW2 up = direction keys
        repeat (DB * 3) @(posedge clk);


        // ---- 2: holding accelerates to 4 px steps ------------------------
        gx0 = gx_now;
        press(0, ACC_THR * 4);          // KEY1 = right in move mode
        frames(1);
        gx1 = gx_now;
        $display("hold %0d clocks: gx %0d -> %0d (%0d px)",
                 ACC_THR * 4, gx0, gx1, gx1 - gx0);
        if (gx1 - gx0 < 6) begin
            errors = errors + 1;
            $display("FAIL: holding moved only %0d px", gx1 - gx0);
        end

        // ---- 3: clamp at the top of the world ----------------------------
        gy0 = gy_now;
        press(3, ACC_THR * 20);         // KEY4 = up in move mode
        frames(1);
        gy1 = gy_now;
        $display("up from gy=%0d: gy=%0d", gy0, gy1);
        if (gy1 !== 12'd0) begin
            errors = errors + 1;
            $display("FAIL: gy stopped at %0d, expected the clamp at 0", gy1);
        end

        // ---- 4: view mode drops the lock ---------------------------------
        sw_n[0] = 1'b0;                 // SW1 down = view mode
        frames(2);
        if (locked !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL: view mode did not drop the lock");
        end
        sw_n[0] = 1'b1;
        sw_n[1] = 1'b0;
        frames(1);

        // ---- 5: cross the seam, then view mode hands the window to B -----
        press(2, DB * 3);               // confirm again
        frames(1);
        sw_n[1] = 1'b1;
        repeat (DB * 3) @(posedge clk);
        press(0, ACC_THR * 120);        // KEY1 = right, plenty of 4 px steps
        frames(1);
        gx1 = gx_now;
        $display("after the long move: gx=%0d (locked=%b owner=%b)", gx1, locked, owner);
        if (gx1 + 12'd150 <= 12'd640) begin
            errors = errors + 1;
            $display("FAIL: the window never reached the seam (gx=%0d)", gx1);
        end
        sw_n[1] = 1'b0;                 // directions off
        sw_n[0] = 1'b0;                 // SW1 down = view mode: drops the lock
        frames(2);
        $display("after view mode: gx=%0d owner=%b locked=%b", gx_now, owner, locked);
        if (locked !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL: view mode did not drop the lock");
        end
        if (owner !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL: centre is past 640 but owner is still A");
        end
        if (errors == 0) $display("TB_DRAG PASS");
        else             $display("TB_DRAG FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
