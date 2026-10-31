//=============================================================================
// wall_sd_dump.v -- capture the head of one SD sector and dump it over its own
// 115200 UART, so the host can see what is actually on the card.
//
// Why this exists: the vendor SD stack (rtl/sd/) only streams bytes, it does not
// store them.  Before writing a FAT32 walker it is worth knowing, from the real
// card, whether sector 0 really is a FAT32 boot sector and what the BPB fields
// are (bytes/cluster, reserved, FAT size, root cluster).  128 bytes is exactly
// the part of the boot sector that contains the whole BPB.
//
// Capture is free-running: the first 128 valid bytes of whatever sector the
// probe reads are latched, then the buffer is re-sent once per gap so a late
// host capture always catches one.
//
// The dump UART is clocked by the 25 MHz pixel clock with DIV = 217, i.e.
// 115207 Bd -- the same 0.006% error as the 50 MHz status UART (DIV = 434).
// wall_top multiplexes it onto the same pin; the two transmitters are in
// different clock domains, so a status frame that is in flight when a dump
// starts is truncated and the host resynchronises on the next 'W','L'.
//=============================================================================
`timescale 1ns/1ps

module wall_sd_dump #(
    parameter integer NBYTES   = 128,       // bytes captured (power of two)
    parameter integer START    = 0,         // first byte of the sector to keep
    parameter integer GAP_CYC  = 22'd4_000_000  // ~160 ms between dumps @25 MHz
)(
    input  wire       clk,        // 25 MHz pixel clock
    input  wire       rst,
    input  wire       sd_valid,   // sd_card_top byte stream
    input  wire [7:0] sd_data,
    input  wire       sd_end,     // end of the sector
    input  wire       cap_en,     // capture window: high while the interesting
                                  // sector is being read (see wall_top: the root
                                  // directory, so the host sees the file names)
    output wire       active,     // capture finished or dump running: pin busy
    output wire       tx
);
    localparam integer AW = 7;      // NBYTES = 128

    // ---- capture -----------------------------------------------------------
    reg [7:0]  mem [0:NBYTES-1];
    reg [AW:0] wcnt;
    reg [9:0]  bcnt;        // byte index inside the sector (0..511)
    reg        full;
    reg        cap_d;       // cap_en delayed, for the re-arm edge

    always @(posedge clk) begin
        if (rst) begin
            wcnt <= {(AW+1){1'b0}};
            bcnt <= 10'd0;
            full <= 1'b0;
            cap_d <= 1'b0;
        end else begin
            cap_d <= cap_en;
            // (re-)arm the capture when the window opens, so the buffer always
            // holds the sector the loader is about to read
            if (cap_en && !cap_d) begin
                wcnt <= {(AW+1){1'b0}};
                bcnt <= 10'd0;
                full <= 1'b0;
            end
            if (cap_en) begin
                if (sd_valid) begin
                    bcnt <= bcnt + 10'd1;
                    // keep only the [START, START+NBYTES) window, so the host can
                    // look at the BPB (START=0) or at the tail / partition table
                    // (START=384).  Bytes outside the window are simply skipped.
                    if ((bcnt >= START[9:0]) && (wcnt != NBYTES[AW:0])) begin
                        mem[wcnt[AW-1:0]] <= sd_data;
                        wcnt <= wcnt + 1'b1;
                    end
                end
                if (sd_end) full <= 1'b1;
            end
        end
    end

    // ---- dump -------------------------------------------------------------
    // One-byte handshake: present the byte + go, then wait for busy to rise and
    // fall before presenting the next one.  wall_uart_tx registers busy one
    // cycle after go, so a plain "if (!busy) issue" loop issues twice per byte
    // and silently skips every second byte (that bug cost one debug cycle here
    // and is the same one wall_status_tx documents at its own FSM).
    reg [AW:0]  raddr;
    reg         dumping;
    reg         go;
    reg         pending;
    reg  [7:0]  tdata;
    reg  [21:0] gap;
    wire        busy;
    wire [7:0]  rdata = mem[raddr[AW-1:0]];

    localparam S_HDR = 2'd0, S_DATA = 2'd1, S_END = 2'd2, S_GAP = 2'd3;
    reg [1:0]  st;
    reg  [1:0] hdr;

    wire [7:0] hdr_byte = (hdr == 2'd0) ? 8'h53 :            // 'S'
                          (hdr == 2'd1) ? 8'h44 :            // 'D'
                          (hdr == 2'd2) ? NBYTES[7:0] : 8'h00;

    always @(posedge clk) begin
        if (rst) begin
            st      <= S_GAP;
            raddr   <= {(AW+1){1'b0}};
            hdr     <= 2'd0;
            dumping <= 1'b0;
            go      <= 1'b0;
            pending <= 1'b0;
            tdata   <= 8'd0;
            gap     <= 22'd0;
        end else begin
            go <= 1'b0;
            if (busy) pending <= 1'b0;
            case (st)
                S_GAP: begin
                    dumping <= 1'b0;
                    if (full) begin
                        if (gap == GAP_CYC) begin
                            gap <= 22'd0;
                            st  <= S_HDR;
                            hdr <= 2'd0;
                        end else begin
                            gap <= gap + 22'd1;
                        end
                    end
                end
                S_HDR: begin
                    dumping <= 1'b1;
                    if (!busy && !pending) begin
                        tdata   <= hdr_byte;
                        go      <= 1'b1;
                        pending <= 1'b1;
                        if (hdr == 2'd3) begin
                            hdr   <= 2'd0;
                            raddr <= {(AW+1){1'b0}};
                            st    <= S_DATA;
                        end else begin
                            hdr <= hdr + 2'd1;
                        end
                    end
                end
                S_DATA: begin
                    dumping <= 1'b1;
                    if (!busy && !pending) begin
                        if (raddr == NBYTES[AW:0]) begin
                            st <= S_END;
                        end else begin
                            tdata   <= rdata;
                            go      <= 1'b1;
                            pending <= 1'b1;
                            raddr   <= raddr + 1'b1;
                        end
                    end
                end
                S_END: begin
                    dumping <= 1'b0;
                    st      <= S_GAP;
                end
                default: st <= S_GAP;
            endcase
        end
    end

    assign active = dumping;

    wall_uart_tx #(.DIV(217)) u_tx (
        .clk(clk), .go(go), .data(tdata), .tx(tx), .busy(busy)
    );
endmodule
