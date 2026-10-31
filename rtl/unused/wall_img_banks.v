//=============================================================================
// wall_img_banks.v -- the on-chip picture library.
//
// Four 96x72 RGB444 thumbnails live in one 32K x 12 block RAM:
//
//   addr[14:13] = window id / bank
//   addr[12:0]  = y*96 + x        (y 0..71, x 0..95, 6912 words of the 8192 slot)
//
// The RAM is instantiated explicitly as EG_LOGIC_BRAM in single-port mode.
// Two reasons:
//   * TD's *inferred* memory mapping does not co-operate here: with a plain
//     `reg [11:0] mem [0:32767]` the synthesis log says
//     "Infer 1 Logic DRAMs, 1 Logic BRAMs" and the array silently disappears
//     (the design grew by ~100 registers instead of ~44 BRAMs).  This is the
//     same wall the earlier wall_img_rom + .mif attempt hit.
//   * single-port is enough because a write may only happen while the bank is
//     NOT being displayed: bank_valid is cleared before a fill/load and set
//     again afterwards, so the one stolen read cycle per written word is
//     invisible (the window shows its procedural fallback meanwhile).
//
// Read side: the scene presents the address for the NEXT pixel (x+1) while it
// renders the current one; doa is combinational, so registering it gives the
// exact 1-cycle latency wall_scene's img_addr/img_rgb444 contract expects.
//
// Write side: this round a power-on pattern generator (so the whole BRAM +
// scene path can be proven on the board without a working card); the TF/BMP
// loader takes the port over next round through wr_en/wr_addr/wr_data.
//
// A read-back checker walks the used words after the fill and counts the ones
// that do not match the generator.  `chk_err` goes to the status frame, so
// "the picture RAM really holds what we wrote" is a number, not an opinion.
//=============================================================================
`timescale 1ns/1ps

module wall_img_banks (
    input  wire        clk,        // 25 MHz pixel clock
    input  wire        rst,        // logic_rst
    input  wire        fill_go,    // one-shot: fill the banks with the pattern
    input  wire [14:0] rd_addr,    // scene address (combinational, for x+1)
    output wire [11:0] rd_data,    // 1 cycle later (BRAM output)
    output reg  [3:0]  bank_valid, // bank holds a finished picture
    output wire        busy,       // filling or checking
    output wire        chk_done,
    output wire [7:0]  chk_err,    // mismatching words, saturating
    // loader write port (unused while the pattern generator owns the RAM)
    input  wire        wr_en,
    input  wire [14:0] wr_addr,
    input  wire [11:0] wr_data
);
    localparam integer XN = 96;     // thumbnail width
    localparam integer YN = 72;     // thumbnail height

    localparam S_IDLE = 3'd0, S_FILL = 3'd1, S_CHK = 3'd2, S_TAIL = 3'd3, S_DONE = 3'd4;

    reg [2:0]  st;
    wire filling  = (st == S_FILL);
    wire checking = (st == S_CHK);

    reg [1:0]  fid;
    reg [6:0]  fy, fx;
    reg [1:0]  cid;
    reg [6:0]  cy, cx;

    // Bank stride 6912 = 0x1B00, the SAME stride wall_scene uses (id*6912).
    // Using 8192 here while the scene uses 6912 was a real bug: bank 0 looked
    // fine while every other bank sampled its neighbour's words.
    function [14:0] bank_of;
        input [1:0] id;
        begin
            bank_of = ({13'd0, id} << 12) + ({13'd0, id} << 11)
                    + ({13'd0, id} << 9)  + ({13'd0, id} << 8);
        end
    endfunction

    wire [12:0] f_off  = (fy << 6) + (fy << 5) + fx;
    wire [14:0] f_addr = bank_of(fid) + f_off;
    wire [12:0] c_off  = (cy << 6) + (cy << 5) + cx;
    wire [14:0] c_addr = bank_of(cid) + c_off;

    // ------------------------------------------------------------- pattern ---
    function [11:0] pat;
        input [1:0] id;
        input [6:0] x;
        input [6:0] y;
        begin
            case (id)
                // solid quadrants: red / green / blue / yellow
                2'd0: pat = (x < 7'd48) ? ((y < 7'd36) ? 12'hF00 : 12'h0F0)
                                        : ((y < 7'd36) ? 12'h00F : 12'hFF0);
                // six vertical bars: red, green, blue, white, cyan, magenta
                2'd1: case (x[6:4])
                    3'd0: pat = 12'hF00;
                    3'd1: pat = 12'h0F0;
                    3'd2: pat = 12'h00F;
                    3'd3: pat = 12'hFFF;
                    3'd4: pat = 12'h0FF;
                    3'd5: pat = 12'hF0F;
                    default: pat = 12'h222;
                endcase
                // checkerboard, tinted so it is obviously a picture
                2'd2: pat = (((x >> 3) ^ (y >> 3)) & 1) ? {4'hF, 4'h6, 4'h6}
                                                        : {4'h1, 4'h1, 4'h8};
                // diagonal ramp
                default: pat = {4'b0, x[3:0]} + {4'b0, y[3:0]};
            endcase
        end
    endfunction

    wire [11:0] fill_word = pat(fid, fx, fy);
    wire [11:0] chk_word  = pat(cid, cx, cy);

    reg  [11:0] exp_q;
    reg  [7:0]  errs;
    reg         done_r;

    assign busy     = filling || checking;
    assign chk_done = done_r;
    assign chk_err  = errs;

    // -------------------------------------------------------------- BRAM -----
    wire        sp_we   = filling | wr_en;
    wire [14:0] sp_addr = filling ? f_addr :
                          wr_en   ? wr_addr :
                          (checking || st == S_TAIL) ? c_addr : rd_addr;
    wire [11:0] sp_din  = filling ? fill_word : wr_data;
    wire [11:0] doa;

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(12), .ADDR_WIDTH_A(15), .DATA_DEPTH_A(32768),
        .DATA_WIDTH_B(12), .ADDR_WIDTH_B(15), .DATA_DEPTH_B(32768),
        .MODE("SP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .DEBUGGABLE("NO"), .PACKABLE("NO"),
        .INIT_FILE("NONE"), .FILL_ALL("NONE")
    ) u_ram (
        .dia(sp_din), .dib(12'd0), .addra(sp_addr), .addrb(15'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(1'b0), .wea(sp_we), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
        .doa(doa), .dob()
    );

    // TD's EG_LOGIC_BRAM registers the ADDRESS internally even in REGMODE
    // "NOREG", which means "no output register": doa is already one cycle
    // behind the address.  Adding another register here (the first cut did)
    // made the effective latency two cycles and every read-back word
    // mismatched on the board -- the self-check is what caught it.
    assign rd_data = doa;

    always @(posedge clk) if (checking) exp_q <= chk_word;

    // ---------------------------------------------------------- fill / check -
    always @(posedge clk) begin
        if (rst) begin
            st         <= S_IDLE;
            fid        <= 2'd0;
            fy         <= 7'd0;
            fx         <= 7'd0;
            cid        <= 2'd0;
            cy         <= 7'd0;
            cx         <= 7'd0;
            errs       <= 8'd0;
            done_r     <= 1'b0;
            bank_valid <= 4'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (fill_go) begin
                        st <= S_FILL;
                        fid <= 2'd0; fy <= 7'd0; fx <= 7'd0;
                    end
                end
                S_FILL: begin
                    if (fx == XN - 1) begin
                        fx <= 7'd0;
                        if (fy == YN - 1) begin
                            fy <= 7'd0;
                            if (fid == 2'd3) begin
                                st   <= S_CHK;
                                cid  <= 2'd0; cy <= 7'd0; cx <= 7'd0;
                                errs <= 8'd0;
                            end else begin
                                fid <= fid + 2'd1;
                            end
                        end else begin
                            fy <= fy + 7'd1;
                        end
                    end else begin
                        fx <= fx + 7'd1;
                    end
                end
                S_CHK: begin
                    // rd_data holds mem[address presented last cycle],
                    // exp_q holds the word expected for that same address.
                    if (!(cx == 7'd0 && cy == 7'd0 && cid == 2'd0))
                        if (rd_data != exp_q && errs != 8'hFF) errs <= errs + 8'd1;

                    if (cx == XN - 1 && cy == YN - 1 && cid == 2'd3) begin
                        // keep the counters so S_TAIL still presents the last
                        // address and can compare its data
                        st <= S_TAIL;
                    end else if (cx == XN - 1) begin
                        cx <= 7'd0;
                        if (cy == YN - 1) begin
                            cy  <= 7'd0;
                            cid <= cid + 2'd1;
                        end else begin
                            cy <= cy + 7'd1;
                        end
                    end else begin
                        cx <= cx + 7'd1;
                    end
                end
                S_TAIL: begin
                    if (rd_data != exp_q && errs != 8'hFF) errs <= errs + 8'd1;
                    st         <= S_DONE;
                end
                S_DONE: begin
                    bank_valid <= 4'hF;
                    done_r     <= 1'b1;
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
