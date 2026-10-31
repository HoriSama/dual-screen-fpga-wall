//=============================================================================
// tb_node.v -- two complete nodes, two independent 50 MHz clocks
//
// Covers the whole distributed contract:
//   * B mirrors A's table exactly (2-frame snapshot pipeline)
//   * A's keys drag a window; both nodes agree on the new position
//   * B's keys reach A over the link (INPUT frame)
//   * cutting B->A drops A's link_ok; cutting A->B freezes B's table
//
// The raster is shrunk to 64x48 so a frame is ~147 us instead of 16.7 ms.
//=============================================================================
`timescale 1ns/1ps

module tb_node;
    reg clk_a = 0, clk_b = 0;
    always #10.00 clk_a = ~clk_a;      // 50.000 MHz
    always #10.01 clk_b = ~clk_b;      // 49.95 MHz (deliberate drift)

    reg  [3:0] key_a = 4'hF, key_b = 4'hF;
    reg  [3:0] sw_a  = 4'b0001;   // pins, with SW_INV=1: 1 = switch up (SW1 up = operate)

    // link wires (A drives the first group, B the second)
    wire        a_lclk, a_lsync, a_lvld;
    wire [3:0]  a_ld;
    wire        b_blvld;
    wire [3:0]  b_bd;

    reg         cut_ab = 0, cut_ba = 0;
    wire [3:0]  a_ld_d = a_ld;
    wire [3:0]  b_bd_d = b_bd;

    wire ddc_a, ddc_b;

    wall_core #(
        .IS_MASTER(1), .NODE_ID(0),
        .HACTIVE(64), .VACTIVE(48), .HFP(2), .HSA(4), .HBP(2),
        .VFP(1), .VSA(1), .VBP(1), .DB_CYC(100), .REP_CYC(400), .POR_BITS(8),
        .AUTODRAG(0), .AUTO_START(2000), .AUTO_STEP(200)
    ) u_a (
        .clk50(clk_a), .key_n(key_a), .sw_n(sw_a), .led(),
        .HDMI_D0_P(), .HDMI_D1_P(), .HDMI_D2_P(), .HDMI_CLK_P(),
        .HDMI_DDC_SCL(), .HDMI_DDC_SDA(ddc_a),
        .o_link_clk(a_lclk), .o_link_sync(a_lsync), .o_link_vld(a_lvld), .o_link_d(a_ld),
        .i_link_bvld(cut_ba ? 1'b0 : b_blvld), .i_link_bd(cut_ba ? 4'h0 : b_bd_d),
        .i_link_clk(1'b0), .i_link_sync(1'b0), .i_link_vld(1'b0), .i_link_d(4'h0),
        .o_link_bvld(), .o_link_bd()
    );

    wall_core #(
        .IS_MASTER(0), .NODE_ID(1),
        .HACTIVE(64), .VACTIVE(48), .HFP(2), .HSA(4), .HBP(2),
        .VFP(1), .VSA(1), .VBP(1), .DB_CYC(100), .REP_CYC(400), .POR_BITS(8),
        .AUTODRAG(0), .AUTO_START(2000), .AUTO_STEP(200)
    ) u_b (
        .clk50(clk_b), .key_n(key_b), .sw_n(4'hF), .led(),
        .HDMI_D0_P(), .HDMI_D1_P(), .HDMI_D2_P(), .HDMI_CLK_P(),
        .HDMI_DDC_SCL(), .HDMI_DDC_SDA(ddc_b),
        .o_link_clk(), .o_link_sync(), .o_link_vld(), .o_link_d(),
        .i_link_bvld(1'b0), .i_link_bd(4'h0),
        .i_link_clk(a_lclk), .i_link_sync(cut_ab ? 1'b0 : a_lsync),
        .i_link_vld(cut_ab ? 1'b0 : a_lvld), .i_link_d(cut_ab ? 4'h0 : a_ld_d),
        .o_link_bvld(b_blvld), .o_link_bd(b_bd)
    );

    // temporary write/event tracing
    always @(posedge u_a.pixel_clk) begin
        if ($test$plusargs("dbg") && u_a.a_set_tbl)
            $display("WR t=%0t idx=%0d gx=%0d flags=%b",
                     $time, u_a.a_set_idx, u_a.a_set_data[11:0],
                     u_a.a_set_data[53:51]);
    end
    always @(posedge u_a.pixel_clk) begin
        if ($test$plusargs("dbg") && (u_a.g_master.u_in.local_press != 4'd0))
            $display("KEY t=%0t press=%b sel=%0d mode=%b sd=%b sw1=%b sw2=%b",
                     $time, u_a.g_master.u_in.local_press, u_a.g_master.u_in.sel,
                     u_a.g_master.u_in.dbg_mode, u_a.g_master.u_in.sd, u_a.g_master.u_in.sw1, u_a.g_master.u_in.sw2);
    end

    always @(posedge u_a.pixel_clk) begin
        if ($test$plusargs("dbg") && (u_a.g_master.rpress != 4'd0))
            $display("RP t=%0t rpress=%b payload=%h ftype=%h flen=%0d",
                     $time, u_a.g_master.rpress, u_a.g_master.rx_payload[31:0],
                     u_a.g_master.rx_type, u_a.g_master.rx_len);
    end

    integer errors = 0;
    integer frames = 0;

    always @(posedge u_a.pixel_clk) begin
        if ($test$plusargs("dbg") && u_a.sof_c && frames > 12 && frames < 34)
            $display("f=%0d A: stage=%0d snap=%0d cur=%0d | B: stage=%0d cur=%0d",
                     frames,
                     u_a.u_state.w0[11:0], u_a.u_state.s0[11:0], u_a.u_state.c0[11:0],
                     u_b.u_state.w0[11:0], u_b.u_state.c0[11:0]);
    end
    always @(posedge u_a.sof_c) frames = frames + 1;

    task wait_frames(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(posedge u_a.sof_c);
        end
    endtask

    task press_a(input integer k);
        begin
            key_a[k] = 1'b0; #20000; key_a[k] = 1'b1; #20000;
        end
    endtask

    task press_b(input integer k);
        begin
            key_b[k] = 1'b0; #20000; key_b[k] = 1'b1; #20000;
        end
    endtask

    task settle;
        begin
            #2000;   // one line at 25 MHz per 40 ns
        end
    endtask

    // Sample at line 40 of A's frame: both nodes have long committed.
    task sample;
        begin
            @(posedge u_a.pixel_clk);
            while (!(u_a.de_c && (u_a.y_c == 9'd40))) @(posedge u_a.pixel_clk);
            #1;
        end
    endtask

    integer gx_a, gx_b, sel_a, sel_b, h0;

    task expect_tables(input [255:0] why_unused);
        begin
            sample;
            if (u_a.cur_tbl !== u_b.cur_tbl) begin
                errors = errors + 1;
                $display("FAIL: table mismatch at frame %0d", frames);
                $display("  A %064h", u_a.cur_tbl);
                $display("  B %064h", u_b.cur_tbl);
            end
        end
    endtask

    initial begin
        // let both nodes boot and lock
        wait_frames(10);
        expect_tables(256'd0);
        gx_a = u_a.cur_tbl[11:0];
        if (gx_a !== 12'd24) begin
            errors = errors + 1;
            $display("FAIL: default gx %0d != 24", gx_a);
        end
        $display("boot ok: gx=%0d sel=%0d", gx_a, u_a.cur_sel);

        // ---- lock window 0, enable directions, move it -------------------
        press_a(2);              // KEY3 = confirm the selected window
        wait_frames(2);
        if (u_a.cur_tbl[52] !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL: lock flag not set after KEY2 (flags=%b)", u_a.cur_tbl[53:51]);
        end
        h0 = u_a.cur_tbl[23:12];

        sw_a[1] = 1'b1;          // SW2 up = direction keys
        #600000;
        press_a(0);              // KEY1 = right (move mode)
        press_a(0);
        press_a(0);
        press_a(3);              // KEY4 = up (move mode)
        wait_frames(3);
        expect_tables(256'd0);
        gx_a = u_a.cur_tbl[11:0];
        gx_b = u_b.cur_tbl[11:0];
        if (gx_a < 12'd27) begin
            errors = errors + 1;
            $display("FAIL: gx after 3 presses %0d (want >= 27)", gx_a);
        end
        if (u_a.cur_tbl[23:12] >= h0) begin
            errors = errors + 1;
            $display("FAIL: gy did not go up (%0d, was %0d)", u_a.cur_tbl[23:12], h0);
        end
        if (gx_b !== gx_a) begin
            errors = errors + 1;
            $display("FAIL: B gx %0d != A gx %0d", gx_b, gx_a);
        end
        $display("move ok: gx=%0d/%0d gy=%0d", gx_a, gx_b, u_a.cur_tbl[23:12]);

        // ---- view mode forces the unlock; centre is on A so owner stays A --
        sw_a[1] = 1'b0;
        sw_a[0] = 1'b0;          // SW1 down = view mode
        wait_frames(3);
        if (u_a.cur_tbl[52] !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL: view mode did not clear the lock (flags=%b)", u_a.cur_tbl[53:51]);
        end
        if (u_a.cur_tbl[50] !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL: owner flipped to B while centre is on A");
        end
        sw_a[0] = 1'b1;          // back to operate
        wait_frames(2);
        // ---- B's KEY1 selects the next window ---------------------------
        press_b(3);              // B's KEY4 selects the next window
        wait_frames(8);
        sel_a = u_a.cur_sel;
        sel_b = u_b.cur_sel;
        if (sel_a !== 2'd1 || sel_b !== 2'd1) begin
            errors = errors + 1;
            $display("FAIL: remote select A=%0d B=%0d (want 1/1)", sel_a, sel_b);
        end
        $display("remote select ok: sel=%0d/%0d", sel_a, sel_b);

        // ---- cut B->A: A loses the peer, B keeps receiving ---------------
        cut_ba = 1;
        wait_frames(16);
        if (u_a.link_ok !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL: A link_ok still 1 after B->A cut");
        end
        if (u_b.link_ok !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL: B link_ok dropped although A still transmits");
        end
        $display("cut B->A ok: A link_ok=%b B link_ok=%b",
                 u_a.link_ok, u_b.link_ok);
        cut_ba = 0;
        wait_frames(4);

        // ---- cut A->B: B must freeze -------------------------------------
        cut_ab = 1;
        wait_frames(10);
        if (u_b.link_ok !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL: B link_ok still 1 after A->B cut");
        end
        sel_b = u_b.cur_sel;
        press_a(3);              // A switches selection (KEY4), B must not follow
        wait_frames(6);
        if (u_a.cur_sel === sel_b) begin
            errors = errors + 1;
            $display("FAIL: A selection did not change, test is inconclusive");
        end
        if (u_b.cur_sel !== sel_b) begin
            errors = errors + 1;
            $display("FAIL: B followed A while the link was cut (%0d -> %0d)",
                     sel_b, u_b.cur_sel);
        end
        $display("cut A->B ok: A sel=%0d frozen B sel=%0d",
                 u_a.cur_sel, u_b.cur_sel);

        // ---- restore: B resyncs within a few frames ----------------------
        cut_ab = 0;
        wait_frames(8);
        if (u_b.link_ok !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL: B did not recover after the link came back");
        end
        expect_tables(256'd0);
        $display("recovery ok: A sel=%0d B sel=%0d, %0d frames simulated",
                 u_a.cur_sel, u_b.cur_sel, frames);

        if (errors == 0) $display("TB_NODE PASS");
        else             $display("TB_NODE FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TB_NODE TIMEOUT");
        $finish;
    end
endmodule
