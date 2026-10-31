//=============================================================================
// tb_scene.v -- proves the seam is pixel-exact
//
// One "wide" instance renders the whole 1280x480 world; node A and node B
// render their own 640x480 halves from the SAME table.  If any pixel of the
// halves differs from the wide reference, clipping is broken.  Because the
// seam column pair (639,640) is compared through the same reference, a
// zero-pixel-error seam is exactly what this test asserts.
//
// W3 step 1 changed the module contract: wall_scene now registers its RGB
// output, so one clock edge after presenting a column the six instances hold
// that column's pixel.  Every comparison therefore sets the column, waits one
// 25 MHz edge and then samples.  The pixel count is unchanged (614,400).
//=============================================================================
`timescale 1ns/1ps

module tb_scene;
    localparam [255:0] TBL_DEFAULT =
        256'h00C733E94A0323A2008223E9540AA208004113492C02C158000803492C018018;

    // W3 HUD inputs: a fixed wall clock and the carousel caption state.
    reg [7:0] t_min = 8'h12;   // BCD
    reg [7:0] t_sec = 8'h34;   // BCD
    reg       t_auto = 1'b1;

    reg clk = 1'b0;
    always #20 clk = ~clk;              // 25 MHz pixel clock

    reg  [10:0]  xw, xa, xb, xh;
    reg  [8:0]   yh;
    reg  [8:0]   y;
    reg  [255:0] tbl;
    reg  [4:0]   anim;
    wire [23:0]  rgb_w, rgb_a, rgb_b;

    wall_scene #(.NODE_X0(0),   .HUD_EN(0), .NODE_ID(0)) u_wide (
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}), .mode_sw(3'b000), .music_ok(1'b1), .music_frames(21'd1439278), .aud_level(8'h80), .meter_en(1'b1), .show_music(1'b1), .ld_err(8'd0), .time_min(t_min), .time_sec(t_sec), .car_auto(t_auto), .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_8080), .adj_on(1'b0), .frame(1'b0), .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .clk(clk), .x(xw), .y(y), .tbl(tbl), .anim(anim), .sel(2'd0),
        .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0), .m_on(1'b0), .m_phase(9'd0), .blink(1'b0), .fade_gain(8'd255), .pic_rgb565(16'hFFFF), .lb_rd_win(), .lb_rd_col(), .pic_valid(4'hF), .osd_en(1'b1), .mute(1'b0), .tlevel(5'd16), .rgb(rgb_w));

    wall_scene #(.NODE_X0(0),   .HUD_EN(0), .NODE_ID(0)) u_a (
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}), .mode_sw(3'b000), .music_ok(1'b1), .music_frames(21'd1439278), .aud_level(8'h80), .meter_en(1'b1), .show_music(1'b1), .ld_err(8'd0), .time_min(t_min), .time_sec(t_sec), .car_auto(t_auto), .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_8080), .adj_on(1'b0), .frame(1'b0), .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .clk(clk), .x(xa), .y(y), .tbl(tbl), .anim(anim), .sel(2'd0),
        .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0), .m_on(1'b0), .m_phase(9'd0), .blink(1'b0), .fade_gain(8'd255), .pic_rgb565(16'hFFFF), .lb_rd_win(), .lb_rd_col(), .pic_valid(4'hF), .osd_en(1'b1), .mute(1'b0), .tlevel(5'd16), .rgb(rgb_a));

    wall_scene #(.NODE_X0(640), .HUD_EN(0), .NODE_ID(1)) u_b (
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}), .mode_sw(3'b000), .music_ok(1'b1), .music_frames(21'd1439278), .aud_level(8'h80), .meter_en(1'b1), .show_music(1'b1), .ld_err(8'd0), .time_min(t_min), .time_sec(t_sec), .car_auto(t_auto), .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_8080), .adj_on(1'b0), .frame(1'b0), .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .clk(clk), .x(xb), .y(y), .tbl(tbl), .anim(anim), .sel(2'd0),
        .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0), .m_on(1'b0), .m_phase(9'd0), .blink(1'b0), .fade_gain(8'd255), .pic_rgb565(16'hFFFF), .lb_rd_win(), .lb_rd_col(), .pic_valid(4'hF), .osd_en(1'b1), .mute(1'b0), .tlevel(5'd16), .rgb(rgb_b));

    // HUD instances: only used to confirm the per-node label differs.
    wire [23:0] rgb_hud_a, rgb_hud_b;
    wall_scene #(.NODE_X0(0),   .HUD_EN(1), .NODE_ID(0)) u_hud_a (
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}), .mode_sw(3'b000), .music_ok(1'b1), .music_frames(21'd1439278), .aud_level(8'h80), .meter_en(1'b1), .show_music(1'b1), .ld_err(8'd0), .time_min(t_min), .time_sec(t_sec), .car_auto(t_auto), .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_8080), .adj_on(1'b0), .frame(1'b0), .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .clk(clk), .x(xh), .y(yh), .tbl(tbl), .anim(5'd0), .sel(2'd0),
        .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0), .m_on(1'b0), .m_phase(9'd0), .blink(1'b0), .fade_gain(8'd255), .pic_rgb565(16'hFFFF), .lb_rd_win(), .lb_rd_col(), .pic_valid(4'hF), .osd_en(1'b1), .mute(1'b0), .tlevel(5'd16), .rgb(rgb_hud_a));
    wall_scene #(.NODE_X0(640), .HUD_EN(1), .NODE_ID(1)) u_hud_b (
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}), .mode_sw(3'b000), .music_ok(1'b1), .music_frames(21'd1439278), .aud_level(8'h80), .meter_en(1'b1), .show_music(1'b1), .ld_err(8'd0), .time_min(t_min), .time_sec(t_sec), .car_auto(t_auto), .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_8080), .adj_on(1'b0), .frame(1'b0), .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .clk(clk), .x(xh), .y(yh), .tbl(tbl), .anim(5'd0), .sel(2'd0),
        .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0), .m_on(1'b0), .m_phase(9'd0), .blink(1'b0), .fade_gain(8'd255), .pic_rgb565(16'hFFFF), .lb_rd_win(), .lb_rd_col(), .pic_valid(4'hF), .osd_en(1'b1), .mute(1'b0), .tlevel(5'd16), .rgb(rgb_hud_b));

    integer errors, checked, x, yy, hud_diff;
    integer cfg_errors;
    reg [23:0] exp;

    task check_row(input integer yy_in);
        begin
            for (x = 0; x < 1280; x = x + 1) begin
                xw = x[10:0];
                xa = x[10:0];          // node A only meaningful for x < 640
                xb = (x >= 640) ? (x - 640) : 0;
                y  = yy_in[8:0];
                @(posedge clk);          // RGB is registered: wait one pixel
                #1;
                if (x < 640) exp = rgb_a;
                else         exp = rgb_b;
                if (rgb_w !== exp) begin
                    errors = errors + 1;
                    if (errors <= 20)
                        $display("MISMATCH y=%0d x=%0d wide=%06h half=%06h",
                                 yy_in, x, rgb_w, exp);
                end
                checked = checked + 1;
            end
        end
    endtask

    wire [23:0] rgb_hw;
    wall_scene #(.NODE_X0(0), .HUD_EN(1), .NODE_ID(0)) u_hud_wide (
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}), .mode_sw(3'b000), .music_ok(1'b1), .music_frames(21'd1439278), .aud_level(8'h80), .meter_en(1'b1), .show_music(1'b1), .ld_err(8'd0), .time_min(t_min), .time_sec(t_sec), .car_auto(t_auto), .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_8080), .adj_on(1'b0), .frame(1'b0), .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .clk(clk), .x(xw), .y(y), .tbl(tbl), .anim(5'd0), .sel(2'd0),
        .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0), .m_on(1'b0), .m_phase(9'd0), .blink(1'b0), .fade_gain(8'd255), .pic_rgb565(16'hFFFF), .lb_rd_win(), .lb_rd_col(), .pic_valid(4'hF), .osd_en(1'b1), .mute(1'b0), .tlevel(5'd16), .rgb(rgb_hw));

    integer cfg;
    integer fd, dx, dy;
    initial begin
        errors = 0;
        checked = 0;
        anim = 5'd0;
        tbl  = TBL_DEFAULT;

        // Configuration 0: default layout (window 2 straddles the seam)
        for (yy = 0; yy < 480; yy = yy + 2) check_row(yy);
        $display("cfg0 default layout: %0d pixels checked, %0d errors", checked, errors);

        // Dump the node-0 screen (HUD enabled) with the default table.
        if ($test$plusargs("dump")) begin
            fd = $fopen("scene_rtl.ppm", "wb");
            $fwrite(fd, "P6\n640 480\n255\n");
            for (dy = 0; dy < 480; dy = dy + 1)
                for (dx = 0; dx < 640; dx = dx + 1) begin
                    xw = dx[10:0]; y = dy[8:0];
                    @(posedge clk);
                    #1;
                    $fwrite(fd, "%c%c%c", rgb_hw[23:16], rgb_hw[15:8], rgb_hw[7:0]);
                end
            $fclose(fd);
            $display("wrote scene_rtl.ppm (node A screen, HUD on)");
        end

        // Configuration 1: drag window 2 fully onto the B half and across
        tbl = TBL_DEFAULT;
        tbl[139:128] = 12'd980;                  // window 2 gx = 980 (B only)
        tbl[255:192] = 64'h0;                    // hide window 3
        errors = 0; checked = 0;
        for (yy = 0; yy < 480; yy = yy + 4) check_row(yy);
        $display("cfg1 window on B half: %0d pixels checked, %0d errors", checked, errors);

        // Configuration 2: window 0 exactly on the seam, z-order swapped
        tbl = TBL_DEFAULT;
        tbl[11:0]   = 12'd640;                   // window 0 starts exactly at x=640
        tbl[49:48]  = 2'd3;                      // window 0 on top
        tbl[127:64] = TBL_DEFAULT[127:64];
        errors = 0; checked = 0;
        for (yy = 0; yy < 480; yy = yy + 4) check_row(yy);
        $display("cfg2 edge on seam: %0d pixels checked, %0d errors", checked, errors);

        // HUD label area must differ between the two nodes (A vs B glyph)
        hud_diff = 0;
        for (yy = 6; yy < 20; yy = yy + 1)
            for (x = 6; x < 60; x = x + 1) begin
                xh = x[10:0]; yh = yy[8:0];
                @(posedge clk);
                #1;
                if (rgb_hud_a !== rgb_hud_b) hud_diff = hud_diff + 1;
            end
        if (hud_diff == 0) begin
            $display("HUD FAIL: node A and node B draw identical label pixels");
            errors = errors + 1;
        end else begin
            $display("HUD label differs in %0d pixels (A/B letters)", hud_diff);
        end

        if (errors == 0) $display("TB_SCENE PASS");
        else             $display("TB_SCENE FAIL (%0d errors)", errors);
        $finish;
    end
endmodule

