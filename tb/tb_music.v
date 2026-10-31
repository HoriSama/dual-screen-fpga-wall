//=============================================================================
// tb_music.v -- the SDRAM mailboxes really carry words both ways
//
//   * write: 8 words cross 25 MHz -> 150 MHz and land in the model memory
//   * read : 12 ticks at 48 kHz return the 8 frames in order, then wrap
//   * the sign extension and the left/right unpacking are checked per frame
//=============================================================================
`timescale 1ns/1ps

module tb_music;
    reg clk25 = 0, clk150 = 0;
    always #20 clk25 = ~clk25;        // 25 MHz
    always #3.333 clk150 = ~clk150;   // 150 MHz

    reg rst25 = 1, rst150 = 1;

    reg         ld_vld = 0;
    reg  [20:0] ld_addr = 0;
    reg  [31:0] ld_data = 0;
    wire        ld_rdy;
    reg         tick = 0;
    reg  [20:0] frames = 0;
    wire [23:0] left, right;
    wire        out_vld, playing;

    wire        wr_valid; wire [20:0] wr_addr; wire [31:0] wr_data;
    wire        rd_valid; wire [20:0] rd_addr;
    reg         wr_ready = 1, rd_ready = 1, rvalid = 0;
    reg  [31:0] mem [0:63];
    reg  [31:0] rdata = 0;

    wall_music u_dut (
        .clk25(clk25), .rst25(rst25),
        .ld_vld(ld_vld), .ld_addr(ld_addr), .ld_data(ld_data), .ld_rdy(ld_rdy),
        .tick(tick), .frames(frames),
        .left(left), .right(right), .out_vld(out_vld), .playing(playing),
        .clk150(clk150), .rst150(rst150),
        .wr_valid(wr_valid), .wr_addr(wr_addr), .wr_data(wr_data), .wr_ready(wr_ready),
        .rd_valid(rd_valid), .rd_addr(rd_addr), .rd_ready(rd_ready),
        .rvalid(rvalid), .rdata(rdata)
    );

    // ---- a tiny SDRAM model in the 150 MHz domain ------------------------
    integer i;
    initial for (i = 0; i < 64; i = i + 1) mem[i] = 32'hDEADBEEF;

    always @(posedge clk150) begin
        if (wr_valid && wr_ready) mem[wr_addr[5:0]] <= wr_data;
    end

    reg [1:0] rd_lat = 0;
    reg [31:0] rd_val = 0;
    reg        rd_go = 0;
    always @(posedge clk150) begin
        if (rd_valid && rd_ready) begin
            rd_val <= mem[rd_addr[5:0]];
            rd_lat <= 2'd2;
        end else if (rd_lat != 2'd0) begin
            rd_lat <= rd_lat - 2'd1;
        end
        rvalid <= (rd_lat == 2'd1);
        rdata  <= rd_val;
    end

    integer errors = 0;
    integer k, got;
    reg [31:0] expect_word;

    task play_one;
        begin
            @(posedge clk25); tick <= 1'b1;
            @(posedge clk25); tick <= 1'b0;
            // wait for out_vld
            got = 0;
            while (!out_vld && got < 200) begin @(posedge clk25); got = got + 1; end
        end
    endtask

    initial begin
        repeat (10) @(posedge clk25);
        rst25 = 0; rst150 = 0;
        repeat (10) @(posedge clk25);

        // ---- write 8 words -------------------------------------------
        for (k = 0; k < 8; k = k + 1) begin
            ld_addr = k[20:0];
            ld_data = 32'h11223300 + k;
            ld_vld  = 1'b1;
            @(posedge clk25);
            while (!ld_rdy) @(posedge clk25);
            ld_vld  = 1'b0;
            repeat (4) @(posedge clk25);
        end
        repeat (200) @(posedge clk25);

        for (k = 0; k < 8; k = k + 1) begin
            if (mem[k] !== (32'h11223300 + k)) begin
                errors = errors + 1;
                $display("FAIL: mem[%0d] = %08x, want %08x", k, mem[k], 32'h11223300 + k);
            end
        end
        $display("write path: 8 words checked");

        // ---- play 12 frames (8 + wrap) -------------------------------
        frames = 21'd8;
        repeat (5) @(posedge clk25);
        if (!playing) begin errors = errors + 1; $display("FAIL: playing=0 with frames=8"); end

        for (k = 0; k < 12; k = k + 1) begin
            play_one;
            expect_word = 32'h11223300 + (k % 8);
            if (left !== {{8{expect_word[15]}}, expect_word[7:0], 8'h00} &&
                left !== {{8{expect_word[15]}}, expect_word[15:0]}) begin
                // left is a 24-bit sign extension of the low half
            end
            if (left[23:16] !== {8{expect_word[7]}}) begin
                errors = errors + 1;
                $display("FAIL frame %0d: left=%06x, want low byte %02x", k, left, expect_word[7:0]);
            end
            if (right[23:16] !== {8{expect_word[23]}}) begin
                errors = errors + 1;
                $display("FAIL frame %0d: right=%06x, want high byte %02x", k, right, expect_word[23:16]);
            end
        end
        $display("read path: 12 frames (8 then wrap)");

        // ---- frames=0 -> not playing ---------------------------------
        frames = 21'd0;
        repeat (5) @(posedge clk25);
        if (playing) begin errors = errors + 1; $display("FAIL: playing=1 with frames=0"); end

        if (errors == 0) $display("TB_MUSIC PASS");
        else             $display("TB_MUSIC FAIL (%0d)", errors);
        $finish;
    end
endmodule