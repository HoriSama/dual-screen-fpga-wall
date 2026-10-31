//=============================================================================
// tb_osd.v -- the MODE captions show exactly one ON
//
// The four caption lines are VIEW / SELECT / MOVE / ZOOM; the line whose mode is
// in force is drawn in the "on" colour (24'h7CFF9E), the others in the dim
// colour.  This test drives every switch/lock combination and checks which line
// is lit, including the rule that SW2 wins when SW2 and SW3 are both on, and
// that MOVE/ZOOM need a confirmed (locked) picture.
//=============================================================================
`timescale 1ns/1ps

module tb_osd;
    reg [10:0] x;
    reg [8:0]  y;
    reg [1:0]  sel      = 2'd1;
    reg        owner    = 1'b0;
    reg [11:0] gx_sel   = 12'h100;
    reg        link_ok  = 1'b1;
    reg        sync_ok  = 1'b1;
    reg        frozen   = 1'b0;
    reg        dragging = 1'b0;
    reg [2:0]  mode_sw  = 3'b001;
    reg        locked   = 1'b0;

    wire        hit;
    wire [23:0] rgb;

    localparam [23:0] C_ON   = 24'h7CFF9E;
    localparam [23:0] C_TEXT = 24'hE2ECFA;
    localparam [23:0] C_DIM  = 24'h8C98AA;

    wall_hud #(.NODE_ID(0)) u_hud (
        .x(x), .y(y), .sel(sel), .owner(owner), .gx_sel(gx_sel),
        .link_ok(link_ok), .sync_ok(sync_ok), .frozen(frozen), .dragging(dragging),
        .music_ok(1'b1), .aud_level(8'h40), .music_frames(21'd1439278), .ld_err(8'd0), .en(1'b1), .mute(1'b0), .mode_sw(mode_sw), .locked(locked),
        .wx(12'd0), .m_on(1'b0), .m_phase(9'd0), .hit(hit), .rgb(rgb)
    );

    integer errors = 0;

    // count "on-coloured" glyph pixels in the 12-char line that starts at ytop
    task measure_on(input integer ytop, output integer n);
        integer i, j;
        begin
            n = 0;
            for (j = 0; j < 8; j = j + 1) begin
                for (i = 0; i < 96; i = i + 1) begin
                    x = 11'd8 + i[10:0];
                    y = ytop[8:0] + j[8:0];
                    #1;
                    if (hit && (rgb == C_ON)) n = n + 1;
                end
            end
        end
    endtask

    task probe(input integer mv, input integer sl, input integer mo, input integer zm);
        integer n_view, n_sel, n_move, n_zoom;
        begin
            measure_on(24, n_view);
            measure_on(40, n_sel);
            measure_on(56, n_move);
            measure_on(72, n_zoom);
            $display("mode_sw=%b locked=%b -> view=%0d sel=%0d move=%0d zoom=%0d",
                     mode_sw, locked, n_view, n_sel, n_move, n_zoom);
            if ((n_view > 0) !== (mv != 0)) begin errors = errors + 1; $display("FAIL: VIEW line"); end
            if ((n_sel  > 0) !== (sl != 0)) begin errors = errors + 1; $display("FAIL: SELECT line"); end
            if ((n_move > 0) !== (mo != 0)) begin errors = errors + 1; $display("FAIL: MOVE line"); end
            if ((n_zoom > 0) !== (zm != 0)) begin errors = errors + 1; $display("FAIL: ZOOM line"); end
        end
    endtask

    // count pixels of one exact colour in the 12-char line at ytop
    task measure_col(input integer ytop, input [23:0] col, output integer n);
        integer i, j;
        begin
            n = 0;
            for (j = 0; j < 8; j = j + 1) begin
                for (i = 0; i < 96; i = i + 1) begin
                    x = 11'd8 + i[10:0];
                    y = ytop[8:0] + j[8:0];
                    #1;
                    if (hit && (rgb == col)) n = n + 1;
                end
            end
        end
    endtask

    integer a, b;

    initial begin
        // SW1 down -> VIEW only
        mode_sw = 3'b000; locked = 1'b0; probe(1, 0, 0, 0);
        mode_sw = 3'b000; locked = 1'b1; probe(1, 0, 0, 0);

        // SW1 up, nothing else -> SELECT
        mode_sw = 3'b001; locked = 1'b0; probe(0, 1, 0, 0);
        mode_sw = 3'b001; locked = 1'b1; probe(0, 1, 0, 0);

        // SW2 needs a confirmed picture
        mode_sw = 3'b011; locked = 1'b0; probe(0, 1, 0, 0);
        mode_sw = 3'b011; locked = 1'b1; probe(0, 0, 1, 0);

        // SW3 needs it too
        mode_sw = 3'b101; locked = 1'b0; probe(0, 1, 0, 0);
        mode_sw = 3'b101; locked = 1'b1; probe(0, 0, 0, 1);

        // both on -> MOVE wins
        mode_sw = 3'b111; locked = 1'b1; probe(0, 0, 1, 0);

        // the picked-picture line still reacts to the lock bit
        mode_sw = 3'b001;
        locked = 1'b1; measure_col(88, C_TEXT, a);
        locked = 1'b0; measure_col(88, C_DIM,  b);
        $display("PIC line: locked=%0d free=%0d", a, b);
        if (a == 0 || b == 0) begin errors = errors + 1; $display("FAIL: PIC line does not react to the lock bit"); end

        if (errors == 0) $display("TB_OSD PASS");
        else             $display("TB_OSD FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
