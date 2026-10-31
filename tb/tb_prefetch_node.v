//=============================================================================
// tb_prefetch_node.v -- C9-R2: each node only fetches the windows it can draw
//
// The picture line buffer fetches one 192-word burst per visible window per
// line.  Both nodes render the same window table, so before C9-R2 each one
// fetched rows for pictures it never draws (a window entirely on the other
// half of the wall), which is what pushed the 4-window case over the SDRAM
// read-port budget and made the last windows in scan order judder while a
// picture was moved up/down.
//
// `wall_pic_prefetch` now takes the node's slice of the world (NODE_X0/NODE_W)
// and reports `nxt_valid = 0` for a window that does not touch it.  This test
// pins the boundary arithmetic: a window that ENDS on the seam is A-only, one
// that STARTS on the seam is B-only, one that crosses is on both.
//
//   vsim -c -do "run -all; quit -f" tb_prefetch_node
//=============================================================================
`timescale 1ns/1ps

module tb_prefetch_node;
    reg clk = 1'b0;
    always #20 clk = ~clk;

    // ---- the table: four records -------------------------------------------
    // 64-bit record: {rsv[63:58], wid[57:54], flags[53:51], owner[50],
    //                 z[49:48], src[47:44], h[43:34], w[33:24], gy[23:12], gx[11:0]}
    function [63:0] rec;
        input [11:0] gx, gy;
        input [9:0]  w, h;
        input [3:0]  wid;
        begin
            rec = {6'd0, wid, 3'd0, 1'b0, 2'd1, 4'd0, h, w, gy, gx};
        end
    endfunction
    // A-only:  0 .. 299      (ends before the seam)
    // A-only:  340 .. 639    (ends exactly ON the seam -> still A's)
    // both:    600 .. 919    (crosses the seam)
    // B-only:  640 .. 939    (starts exactly ON the seam -> B's)
    wire [255:0] tbl = { rec(12'd640, 12'd40, 10'd300, 10'd200, 4'd3),
                         rec(12'd600, 12'd40, 10'd320, 10'd200, 4'd2),
                         rec(12'd340, 12'd40, 10'd300, 10'd200, 4'd1),
                         rec(12'd0,   12'd40, 10'd300, 10'd200, 4'd0) };

    wire [35:0] rows_a, rows_b;
    wire [3:0]  val_a, val_b;
    wire [7:0]  idx_a, idx_b;
    wire [39:0] c1_a, c1_b;

    wall_pic_prefetch #(.NODE_X0(0),   .NODE_W(640)) u_a (
        .y_target(9'd100), .tbl(tbl), .zstep({4{18'd24322}}), .zdh({4{12'd200}}),
        .nxt_rows(rows_a), .nxt_valid(val_a), .nxt_hi(), .nxt_idx(idx_a), .nxt_c1(c1_a));
    wall_pic_prefetch #(.NODE_X0(640), .NODE_W(640)) u_b (
        .y_target(9'd100), .tbl(tbl), .zstep({4{18'd24322}}), .zdh({4{12'd200}}),
        .nxt_rows(rows_b), .nxt_valid(val_b), .nxt_hi(), .nxt_idx(idx_b), .nxt_c1(c1_b));

    // ---- the frameless (album) record must be on BOTH nodes ----------------
    wire [255:0] alb_tbl = { rec(12'd0, 12'd0, 10'd0, 10'd0, 4'd3),
                             rec(12'd0, 12'd0, 10'd0, 10'd0, 4'd2),
                             rec(12'd0, 12'd0, 10'd0, 10'd0, 4'd1),
                             {3'b000, 2'd1, 1'b1, 4'd0, 3'd0, 1'b0, 2'd3, 4'd0,
                              10'd480, 10'd1023, 12'd0, 12'd0} };
    wire [3:0] alb_val_a, alb_val_b;
    wall_pic_prefetch #(.NODE_X0(0),   .NODE_W(640)) u_alb_a (
        .y_target(9'd100), .tbl(alb_tbl), .zstep({4{18'd65536}}), .zdh({4{12'd480}}),
        .nxt_rows(), .nxt_valid(alb_val_a), .nxt_hi(), .nxt_idx(), .nxt_c1());
    wall_pic_prefetch #(.NODE_X0(640), .NODE_W(640)) u_alb_b (
        .y_target(9'd100), .tbl(alb_tbl), .zstep({4{18'd65536}}), .zdh({4{12'd480}}),
        .nxt_rows(), .nxt_valid(alb_val_b), .nxt_hi(), .nxt_idx(), .nxt_c1());

    integer errors = 0;
    initial begin
        $display("=== tb_prefetch_node");
        repeat (4) @(posedge clk); #1;
        $display("  A half: valid=%b (want 0111)   B half: valid=%b (want 1100)",
                 val_a, val_b);
        if (val_a !== 4'b0111) begin
            $display("FAIL: A half fetches %b, want 0111 (w0,w1 + the crossing w2)", val_a);
            errors = errors + 1;
        end
        if (val_b !== 4'b1100) begin
            $display("FAIL: B half fetches %b, want 1100 (the crossing w2 + w3)", val_b);
            errors = errors + 1;
        end
        $display("  album: A valid=%b B valid=%b (want 0001 on both)",
                 alb_val_a, alb_val_b);
        if (alb_val_a !== 4'b0001 || alb_val_b !== 4'b0001) begin
            $display("FAIL: the frameless window must be fetched on BOTH nodes");
            errors = errors + 1;
        end

        // ---- C9-R3: the fetch stops at the last column this node can show ----
        // w0/w1 are fully on the A half -> full 192-word row (last column 191).
        // w2 is cut by the seam at x=640 (gx=600): only ~40 content pixels, so the
        // burst must stop around column 45 (the safe bound is gxroom+5 = 45) --
        // that is what gives node A's read port its line back.
        $display("  A last col: w3=%0d w2=%0d w1=%0d w0=%0d (want 5 / <=60 / 191 / 191)",
                 c1_a[39:30], c1_a[29:20], c1_a[19:10], c1_a[9:0]);
        if (c1_a[9:0]   !== 10'd191) begin
            $display("FAIL: A w0 last col %0d (want 191)", c1_a[9:0]); errors = errors + 1;
        end
        if (c1_a[19:10] !== 10'd191) begin
            $display("FAIL: A w1 last col %0d (want 191)", c1_a[19:10]); errors = errors + 1;
        end
        if (c1_a[29:20] > 10'd60 || c1_a[29:20] < 10'd24) begin
            $display("FAIL: A w2 last col %0d (want the seam-limited ~45)", c1_a[29:20]);
            errors = errors + 1;
        end
        // B sees w2 in full: its right neighbour is the world edge, not the seam
        $display("  B last col: w3=%0d w2=%0d (want 191 on both)",
                 c1_b[39:30], c1_b[29:20]);
        if (c1_b[39:30] !== 10'd191 || c1_b[29:20] !== 10'd191) begin
            $display("FAIL: B must fetch both of its windows in full");
            errors = errors + 1;
        end

        if (errors == 0) $display("TB_PREFETCH_NODE PASS");
        else             $display("TB_PREFETCH_NODE FAIL (%0d)", errors);
        $finish;
    end
endmodule
