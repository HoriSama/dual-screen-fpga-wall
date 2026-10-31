//=============================================================================
// tb_img.v -- picture path end-to-end in simulation: scene over the line buffer
//
// The SDRAM model answers every read with rdata = its address (low 16 bits),
// so wall_pic_line fills each window's line buffer with a deterministic
// function of (window, row, column).  One window is set up, its source row for
// a chosen scanline is fetched, then a scanline is swept one pixel per clock
// (exactly the raster) while the scene's RGB is compared against the sample the
// buffer should hold.  This catches any off-by-one in the "column for x+1"
// latency trick and the 96 -> 192 (x2) source-column scaling.
//
//   vsim -c -do "run -all; quit -f" tb_img
//=============================================================================
`timescale 1ns/1ps

module tb_img;
    reg clk25 = 1'b0;
    always #20 clk25 = ~clk25;          // 25 MHz
    reg clk150 = 1'b0;
    always #3.333 clk150 = ~clk150;     // ~150 MHz

    reg rst25 = 1'b1, rst150 = 1'b1;

    // ---- line buffer + SDRAM model -----------------------------------------
    reg        prime     = 1'b0;
    reg        line_tick = 1'b0;
    reg  [35:0] nxt_rows  = 36'd0;
    reg  [3:0]  nxt_valid = 4'd0;
    reg  [3:0]  nxt_hi    = 4'd0;
    reg  [7:0]  nxt_idx   = 8'd0;   // C9: album page (0 for every thumbnail)
    reg  [39:0] nxt_c1 = {10'd191, 10'd191, 10'd191, 10'd191};  // C9-R3: thumbnails are 192 wide
    wire [2:0]  rd_win;
    wire [9:0]  rd_col;
    wire [15:0] rd_data;
    wire        rd_valid;
    wire [20:0] rd_addr;
    reg         rd_ready;
    reg         rvalid;
    reg  [31:0] rdata;

    wall_pic_line u_line (
        .clk25(clk25), .rst25(rst25),
        .car_cyc(2'd0), .prime(prime), .line_tick(line_tick),
        .nxt_rows(nxt_rows), .nxt_valid(nxt_valid), .nxt_hi(nxt_hi), .nxt_idx(nxt_idx),
        .nxt_c1(nxt_c1),
        .rd_win(rd_win), .rd_col(rd_col), .rd_data(rd_data),
        .clk150(clk150), .rst150(rst150),
        .rd_valid(rd_valid), .rd_addr(rd_addr), .rd_ready(rd_ready),
        .rvalid(rvalid), .rdata(rdata), .busy(), .late_cnt(), .late_msk()
    );

    reg [20:0] ap0, ap1;
    reg        v0, v1;
    always @(posedge clk150) begin
        if (rst150) begin ap0 <= 21'd0; ap1 <= 21'd0; v0 <= 1'b0; v1 <= 1'b0; end
        else        begin ap0 <= rd_addr; ap1 <= ap0; v0 <= rd_valid; v1 <= v0; end
    end
    always @(*) rd_ready = rd_valid;
    always @(*) rvalid   = v1;
    always @(*) rdata    = {11'd0, ap1};

    // ---- scene on top ------------------------------------------------------
    localparam [11:0] GX = 12'd10, GY = 12'd10;
    localparam [9:0]  WW = 10'd300, WH = 10'd210;

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

    wire [255:0] tbl = { rec(12'd0, 12'd1000, WW, WH, 4'd3, 2'd3, 1'b1, 3'd0, 4'd3),
                         rec(12'd0, 12'd1000, WW, WH, 4'd2, 2'd2, 1'b0, 3'd0, 4'd2),
                         rec(12'd0, 12'd1000, WW, WH, 4'd1, 2'd1, 1'b0, 3'd0, 4'd1),
                         rec(GX, GY, WW, WH, 4'd3, 2'd0, 1'b0, 3'd0, 4'd3) };

    reg [10:0] sx = 11'd0;
    reg [8:0]  sy = 9'd0;

    wire [1:0]  lb_win;
    wire [8:0]  lb_col;
    wire [23:0] rgb;

    wall_scene #(.NODE_X0(0), .HUD_EN(0), .DITHER_EN(0), .NODE_ID(0)) u_scene (
        .clk(clk25),
        .zstep({4{18'd24322}}), .zdw({4{12'd258}}), .zdh({4{12'd194}}),
        .osd_en(1'b1), .mute(1'b0), .mode_sw(3'b000), .music_ok(1'b1),
        .music_frames(21'd1439278), .aud_level(8'h80), .meter_en(1'b1),
        .show_music(1'b1), .ld_err(8'd0), .time_min(8'd0), .time_sec(8'd0), .car_auto(1'b0), .car_cyc(2'd0), .bc_tbl(64'h8080_8080_8080_8080), .adj_on(1'b0), .frame(1'b0), .wav_base(8'd0), .wav_addr(),
        .wav_data(8'd128),
        .x(sx), .y(sy), .de(1'b1), .tbl(tbl), .anim(5'd0), .sel(2'd0),
        .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0),
        .fade_gain(8'd255), .pic_rgb565(rd_data), .lb_rd_win(lb_win), .lb_rd_col(lb_col),
        .pic_valid(5'h1F), .tlevel(5'd16),
        .m_on(1'b0), .m_phase(9'd0), .blink(1'b0), .rgb(rgb)
    );
    assign rd_win = lb_win;
    assign rd_col = lb_col;

    // ---- prefetch row-mapping probe ---------------------------------------
    // Same table/zoom as the scene.  At content row 97 the source row must be
    // ~72 (192-row sampling); a "x + (x<<1)" (3x) slip would saturate it at
    // 143 and smear the bottom half of every window.
    reg  [8:0]  probe_y = 9'd0;
    wire [35:0] probe_rows;
    wire [3:0]  probe_valid;
    wall_pic_prefetch u_probe (
        .y_target(probe_y), .tbl(tbl),
        .zstep({4{18'd24322}}), .zdh({4{12'd194}}),
        .nxt_rows(probe_rows), .nxt_valid(probe_valid), .nxt_hi(), .nxt_idx(), .nxt_c1()
    );

    // ---- expected model ----------------------------------------------------
    localparam integer SY_LINE = 37;          // content-local row we scan
    integer cly = SY_LINE;
    function [15:0] want16;
        input [9:0] col;
        reg [20:0] a;
        begin
            // window 3 source row = (2*37 * 24322) >> 16 = 27
            a = 21'd2034944 + ({5'd0, 8'd27} << 7) + ({5'd0, 8'd27} << 6) + {12'd0, col};
            want16 = a[15:0];
        end
    endfunction
    // W3.5: the fade moved into the per-picture gain table (wall_picadj).  This
    // TB drives fade_gain = 255 and the neutral brightness/contrast table
    // (0x80/0x80), which is EXACTLY transparent -- gain = 256, offset = 0 -- so
    // the expected colour is the plain expanded RGB565, no rounding term.
    function [23:0] expand565;
        input [15:0] c;
        begin
            expand565 = {c[15:11], c[15:13], c[10:5], c[10:9], c[4:0], c[4:2]};
        end
    endfunction

    // ---- test sequence -----------------------------------------------------
    integer errors = 0, checked = 0, x, clx;
    reg [23:0] exp_rgb;
    // The scene presents the column for display pixel x, and the line buffer
    // returns it one clock later, so the RGB for a column comes from the
    // address presented on the PREVIOUS edge.  Comparing against that
    // registered address checks the data path (address -> BRAM -> RGB565->888)
    // exactly, without re-deriving the zoom coordinate in the testbench.
    //
    // W3 step 1: wall_scene registers its RGB output, so sampling moved one
    // clock later as well.  At the edge that publishes column x the buffer has
    // already presented x+1, which is why the expected column is TWO registers
    // deep (col_qq), not one: col_q at that instant is one column ahead.
    reg [9:0] col_q, col_qq;
    always @(posedge clk25) begin
        col_q  <= lb_col;
        col_qq <= col_q;
    end

    initial begin
        repeat (8) @(posedge clk25);
        rst25 = 1'b0;
        rst150 = 1'b0;
        repeat (8) @(posedge clk25);

        // fill window 3, source row 27 (the row the chosen scanline samples):
        // prime requests it into the non-read bank, then a line tick swaps it in
        nxt_rows[27 +: 9] = 9'd27;   // window 3 is the one being scanned
        nxt_valid = 4'b1000;
        @(posedge clk25);
        prime <= 1'b1;
        @(posedge clk25);
        prime <= 1'b0;
        repeat (1500) @(posedge clk150);     // let the burst drain
        nxt_valid = 4'b0000;
        @(posedge clk25);
        line_tick <= 1'b1;
        @(posedge clk25);
        line_tick <= 1'b0;
        repeat (4) @(posedge clk25);

        // ---- scanline through window 3's content area, one pixel per clock --
        sy  = GY + 9'd16 + SY_LINE;          // content-local row 37
        sx  = GX + 2;                        // prime: address for x0
        @(posedge clk25);
        for (x = GX + 3; x <= GX + 2 + 276; x = x + 1) begin
            sx = x[10:0];
            @(posedge clk25);                // RGB is registered one clock later
            #1;
            clx = x - GX - 2;
            // uniformly scaled 258x194 picture centred in 296x194 content area:
            // step 24322, x letterbox offset 19
            if ((clx >= 19) && (clx < 19 + 258) && (cly < 194)) begin
                exp_rgb = expand565(want16(col_qq));   // neutral table, fade 255
            end else begin
                exp_rgb = 24'h000000;
            end
            if (rgb !== exp_rgb) begin
                if (errors < 6)
                    $display("  x=%0d clx=%0d got %06X exp %06X (col_qq %0d)",
                             x, clx, rgb, exp_rgb, col_qq);
                errors = errors + 1;
            end
            // Mapping guard: two thirds across the drawn picture the source
            // column must be around 128, NOT already at the 191 clamp.  A
            // "x + (x<<1)" (3x instead of 2x) bug saturates here and stretches
            // the right third of every window.
            if (clx == 19 + 170) begin
                if (col_qq > 9'd160) begin
                    $display("  MAP FAIL: column %0d at clx=%0d (should be ~128, saturating)",
                             col_qq, clx);
                    errors = errors + 1;
                end else begin
                    $display("  map ok: column %0d at clx=%0d", col_qq, clx);
                end
            end
            checked = checked + 1;
        end

        $display("scanline: %0d pixels compared, %0d errors", checked, errors);

        // ---- prefetch row mapping at content row 97 ------------------------
        probe_y = GY + 16 + 97;
        #1;
        $display("  prefetch: row %0d at content row 97 (want ~71, 143 = 3x bug)",
                 probe_rows[8:0]);
        if (probe_rows[8:0] > 8'd100) begin
            $display("  MAP FAIL: source row saturating");
            errors = errors + 1;
        end

        if (errors == 0) $display("TB_IMG PASS");
        else             $display("TB_IMG FAIL (%0d)", errors);
        $finish;
    end
endmodule
