//=============================================================================
// wall_pic_prefetch.v -- per-line source-row + visibility generator
//
// Purely combinational: given the active line whose row is about to be
// prefetched, produce for every window
//   nxt_rows[w]  the source row to fetch
//   nxt_valid[w] 1 when that window actually shows picture content on that line
//   nxt_hi[w]    1 when the window is FRAMELESS, i.e. it shows a 640x480 1:1
//                copy (album mode) instead of a 192x144 thumbnail; the row then
//                runs 0..479 instead of 0..143
//   nxt_idx[w*2+:2] which of the four 1:1 copies the window shows (C9): record
//                bits [60:59].  Only meaningful when nxt_hi is set.
//
// Skipping invisible windows is not an optimisation detail, it is required:
// four 288-word bursts per display line do not fit the SDRAM read port
// (measured shortfall showed up on the board as a torn, flickering A screen and
// a starved A->B carousel).  With the default table only one or two windows
// cover any given line, so skipping cuts the burst traffic by more than half.
// The album window is additionally the only window that is ever 640 words wide,
// and in album mode the other three records are blanked to w=h=0 by the
// sequencer in wall_top, so a line never asks for more than one long burst.
//
// The source row for window w at active line y is
//     cly = y - gy - (frameless ? 0 : 16)      (content-local, >= 0 clamped)
//     py  = cly - oy  (>= 0 clamped)           (letterbox offset removed)
//     sy  = 2 * ((py * step) >> 16)            (96-based step -> 192-wide)
//           (py * step) >> 16                  (640-wide, frameless)
// clamped to 143 (192x144) or 479 (640x480).  The scene shows black outside
// [oy, oy+zdh), so those lines need no fetch at all.
//=============================================================================
`timescale 1ns/1ps

module wall_pic_prefetch #(
    // This node's slice of the world.  A window that does not intersect it is
    // never drawn here, so its row must not be fetched either: with four windows
    // on screen each node used to fetch FOUR 192-word bursts per line while it
    // draws at most three, and the line buffer missed its one-line deadline on
    // the last windows in scan order (visible as judder while a picture is moved
    // up/down).  See docs/10_album_plan.md, C9-R2.
    parameter integer NODE_X0 = 0,
    parameter integer NODE_W  = 640
)(
    input  wire [8:0]   y_target,      // active line whose rows are wanted
    input  wire [255:0] tbl,           // current window table
    input  wire [71:0]  zstep,         // 4 x Q16 step (source-size based)
    input  wire [47:0]  zdh,           // 4 x drawn height
    output wire [35:0]  nxt_rows,      // 4 x 9-bit source row (0..143 / 0..479)
    output wire [3:0]   nxt_valid,     // 4 x "needs a fetch on this line"
    output wire [3:0]   nxt_hi,        // 4 x "this window reads a 1:1 copy"
    output wire [7:0]   nxt_idx,       // 4 x 2-bit "which copy" (record [60:59])
    // C9-R3: last source column this node can possibly display for window g.
    // A window that the node's right edge cuts (only the seam-crossing one)
    // needs a fraction of the row, and that burst is exactly the one that starves
    // the line buffer: on node A the three visible windows are fetched in the
    // order 0,1,2, so window 2 is served last and missed its line.
    output wire [39:0]  nxt_c1         // 4 x 10-bit last column (191 / 639 = full)
);
    localparam [12:0] NODE_X1 = NODE_X0 + NODE_W;

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_row
            wire [11:0] gy   = tbl[g*64 + 23 : g*64 + 12];
            wire [9:0]  h    = tbl[g*64 + 43 : g*64 + 34];
            wire [9:0]  w    = tbl[g*64 + 33 : g*64 + 24];
            wire [11:0] gx   = tbl[g*64 + 11 : g*64 +  0];
            // bit 58 = frameless.  The record's reserved field starts at 58, and
            // wall_input always writes 0 there, so only the album sequencer can
            // ever set it.  C9: bits [60:59] carry the album page number.
            wire        fw   = tbl[g*64 + 58];
            wire [1:0]  idx  = tbl[g*64 + 59 +: 2];
            wire [11:0] hh   = {2'b00, h};
            // Frameless: the content area is the whole window (no 2 px border,
            // no 14 px title) and the window is always the full 1280x480 world.
            wire [11:0] chh  = fw ? 12'd480 : ((h < 10'd24) ? 12'd8 : (hh - 12'd16));
            wire [11:0] zdhw = zdh[g*12 +: 12];
            wire [11:0] oy   = (chh > zdhw) ? ((chh - zdhw) >> 1) : 12'd0;
            // cly = y - gy - (16 if decorated), clamped to 0 above the window
            wire [12:0] ymg  = {1'b0, y_target} - {1'b0, gy};
            wire [12:0] cly13 = fw ? ymg : (ymg - 13'd16);
            wire [11:0] cly  = cly13[12] ? 12'd0 : cly13[11:0];
            // visible only inside the drawn picture rect.  h == 0 is a blanked
            // record (the album sequencer parks the other three windows that
            // way), and must never be treated as visible even though the zoom
            // block would report a non-zero drawn height for it.
            wire        vis  = (h != 10'd0) && (cly >= oy) && (cly < oy + zdhw) &&
                               (zdhw != 12'd0);
            // ...and only when the window touches THIS node's half of the world.
            // Both nodes render the same table, so without this each one fetched
            // rows for pictures it cannot draw.
            wire [12:0] gxr   = {1'b0, gx} + {3'd0, w};
            wire        on_node = (w != 10'd0) && ({1'b0, gx} < NODE_X1) &&
                                  (gxr > NODE_X0);
            // C9-R3: how much of the row this node can possibly show.  `gxroom`
            // is the number of content pixels between the window's left edge and
            // this node's right edge; the source column never runs ahead of the
            // drawn pixel when 2*step <= 65536 (i.e. at most one source column
            // per drawn pixel), so gxroom + 5 is a SAFE upper bound.  Trimming
            // the burst to it is what gives node A its line back.
            wire [11:0] gxroom = ({1'b0, gx} < NODE_X1) ? (NODE_X1 - {1'b0, gx}) : 12'd0;
            wire [9:0]  full_c = fw ? 10'd639 : 10'd191;
            wire        trim_ok = fw || (zstep[g*18 +: 18] <= 18'd32768);
            wire [11:0] c1x  = gxroom + 12'd5;
            wire [9:0]  c1   = (!trim_ok || (gxroom >= {2'b00, w})) ? full_c :
                               (c1x >= {2'b00, full_c})               ? full_c :
                                                                        c1x[9:0];
            assign nxt_c1[g*10 +: 10] = c1;
            wire [11:0] py0  = (cly >= oy) ? (cly - oy) : 12'd0;
            wire [11:0] py   = (py0 >= zdhw) ? (zdhw - 12'd1) : py0;
            // scale BEFORE the multiply: the step maps a drawn pixel to the
            // source grid it was computed from (96/72 based for a thumbnail,
            // 640/480 based for the full-resolution copy), so scaling its
            // RESULT would quantise the source coordinate.
            // (2*py) x step >> 16 is the true 192-row coordinate for a
            // thumbnail; the frameless window is already on the 640x480 grid and
            // needs no doubling.
            // Must be a plain x<<1 -- "py + (py<<1)" is 3x and saturates the row
            // two thirds down every window.
            wire [12:0] py2  = fw ? {1'b0, py} : ({1'b0, py} << 1);
            wire [30:0] icy2 = py2 * zstep[g*18 +: 18];
            wire [14:0] syraw = icy2[30:16];
            wire [8:0]  sy   = fw ? ((syraw > 15'd479) ? 9'd479 : syraw[8:0])
                                  : ((syraw > 15'd143) ? 9'd143 : syraw[7:0]);
            assign nxt_rows[g*9 +: 9] = sy;
            assign nxt_valid[g]       = vis & on_node;
            assign nxt_hi[g]          = fw;
            assign nxt_idx[g*2 +: 2]  = idx;
        end
    endgenerate

endmodule
