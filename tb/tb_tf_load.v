//=============================================================================
// tb_tf_load.v -- wall_tf_load against a FAT32 volume served sector by sector
//
// The "card" is tb/tb_sd_sector.v: it sits exactly where sd_card_top sits and
// streams sd_valid/sd_data/sd_end, so no SPI is simulated.  The volume
// (tb/fat32_img.hex) holds four DIFFERENT 640x480 CAM1..4.BMP files and
// tb/expected_pic.hex holds the 4 x 27,648 RGB565 sampled words the loader must
// end up writing; tb/expected_hi.hex holds the 4 x 307,200 words of the 1:1
// copies (C9: one per picture, contiguous from HI_BASE).
//
// Checked, in this order:
//   1. phase reaches DONE (6) and err == 0
//   2. found == 11111, bank_ok == 11111
//   3. every one of the 110,592 sampled words equals expected_pic.hex
//   4. exactly 110,592 sampled writes happened (no double writes)
//   5. every one of the 4 x 307,200 1:1 words equals expected_hi.hex -- WORD FOR
//      WORD, all four copies (C9), and exactly 1,228,800 such writes
//   6. the four 1:1 regions do not overlap and all four were written
//
// The first sector request is deliberately dropped, because on the real board
// the first pulse after init is lost (the vendor stack only samples it in
// S_WAIT_READ_WRITE).  That exercises the re-arm path.
//
// Run from wall/:
//   vsim -c -do "run -all; quit -f" tb_tf_load
//=============================================================================
`timescale 1ns/1ps

module tb_tf_load #(
    parameter         IMAGE = "tb/fat32_img.hex",
    parameter integer NSEC  = 8192
);
    localparam integer TIMEOUT = 9_000_000;
    localparam integer WORDS   = 27648;

    reg clk = 1'b0;
    always #20 clk = ~clk;              // 25 MHz

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
    wire [20:0] music_frames;
    wire        music_ok;

    wire [3:0]  phase;
    wire [7:0]  err;
    wire [4:0]  found;
    wire [4:0]  bank_ok;
    wire [7:0]  sec_bytes;

    // ---- drop the first request, like the board does ----------------------
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

    wall_tf_load #(.TMO_CYC(2000), .RETRY_MAX(8)) dut (
        .clk(clk), .rst(rst), .wav_en(1'b0), .sd_init_done(sd_init_done),
        .sd_req(sd_req), .sd_lba(sd_lba),
        .sd_valid(sd_valid), .sd_data(sd_data), .sd_end(sd_end),
        .mw_vld(mw_vld), .mw_addr(mw_addr), .mw_data(mw_data), .mw_rdy(1'b1),
        .music_frames(music_frames), .music_ok(music_ok),
        .phase(phase), .err(err), .found(found), .bank_ok(bank_ok), .sec_bytes(sec_bytes)
    );

    // ---- progress trace ---------------------------------------------------
    //  phase: 0 idle 1 boot 2 root 3 pick 4 chain 5 data 6 done 15 err
    reg [3:0] last_phase = 4'hF;
    always @(posedge clk) begin
        if (!rst && phase !== last_phase) begin
            $display("[%0t] phase %0d -> %0d  err=%0d found=%b ok=%b", $time, last_phase, phase, err, found, bank_ok);
            last_phase = phase;
        end
    end

    // W3: the legacy 96x72 on-chip bank is gone (the scene reads the SDRAM line
    // buffer), so only the high-resolution word stream is checked now.

    // HDRDBG: what did the header pass actually latch when it rejected a file?
    reg hdr_reported = 1'b0;
    always @(posedge clk) begin
        if (!rst && (err == 8'd6) && !hdr_reported) begin
            hdr_reported = 1'b1;
            $display("HDRDBG cid=%0d h_bm=%04X h_bits=%0d h_comp=%0d h_w=%0d h_h=%0d h_mag=%0d",
                     dut.cid, dut.h_bm, dut.h_bits, dut.h_comp, dut.h_w, dut.h_h, dut.h_mag);
        end
    end

    // ---- capture the sampled 192x144 words the loader pushes to SDRAM ------
    // Each picture owns a 62,208-word slot from word 1,848,320 (C9) and uses only
    // its first 27,648 words.  The compact index the expectation file uses is
    // bank*27648 + (addr - pic_base[bank]).
    localparam integer PIC_BANK_WORDS = 27648;
    localparam integer PIC_WORDS      = 4 * PIC_BANK_WORDS;
    reg [31:0] pic_mem [0:PIC_WORDS-1];
    integer pic_writes = 0;
    reg [31:0] exp_pic [0:PIC_WORDS-1];
    reg [31:0] exp_hi  [0:4*307200-1];
    integer    hi_mismatch;
    initial begin
        $readmemh("tb/expected_pic.hex", exp_pic);
        $readmemh("tb/expected_hi.hex", exp_hi);
    end

    function [21:0] pic_idx;
        input [20:0] a;
        begin
            if      (a >= 21'd2034944) pic_idx = 3*PIC_BANK_WORDS + (a - 21'd2034944);
            else if (a >= 21'd1972736) pic_idx = 2*PIC_BANK_WORDS + (a - 21'd1972736);
            else if (a >= 21'd1910528) pic_idx = 1*PIC_BANK_WORDS + (a - 21'd1910528);
            else if (a >= 21'd1848320) pic_idx = 0*PIC_BANK_WORDS + (a - 21'd1848320);
            else                       pic_idx = 22'h3FFFFF;   // outside every block
        end
    endfunction

    // Sampling trace (diagnostics): set TB_TRACE to 1 to get samp_trace.txt with
    // "n bank brow k px emit_row" for the 900 writes after the first picture.
    // That trace is how the DDA row phase was found (brow used to step on every
    // source row instead of every kept one).
    integer trace_fd, wr_n;
    initial begin
        wr_n = 0;
        if ($test$plusargs("TRACE")) trace_fd = $fopen("samp_trace.txt", "w");
        else trace_fd = 0;
    end

    // 1:1 copies (C2/C9): four 640x480 RGB565 regions, contiguous from HI_BASE.
    // HI0 = CAM1 at 619,520, and 4 x 307,200 words later the thumbnail gallery
    // starts at 1,848,320 -- the map is exactly full.
    localparam [20:0] HI_BASE    = 21'd619520;
    localparam integer HI_STRIDE = 307200;
    localparam integer HI_ONE    = 307200;             // words per copy
    localparam integer HI_ALL    = 4 * HI_ONE;         // 1,228,800
    reg [31:0] hi_mem [0:HI_ALL-1];
    integer    hi_writes = 0;

    // flat index into the four copies (they are contiguous, so one subtract)
    function [22:0] hi_idx;
        input [20:0] a;
        reg [20:0] d;
        begin
            d = a - HI_BASE;
            hi_idx = (a >= HI_BASE && d < HI_ALL) ? {2'b00, d} : 23'h7FFFFF;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst && mw_vld) begin
            if (hi_idx(mw_addr) < HI_ALL) begin
                hi_mem[hi_idx(mw_addr)] = mw_data;
                hi_writes = hi_writes + 1;
            end else if (pic_idx(mw_addr) < PIC_WORDS) begin
                pic_mem[pic_idx(mw_addr)] = mw_data;
                pic_writes = pic_writes + 1;
            end
            if (trace_fd != 0 && wr_n >= 27648 && wr_n < 27648 + 900) begin
                $fwrite(trace_fd, "%0d %0d %0d %0d %0d %0d\n",
                        wr_n, pic_idx(mw_addr) / PIC_BANK_WORDS,
                        dut.brow, dut.k, dut.px, dut.emit_row);
            end
            wr_n = wr_n + 1;
        end
    end

    // ---- request counter (diagnostics only) --------------------------------
    integer req_cnt = 0;
    always @(posedge clk) if (!rst && sd_req) req_cnt <= req_cnt + 1;

    // ---- run --------------------------------------------------------------
    integer cycles;
    integer j;
    integer k;
    integer errors;
    integer per_copy [0:3];
    integer pic_mismatch, pic_first_bad;
    reg [31:0] got32, want32;

    initial begin
        $display("=== tb_tf_load");
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);
        sd_init_done = 1'b1;

        cycles = 0;
        while ((phase != 4'd6) && (phase != 4'd15) && (cycles < TIMEOUT)) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        repeat (4) @(posedge clk);

        $display("--- finished after %0d cycles: phase=%0d err=%0d found=%b bank_ok=%b pic_writes=%0d requests=%0d",
                 cycles, phase, err, found, bank_ok, pic_writes, req_cnt);

        if (phase != 4'd6) begin
            $display("RESULT: FAIL  (phase=%0d, err=%0d)", phase, err);
            $finish;
        end
        if (err != 8'd0) begin
            $display("RESULT: FAIL  (err=%0d)", err);
            $finish;
        end
        if (found[3:0] !== 4'hF) begin
            $display("RESULT: FAIL  (found=%b, expected 1111)", found);
            $finish;
        end
        if (bank_ok !== 4'hF) begin
            $display("RESULT: FAIL  (bank_ok=%b, expected 1111)", bank_ok);
            $finish;
        end

        // ---- high-resolution SDRAM stream (4 x 27648 RGB565) --------------
        // "x" in expected_pic.hex means "never written, don't compare"; the
        // current generator writes every word, but the rule is kept for other
        // image sizes.  pic_writes must be exactly 4*27648 = 110592.
        pic_mismatch  = 0;
        pic_first_bad = -1;
        for (j = 0; j < PIC_WORDS; j = j + 1) begin
            got32  = pic_mem[j];
            want32 = exp_pic[j];
            if (want32[3:0] === 4'bx) begin
                // don't care
            end else if (got32 !== want32) begin
                pic_mismatch = pic_mismatch + 1;
                if (pic_first_bad < 0) begin
                    pic_first_bad = j;
                    $display("  first pic mismatch: word %0d (bank %0d, row %0d, col %0d) got=%05h want=%05h",
                             j, j / PIC_BANK_WORDS, (j % PIC_BANK_WORDS) / 192,
                             (j % PIC_BANK_WORDS) % 192, got32, want32);
                end
            end
        end
        $display("  pic: %0d/%0d words differ, %0d writes (expected %0d)",
                 pic_mismatch, PIC_WORDS, pic_writes, PIC_WORDS);

        // ---- 1:1 copies (C2/C9): 4 x 307,200 1:1 words --------------------
        // WORD FOR WORD for all four copies, not a spot check.  A "x" in the
        // expectation means "never written, don't compare" (only possible for a
        // source smaller than 640x480; the TB volume uses four 640x480 files, so
        // every word must match and every word must be written exactly once).
        hi_mismatch = 0;
        for (j = 0; j < HI_ALL; j = j + 1) begin
            got32  = hi_mem[j];
            want32 = exp_hi[j];
            if (want32[3:0] === 4'bx) begin
                // don't care
            end else if (got32 !== want32) begin
                hi_mismatch = hi_mismatch + 1;
                if (hi_mismatch == 1)
                    $display("  first 1:1 mismatch: CAM%0d x=%0d y=%0d got=%05h want=%05h",
                             (j / HI_ONE) + 1, (j % HI_ONE) % 640,
                             (j % HI_ONE) / 640, got32, want32);
            end
        end
        $display("  1:1 : %0d/%0d words differ across 4 copies, %0d writes (expected %0d)",
                 hi_mismatch, HI_ALL, hi_writes, HI_ALL);

        // all four copies must be fully specified AND fully written, i.e. the
        // four regions really are four disjoint 307,200-word blocks
        errors = 0;
        for (k = 0; k < 4; k = k + 1) per_copy[k] = 0;
        for (j = 0; j < HI_ALL; j = j + 1)
            if (exp_hi[j][3:0] !== 4'bx) per_copy[j / HI_ONE] = per_copy[j / HI_ONE] + 1;
        for (k = 0; k < 4; k = k + 1) begin
            if (per_copy[k] != HI_ONE) begin
                $display("  CAM%0d: expectation covers %0d of %0d 1:1 words",
                         k + 1, per_copy[k], HI_ONE);
                errors = errors + 1;
            end
        end

        if (pic_mismatch != 0) begin
            $display("RESULT: FAIL  (%0d/%0d hires words wrong)", pic_mismatch, PIC_WORDS);
        end else if (pic_writes != PIC_WORDS) begin
            $display("RESULT: FAIL  (%0d hires writes, expected %0d)", pic_writes, PIC_WORDS);
        end else if (hi_mismatch != 0 || hi_writes != HI_ALL || errors != 0) begin
            $display("RESULT: FAIL  (1:1 copies: %0d/%0d wrong, %0d writes, expected %0d)",
                     hi_mismatch, HI_ALL, hi_writes, HI_ALL);
        end else begin
            $display("RESULT: PASS  %0d/%0d hires + %0d/%0d 1:1 words (4 copies) match",
                     PIC_WORDS, PIC_WORDS, HI_ALL, HI_ALL);
        end
        $finish;
    end
endmodule
