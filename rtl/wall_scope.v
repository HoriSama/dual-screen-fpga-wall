//=============================================================================
// wall_scope.v -- waveform ring for the on-screen audio scope
//
// The scope must follow whatever is actually playing, so it taps the muxed
// output (card music or the synth) instead of one particular source:
//
//   tick   : the 48 kHz sample strobe
//   sample : the 24-bit sample that was just sent to HDMI
//
// One point is stored every DEC samples, so 240 points span DEC*240/48000
// seconds (DEC=6 -> 30 ms), which is short enough that the trace visibly moves
// with the music instead of blurring into a band.
//=============================================================================
`timescale 1ns/1ps

module wall_scope (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,           // 1-cycle strobe at 48 kHz
    input  wire [23:0] sample,         // what the HDMI port is being fed
    output wire [7:0]  wav_base,       // oldest ring entry
    input  wire [7:0]  wav_addr,
    output wire [7:0]  wav_data,
    output wire [7:0]  level           // |sample| for anything else that wants it
);
    localparam integer WAV_LEN = 240;
    localparam integer DEC     = 6;    // store every 6th sample -> 30 ms window

    reg [7:0] ram [0:WAV_LEN-1];
    reg [7:0] wptr;
    reg [7:0] dec;
    reg [7:0] lvl;

    assign wav_data = ram[wav_addr];
    assign wav_base = wptr;
    assign level    = lvl;

    // |top byte of the sample|: the 16-bit data sits in [23:8], so bits 23:16
    // are the loudest part and give the meter its full range.
    wire [7:0] mag = sample[23] ? (~sample[23:16] + 8'd1) : sample[23:16];
    // peak with a slow decay: the bar shoots up on a hit and eases back, which
    // reads as "moving with the music" even for a soft pad
    reg [7:0] peak;

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            wptr <= 8'd0;
            dec  <= 8'd0;
            lvl  <= 8'd0;
            peak <= 8'd0;
            for (i = 0; i < WAV_LEN; i = i + 1) ram[i] <= 8'd128;
        end else begin
            if (tick) begin
                if (mag >= peak) peak <= mag;
                else if (peak != 8'd0) peak <= peak - 8'd1;
                lvl <= peak;
                if (dec == DEC - 1) begin
                    dec <= 8'd0;
                    ram[wptr] <= mag;
                    wptr <= (wptr == WAV_LEN - 1) ? 8'd0 : (wptr + 8'd1);
                end else begin
                    dec <= dec + 8'd1;
                end
            end
        end
    end
endmodule