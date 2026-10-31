//=============================================================================
// wall_zoom_calc.v -- per-window uniform zoom factors, recomputed per frame
//
// The picture source is a 192x144 thumbnail (96x72 based Q16 step, see the
// comment history below) -- except for a FRAMELESS window (record bit 58,
// album mode), which shows the 640x480 full-resolution copy, so its step is
// 640/480 based and its content area is the whole 1280x480 world.
//
// A window's content area is (w-4) x (h-16) for a decorated window, which is
// usually NOT 4:3, so scaling each axis independently stretched the picture.
// The operator asked for a true proportional zoom, so this module picks ONE
// step for both axes:
//
//     sx = (SRC_W<<16)/cw     sy = (SRC_H<<16)/chh
//     step = max(sx, sy)                  <- the tighter axis wins
//     dw = (SRC_W<<16)/step   dh = (SRC_H<<16)/step
//
// wall_scene then draws a dw x dh picture centred in the content area and
// leaves black bars on the spare axis.  At the default 300x210 window that is
// step 24322, dw 258, dh 194.
//
// C3: at the album geometry (frameless, 1280x480 content, 640x480 source)
// sx = 41943040/1280 = 32768, sy = 31457280/480 = 65536, so step = 65536,
// dw = 640, dh = 480 and the photograph lands centred across the seam at
// exactly one source pixel per screen pixel.
//
// Five divisions per window, ~26 clocks each, once per frame: ~520 clocks out
// of a 25 MHz 16.7 ms frame, using a single bit-serial divider.  The numerator
// is 26 bits because 640<<16 does not fit in 24.
//=============================================================================
`timescale 1ns/1ps

module wall_zoom_calc (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,        // 1-cycle pulse, normally sof
    input  wire [255:0] tbl,          // four 64-bit window records
    output wire [71:0]  zstep,        // 4 x Q16 step (source-size based)
    output wire [47:0]  zdw,          // 4 x drawn width  in pixels
    output wire [47:0]  zdh           // 4 x drawn height in pixels
);
    localparam [25:0] NUM_X_TH  = 26'd6291456;    //  96 << 16
    localparam [25:0] NUM_Y_TH  = 26'd4718592;    //  72 << 16
    localparam [25:0] NUM_X_HI  = 26'd41943040;   // 640 << 16
    localparam [25:0] NUM_Y_HI  = 26'd31457280;   // 480 << 16

    localparam [11:0] CW_HI = 12'd1280;
    localparam [11:0] CH_HI = 12'd480;

    // ------------------------------------------------------------- state ---
    reg [1:0]  idx;        // window 0..3
    // Combinationally, NOT a registered copy: a registered wi made every
    // window use the previous window's size, so zooming window 0 changed
    // the picture in window 1 while its border stayed put.
    wire [1:0] wi = idx;
    reg [2:0]  ph;         // 0 = sx, 1 = sy, 2 = step, 3 = dw, 4 = dh
    reg [4:0]  k;          // 0 = load, 1..26 = one quotient bit
    reg        busy;
    reg [25:0] num, rem;
    reg [17:0] den;
    reg [17:0] quo;
    reg        hi_q;       // the window being divided is frameless

    // ---------------------------------------------------------- table access --
    reg  [9:0]  w_sel, h_sel;
    reg         fw_sel;
    always @(*) begin
        case (wi)
            2'd0:    begin w_sel = tbl[33:24];   h_sel = tbl[43:34];   fw_sel = tbl[58];  end
            2'd1:    begin w_sel = tbl[97:88];   h_sel = tbl[107:98];  fw_sel = tbl[122]; end
            2'd2:    begin w_sel = tbl[161:152]; h_sel = tbl[171:162]; fw_sel = tbl[186]; end
            default: begin w_sel = tbl[225:216]; h_sel = tbl[235:226]; fw_sel = tbl[250]; end
        endcase
    end

    wire [11:0] cw  = fw_sel ? CW_HI :
                      ((w_sel < 10'd12) ? 12'd8 : ({2'b00, w_sel} - 12'd4));
    wire [11:0] chh = fw_sel ? CH_HI :
                      ((h_sel < 10'd24) ? 12'd8 : ({2'b00, h_sel} - 12'd16));

    reg [17:0] q0, q1, step_q;
    reg [11:0] dw_q;

    reg [17:0] st0, st1, st2, st3;
    reg [11:0] dw0, dw1, dw2, dw3;
    reg [11:0] dh0, dh1, dh2, dh3;

    wire [25:0] rem_sh = {rem[24:0], num[25]};
    wire        ge     = (rem_sh >= {8'd0, den});
    wire [17:0] quo_n  = {quo[16:0], ge};
    wire [17:0] step_sel = (q1 > q0) ? q1 : q0;

    // numerator / divisor for the current phase
    reg [25:0] num_nx;
    reg [17:0] den_nx;
    always @(*) begin
        case (ph)
            3'd0:    begin num_nx = hi_q ? NUM_X_HI : NUM_X_TH;
                           den_nx = {6'd0, cw};  end                    // sx
            3'd1:    begin num_nx = hi_q ? NUM_Y_HI : NUM_Y_TH;
                           den_nx = {6'd0, chh}; end                    // sy
            3'd3:    begin num_nx = hi_q ? NUM_X_HI : NUM_X_TH;
                           den_nx = step_q;      end                    // dw
            default: begin num_nx = hi_q ? NUM_Y_HI : NUM_Y_TH;
                           den_nx = step_q;      end                    // dh
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            // hi_q is reset in its own block below (one driver per net)
            idx <= 2'd0; ph <= 3'd0; k <= 5'd0; busy <= 1'b0;
            num <= 26'd0; den <= 18'd0; rem <= 26'd0; quo <= 18'd0;
            q0 <= 18'd0; q1 <= 18'd0; step_q <= 18'd0; dw_q <= 12'd0;
            st0 <= 18'd0; st1 <= 18'd0; st2 <= 18'd0; st3 <= 18'd0;
            dw0 <= 12'd0; dw1 <= 12'd0; dw2 <= 12'd0; dw3 <= 12'd0;
            dh0 <= 12'd0; dh1 <= 12'd0; dh2 <= 12'd0; dh3 <= 12'd0;
        end else if (!busy) begin
            if (start) begin
                busy <= 1'b1;
                idx  <= 2'd0;
                ph   <= 3'd0;
                k    <= 5'd0;
            end
        end else if (ph == 3'd2) begin
            // step = max(sx, sy): no division needed
            step_q <= step_sel;
            ph     <= 3'd3;
            k      <= 5'd0;
        end else if (k == 5'd0) begin
            num <= num_nx;
            den <= den_nx;
            rem <= 26'd0;
            quo <= 18'd0;
            k   <= 5'd1;
        end else begin
            rem <= ge ? (rem_sh - {8'd0, den}) : rem_sh;
            quo <= quo_n;
            num <= {num[24:0], 1'b0};

            if (k == 5'd26) begin
                k <= 5'd0;
                case (ph)
                    3'd0: begin q0 <= quo_n;  ph <= 3'd1; end
                    3'd1: begin q1 <= quo_n;  ph <= 3'd2; end
                    3'd3: begin dw_q <= quo_n[11:0]; ph <= 3'd4; end
                    default: begin
                        ph <= 3'd0;
                        case (idx)
                            2'd0: begin st0 <= step_q; dw0 <= dw_q; dh0 <= quo_n[11:0]; end
                            2'd1: begin st1 <= step_q; dw1 <= dw_q; dh1 <= quo_n[11:0]; end
                            2'd2: begin st2 <= step_q; dw2 <= dw_q; dh2 <= quo_n[11:0]; end
                            default: begin st3 <= step_q; dw3 <= dw_q; dh3 <= quo_n[11:0]; end
                        endcase
                        if (idx == 2'd3) busy <= 1'b0;
                        else             idx  <= idx + 2'd1;
                    end
                endcase
            end else begin
                k <= k + 5'd1;
            end
        end
    end

    // Latch "this window is frameless" when the window's own division run
    // starts (ph == 0, k == 0 happens once per window), so the numerator stays
    // stable while that run is in flight.
    always @(posedge clk) begin
        if (rst) hi_q <= 1'b0;
        else if (busy && (ph == 3'd0) && (k == 5'd0)) hi_q <= fw_sel;
    end

    assign zstep = {st3, st2, st1, st0};
    assign zdw   = {dw3, dw2, dw1, dw0};
    assign zdh   = {dh3, dh2, dh1, dh0};
endmodule
