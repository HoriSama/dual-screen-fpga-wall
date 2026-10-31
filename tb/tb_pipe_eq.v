//=============================================================================
// tb_pipe_eq.v -- the scene's output pipeline must be pixel-identical
//
// W3 step 1 registers wall_scene's RGB output and compensates the one clock of
// latency by feeding the compositor x+1 on active pixels (wall_top).  This TB
// proves that the pair (register + x+1) reproduces the OLD combinational
// compositor bit for bit, i.e. that the picture does not slide by one column:
//
//   u_ref : the pre-W3 wiring -- x = column, x = 0 while blanking, RGB read
//           combinationally from the same clock (the module's rgb_c cone).
//   u_new : the W3 wiring -- x = column+1 while active, x = 0 while blanking,
//           RGB taken from the registered output (one clock later).
//
// Both are driven by a "perfect line buffer": the 16-bit word that arrives in
// a cycle is a function of the column the instance addressed on the PREVIOUS
// edge, which is exactly wall_pic_line's contract (registered read, one
// column ahead).  So the photo path is exercised too, not just the frames.
//
// Every active pixel of a set of scanlines is compared, for three window
// tables (overlapping windows, a window hanging off the right edge, and a
// window flush against the left edge, where the line-buffer priming edge
// lives).
//
//   vsim -c -do "run -all; quit -f" tb_pipe_eq
//=============================================================================
`timescale 1ns/1ps

module tb_pipe_eq;
    reg clk = 1'b0;
    always #20 clk = ~clk;              // 25 MHz pixel clock

    function [63:0] rec;
        input [11:0] gx, gy;
        input [9:0]  w, h;
        input [3:0]  src;
        input [1:0]  z;
        input        own;
        input [2:0]  fl;
        input [3:0]  wid;
        begin
            rec = {6'd0, wid, fl, own, z, src, h, w, gy, gx};
        end
    endfunction

    reg [255:0] tbl;
    reg [10:0]  col  = 11'd0;
    reg         de   = 1'b0;
    reg [8:0]   y    = 9'd0;

    // ---- new (pipelined) side ---------------------------------------------
    wire [1:0]  nw_win;
    wire [8:0]  nw_col;
    wire [23:0] rgb_new;

    // ---- reference (old combinational) side --------------------------------
    wire [1:0]  rf_win;
    wire [8:0]  rf_col;
    wire [23:0] rgb_ref;

    // perfect line buffer: data in a cycle = the word addressed one edge ago
    reg [8:0] q_new, q_ref;
    always @(posedge clk) begin
        q_new <= nw_col;
        q_ref <= rf_col;
    end
    wire [15:0] pic_new = {q_new[7:0], q_new[7:0]};
    wire [15:0] pic_ref = {q_ref[7:0], q_ref[7:0]};

    // Negative control: "+noadv" drops the x+1 compensation, which MUST make
    // this test fail.  Without that check a constant-pass test would look the
    // same as a correct one.
    reg no_adv = 1'b0;
    initial no_adv = $test$plusargs("noadv") ? 1'b1 : 1'b0;

    wire [10:0] x_new = de ? (col + (no_adv ? 11'd0 : 11'd1)) : 11'd0;   // wall_top's x_scene
    wire [10:0] x_ref = de ? col : 11'd0;             // pre-W3 x_scene

    wall_scene #(.NODE_X0(0), .HUD_EN(1), .NODE_ID(0)) u_new (
        .clk(clk), .x(x_new), .y(y), .de(de), .tbl(tbl),
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}),
        .mode_sw(3'b010), .music_ok(1'b1), .music_frames(21'd1439278),
        .aud_level(8'h40), .meter_en(1'b1), .show_music(1'b1), .ld_err(8'd0),
        .time_min(8'h12), .time_sec(8'h34), .car_auto(1'b1), .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_8080), .adj_on(1'b0), .frame(1'b0),
        .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .anim(5'd0), .sel(2'd1), .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0),
        .m_on(1'b0), .m_phase(9'd0), .blink(1'b1), .pic_rgb565(pic_new), .lb_rd_win(nw_win), .lb_rd_col(nw_col),
        .pic_valid(4'hF), .osd_en(1'b1), .mute(1'b0), .tlevel(5'd16), .fade_gain(8'd255), .rgb(rgb_new));

    wall_scene #(.NODE_X0(0), .HUD_EN(1), .NODE_ID(0)) u_ref (
        .clk(clk), .x(x_ref), .y(y), .de(de), .tbl(tbl),
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}),
        .mode_sw(3'b010), .music_ok(1'b1), .music_frames(21'd1439278),
        .aud_level(8'h40), .meter_en(1'b1), .show_music(1'b1), .ld_err(8'd0),
        .time_min(8'h12), .time_sec(8'h34), .car_auto(1'b1), .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_8080), .adj_on(1'b0), .frame(1'b0),
        .wav_base(8'd0), .wav_addr(), .wav_data(8'd128),
        .anim(5'd0), .sel(2'd1), .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0),
        .m_on(1'b0), .m_phase(9'd0), .blink(1'b1), .pic_rgb565(pic_ref), .lb_rd_win(rf_win), .lb_rd_col(rf_col),
        .pic_valid(4'hF), .osd_en(1'b1), .mute(1'b0), .tlevel(5'd16), .fade_gain(8'd255), .rgb(rgb_ref));

    // The reference must be the COMBINATIONAL result: the module has no port
    // for it any more, so read the internal cone directly (same file, same
    // expression).  rgb is the registered version by construction.
    wire [23:0] ref_c = u_ref.rgb_c;

    integer errors = 0, checked = 0, k, row, cfg;
    integer blank = 64;

    task run_cfg(input integer tag);
        begin
            for (row = 0; row < 480; row = row + 24) begin
                y = row[8:0];
                de = 1'b0; col = 11'd0;
                repeat (blank) @(posedge clk);      // hblank = addressing prime
                for (k = 0; k < 640; k = k + 1) begin
                    col = k[10:0];
                    de  = 1'b1;
                    // sample the values that were in flight before this edge:
                    // rgb_new is the registered pixel for this column, ref_c is
                    // the old combinational pixel for the same column.
                    @(posedge clk);
                    if (rgb_new !== ref_c) begin
                        if (errors < 10)
                            $display("  cfg%0d y=%0d x=%0d new=%06h ref=%06h",
                                     tag, row, k, rgb_new, ref_c);
                        errors = errors + 1;
                    end
                    checked = checked + 1;
                end
                de = 1'b0;
            end
        end
    endtask

    initial begin
        // cfg0: four windows, one hanging off the right edge, one on the left
        tbl = { rec(12'd0,   12'd380, 10'd220, 10'd160, 4'd0, 2'd3, 1'b1, 3'd0, 4'd3),
                rec(12'd480, 12'd80,  10'd416, 10'd300, 4'd2, 2'd2, 1'b0, 3'd0, 4'd2),
                rec(12'd200, 12'd300, 10'd300, 10'd210, 4'd1, 2'd1, 1'b1, 3'd1, 4'd1),
                rec(12'd40,  12'd60,  10'd300, 10'd210, 4'd3, 2'd0, 1'b0, 3'd0, 4'd0) };
        run_cfg(0);

        // cfg1: one window flush at the left edge (content starts at column 2),
        // plus one at the top-left corner where the HUD sits
        tbl = { 64'd0,
                rec(12'd0, 12'd0, 10'd200, 10'd160, 4'd3, 2'd1, 1'b0, 3'd0, 4'd1),
                64'd0,
                rec(12'd0, 12'd120, 10'd260, 10'd200, 4'd1, 2'd0, 1'b1, 3'd0, 4'd0) };
        run_cfg(1);

        // cfg2: all four stacked on the same area -- stress the z pick
        tbl = { rec(12'd120, 12'd150, 10'd300, 10'd200, 4'd2, 2'd3, 1'b1, 3'd0, 4'd3),
                rec(12'd130, 12'd140, 10'd300, 10'd200, 4'd1, 2'd2, 1'b0, 3'd0, 4'd2),
                rec(12'd140, 12'd130, 10'd300, 10'd200, 4'd3, 2'd1, 1'b1, 3'd0, 4'd1),
                rec(12'd150, 12'd120, 10'd300, 10'd200, 4'd0, 2'd0, 1'b0, 3'd0, 4'd0) };
        run_cfg(2);

        $display("pipeline vs combinational: %0d pixels compared, %0d mismatches",
                 checked, errors);
        if (checked != 3 * 20 * 640) begin
            $display("CHECK COUNT FAIL: expected %0d", 3 * 20 * 640);
            errors = errors + 1;
        end
        if (errors == 0) $display("TB_PIPE_EQ PASS");
        else             $display("TB_PIPE_EQ FAIL (%0d)", errors);
        $finish;
    end
endmodule

