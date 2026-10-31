//=============================================================================
// wall_link.v -- 4-bit synchronous link: nibble framing + CRC8
//
// Wire format (one nibble per tick, low nibble of a byte first):
//
//   0xA 0x5 TYPE LEN payload[0..LEN-1] CRC8
//
// The TX nibbles out of a live payload mux (no frame buffer); the RX assembles
// into a 40-byte register bank and pulses `frame` on a good CRC.
//
// Both modules take an enable `en` so the same RTL can run either:
//   * node A: 25 MHz pixel clock with a 6.25 MHz nibble enable
//   * node B: the forwarded 6.25 MHz link clock with en = 1
//=============================================================================
`timescale 1ns/1ps

module wall_crc8 (
    input  wire [7:0] crc_in,
    input  wire [7:0] data,
    output wire [7:0] crc_out
);
    function [7:0] step;
        input [7:0] c;
        input [7:0] d;
        integer i;
        begin
            step = c ^ d;
            for (i = 0; i < 8; i = i + 1)
                step = step[7] ? ((step << 1) ^ 8'h07) : (step << 1);
        end
    endfunction
    assign crc_out = step(crc_in, data);
endmodule

//-----------------------------------------------------------------------------
// TX: KIND 0 = STATE (37 B: seq, anim, sel/cyc, fade, car, 4x8B table)
//     KIND 1 = SMALL (LEN bytes from p0/p1/p2)
//
// STATE payload layout (the receiver's copy FSM mirrors these indices):
//   byte 0      seq (frame counter, blink phase)
//   byte 1      {audio level[2:0], anim[4:0]}
//   byte 2      {car_cyc[1:0], music_ok, mode[2:0], sel[1:0]}
//   byte 3      fade gain[7:0]      -- so both halves dim on the SAME frame
//   byte 4      {1'b0, tlvl[4:0], t_adj, car_auto}
//                                  -- C5: tlvl is the album-mode transition
//                                     level (0 = black .. 16 = full) so the peer
//                                     dims in step with the master's fade
//   bytes 5..36 window table (32 x 8 bit, little endian)
//   byte 37     brightness[7:0]  \  round-robin: one picture per frame, the
//   byte 38     contrast[7:0]     > id in byte 39 says which one (4 frames =
//   byte 39     {4'b0, mute, osd, pic_id[1:0]}  -- C6: UI on/off + mute travel
//                                      with the same round-robin byte)
//-----------------------------------------------------------------------------
module wall_link_tx #(
    parameter [7:0] FRAME_TYPE = 8'h01,
    parameter integer KIND     = 0
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         en,           // one tick per nibble
    input  wire         start_tog,    // toggle = send one frame
    input  wire [7:0]   seq,
    input  wire [4:0]   anim,
    input  wire         t_mok,       // 'a card WAV is loaded', broadcast
    input  wire [2:0]   t_lvl,       // audio level (0..7), broadcast for the peer meter
    input  wire [1:0]   car_cyc,      // KIND 0: carousel phase, broadcast so the peer stays in step
    input  wire [7:0]   t_fade,       // KIND 0: carousel fade gain (255 = full)
    input  wire         t_car,        // KIND 0: carousel auto-advance flag
    input  wire         t_adj,        // KIND 0: master is in ADJUST mode (byte 4 bit 1)
    // C5: album-mode transition level, 0 = black .. 16 = full (byte 4 bits 6:2).
    // Broadcast so the peer dims in step with the master's fade-to-black instead
    // of cutting abruptly one frame later.
    input  wire [4:0]   t_tlvl,
    // C6: UI-visible and muted flags, broadcast so both halves hide the overlay
    // and mute together (either board's keys may toggle them).
    // C10: marquee switch + the top bit of its scroll phase (see wall_top).
    input  wire         t_marq,
    input  wire         t_mp8,
    input  wire         t_osd,
    input  wire         t_mute,
    // KIND 0, round-robin: one picture's brightness/contrast per frame (4 frames
    // cover all four pictures, ~67 ms of convergence on the peer)
    input  wire [1:0]   t_bc_id,
    input  wire [7:0]   t_bc_b,
    input  wire [7:0]   t_bc_c,
    input  wire [1:0]   sel,
    input  wire [2:0]   mode,        // {sw3, sw2, sw1} broadcast for the peer OSD
    input  wire [255:0] tbl,
    input  wire [7:0]   p0,
    input  wire [7:0]   p1,
    input  wire [7:0]   p2,
    input  wire [279:0] ipay,         // KIND 2: 35 payload bytes (image block)
    output reg          o_vld,
    output reg  [3:0]   o_d,
    output reg          busy
);
    localparam [7:0] LEN_CONST = (KIND == 0) ? 8'd40 : (KIND == 1) ? 8'd3 : 8'd35;

    reg        tog_q;
    reg        active;
    reg        busy_d = 1'b0;
    reg [5:0]  bi;
    reg        half;
    reg [7:0]  crc;

    // o_vld is a LEVEL, not a one-cycle pulse: the peer samples it on its own
    // forwarded-clock edge 80 ns later, where a 40 ns pulse would be missed.
    always @(posedge clk) begin
        if (en) busy_d <= active;
    end
    always @(*) o_vld = active | busy_d;

    // Payload byte mux.  The table index is masked to 0..31 so the variable
    // part-select can never address outside tbl[255:0] even in a dead branch.
    wire [5:0] pi = (bi >= 6'd8) ? (bi - 6'd8) : 6'd0;
    wire [7:0] pay;
    generate
        if (KIND == 0) begin : g_state_pay
            assign pay = (bi == 6'd3) ? seq :
                         (bi == 6'd4) ? {t_lvl, anim} :
                         (bi == 6'd5) ? {car_cyc, t_mok, mode, sel} :
                         (bi == 6'd6) ? t_fade :
                         (bi == 6'd7) ? {t_mp8, t_tlvl, t_adj, t_car} :
                         (bi == 6'd40) ? t_bc_b :
                         (bi == 6'd41) ? t_bc_c :
                         (bi == 6'd42) ? {3'b0, t_marq, t_mute, t_osd, t_bc_id} :
                         tbl[{pi[4:0], 3'b000} +: 8];
        end else if (KIND == 1) begin : g_small_pay
            assign pay = (bi == 6'd3) ? p0 :
                         (bi == 6'd4) ? p1 : p2;
        end else begin : g_img_pay
            // KIND 2: byte n of the image block.  The index is clamped so the
            // variable part-select can never leave ipay[279:0].
            wire [5:0] pj = (bi >= 6'd3) ? (bi - 6'd3) : 6'd0;
            wire [5:0] pc = (pj > 6'd34) ? 6'd34 : pj;
            assign pay = ipay[{pc, 3'b000} +: 8];
        end
    endgenerate

    wire [7:0] cur = (bi == 6'd0) ? 8'h5A :
                     (bi == 6'd1) ? FRAME_TYPE :
                     (bi == 6'd2) ? LEN_CONST :
                     (bi <= 6'd2 + LEN_CONST) ? pay : crc;

    wire [7:0] crc_step;
    wall_crc8 u_crc (.crc_in(crc), .data(cur), .crc_out(crc_step));

    wire last_byte = (bi == 6'd3 + LEN_CONST);

    always @(posedge clk) begin
        if (rst) begin
            tog_q  <= 1'b0;
            active <= 1'b0;
            bi     <= 6'd0;
            half   <= 1'b0;
            crc    <= 8'h00;
            o_d    <= 4'h0;
            busy   <= 1'b0;
        end else begin
            tog_q <= start_tog;
            busy  <= active;

            if (!active) begin
                if (start_tog != tog_q) begin
                    active <= 1'b1;
                    bi     <= 6'd0;
                    half   <= 1'b0;
                    crc    <= 8'h00;
                end
            end else if (en) begin
                o_d <= half ? cur[7:4] : cur[3:0];

                if (!half) begin
                    half <= 1'b1;
                    if (bi >= 6'd1 && bi <= 6'd2 + LEN_CONST) crc <= crc_step;
                end else begin
                    half <= 1'b0;
                    if (last_byte) begin
                        active <= 1'b0;
                        bi     <= 6'd0;
                    end else begin
                        bi <= bi + 6'd1;
                    end
                end
            end
        end
    end
endmodule

//-----------------------------------------------------------------------------
// RX: hunt 0xA5, assemble bytes, check CRC8
//-----------------------------------------------------------------------------
module wall_link_rx (
    input  wire         clk,
    input  wire         rst,
    input  wire         en,
    input  wire [3:0]   i_d,
    input  wire         i_vld,
    output reg          frame,        // 1-cycle pulse, payload valid
    output reg  [7:0]   f_type,
    output reg  [7:0]   f_len,
    output reg  [319:0] payload,
    output reg  [15:0]  err_cnt,
    output reg  [15:0]  ok_cnt
);
    localparam [1:0] S_HUNT = 2'd0, S_BYTE = 2'd1;

    reg [1:0]  st;
    reg [3:0]  prev;
    reg [5:0]  bi;
    reg        half;
    reg [3:0]  lo;
    reg [7:0]  crc;
    reg [7:0]  len;
    reg [7:0]  typ;

    wire [7:0] byte_v = {i_d, lo};   // low nibble arrived first
    wire [7:0] crc_step;
    wall_crc8 u_crc (.crc_in(crc), .data(byte_v), .crc_out(crc_step));

    always @(posedge clk) begin
        if (rst) begin
            st      <= S_HUNT;
            prev    <= 4'h0;
            bi      <= 6'd0;
            half    <= 1'b0;
            lo      <= 8'h00;
            crc     <= 8'h00;
            len     <= 8'h00;
            typ     <= 8'h00;
            frame   <= 1'b0;
            f_type  <= 8'h00;
            f_len   <= 8'h00;
            payload <= 320'd0;
            err_cnt <= 16'd0;
            ok_cnt  <= 16'd0;
        end else begin
            frame <= 1'b0;

            if (en && i_vld) begin
                if (st == S_HUNT) begin
                    if (prev == 4'hA && i_d == 4'h5) begin
                        st   <= S_BYTE;
                        bi   <= 6'd0;
                        half <= 1'b0;
                        crc  <= 8'h00;
                    end else begin
                        prev <= i_d;
                    end
                end else if (!half) begin
                    lo   <= i_d;
                    half <= 1'b1;
                end else begin
                    half <= 1'b0;

                    if (bi == 6'd0) begin
                        typ <= byte_v;
                        crc <= crc_step;
                        bi  <= 6'd1;
                    end else if (bi == 6'd1) begin
                        len <= byte_v;
                        crc <= crc_step;
                        bi  <= 6'd2;
                        if (byte_v > 8'd40) begin
                            st   <= S_HUNT;
                            prev <= 4'hF;
                            if (err_cnt != 16'hFFFF) err_cnt <= err_cnt + 16'd1;
                        end
                    end else if (bi <= 6'd1 + len) begin
                        payload[(bi - 6'd2)*8 +: 8] <= byte_v;
                        crc <= crc_step;
                        bi  <= bi + 6'd1;
                    end else begin
                        // CRC byte
                        if (byte_v == crc) begin
                            frame  <= 1'b1;
                            f_type <= typ;
                            f_len  <= len;
                            if (ok_cnt != 16'hFFFF) ok_cnt <= ok_cnt + 16'd1;
                        end else begin
                            if (err_cnt != 16'hFFFF) err_cnt <= err_cnt + 16'd1;
                        end
                        st <= S_HUNT;
                        // The header match leaves prev = 0xA, and the next nibble
                        // on the wire after a frame is the transmitter's stale
                        // last nibble.  If that is 0x5 the hunt would pair the two
                        // and start a false frame that eats the next header (one
                        // lost frame whenever the CRC's high nibble is 5, i.e.
                        // ~6% of frames).  Park prev on a value that cannot start
                        // a header instead.
                        prev <= 4'hF;
                    end
                end
            end
        end
    end
endmodule
