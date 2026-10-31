// tb_mute.v -- the two "view-only" key maps of wall_input
//
//   1. VIEW mode (SW1 down): KEY2 = captions on/off, KEY1 = mute;
//   2. ALBUM mode (SW1 + SW4 up, C9): KEY4 = next picture, KEY3 = previous,
//      each exactly ONE pulse per press (a level would step the page every
//      clock), and the album branch must never touch the window table -- the
//      table belongs to wall_album_seq.
`timescale 1ns/1ps

module tb_mute;
    reg clk = 0;
    always #20 clk = ~clk;

    reg rst = 1;
    reg [3:0] key_n = 4'hF;
    reg [3:0] sw_n  = 4'hF;      // active low: 1 = switch up
    wire mute, osd_en;
    wire [2:0] mode_out;
    wire [1:0] rd_idx_w;
    wire alb_next, alb_prev;
    wire set_tbl;

    wall_input #(.FORCE_DIRS(0)) dut (
        .clk(clk), .rst(rst), .key_n(key_n), .sw_n(sw_n),
        .remote_press(4'd0), .commit(1'b0), .db_cyc(17'd20), .rep_cyc(20'd200),
        .acc_thr(24'd100),
        .cur_sel(2'd0), .stage_word(64'd0), .rd_idx(rd_idx_w),
        .set_tbl(set_tbl), .set_idx(), .set_data(), .set_sel(), .sel_out(),
        .local_press(), .evt_valid(), .evt_gx(),
        .dbg_mode(), .mode_out(mode_out), .mute(mute), .osd_en(osd_en),
        .car_toggle(), .car_step(),
        .adj_ev(), .adj_con(), .adj_up(), .adj_on(),
        .adj_rst_b(), .adj_rst_c(),
        .alb_next(alb_next), .alb_prev(alb_prev), .album_out()
    );

    // count the page pulses: each key press must produce exactly one
    integer n_next = 0, n_prev = 0, n_tbl = 0;
    always @(posedge clk) begin
        if (alb_next) n_next = n_next + 1;
        if (alb_prev) n_prev = n_prev + 1;
        if (set_tbl)  n_tbl  = n_tbl + 1;
    end

    task press(input integer i);
        begin
            key_n[i] = 1'b0;
            repeat (600) @(posedge clk);     // debounce
            key_n[i] = 1'b1;
            repeat (600) @(posedge clk);
        end
    endtask

    integer errors = 0;

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (20) @(posedge clk);
        $display("after reset: mute=%b osd_en=%b mode=%b", mute, osd_en, mode_out);

        // SW1 down = VIEW mode
        sw_n[0] = 1'b0;
        repeat (600) @(posedge clk);
        $display("view mode  : mute=%b osd_en=%b mode=%b", mute, osd_en, mode_out);

        press(3);  // KEY4
        $display("after KEY4 : mute=%b osd_en=%b", mute, osd_en);
        press(3);
        $display("after KEY4 : mute=%b osd_en=%b", mute, osd_en);

        press(2);  // KEY3
        $display("after KEY3 : mute=%b osd_en=%b", mute, osd_en);
        press(2);
        $display("after KEY3 : mute=%b osd_en=%b", mute, osd_en);

        if (osd_en !== 1'b1) begin $display("FAIL: two KEY3 presses did not restore osd_en"); errors = errors + 1; end
        if (n_next != 0 || n_prev != 0) begin
            $display("FAIL: page pulses fired in VIEW mode (next=%0d prev=%0d)", n_next, n_prev);
            errors = errors + 1;
        end

        // ---- ALBUM mode: SW1 up + SW4 up ----------------------------------
        sw_n[0] = 1'b1;
        sw_n[3] = 1'b1;
        repeat (600) @(posedge clk);
        $display("album mode : mode=%b", mode_out);
        n_next = 0; n_prev = 0; n_tbl = 0;

        press(3);                               // KEY4 = next
        if (n_next != 1 || n_prev != 0) begin
            $display("FAIL: KEY4 in album gave next=%0d prev=%0d (want 1/0)", n_next, n_prev);
            errors = errors + 1;
        end
        press(2);                               // KEY3 = previous
        if (n_next != 1 || n_prev != 1) begin
            $display("FAIL: KEY3 in album gave next=%0d prev=%0d (want 1/1)", n_next, n_prev);
            errors = errors + 1;
        end
        press(3);
        press(3);                               // held keys must still be one pulse each
        if (n_next != 3 || n_prev != 1) begin
            $display("FAIL: page pulse count next=%0d prev=%0d (want 3/1)", n_next, n_prev);
            errors = errors + 1;
        end
        press(1);                               // KEY2 / KEY1 do nothing in album mode
        press(0);
        if (n_next != 3 || n_prev != 1) begin
            $display("FAIL: KEY2/KEY1 moved the page (next=%0d prev=%0d)", n_next, n_prev);
            errors = errors + 1;
        end
        if (n_tbl != 0) begin
            $display("FAIL: the album branch wrote the window table %0d times", n_tbl);
            errors = errors + 1;
        end
        $display("album keys : next=%0d prev=%0d table writes=%0d", n_next, n_prev, n_tbl);

        if (errors == 0) $display("TB_MUTE PASS");
        else             $display("TB_MUTE FAIL (%0d)", errors);
        $finish;
    end
endmodule
