//=============================================================================
// tb_link.v -- frame framing + CRC8 round trip, including a corrupted frame
//=============================================================================
`timescale 1ns/1ps

module tb_link;
    reg clk = 0;
    always #20 clk = ~clk;          // 25 MHz nibble clock (en = 1)

    reg         rst = 1;
    reg         start_tog = 0;
    reg  [7:0]  seq  = 8'h5A;
    reg  [4:0]  anim = 5'd3;
    reg  [1:0]  sel  = 2'd2;
    reg  [255:0] tbl;
    // the rest of the STATE payload (every TX input must be driven: an
    // unconnected input is 'z' here, which turns the CRC byte into x/z and
    // makes the receiver reject an otherwise perfect frame)
    reg         t_mok = 1'b1;
    reg  [2:0]  t_lvl = 3'd5;
    reg  [1:0]  car_cyc = 2'd3;
    reg  [2:0]  mode = 3'd4;
    reg  [7:0]  t_fade = 8'hAA;
    reg         t_car = 1'b1;
reg         t_adj = 1'b1;   // must be driven: an x here poisons the CRC
    reg  [4:0]  t_tlvl = 5'd11; // C5 transition level (byte 4 bits 6:2)
    reg         t_osd  = 1'b0;  // C6 UI visible  (byte 39 bit 2)
    reg         t_mute = 1'b1;  // C6 muted       (byte 39 bit 3)
    reg  [1:0]  t_bc_id = 2'd3;
    reg  [7:0]  t_bc_b  = 8'hA5;
    reg  [7:0]  t_bc_c  = 8'h3C;

    wire        tx_vld;
    wire [3:0]  tx_d;
    reg         corrupt = 0;
    reg         start_q = 0;
    integer     nibs = 0;

    // Corrupt one nibble INSIDE the frame (keep the 0xA5 sync intact) so the
    // receiver reaches its CRC check instead of just losing sync.
    always @(posedge clk) begin
        if (start_tog != start_q) nibs <= 0;
        else if (tx_vld)          nibs <= nibs + 1;
        start_q <= start_tog;
    end

    wire [3:0]  line = (corrupt && nibs > 4 && nibs < 8) ? (tx_d ^ 4'h1) : tx_d;

    wire        frame;
    wire [7:0]  f_type, f_len;
    wire [319:0] payload;
    wire [15:0] err_cnt, ok_cnt;

    integer errors = 0;

    wall_link_tx #(.FRAME_TYPE(8'h01), .KIND(0)) u_tx (
        .clk(clk), .rst(rst), .en(1'b1), .start_tog(start_tog),
        .seq(seq), .anim(anim), .sel(sel), .tbl(tbl),
        .t_mok(t_mok), .t_lvl(t_lvl), .car_cyc(car_cyc), .mode(mode),
        .t_fade(t_fade), .t_car(t_car), .t_adj(t_adj), .t_tlvl(t_tlvl), .t_osd(t_osd), .t_mute(t_mute), .t_marq(1'b0), .t_mp8(1'b0),
        .t_bc_id(t_bc_id), .t_bc_b(t_bc_b), .t_bc_c(t_bc_c), .ipay(280'd0),
        .p0(8'h00), .p1(8'h00), .p2(8'h00),
        .o_vld(tx_vld), .o_d(tx_d), .busy());

    wall_link_rx u_rx (
        .clk(clk), .rst(rst), .en(1'b1),
        .i_d(line), .i_vld(tx_vld),
        .frame(frame), .f_type(f_type), .f_len(f_len),
        .payload(payload), .err_cnt(err_cnt), .ok_cnt(ok_cnt));

    task send_frame;
        begin
            @(posedge clk);
            #1 start_tog = ~start_tog;
        end
    endtask

    task wait_frame(input integer max_ticks, output integer got);
        integer t;
        begin
            got = 0;
            for (t = 0; t < max_ticks; t = t + 1) begin
                @(posedge clk);
                if (frame) begin got = 1; t = max_ticks; end
            end
        end
    endtask

    integer got, i;

    initial begin
        tbl = 256'h00C733E94A0323A2008223E9540AA208004113492C02C158000803492C018018;
        #100 rst = 0;
        #100;

        // ---- frame 1: clean ------------------------------------------------
        send_frame;
        wait_frame(500, got);
        if (!got) begin
            $display("FAIL: no frame received");
            errors = errors + 1;
        end else begin
            if (payload[7:0] !== seq)                     begin $display("FAIL byte0 seq %02h", payload[7:0]); errors = errors + 1; end
            if (payload[15:8] !== {t_lvl, anim})          begin $display("FAIL byte1 {lvl,anim} %02h", payload[15:8]); errors = errors + 1; end
            if (payload[23:16] !== {car_cyc, t_mok, mode, sel})
                                                          begin $display("FAIL byte2 cyc/mok/mode/sel %02h", payload[23:16]); errors = errors + 1; end
            if (payload[31:24] !== t_fade)                begin $display("FAIL byte3 fade %02h", payload[31:24]); errors = errors + 1; end
            if (payload[39:32] !== {1'b0, t_tlvl, t_adj, t_car}) begin $display("FAIL byte4 tlvl/adj/car %02h", payload[39:32]); errors = errors + 1; end
            for (i = 0; i < 32; i = i + 1)
                if (payload[(5+i)*8 +: 8] !== tbl[i*8 +: 8]) begin
                    $display("FAIL tbl byte %0d: %02h != %02h", i,
                             payload[(5+i)*8 +: 8], tbl[i*8 +: 8]);
                    errors = errors + 1;
                end
            // round-robin brightness/contrast bytes (37..39)
            if (payload[37*8 +: 8] !== t_bc_b)           begin $display("FAIL byte37 brightness %02h", payload[37*8 +: 8]); errors = errors + 1; end
            if (payload[38*8 +: 8] !== t_bc_c)           begin $display("FAIL byte38 contrast %02h", payload[38*8 +: 8]); errors = errors + 1; end
            if (payload[39*8 +: 8] !== {4'b0, t_mute, t_osd, t_bc_id}) begin $display("FAIL byte39 mute/osd/id %02h", payload[39*8 +: 8]); errors = errors + 1; end
            if (f_type !== 8'h01 || f_len !== 8'd40) begin
                $display("FAIL type/len %02h/%0d", f_type, f_len);
                errors = errors + 1;
            end
        end
        $display("frame1: ok_cnt=%0d err_cnt=%0d", ok_cnt, err_cnt);

        // ---- frame 2: one nibble flipped -> CRC must reject ----------------
        corrupt = 1;
        send_frame;
        wait_frame(500, got);
        corrupt = 0;
        if (got) begin
            $display("FAIL: corrupted frame was accepted");
            errors = errors + 1;
        end
        if (err_cnt != 16'd1) begin
            $display("FAIL: err_cnt=%0d after a bad frame", err_cnt);
            errors = errors + 1;
        end
        $display("frame2: ok_cnt=%0d err_cnt=%0d", ok_cnt, err_cnt);

        // ---- frame 3: clean again, must resync -----------------------------
        tbl[63:0] = 64'h0000000000000000;      // also prove the payload changed
        send_frame;
        wait_frame(500, got);
        if (!got) begin
            $display("FAIL: no resync after error");
            errors = errors + 1;
        end else if (payload[5*8 +: 64] !== 64'h0) begin
            $display("FAIL: stale payload after resync");
            errors = errors + 1;
        end

        if (errors == 0) $display("TB_LINK PASS (ok=%0d err=%0d)", ok_cnt, err_cnt);
        else             $display("TB_LINK FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
