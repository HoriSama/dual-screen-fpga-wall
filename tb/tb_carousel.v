//=============================================================================
// tb_carousel.v -- wall_pic_line carousel (轮播) behaviour
//
// The point of this test is the case that row-reuse alone can NOT handle: the
// carousel advances to the next picture while the source row stays the same.
// `row_chg` sees no change, so without the invalidation path the line buffer
// would happily keep showing the OLD picture forever.  The DUT must instead
// refetch the same row from the new picture and swap it in.
//
// SDRAM model: word = f(address), so a fetch from the wrong picture base is
// visible in the data, not just in a counter.
//=============================================================================
`timescale 1ns/1ps
module tb_carousel;
    reg clk25 = 1'b0;
    always #20 clk25 = ~clk25;             // 25 MHz
    reg clk150 = 1'b0;
    always #3.333 clk150 = ~clk150;        // ~150 MHz

    reg rst25 = 1'b1, rst150 = 1'b1;

    reg  [1:0]  car_cyc   = 2'd0;
    reg         prime     = 1'b0;
    reg         line_tick = 1'b0;
    reg  [35:0] nxt_rows  = 36'd0;   // 4 x 9-bit (C3; was 32 bits, which left window 3 X)
    reg  [3:0]  nxt_valid = 4'd0;
    reg  [3:0]  nxt_hi    = 4'd0;    // C9: no album window here
    reg  [7:0]  nxt_idx   = 8'd0;
    reg  [39:0] nxt_c1    = {10'd191, 10'd191, 10'd191, 10'd191};

    reg  [2:0]  rd_win = 3'd0;       // {frameless, window}
    reg  [9:0]  rd_col = 10'd0;      // 0..639
    wire [15:0] rd_data;

    wire        rd_valid;
    wire [20:0] rd_addr;
    wire        rd_ready;
    reg         rvalid = 1'b0;
    reg  [31:0] rdata  = 32'd0;
    wire        busy;

    wall_pic_line u_dut (
        .clk25(clk25), .rst25(rst25), 
        .car_cyc(car_cyc), .prime(prime), .line_tick(line_tick),
        .nxt_rows(nxt_rows), .nxt_valid(nxt_valid), .nxt_hi(nxt_hi), .nxt_idx(nxt_idx), .nxt_c1(nxt_c1),
        .rd_win(rd_win), .rd_col(rd_col), .rd_data(rd_data),
        .clk150(clk150), .rst150(rst150),
        .rd_valid(rd_valid), .rd_addr(rd_addr), .rd_ready(rd_ready),
        .rvalid(rvalid), .rdata(rdata), .busy(busy), .late_cnt(), .late_msk()
    );

    // ---- address -> data model --------------------------------------------
    function [20:0] pic_base;
        input [1:0] p;
        begin
            case (p)
                2'd0: pic_base = 21'd1848320;
                2'd1: pic_base = 21'd1910528;
                2'd2: pic_base = 21'd1972736;
                default: pic_base = 21'd2034944;
            endcase
        end
    endfunction

    function [15:0] want;
        input [20:0] a;
        begin
            // ADD, not XOR: XOR with a copy of the low bits would cancel them
            // and make every column of a row look identical.
            want = a[15:0] + {a[20:16], a[10:0]};
        end
    endfunction

    // accept whenever the DUT asks, respond two clocks later (registered latency)
    assign rd_ready = rd_valid;
    reg [1:0] vpipe = 2'd0;
    reg [20:0] apipe = 21'd0;
    always @(posedge clk150) begin
        if (rst150) begin
            vpipe <= 2'd0; rvalid <= 1'b0; rdata <= 32'd0;
        end else begin
            vpipe <= {vpipe[0], (rd_valid && rd_ready)};
            apipe <= rd_addr;
            rvalid <= vpipe[1];
            rdata  <= {16'd0, want(apipe)};
        end
    end

    // ---- helpers -----------------------------------------------------------
    reg [15:0] got;
    task read_col(input [9:0] col, output [15:0] d);
        begin
            rd_win <= 3'd0; rd_col <= col;
            @(posedge clk25);
            #1;
            d = rd_data;
        end
    endtask

    integer errors = 0, k;
    integer nacc = 0;
    integer nwr = 0;
    always @(posedge clk150) if (u_dut.rvalid) begin
        if (nwr < 3) $display("    WR addr=%0d data=%04h", u_dut.lb_wr_addr, rdata);
        nwr = nwr + 1;
    end
    always @(posedge clk150) if (rd_valid && rd_ready) nacc = nacc + 1;
    reg [15:0] d;

    task check_row(input [1:0] pic, input [7:0] row, input [8:0] cols);
        begin
            for (k = 0; k < cols; k = k + 1) begin
                read_col(k[9:0], d);
                if (d !== want(pic_base(pic) + ({13'd0, row} * 21'd192) + k)) begin
                    if (errors < 6)
                        $display("  row fail: pic%0d row%0d col%0d got=%04h want=%04h",
                                 pic, row, k, d,
                                 want(pic_base(pic) + ({13'd0, row} * 21'd192) + k));
                    errors = errors + 1;
                end
            end
        end
    endtask

    // ---- sequence ----------------------------------------------------------
    initial begin
        $display("=== tb_carousel");
        repeat (8) @(posedge clk25);
        rst25  = 1'b0;
        rst150 = 1'b0;
        repeat (8) @(posedge clk25);

        // row 5, carousel phase 0 -> window 0 shows picture 0
        nxt_rows[8:0] = 9'd5;
        nxt_valid     = 4'b0001;
        @(posedge clk25); prime <= 1'b1;
        @(posedge clk25); prime <= 1'b0;
        repeat (4) @(posedge clk25);
        repeat (4000) @(posedge clk150);
        @(posedge clk25); line_tick <= 1'b1;
        @(posedge clk25); line_tick <= 1'b0;
        repeat (6) @(posedge clk25);
        $display("  debug: accepts=%0d rd_bank=%b filled=%b lb192=%04h lb0=%04h rd_col=%0d rd_data=%04h",
                 nacc, u_dut.rd_bank, u_dut.filled, u_dut.lb[768], u_dut.lb[192], u_dut.lb_rd_addr, u_dut.rd_data);
        check_row(2'd0, 8'd5, 9'd24);
        $display("  phase 0: window 0 reads picture 0 (row 5)");

        // ---- the interesting case: advance the carousel, SAME row ----------
        car_cyc = 2'd1;                       // window 0 must become picture 1
        repeat (4) @(posedge clk25);          // let the invalidation take effect
        @(posedge clk25); line_tick <= 1'b1;   // tick 1: forced refetch starts
        @(posedge clk25); line_tick <= 1'b0;
        repeat (6) @(posedge clk25);
        repeat (4000) @(posedge clk150);      // let the refetch finish
        @(posedge clk25); line_tick <= 1'b1;   // tick 2: swap to the new bank
        @(posedge clk25); line_tick <= 1'b0;
        repeat (6) @(posedge clk25);
        repeat (8) @(posedge clk25);
        check_row(2'd1, 8'd5, 9'd24);
        $display("  phase 1: window 0 reads picture 1 (same row 5)");

        // ---- and once more, phase 2 ---------------------------------------
        car_cyc = 2'd2;
        repeat (4) @(posedge clk25);
        @(posedge clk25); line_tick <= 1'b1;
        @(posedge clk25); line_tick <= 1'b0;
        repeat (6) @(posedge clk25);
        repeat (4000) @(posedge clk150);
        @(posedge clk25); line_tick <= 1'b1;
        @(posedge clk25); line_tick <= 1'b0;
        repeat (6) @(posedge clk25);
        repeat (8) @(posedge clk25);
        check_row(2'd2, 8'd5, 9'd24);
        $display("  phase 2: window 0 reads picture 2 (same row 5)");

        if (errors == 0) $display("TB_CAROUSEL PASS");
        else             $display("TB_CAROUSEL FAIL (%0d)", errors);
        $finish;
    end
endmodule
