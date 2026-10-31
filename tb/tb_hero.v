//=============================================================================
// tb_hero.v -- render the whole 1280x480 wall to a PPM, for the README
//
// Two wall_scene instances stand in for the two boards (NODE_X0 = 0 and 640),
// exactly like tb_scene does for the seam comparison, but instead of comparing
// pixels this writes what the pair would put on the two screens:
//
//     +DUMP   -> world_1280x480.ppm   (what a viewer sees across the seam)
//
// The HUD is on for both halves (so "WALL A" / "WALL B" appear at the far left
// and right), the marquee is on with a mid-scroll phase, and the window table is
// the power-on default layout -- i.e. this is a render of the shipped default,
// not a staged screenshot.  It is a SIMULATION render: the real boards are
// photographed for the competition material.
//
//   vsim -c -do "run -all; quit -f" tb_hero +DUMP
//=============================================================================
`timescale 1ns/1ps

module tb_hero;
    localparam [255:0] TBL_DEFAULT =
        256'h00C733E94A0323A2008223E9540AA208004113492C02C158000803492C018018;

    reg clk = 1'b0;
    always #20 clk = ~clk;              // 25 MHz pixel clock

    reg  [10:0] xa, xb;
    reg  [8:0]  y;
    reg  [255:0] tbl;
    wire [23:0] rgb_a, rgb_b;

    // ---- node A: world x 0..639 -------------------------------------------
    wall_scene #(.NODE_X0(0), .HUD_EN(1), .NODE_ID(0)) u_a (
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}),
        .mode_sw(3'b000), .music_ok(1'b1), .music_frames(21'd1439278),
        .aud_level(8'hB4), .meter_en(1'b1), .show_music(1'b1), .ld_err(8'd0),
        .time_min(8'h12), .time_sec(8'h34), .car_auto(1'b1),
        .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_8080), .adj_on(1'b0),
        .frame(1'b0), .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .clk(clk), .x(xa), .y(y), .tbl(tbl), .anim(5'd0), .sel(2'd0),
        .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0),
        .m_on(1'b1), .m_phase(9'd96), .blink(1'b0),
        .fade_gain(8'd255), .pic_rgb565(16'hFFFF), .lb_rd_win(), .lb_rd_col(),
        .pic_valid(5'h00), .osd_en(1'b1), .mute(1'b0), .tlevel(5'd16),
        .rgb(rgb_a));

    // ---- node B: the right half of the same world -------------------------
    wall_scene #(.NODE_X0(640), .HUD_EN(1), .NODE_ID(1)) u_b (
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}),
        .mode_sw(3'b000), .music_ok(1'b1), .music_frames(21'd1439278),
        .aud_level(8'hB4), .meter_en(1'b1), .show_music(1'b1), .ld_err(8'd0),
        .time_min(8'h12), .time_sec(8'h34), .car_auto(1'b1),
        .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_8080), .adj_on(1'b0),
        .frame(1'b0), .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .clk(clk), .x(xb), .y(y), .tbl(tbl), .anim(5'd0), .sel(2'd0),
        .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0),
        .m_on(1'b1), .m_phase(9'd96), .blink(1'b0),
        .fade_gain(8'd255), .pic_rgb565(16'hFFFF), .lb_rd_win(), .lb_rd_col(),
        .pic_valid(5'h00), .osd_en(1'b1), .mute(1'b0), .tlevel(5'd16),
        .rgb(rgb_b));

    integer fd, wx, wy;
    reg [23:0] px;
    initial begin
        tbl = TBL_DEFAULT;
        xa = 11'd0; xb = 11'd0; y = 9'd0;
        @(posedge clk);
        if ($test$plusargs("DUMP") || $test$plusargs("dump")) begin
            fd = $fopen("world_1280x480.ppm", "wb");
            $fwrite(fd, "P6\n1280 480\n255\n");
            for (wy = 0; wy < 480; wy = wy + 1) begin
                for (wx = 0; wx < 1280; wx = wx + 1) begin
                    if (wx < 640) begin
                        xa = wx[10:0];
                        y  = wy[8:0];
                        @(posedge clk); #1;
                        px = rgb_a;
                    end else begin
                        xb = (wx - 640);
                        y  = wy[8:0];
                        @(posedge clk); #1;
                        px = rgb_b;
                    end
                    $fwrite(fd, "%c%c%c", px[23:16], px[15:8], px[7:0]);
                end
            end
            $fclose(fd);
            $display("wrote world_1280x480.ppm (both halves, default table, HUD+marquee on)");
        end else begin
            $display("tb_hero: pass +DUMP to write the PPM");
        end
        $finish;
    end
endmodule
