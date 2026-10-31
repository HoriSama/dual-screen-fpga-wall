//=============================================================================
// tb_wav.v -- the MUSIC.WAV pass really streams PCM into SDRAM
//
// The card image (tools/make_tb_wav.py) holds one 8.3 file, "MUSIC   WAV",
// with a canonical 48 kHz / 16-bit / stereo header and 1000 frames of a
// deterministic pattern.  The loader must:
//   * find it in the root directory after the (absent) pictures,
//   * accept the header,
//   * push exactly 1000 words to mw_*, each (right<<16)|left,
//   * assert music_ok with music_frames = 1000.
//=============================================================================
`timescale 1ns/1ps

module tb_wav;
    localparam integer NSEC = 19;
    localparam IMAGE = "tb/wav_img.hex";

    reg clk = 1'b0;
    always #20 clk = ~clk;

    reg rst = 1'b1;
    reg sd_init_done = 1'b0;

    wire        sd_req;
    wire [31:0] sd_lba;
    wire        sd_valid;
    wire [7:0]  sd_data;
    wire        sd_end;

    wire        mw_vld;
    wire [20:0] mw_addr;
    wire [31:0] mw_data;
    reg         mw_rdy = 1'b1;
    wire [20:0] music_frames;
    wire        music_ok;

    wire [3:0]  phase;
    wire [7:0]  err;
    wire [3:0]  found, bank_ok;
    wire [7:0]  sec_bytes;

    // the first request is always dropped, like the board does
    reg  drop_pending = 1'b1;
    wire card_req = sd_req & ~drop_pending;
    always @(posedge clk) begin
        if (rst) drop_pending <= 1'b1;
        else if (sd_req && drop_pending) drop_pending <= 1'b0;
    end

    tb_sd_sector #(.NSEC(NSEC), .IMAGE(IMAGE), .DELAY(4)) u_card (
        .clk(clk), .rst(rst), .req(card_req), .lba(sd_lba),
        .valid(sd_valid), .data(sd_data), .end_o(sd_end)
    );

    wall_tf_load #(.TMO_CYC(4000), .RETRY_MAX(8)) dut (
        .clk(clk), .rst(rst), .wav_en(1'b1), .sd_init_done(sd_init_done),
        .sd_req(sd_req), .sd_lba(sd_lba),
        .sd_valid(sd_valid), .sd_data(sd_data), .sd_end(sd_end),
        .mw_vld(mw_vld), .mw_addr(mw_addr), .mw_data(mw_data), .mw_rdy(mw_rdy),
        .music_frames(music_frames), .music_ok(music_ok),
        .phase(phase), .err(err), .found(found), .bank_ok(bank_ok),
        .sec_bytes(sec_bytes)
    );

    // ---- capture what the loader pushes to SDRAM ------------------------
    localparam integer MAXW = 4096;
    reg [31:0] got [0:MAXW-1];
    reg [31:0] exp_w [0:MAXW-1];
    integer widx = 0;
    always @(posedge clk) begin
        if (!rst && mw_vld && mw_rdy) begin
            if (mw_addr < MAXW) got[mw_addr] = mw_data;
            widx = widx + 1;
        end
    end

    // debug: what did the header pass see?
    always @(posedge clk) begin
        if (dut.st == 5'd16 && sd_end)
            $display("   [dbg] WAVH end: hdr_ok=%b wtmp=%0d words_left=%0d", dut.hdr_ok, dut.wtmp, dut.words_left);
        if (dut.st == 5'd17 && sd_end && music_frames < 21'd1200)
            $display("   [dbg] WAVD sector end: wav_lba=%0d words_left=%0d frames=%0d", dut.wav_lba, dut.words_left, music_frames);
    end

    integer i, errors;
    integer cycles;
    reg [31:0] want;

    initial begin
        for (i = 0; i < MAXW; i = i + 1) begin got[i] = 32'h0; exp_w[i] = 32'h0; end
        $readmemh("tb/expected_wav.hex", exp_w);

        $display("=== tb_wav");
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);
        sd_init_done = 1'b1;

        cycles = 0;
        while ((phase != 4'd6) && (phase != 4'd15) && (cycles < 200000)) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        repeat (8) @(posedge clk);

        $display("--- phase=%0d err=%0d found=%b music_ok=%b music_frames=%0d words=%0d cycles=%0d",
                 phase, err, found, music_ok, music_frames, widx, cycles);

        errors = 0;
        if (phase != 4'd6)    begin errors = errors + 1; $display("FAIL: phase=%0d", phase); end
        if (!music_ok)        begin errors = errors + 1; $display("FAIL: music_ok=0 (err=%0d)", err); end
        if (music_frames != 21'd1000) begin
            errors = errors + 1;
            $display("FAIL: music_frames=%0d, want 1000", music_frames);
        end
        if (widx != 1000) begin
            errors = errors + 1;
            $display("FAIL: %0d words pushed, want 1000", widx);
        end

        for (i = 0; i < 1000 && i < MAXW; i = i + 1) begin
            want = exp_w[i];
            if (got[i] !== want) begin
                errors = errors + 1;
                if (errors < 6) $display("FAIL: word %0d = %08x, want %08x", i, got[i], want);
            end
        end

        if (errors == 0) $display("TB_WAV PASS  (1000 frames, PCM byte-exact)");
        else             $display("TB_WAV FAIL (%0d)", errors);
        $finish;
    end
endmodule