//=============================================================================
// tb_hud_dump.v -- renders the W3 status lines to a PPM so they can be looked at
//
// The two new HUD rows are pure text, so a pixel diff between two instances
// would only say "they agree", not "the glyphs are the right ones".  This TB
// drives the compositor over the caption block (x = 0..127, y = 112..152) with
// a fixed wall clock and carousel state and writes the RGB to two PPM files:
//
//   hud_auto.ppm  min=12 sec=34 car_auto=1  ->  "TIME 12 34" / "  CAR AUTO  "
//   hud_stop.ppm  min=07 sec=59 car_auto=0  ->  "TIME 07 59" / "  CAR STOP  "
//
// Checks, besides the pictures:
//   * node A must actually paint the two rows (compare against a HUD-less
//     instance of the same node);
//   * node B must paint NOTHING there (both lines are A-only), i.e. its pixels
//     must be identical to the same node with the HUD disabled.
//
//   vsim -c -do "run -all; quit -f" tb_hud_dump
//=============================================================================
`timescale 1ns/1ps

module tb_hud_dump;
    reg clk = 1'b0;
    always #20 clk = ~clk;              // 25 MHz pixel clock

    // The window starts two rows below the MUSIC box (Y0 = 104, padding down to
    // y = 113) so the paint counters below only ever see the two new rows.
    // Y_SPLIT: CAR box is y 118..129, TIME box is y 134..145.
    localparam integer X0 = 0, X1 = 272, Y0 = 116, Y1 = 166, Y_SPLIT = 132, Y_SPLIT2 = 148;   // X1 covers the BRT/CON level bars

    reg [10:0] x = 11'd0;
    reg [8:0]  y = 9'd0;
    reg [7:0]  t_min = 8'h12, t_sec = 8'h34;   // BCD, see wall_top
    reg        t_auto = 1'b1;

    wire [23:0] rgb_a, rgb_a0, rgb_b, rgb_b0;

    wall_scene #(.NODE_X0(0), .HUD_EN(1), .NODE_ID(0)) u_a (
        .clk(clk), .x(x), .y(y), .de(1'b1), .tbl(256'd0),
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}),
        .mode_sw(3'b010), .osd_en(1'b1), .mute(1'b0), .music_ok(1'b1),
        .music_frames(21'd1439278), .aud_level(8'h40), .meter_en(1'b1),
        .show_music(1'b1), .ld_err(8'd0),
        .time_min(t_min), .time_sec(t_sec), .car_auto(t_auto),
        .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_A0C0),   // picture 0: brightness C0, contrast A0
        .adj_on(1'b1), .frame(1'b0),
        .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .anim(5'd0), .sel(2'd0), .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0),
        .m_on(1'b0), .m_phase(9'd0), .blink(1'b0), .pic_rgb565(16'h0000), .lb_rd_win(), .lb_rd_col(),
        .pic_valid(4'h0), .tlevel(5'd16), .fade_gain(8'd255), .rgb(rgb_a));

    // same node, HUD off: the reference "nothing painted here" image
    wall_scene #(.NODE_X0(0), .HUD_EN(0), .NODE_ID(0)) u_a0 (
        .clk(clk), .x(x), .y(y), .de(1'b1), .tbl(256'd0),
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}),
        .mode_sw(3'b010), .osd_en(1'b1), .mute(1'b0), .music_ok(1'b1),
        .music_frames(21'd1439278), .aud_level(8'h40), .meter_en(1'b1),
        .show_music(1'b1), .ld_err(8'd0),
        .time_min(t_min), .time_sec(t_sec), .car_auto(t_auto),
        .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_A0C0),   // picture 0: brightness C0, contrast A0
        .adj_on(1'b1), .frame(1'b0),
        .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .anim(5'd0), .sel(2'd0), .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0),
        .m_on(1'b0), .m_phase(9'd0), .blink(1'b0), .pic_rgb565(16'h0000), .lb_rd_win(), .lb_rd_col(),
        .pic_valid(4'h0), .tlevel(5'd16), .fade_gain(8'd255), .rgb(rgb_a0));

    wall_scene #(.NODE_X0(640), .HUD_EN(1), .NODE_ID(1)) u_b (
        .clk(clk), .x(x), .y(y), .de(1'b1), .tbl(256'd0),
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}),
        .mode_sw(3'b010), .osd_en(1'b1), .mute(1'b0), .music_ok(1'b1),
        .music_frames(21'd1439278), .aud_level(8'h40), .meter_en(1'b1),
        .show_music(1'b1), .ld_err(8'd0),
        .time_min(t_min), .time_sec(t_sec), .car_auto(t_auto),
        .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_A0C0),   // picture 0: brightness C0, contrast A0
        .adj_on(1'b1), .frame(1'b0),
        .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .anim(5'd0), .sel(2'd0), .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0),
        .m_on(1'b0), .m_phase(9'd0), .blink(1'b0), .pic_rgb565(16'h0000), .lb_rd_win(), .lb_rd_col(),
        .pic_valid(4'h0), .tlevel(5'd16), .fade_gain(8'd255), .rgb(rgb_b));

    wall_scene #(.NODE_X0(640), .HUD_EN(0), .NODE_ID(1)) u_b0 (
        .clk(clk), .x(x), .y(y), .de(1'b1), .tbl(256'd0),
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}),
        .mode_sw(3'b010), .osd_en(1'b1), .mute(1'b0), .music_ok(1'b1),
        .music_frames(21'd1439278), .aud_level(8'h40), .meter_en(1'b1),
        .show_music(1'b1), .ld_err(8'd0),
        .time_min(t_min), .time_sec(t_sec), .car_auto(t_auto),
        .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_A0C0),   // picture 0: brightness C0, contrast A0
        .adj_on(1'b1), .frame(1'b0),
        .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .anim(5'd0), .sel(2'd0), .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0),
        .m_on(1'b0), .m_phase(9'd0), .blink(1'b0), .pic_rgb565(16'h0000), .lb_rd_win(), .lb_rd_col(),
        .pic_valid(4'h0), .tlevel(5'd16), .fade_gain(8'd255), .rgb(rgb_b0));

    integer errors = 0;
    integer fd, xx, yy, a_car, a_time, a_adj, b_car, b_time, b_adj;

    // walk the caption block once, dumping A and counting what each node paints
    task walk(input integer fnum, input dump_it);
        begin
            a_car  = 0; a_time = 0; a_adj = 0;
            b_car  = 0; b_time = 0; b_adj = 0;
            if (dump_it) $fwrite(fnum, "P6\n%0d %0d\n255\n", X1 - X0, Y1 - Y0);
            for (yy = Y0; yy < Y1; yy = yy + 1) begin
                for (xx = X0; xx < X1; xx = xx + 1) begin
                    x = xx[10:0];
                    y = yy[8:0];
                    @(posedge clk);          // output register: sample after it
                    #1;
                    if (dump_it) $fwrite(fnum, "%c%c%c",
                                         rgb_a[23:16], rgb_a[15:8], rgb_a[7:0]);
                    if (yy < Y_SPLIT) begin
                        if (rgb_a !== rgb_a0) a_car  = a_car  + 1;
                        if (rgb_b !== rgb_b0) b_car  = b_car  + 1;
                    end else if (yy < Y_SPLIT2) begin
                        if (rgb_a !== rgb_a0) a_time = a_time + 1;
                        if (rgb_b !== rgb_b0) b_time = b_time + 1;
                    end else begin
                        if (rgb_a !== rgb_a0) a_adj  = a_adj  + 1;
                        if (rgb_b !== rgb_b0) b_adj  = b_adj  + 1;
                    end
                end
            end
        end
    endtask

    // A paints CAR + TIME; B paints CAR (broadcast now) and nothing on TIME.
    task check_paint;
        begin
            if (a_car < 1000) begin
                $display("NODE A FAIL: CAR row unpainted (%0d px)", a_car);
                errors = errors + 1;
            end
            if (a_time < 1000) begin
                $display("NODE A FAIL: TIME row unpainted (%0d px)", a_time);
                errors = errors + 1;
            end
            if (b_car < 1000) begin
                $display("NODE B FAIL: CAR row unpainted (%0d px)", b_car);
                errors = errors + 1;
            end
            if (b_time != 0) begin
                $display("NODE B FAIL: %0d pixels painted on the A-only TIME row", b_time);
                errors = errors + 1;
            end
            if (a_adj < 1000) begin
                $display("NODE A FAIL: BRT/CON row unpainted (%0d px)", a_adj);
                errors = errors + 1;
            end
            if (b_adj < 1000) begin
                $display("NODE B FAIL: BRT/CON row unpainted (%0d px)", b_adj);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        x = 11'd0; y = 9'd0;
        repeat (4) @(posedge clk);

        // ---- state 1: 12:34, auto -----------------------------------------
        t_min = 8'h12; t_sec = 8'h34; t_auto = 1'b1;
        fd = $fopen("hud_auto.ppm", "wb");
        walk(fd, 1'b1);
        $fclose(fd);
        $display("wrote hud_auto.ppm  (TIME 12 34 / CAR AUTO): A car=%0d time=%0d adj=%0d, B car=%0d time=%0d adj=%0d",
                 a_car, a_time, a_adj, b_car, b_time, b_adj);
        check_paint;

        // ---- state 2: 07:59, stopped --------------------------------------
        t_min = 8'h07; t_sec = 8'h59; t_auto = 1'b0;
        fd = $fopen("hud_stop.ppm", "wb");
        walk(fd, 1'b1);
        $fclose(fd);
        $display("wrote hud_stop.ppm  (TIME 07 59 / CAR STOP): A car=%0d time=%0d adj=%0d, B car=%0d time=%0d adj=%0d",
                 a_car, a_time, a_adj, b_car, b_time, b_adj);
        check_paint;

        if (errors == 0) $display("TB_HUD_DUMP PASS");
        else             $display("TB_HUD_DUMP FAIL (%0d)", errors);
        $finish;
    end
endmodule

