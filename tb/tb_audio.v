//=============================================================================
// tb_audio.v -- the synth really produces 48 kHz audio and a scope trace
//
// checks:
//   1. the sample strobe is 48 kHz (within 0.1%) of the 25 MHz pixel clock
//   2. the samples are non-trivial (they swing, and both signs appear)
//   3. the waveform ring fills and holds varying values (the OSD scope)
//=============================================================================
`timescale 1ns/1ps

module tb_audio;
    reg clk = 0;
    always #20 clk = ~clk;         // 25 MHz

    reg rst = 1;
    wire        valid;
    wire [23:0] left, right;
    wire [7:0]  wav_base, wav_data, level;

    reg  [7:0]  wav_addr = 8'd0;

    wall_audio #(.CLK_HZ(25_000_000), .FS_HZ(48_000)) u_dut (
        .clk(clk), .rst(rst), .valid(valid),
        .left(left), .right(right),
        .wav_base(wav_base), .wav_addr(wav_addr), .wav_data(wav_data),
        .level(level)
    );

    integer errors = 0;
    integer clks = 0, strobes = 0;
    integer pos = 0, neg = 0;
    integer maxabs = 0, i, v;
    real    fs_hz;
    reg [7:0] first_byte;
    integer changed = 0;

    always @(posedge clk) begin
        clks = clks + 1;
        if (valid) begin
            strobes = strobes + 1;
            v = left;
            if (left[23]) neg = neg + 1; else pos = pos + 1;
            if (left[23]) begin
                if ((-$signed(left[23:8])) > maxabs) maxabs = -$signed(left[23:8]);
            end else begin
                if (left[23:8] > maxabs) maxabs = left[23:8];
            end
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;

        // ~110 ms of audio: 25 MHz * 0.11 s = 2.75e6 clocks, 5280 samples
        repeat (2_750_000) @(posedge clk);

        fs_hz = (strobes * 25000000.0) / clks;
        $display("clocks=%0d strobes=%0d -> fs=%0.1f Hz (want 48000)", clks, strobes, fs_hz);
        if (fs_hz < 47950.0 ||
            fs_hz > 48050.0) begin
            errors = errors + 1;
            $display("FAIL: sample rate");
        end

        $display("samples: pos=%0d neg=%0d maxabs=%0d", pos, neg, maxabs);
        if (pos < 100 || neg < 100) begin
            errors = errors + 1;
            $display("FAIL: audio is not swinging around zero");
        end
        if (maxabs < 500) begin
            errors = errors + 1;
            $display("FAIL: audio amplitude too low (%0d)", maxabs);
        end

        // the scope ring: read all 240 entries back and require variation
        first_byte = wav_data;
        for (i = 1; i < 240; i = i + 1) begin
            wav_addr = i[7:0];
            #1;
            if (wav_data !== first_byte) changed = changed + 1;
        end
        $display("wave ring: %0d of 240 entries differ from the first", changed);
        if (changed < 20) begin
            errors = errors + 1;
            $display("FAIL: waveform ring is flat");
        end

        if (errors == 0) $display("TB_AUDIO PASS");
        else             $display("TB_AUDIO FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
