//=============================================================================
// wall_tf_load.v -- TF card -> FAT32 -> 24-bit BMP -> SDRAM picture library
//
// One streaming pass, no frame buffer: every byte that comes out of sd_card_top
// is consumed on the cycle it arrives.  The only arithmetic that needs more than
// a few gates (nfats*fatsz, (cluster-2)*spc, w/192, h/144, (h-1)/sy) runs in
// short micro-sequences while no byte can arrive -- between sector requests, or
// during the BMP header pass -- so the byte path stays one byte per cycle.
//
// The pictures go straight to SDRAM as 288x216 RGB565 words (mw_*), which is
// what wall_pic_line feeds the scene from.  The old 96x72 RGB444 on-chip bank
// (wr_en/wr_addr/wr_data) was removed in W3: the scene stopped reading it when
// the line buffer landed, so it only cost LUTs.
//
// C9: every one of the four pictures also gets a 1:1 640x480 RGB565 copy in its
// own HI region (HI_BASE + cid*307200), which is what the full-screen album mode
// shows; the WAV moved down to make room, see the memory map below the pic_base
// function.
//
// Flow (phase is what the status frame reports, see docs/05_w2_loader_design.md 2):
//
//   IDLE   wait sd_init_done
//   BOOT   read LBA 0, latch BPB: bps(0x0B) spc(0x0D) rsv(0x0E) nfats(0x10)
//          fatsz32(0x24) rootclus(0x2C) 0x55AA(0x1FE)
//   PREP   data_start = rsv + nfats*fatsz ; root_lba = data_start + (rootclus-2)*spc
//   ROOT   scan the root directory's first cluster (spc sectors), collect
//          CAM1..4.BMP -> first cluster + size
//   PICK   lowest bank with found & !ok & !bad
//   HDR    read the file's first sector once, latch the BMP header, then run the
//          divisions with nothing streaming
//   DATA   re-read from the file's first cluster and decimate:
//            x = k*sx, y = m*sy, bank_row = 71-m (bottom-up BMP), 96 columns,
//            72 rows, RGB444 = {R[7:4],G[7:4],B[7:4]}
//   CHAIN  one FAT sector per cluster: next = FAT[c] & 0x0FFFFFFF, >=0x0FFFFFF8 = end
//
// Deliberate simplifications (documented, not accidental):
//   * root directory = first cluster only (no FAT walk while scanning)
//   * one FAT sector read per cluster (no FAT cache) -- correct, just slower
//   * any 24-bit uncompressed BMP, |width|,|height| <= 65535, negative height ok
//
// The sector request is a single-cycle pulse and the vendor stack only samples
// it in S_WAIT_READ_WRITE, so every request is re-armed on a timeout: on the
// real board the first pulse after init is usually dropped (see
// docs/02_bringup_log.md 16), and a dropped pulse is otherwise silent forever.
//=============================================================================
`timescale 1ns/1ps

module wall_tf_load #(
    parameter integer TMO_CYC   = 500_000,   // ~20 ms @ 25 MHz
    parameter integer RETRY_MAX = 8
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        sd_init_done,
    input  wire        wav_en,       // 0 = leave the MUSIC.WAV pass disabled

    output reg         sd_req,       // 1-cycle request pulse
    output reg  [31:0] sd_lba,
    input  wire        sd_valid,     // one byte per cycle
    input  wire [7:0]  sd_data,
    input  wire        sd_end,       // sector finished

    output reg  [3:0]  phase,        // 0 idle 1 boot 2 root 3 pick 4 chain 5 data 6 done 15 err
    output reg  [7:0]  err,
    output reg  [4:0]  found,        // CAM1..4 + MUSIC.WAV present in the root directory
    output reg  [4:0]  bank_ok,      // bank completed (bit 4 = the WAV pass)
    output reg  [7:0]  sec_bytes,    // bytes of the current sector (saturating)
    output wire [4:0]  dbg_state,    // raw FSM state (16 = WAV header, 17 = WAV data)
    output reg  [7:0]  dbg_ent_cnt,  // root-directory entries processed
    output reg  [31:0] dbg_ent4,     // first 4 name bytes of entry #4
    // MUSIC.WAV -> SDRAM, one 32-bit word per stereo frame
    output wire        mw_vld,
    output wire [20:0] mw_addr,
    output wire [31:0] mw_data,
    input  wire        mw_rdy,
    output reg  [20:0] music_frames, // 0 = no usable WAV -> wall_top uses the synth
    output reg         music_ok,

    // root-directory dump (raw inspection of the card's FAT entries)
    input  wire [8:0]  dump_addr,
    output wire [7:0]  dump_byte
);
    localparam [3:0] RETRY_MAX4 = RETRY_MAX;

    // ---- states (16, fits the 4-bit status nibble) -------------------------
    localparam [4:0]
        S_IDLE = 5'd0,  S_BOOT = 5'd1,  S_PREP = 5'd2,  S_PREP_B = 5'd3,
        S_ROOT = 5'd4,  S_ROOT_NEXT = 5'd5, S_PICK = 5'd6, S_HDR = 5'd7,
        S_HDRC = 5'd8,  S_FILE = 5'd9,  S_FILE_NEXT = 5'd10, S_FAT = 5'd11,
        S_FAT_NEXT = 5'd12, S_MUL = 5'd13, S_DONE = 5'd14, S_ERR = 5'd15,
        S_WAVH = 5'd16, S_WAVD = 5'd17;   // MUSIC.WAV header / data

    localparam [3:0]
        P_IDLE = 4'd0, P_BOOT = 4'd1, P_ROOT = 4'd2, P_PICK = 4'd3,
        P_CHAIN = 4'd4, P_DATA = 4'd5, P_DONE = 4'd6, P_ERR = 4'd15;

    localparam [7:0]
        E_NOTINIT = 8'd1, E_BPS = 8'd2, E_SIG = 8'd3, E_NOTFAT32 = 8'd4,
        E_NOFILE = 8'd5, E_BMP = 8'd6, E_CHAIN = 8'd7, E_TMO = 8'd8;

    reg [4:0]  st;
    reg [4:0]  mul_ret;   // 5 bits: S_WAVH is 16
    reg [1:0]  mul_dst;      // 0 data_start, 1 root_lba, 2 cur_lba
    reg [39:0] mul_a, mul_acc;
    reg [15:0] mul_b;
    reg        req_done;
    reg [3:0]  retry;
    reg [20:0] tmo;

    // ---- boot sector ------------------------------------------------------
    reg [15:0] bps, rsv, sb, sbsig;
    reg [7:0]  spc, nfats;
    reg [31:0] fatsz, rootclus;
    reg [31:0] data_start, root_lba, cur_lba;

    // A partitioned card puts the FAT32 volume in a partition: LBA 0 is then a
    // partition table (MBR), not a boot sector, and its first 128 bytes are
    // often all zero because most partitioning tools write no boot code.  That
    // is exactly the card on board A (docs/02_bringup_log.md 20), which is why
    // "LBA 0 is all zeros" never meant "the card is empty".
    reg        boot_pass;      // 0 = read LBA 0, 1 = read the partition's boot sector
    reg [31:0] part_base;      // first LBA of the volume (0 for a superfloppy)
    reg [7:0]  p_type0, p_type1, p_type2, p_type3;
    reg [31:0] p_lba0, p_lba1, p_lba2, p_lba3;

    // ---- root directory ---------------------------------------------------
    reg [7:0]   dir_sec;
    reg [5:0]   eb;
    reg [255:0] ent;
    reg         dir_stop;
    reg  [7:0]  ent_cnt;
    reg [27:0]  f_first [0:4];   // slot 4 = MUSIC.WAV
    reg [31:0]  f_size  [0:4];
    reg [4:0]   f_bad;

    // ---- MUSIC.WAV -------------------------------------------------------
    // The file is read linearly (no FAT walk): it is written to a freshly
    // prepared card right after the pictures, so it lands contiguous.  If it is
    // ever fragmented the audio glitches and the board falls back to the synth
    // by simply not finding a valid header.
    reg         wav_found, wav_done;

    reg [31:0]  wav_lba, words_left;
    reg         hdr_ok, wav_first_sec;
    reg         hold_valid;
    reg [31:0]  hold_data;
    reg [20:0]  hold_addr;
    reg [1:0]   wfb;
    reg [31:0]  wtmp;
    reg [15:0]  wsb;

    // ---- current file -----------------------------------------------------
    reg [2:0]  cid;
    reg [27:0] cur_clu;
    reg [7:0]  sec_in_clu;
    reg [31:0] foff;
    reg        bank_done, discard;

    // ---- BMP header -------------------------------------------------------
    reg [15:0] h_bm, h_bits;
    reg [31:0] h_offb, h_w, h_h, h_comp;
    reg        bottom_up;
    reg [15:0] img_w, img_h, row_pad;
    reg [31:0] offbits;
    reg [15:0] sx, sy, q0, yrem, rem0;

    // ---- decimation -------------------------------------------------------
    reg [15:0] brow, px, pad_left;
    reg        sel_row, emit_row;
    reg [1:0]  pbp;
    reg [7:0]  pb, pg;
    reg [8:0]  k;          // 0..287 sampled column (288x216 hires)

    // ---- FAT --------------------------------------------------------------
    reg [15:0] fat_off;
    reg [31:0] fat_val;

    // ---- header divider (subtract loop, only runs between sectors) --------
    reg [1:0]  dv_job;
    reg        dv_run;
    reg [23:0] dv_a, dv_b, dv_q;

    // ---- helpers ----------------------------------------------------------
    wire [255:0] ent_n    = {sd_data, ent[255:8]};   // same shift as the register
    wire [7:0]   ent_b0   = ent_n[7:0];
    wire [7:0]   ent_att  = ent_n[95:88];
    wire         ent_skip = (ent_b0 == 8'hE5) || ((ent_att & 8'h3F) == 8'h0F) || ent_att[4];
    wire [31:0]  ent_clus = {ent_n[175:168], ent_n[167:160], ent_n[223:216], ent_n[215:208]};
    wire [31:0]  ent_size = {ent_n[255:248], ent_n[247:240], ent_n[239:232], ent_n[231:224]};

    wire [31:0]  h_mag = h_h[31] ? (~h_h + 32'd1) : h_h;

    // MBR partition picker: the first entry whose type looks like FAT and whose
    // start LBA is non-zero.  0x0B/0x0C = FAT32, 0x06/0x0E = FAT16 (accepted and
    // rejected later by the FAT32 check, with a specific error code).
    wire mbr_ok0 = (p_type0 == 8'h0B) || (p_type0 == 8'h0C) || (p_type0 == 8'h06) || (p_type0 == 8'h0E);
    wire mbr_ok1 = (p_type1 == 8'h0B) || (p_type1 == 8'h0C) || (p_type1 == 8'h06) || (p_type1 == 8'h0E);
    wire mbr_ok2 = (p_type2 == 8'h0B) || (p_type2 == 8'h0C) || (p_type2 == 8'h06) || (p_type2 == 8'h0E);
    wire mbr_ok3 = (p_type3 == 8'h0B) || (p_type3 == 8'h0C) || (p_type3 == 8'h06) || (p_type3 == 8'h0E);
    wire mbr_any = mbr_ok0 | mbr_ok1 | mbr_ok2 | mbr_ok3;
    wire [31:0] mbr_lba = mbr_ok0 ? p_lba0 : mbr_ok1 ? p_lba1 : mbr_ok2 ? p_lba2 : p_lba3;

    // The entry shift register ends up with byte0 in [7:0] and byte31 in
    // [255:248], so the 11 name bytes are compared LSB-first: the literal below
    // reads "PMB....1MAC" for "CAM1    BMP".
    reg [2:0] name_id;      // 0..3 = CAM1..4, 4 = MUSIC.WAV, 5 = no match
    always @(*) begin
        if      (ent_n[87:0] == {8'h50,8'h4D,8'h42,8'h20,8'h20,8'h20,8'h20,8'h31,8'h4D,8'h41,8'h43}) name_id = 3'd0;
        else if (ent_n[87:0] == {8'h50,8'h4D,8'h42,8'h20,8'h20,8'h20,8'h20,8'h32,8'h4D,8'h41,8'h43}) name_id = 3'd1;
        else if (ent_n[87:0] == {8'h50,8'h4D,8'h42,8'h20,8'h20,8'h20,8'h20,8'h33,8'h4D,8'h41,8'h43}) name_id = 3'd2;
        else if (ent_n[87:0] == {8'h50,8'h4D,8'h42,8'h20,8'h20,8'h20,8'h20,8'h34,8'h4D,8'h41,8'h43}) name_id = 3'd3;
        // "MUSIC   WAV", same LSB-first convention
        // Slot 4 accepts ANY file whose extension is WAV: the base name does not
        // matter, and this cannot be tripped up by case or by a long-name entry
        // that sits in front of the short one.
        // Slot 4 = the audio file.  Two independent ways to recognise it:
        //   * the extension is WAV, or
        //   * the file is bigger than 1 MB (the pictures are 921,654 B each).
        // The size rule is the safety net: it cannot be defeated by a long-name
        // entry, an orphan VFAT entry or an unusual short name.
        else if ((ent_n[87:64] == {8'h56, 8'h41, 8'h57}) ||
                 (ent_size > 32'd1_000_000 && !(ent_att & 8'h18))) name_id = 3'd4;
        else name_id = 3'd5;
    end

    reg        pick_valid;
    reg [2:0]  pick_id;
    always @(*) begin
        pick_valid = 1'b0;
        pick_id    = 3'd0;
        if      (found[0] && !bank_ok[0] && !f_bad[0]) begin pick_valid = 1'b1; pick_id = 3'd0; end
        else if (found[1] && !bank_ok[1] && !f_bad[1]) begin pick_valid = 1'b1; pick_id = 3'd1; end
        else if (found[2] && !bank_ok[2] && !f_bad[2]) begin pick_valid = 1'b1; pick_id = 3'd2; end
        else if (found[3] && !bank_ok[3] && !f_bad[3]) begin pick_valid = 1'b1; pick_id = 3'd3; end
        else if (found[4] && !bank_ok[4] && !f_bad[4]) begin pick_valid = 1'b1; pick_id = 3'd4; end
    end

    // ---- row/column sampling: FRACTIONAL (DDA), not an integer step --------
    // 640x480 used to be sampled every 3rd column/row (integer step), losing the
    // right 10% / bottom 10% of every photo.  The DDA samples whenever the
    // accumulator crosses the image size, so the samples cover the WHOLE photo.
    reg  [16:0] racc;                        // row accumulator (0 .. img_h-1)
    reg  [16:0] col_acc;                     // column accumulator (0 .. img_w-1)
    wire [16:0] racc_sum  = racc + 17'd144;
    wire        racc_hit  = (racc_sum >= {1'b0, img_h});
    wire [16:0] col_sum   = col_acc + 17'd192;
    wire        col_hit   = (col_sum  >= {1'b0, img_w});
    // racc starts at 0: the row check runs at the END of a row and decides the
    // NEXT row, so 0 makes the 2nd row's check fire first (row 0 is kept anyway
    // via sel_first).  Starting at img_h-144 kept EVERY row instead.
    wire [16:0] racc_init = 17'd0;
    wire [16:0] col_init  = (img_w > 16'd192) ? ({1'b0, img_w} - 17'd192) : 17'd0;
    wire        sel_first = 1'b1;            // DDA: the first source row is kept
    // m = sampled source row.  Bank row 0 is the TOP of the window (wall_scene
    // addresses the bank as y*96 + x with y growing downwards), so the bank row
    // IS m.  The first version used bank_row = 71-m and every photo came out
    // upside down on the board.
    wire [15:0] m_first   = bottom_up ? ((img_h >= 16'd144) ? 16'd143
                                        : ((img_h == 16'd0) ? 16'd0 : (img_h - 16'd1)))
                                      : 16'd0;
    wire [15:0] m_nx      = bottom_up ? (brow - 16'd1) : (brow + 16'd1);
    wire [15:0] m_sel     = sel_row ? m_nx : brow;

    // High-resolution copy of each picture in SDRAM: 288x216 RGB565 = 62,208
    // pixels = 62,208 words, four contiguous slots whose spacing is still
    // 288x216 = 62,208 words (only the first 192x144 are used).
    //
    // C9 moved the whole thumbnail gallery up to 1,848,320 so that four
    // 640x480 1:1 copies fit below it.  The slot spacing did NOT change.
    function [20:0] pic_base;
        input [1:0] id;
        begin
            case (id)
                2'd0: pic_base = 21'd1848320;
                2'd1: pic_base = 21'd1910528;
                2'd2: pic_base = 21'd1972736;
                default: pic_base = 21'd2034944;
            endcase
        end
    endfunction
    // ---- full-resolution copy (C2/C9) ------------------------------------
    // A 1:1 640x480 RGB565 copy of EVERY picture (CAM1..CAM4) goes into its own
    // 307,200-word area, so the album mode can show any of the four
    // pixel-for-pixel instead of the 192x144 sampler's output.  A second write
    // register (hi_*) shares the single SDRAM write port with the 192x144 pass
    // through a 2-way arbiter; the pixel rate (~0.7 MB/s off the card) leaves
    // ~100 clocks between pixels, so the arbiter never has to stall.
    //
    // C9 memory map (2,097,152 words = the whole 2Mx32 device):
    //   MUSIC.WAV     0        ..  619,519   619,520 words (~12.9 s @ 48 kHz)
    //   HI0 (CAM1)  619,520    ..  926,719   307,200
    //   HI1 (CAM2)  926,720    ..1,233,919   307,200
    //   HI2 (CAM3)  1,233,920  ..1,541,119   307,200
    //   HI3 (CAM4)  1,541,120  ..1,848,319   307,200
    //   thumbs      1,848,320  ..2,097,151   4 x 62,208 (only 27,648 used each)
    // The four regions are exactly full -- no gap anywhere.
    localparam [20:0] HI_BASE   = 21'd619520;
    localparam integer HI_STRIDE = 307200;
    localparam [15:0] HI_W    = 16'd640;
    localparam [15:0] HI_H    = 16'd480;
    // WAV data must stay below HI_BASE, otherwise it would overwrite HI0.
    // (Equal to HI_BASE on purpose: the WAV owns everything below the copies.)
    localparam [20:0] WAV_CAP = 21'd619520;

    reg         hi_valid;
    reg  [20:0] hi_addr;
    reg  [31:0] hi_data;
    reg  [14:0] src_row;                 // source row counter, file order
    wire [14:0] hi_y     = bottom_up ? (img_h[14:0] - 15'd1 - src_row) : src_row;
    wire [20:0] hi_off   = ({6'd0, hi_y[8:0]} << 9) + ({6'd0, hi_y[8:0]} << 7);  // y*640
    // Which of the four 1:1 copies: HI region = cid, i.e. HI_BASE + cid*307200.
    // 307200 = 262144+32768+8192+4096 = 2^18 + 2^15 + 2^13 + 2^12, so it is a
    // shift-and-add of the 3-bit cid -- no multiplier on the write-address path.
    wire [20:0] hi_blk   = ({18'd0, cid} << 18) + ({18'd0, cid} << 15)
                         + ({18'd0, cid} << 13) + ({18'd0, cid} << 12);

    wire [20:0] pic_addr = pic_base(cid[1:0]) + ({5'd0, brow[7:0]} << 7)
                         + ({5'd0, brow[7:0]} << 6) + {12'd0, k};

    // Raw copy of the root-directory sector, so it can be read out over the
    // status frame when the on-card layout needs inspecting.
    reg [7:0] root_dump [0:511];
    assign dump_byte = root_dump[dump_addr];
    always @(posedge clk) begin
        if (st == S_ROOT && sd_valid) root_dump[sb[8:0]] <= sd_data;
    end

    // SDRAM write port: the hold registers ARE the handshake.  Two producers now
    // share the single port (the 192x144 pass and the full-resolution copy); the
    // 192x144 side wins, the hi-res side waits (there are ~100 clocks of slack
    // per source pixel, so neither can starve the other).
    assign dbg_state = st;

    assign mw_vld  = hold_valid | hi_valid;
    assign mw_addr = hold_valid ? hold_addr : hi_addr;
    assign mw_data = hold_valid ? hold_data : hi_data;

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; phase <= P_IDLE; err <= 8'd0;
            sd_req <= 1'b0; sd_lba <= 32'd0;
            found <= 5'd0; bank_ok <= 5'd0; sec_bytes <= 8'd0;
            music_ok <= 1'b0; music_frames <= 21'd0; 
            hdr_ok <= 1'b0; hold_valid <= 1'b0; hi_valid <= 1'b0; src_row <= 15'd0;
            music_ok <= 1'b0; music_frames <= 21'd0;  wav_found <= 1'b0;
            hdr_ok <= 1'b0; hold_valid <= 1'b0; hi_valid <= 1'b0; src_row <= 15'd0;
            mul_ret <= S_IDLE; mul_dst <= 2'd0; mul_a <= 40'd0; mul_acc <= 40'd0; mul_b <= 16'd0;
            req_done <= 1'b0; retry <= 4'd0; tmo <= 21'd0;
            bps <= 16'd0; rsv <= 16'd0; sb <= 16'd0; sbsig <= 16'd0;
            spc <= 8'd0; nfats <= 8'd0; fatsz <= 32'd0; rootclus <= 32'd0;
            data_start <= 32'd0; root_lba <= 32'd0; cur_lba <= 32'd0;
            boot_pass <= 1'b0; part_base <= 32'd0;
            p_type0 <= 8'd0; p_type1 <= 8'd0; p_type2 <= 8'd0; p_type3 <= 8'd0;
            p_lba0 <= 32'd0; p_lba1 <= 32'd0; p_lba2 <= 32'd0; p_lba3 <= 32'd0;
            dir_sec <= 8'd0; eb <= 6'd0; ent <= 256'd0; dir_stop <= 1'b0; f_bad <= 5'd0;
            ent_cnt <= 8'd0; dbg_ent4 <= 32'd0;
            f_first[0] <= 28'd0; f_first[1] <= 28'd0; f_first[2] <= 28'd0; f_first[3] <= 28'd0;
            f_first[4] <= 28'd0;
            f_size[0]  <= 32'd0; f_size[1]  <= 32'd0; f_size[2]  <= 32'd0; f_size[3]  <= 32'd0;
            f_size[4]  <= 32'd0;
            cid <= 2'd0; cur_clu <= 28'd0; sec_in_clu <= 8'd0; foff <= 32'd0;
            bank_done <= 1'b0; discard <= 1'b0;
            h_bm <= 16'd0; h_bits <= 16'd0; h_offb <= 32'd0; h_w <= 32'd0; h_h <= 32'd0; h_comp <= 32'd0;
            bottom_up <= 1'b1; img_w <= 16'd0; img_h <= 16'd0; row_pad <= 16'd0; offbits <= 32'd0;
            sx <= 16'd1; sy <= 16'd1; q0 <= 16'd0; yrem <= 16'd0; rem0 <= 16'd0;
            brow <= 16'd0; px <= 16'd0; col_acc <= 16'd0; pad_left <= 16'd0;
            sel_row <= 1'b0; emit_row <= 1'b0; pbp <= 2'd0; pb <= 8'd0; pg <= 8'd0; k <= 9'd0;
            fat_off <= 16'd0; fat_val <= 32'd0;
            dv_job <= 2'd0; dv_run <= 1'b0; dv_a <= 24'd0; dv_b <= 24'd0; dv_q <= 24'd0;
        end else begin
            // SDRAM write handshake: the hold register is shared by the two
            // passes, but only the MUSIC.WAV pass (cid == 4) advances the frame
            // counter.  The high-resolution picture pass (cid < 4) writes its
            // 288x216 RGB565 words to the picture block instead and must leave
            // music_frames untouched, otherwise the WAV pass would start at a
            // bogus offset and overlap the pictures.
            if (mw_rdy && (hold_valid || hi_valid)) begin
                if (hold_valid) begin
                    hold_valid <= 1'b0;
                    if (cid == 3'd4) begin
                        music_frames <= music_frames + 21'd1;
                        if (words_left != 32'd0) words_left <= words_left - 32'd1;
                    end
                end else begin
                    hi_valid <= 1'b0;
                end
            end

            sd_req <= 1'b0;

            // ---- request watchdog: re-arm a dropped pulse, give up after N --
            // retry must be cleared by every *successful* sector: counting them
            // across the whole session meant 8 sporadic hiccups anywhere in a
            // 11,000-sector WAV aborted the whole load (the board showed
            // "MUSIC ERR 8" and played only the first fragment).
            if (sd_end) retry <= 4'd0;

            if (req_done && !sd_end) begin
                if (tmo == TMO_CYC - 1) begin
                    tmo <= 21'd0;
                    if (retry == RETRY_MAX4) begin
                        err <= E_TMO; phase <= P_ERR; st <= S_ERR;
                    end else begin
                        retry <= retry + 4'd1;
                        req_done <= 1'b0;      // the stream state re-issues
                    end
                end else begin
                    tmo <= tmo + 21'd1;
                end
            end

            // A byte resets the watchdog: it measures a *stall*, not the total
            // time one sector takes.  A 512-byte sector is ~16k cycles at
            // 6.25 MHz; re-arming in the middle of one would reset the byte
            // index and quietly corrupt whatever the state was assembling.
            if (sd_valid) tmo <= 21'd0;

            case (st)
                // =============================================================
                S_IDLE: begin
                    if (sd_init_done) begin
                        st <= S_BOOT; phase <= P_BOOT; req_done <= 1'b0; retry <= 4'd0; tmo <= 21'd0;
                    end
                end

                // ---- LBA 0: BPB ------------------------------------------
                S_BOOT: begin
                    if (!req_done) begin
                        sd_lba <= boot_pass ? part_base : 32'd0;
                        sd_req <= 1'b1; req_done <= 1'b1; tmo <= 21'd0;
                        retry <= 4'd0; sb <= 16'd0; sec_bytes <= 8'd0;
                    end else if (sd_valid) begin
                        sb <= sb + 16'd1;
                        sec_bytes <= (sec_bytes == 8'hFF) ? sec_bytes : (sec_bytes + 8'd1);
                        case (sb)
                            16'd11: bps[7:0]     <= sd_data;
                            16'd12: bps[15:8]    <= sd_data;
                            16'd13: spc          <= sd_data;
                            16'd14: rsv[7:0]     <= sd_data;
                            16'd15: rsv[15:8]    <= sd_data;
                            16'd16: nfats        <= sd_data;
                            16'd36: fatsz[7:0]   <= sd_data;
                            16'd37: fatsz[15:8]  <= sd_data;
                            16'd38: fatsz[23:16] <= sd_data;
                            16'd39: fatsz[31:24] <= sd_data;
                            16'd44: rootclus[7:0]   <= sd_data;
                            16'd45: rootclus[15:8]  <= sd_data;
                            16'd46: rootclus[23:16] <= sd_data;
                            16'd47: rootclus[31:24] <= sd_data;
                            16'd510: sbsig[7:0]  <= sd_data;
                            16'd511: sbsig[15:8] <= sd_data;
                            // MBR partition table entries (only used when LBA 0
                            // turns out to be a partition table, see the check)
                            16'd450: p_type0 <= sd_data;
                            16'd454: p_lba0[7:0]   <= sd_data;
                            16'd455: p_lba0[15:8]  <= sd_data;
                            16'd456: p_lba0[23:16] <= sd_data;
                            16'd457: p_lba0[31:24] <= sd_data;
                            16'd466: p_type1 <= sd_data;
                            16'd470: p_lba1[7:0]   <= sd_data;
                            16'd471: p_lba1[15:8]  <= sd_data;
                            16'd472: p_lba1[23:16] <= sd_data;
                            16'd473: p_lba1[31:24] <= sd_data;
                            16'd482: p_type2 <= sd_data;
                            16'd486: p_lba2[7:0]   <= sd_data;
                            16'd487: p_lba2[15:8]  <= sd_data;
                            16'd488: p_lba2[23:16] <= sd_data;
                            16'd489: p_lba2[31:24] <= sd_data;
                            16'd498: p_type3 <= sd_data;
                            16'd502: p_lba3[7:0]   <= sd_data;
                            16'd503: p_lba3[15:8]  <= sd_data;
                            16'd504: p_lba3[23:16] <= sd_data;
                            16'd505: p_lba3[31:24] <= sd_data;
                            default: ;
                        endcase
                    end else if (sd_end) begin
                        if (sbsig != 16'hAA55) begin
                            err <= E_SIG; phase <= P_ERR; st <= S_ERR;
                        end else if ((bps == 16'd512) && (spc != 8'd0) &&
                                     (fatsz != 32'd0) && (rootclus >= 32'd2)) begin
                            // This LBA is a boot sector.  On the first pass that
                            // means a superfloppy layout (volume starts at LBA 0);
                            // on the second pass part_base is already the MBR
                            // partition start and must be kept.
                            if (!boot_pass) part_base <= 32'd0;
                            st <= S_PREP;
                        end else if (!boot_pass && mbr_any && (mbr_lba != 32'd0)) begin
                            // LBA 0 is a partition table: go read the volume's
                            // own boot sector at the partition's start LBA.
                            boot_pass <= 1'b1;
                            part_base <= mbr_lba;
                            req_done  <= 1'b0;
                            st        <= S_BOOT;
                        end else if (bps != 16'd512) begin
                            err <= E_BPS; phase <= P_ERR; st <= S_ERR;
                        end else begin
                            err <= E_NOTFAT32; phase <= P_ERR; st <= S_ERR;
                        end
                    end
                end

                // ---- data_start = rsv + nfats*fatsz ----------------------
                S_PREP: begin
                    mul_a   <= {8'd0, fatsz};
                    mul_b   <= {8'd0, nfats};
                    mul_acc <= {8'd0, part_base} + {8'd0, rsv};
                    mul_dst <= 2'd0;
                    mul_ret <= S_PREP_B;
                    st <= S_MUL;
                end

                // ---- root_lba = data_start + (rootclus-2)*spc ------------
                S_PREP_B: begin
                    mul_a   <= {12'd0, rootclus[27:0]} - 40'd2;
                    mul_b   <= {8'd0, spc};
                    mul_acc <= {8'd0, data_start};
                    mul_dst <= 2'd1;
                    mul_ret <= S_ROOT;
                    dir_sec <= 8'd0;
                    req_done <= 1'b0;
                    phase <= P_ROOT;
                    st <= S_MUL;
                end

                // ---- root directory scan ---------------------------------
                S_ROOT: begin
                    if (!req_done) begin
                        sd_lba <= root_lba + {24'd0, dir_sec};
                        sd_req <= 1'b1; req_done <= 1'b1; tmo <= 21'd0; retry <= 4'd0;
                        sb <= 16'd0; eb <= 6'd0; ent <= 256'd0; sec_bytes <= 8'd0;
                    end else if (sd_valid) begin
                        sb <= sb + 16'd1;
                        sec_bytes <= (sec_bytes == 8'hFF) ? sec_bytes : (sec_bytes + 8'd1);
                        ent <= {sd_data, ent[255:8]};
                        if (eb == 6'd31) begin
                            eb <= 6'd0;
                            if (ent_cnt == 8'd4) dbg_ent4 <= ent_n[31:0];
                            ent_cnt <= ent_cnt + 8'd1;
                            if (ent_b0 == 8'h00) begin
                                dir_stop <= 1'b1;
                            end else if (!ent_skip && (name_id < 3'd4)) begin
                                if (!found[name_id]) begin
                                    found[name_id]           <= 1'b1;
                                    f_first[name_id]         <= ent_clus[27:0];
                                    f_size[name_id]          <= ent_size;
                                end
                            end else if (!ent_skip && (name_id == 3'd4)) begin
                                // "MUSIC   WAV" is simply slot 4 of the same loop
                                if (!found[4]) begin
                                    found[4]   <= 1'b1;
                                    f_first[4] <= ent_clus[27:0];
                                    f_size[4]  <= ent_size;
                                end
                            end
                        end else begin
                            eb <= eb + 6'd1;
                        end
                    end else if (sd_end) begin
                        st <= S_ROOT_NEXT;
                    end
                end

                S_ROOT_NEXT: begin
                    dir_sec <= dir_sec + 8'd1;
                    if (dir_stop || ((dir_sec + 8'd1) >= spc)) begin
                        phase <= P_PICK;
                        st <= S_PICK;
                    end else begin
                        req_done <= 1'b0;
                        st <= S_ROOT;
                    end
                end

                // ---- choose the next bank --------------------------------
                S_PICK: begin
                    if (found == 5'b00000 && !pick_valid) begin
                        err <= E_NOFILE; phase <= P_DONE; st <= S_DONE;
                    end else if (!pick_valid) begin
                        phase <= P_DONE; st <= S_DONE;
                    end else begin
                        cid     <= pick_id;
                        cur_clu <= f_first[pick_id];
                        foff    <= 32'd0; sec_in_clu <= 8'd0;
                        bank_done <= 1'b0; discard <= 1'b0; req_done <= 1'b0;
                        mul_a   <= {12'd0, f_first[pick_id]} - 40'd2;
                        mul_b   <= {8'd0, spc};
                        mul_acc <= {8'd0, data_start};
                        mul_dst <= (pick_id == 3'd4) ? 2'd3 : 2'd2;
                        mul_ret <= (pick_id == 3'd4) ? S_WAVH : S_HDR;
                        phase <= P_CHAIN;
                        st <= S_MUL;
                    end
                end

                // ---- BMP header pass (first sector of the file) ----------
                S_HDR: begin
                    if (!req_done) begin
                        sd_lba <= cur_lba;
                        sd_req <= 1'b1; req_done <= 1'b1; tmo <= 21'd0; retry <= 4'd0;
                        sb <= 16'd0; sec_bytes <= 8'd0;
                    end else if (sd_valid) begin
                        sb <= sb + 16'd1;
                        sec_bytes <= (sec_bytes == 8'hFF) ? sec_bytes : (sec_bytes + 8'd1);
                        case (sb)
                            16'd0:  h_bm[7:0]     <= sd_data;
                            16'd1:  h_bm[15:8]    <= sd_data;
                            16'd10: h_offb[7:0]   <= sd_data;
                            16'd11: h_offb[15:8]  <= sd_data;
                            16'd12: h_offb[23:16] <= sd_data;
                            16'd13: h_offb[31:24] <= sd_data;
                            16'd18: h_w[7:0]      <= sd_data;
                            16'd19: h_w[15:8]     <= sd_data;
                            16'd20: h_w[23:16]    <= sd_data;
                            16'd21: h_w[31:24]    <= sd_data;
                            16'd22: h_h[7:0]      <= sd_data;
                            16'd23: h_h[15:8]     <= sd_data;
                            16'd24: h_h[23:16]    <= sd_data;
                            16'd25: h_h[31:24]    <= sd_data;
                            16'd28: h_bits[7:0]   <= sd_data;
                            16'd29: h_bits[15:8]  <= sd_data;
                            16'd30: h_comp[7:0]   <= sd_data;
                            16'd31: h_comp[15:8]  <= sd_data;
                            16'd32: h_comp[23:16] <= sd_data;
                            16'd33: h_comp[31:24] <= sd_data;
                            default: ;
                        endcase
                    end else if (sd_end) begin
                        st <= S_HDRC;
                        dv_job <= 2'd0; dv_run <= 1'b0;
                    end
                end

                // ---- validate + divide (nothing is streaming here) -------
                S_HDRC: begin
                    if (h_bm != 16'h4D42 || h_bits != 16'd24 || h_comp != 32'd0 ||
                        h_w == 32'd0 || (h_w[31:16] != 16'd0) ||
                        h_mag == 32'd0 || (h_mag[31:16] != 16'd0)) begin
                        err <= E_BMP;
                        f_bad[cid] <= 1'b1;
                        phase <= P_PICK;
                        st <= S_PICK;
                    end else if (!dv_run) begin
                        case (dv_job)
                            2'd0: begin
                                dv_a <= {8'd0, h_w[15:0]}; dv_b <= 24'd192; dv_q <= 24'd0; dv_run <= 1'b1;
                                img_w    <= h_w[15:0];
                                img_h    <= h_mag[15:0];
                                bottom_up <= ~h_h[31];
                            end
                            2'd1: begin dv_a <= {8'd0, img_h};        dv_b <= 24'd144; dv_q <= 24'd0; dv_run <= 1'b1; end
                            2'd2: begin dv_a <= {8'd0, img_h - 16'd1}; dv_b <= {8'd0, sy}; dv_q <= 24'd0; dv_run <= 1'b1; end
                            default: begin
                                // all divisions done: set up the data pass
                                offbits  <= h_offb;
                                row_pad  <= (16'd4 - ((({1'b0, img_w} << 1) + {1'b0, img_w}) & 16'd3)) & 16'd3;
                                racc     <= racc_init;
                                sel_row  <= sel_first;
                                brow     <= m_first;
                                emit_row <= sel_first && (m_first <= 16'd143);
                                px <= 16'd0; pbp <= 2'd0; col_acc <= col_init; k <= 9'd0;
                                src_row <= 15'd0; hi_valid <= 1'b0;
                                pad_left <= 16'd0; foff <= 32'd0;
                                req_done <= 1'b0;
                                phase <= P_DATA;
                                st <= S_FILE;
                            end
                        endcase
                    end else if (dv_a >= dv_b) begin
                        dv_a <= dv_a - dv_b;
                        dv_q <= dv_q + 24'd1;
                    end else begin
                        dv_run <= 1'b0;
                        dv_job <= dv_job + 2'd1;
                        case (dv_job)
                            2'd0: sx <= (dv_q == 24'd0) ? 16'd1 : dv_q[15:0];
                            2'd1: sy <= (dv_q == 24'd0) ? 16'd1 : dv_q[15:0];
                            default: begin q0 <= dv_q[15:0]; rem0 <= dv_a[15:0]; end
                        endcase
                    end
                end

                // ---- one data sector of the current cluster --------------
                S_FILE: begin
                    if (!req_done) begin
                        sd_lba <= cur_lba + {24'd0, sec_in_clu};
                        sd_req <= 1'b1; req_done <= 1'b1; tmo <= 21'd0; retry <= 4'd0;
                        sb <= 16'd0; sec_bytes <= 8'd0;
                    end else begin
                        if (sd_valid) begin
                            sb <= sb + 16'd1;
                            sec_bytes <= (sec_bytes == 8'hFF) ? sec_bytes : (sec_bytes + 8'd1);
                            foff <= foff + 32'd1;
                            if (!discard && (foff >= offbits)) begin
                                if (pad_left != 16'd0) begin
                                    pad_left <= pad_left - 16'd1;
                                end else begin
                                    case (pbp)
                                        2'd0: begin pb <= sd_data; pbp <= 2'd1; end
                                        2'd1: begin pg <= sd_data; pbp <= 2'd2; end
                                        default: begin
                                            // R arrives: the pixel is complete
                                            //
                                            // Full-resolution copy (C2, four of
                                            // them since C9): EVERY picture goes
                                            // 1:1 into its own HI region, so the
                                            // album mode can show any of the four
                                            // pixel for pixel instead of the
                                            // 192x144 sampler's output.
                                            if ((cid < 3'd4) && !hi_valid &&
                                                (px < HI_W) && (hi_y < HI_H)) begin
                                                hi_data  <= {sd_data[7:3], pg[7:2], pb[7:3]};
                                                hi_addr  <= HI_BASE + hi_blk + hi_off
                                                            + {5'd0, px[9:0]};
                                                hi_valid <= 1'b1;
                                            end
                                            // sampled 192x144 copy used by the
                                            // window/desktop path
                                            if (emit_row && col_hit && (k <= 9'd191)) begin
                                                if (!hold_valid) begin
                                                    hold_data  <= {sd_data[7:3], pg[7:2], pb[7:3]};
                                                    hold_addr  <= pic_addr;
                                                    hold_valid <= 1'b1;
                                                end
                                                k  <= k + 9'd1;
                                            end
                                            pbp     <= 2'd0;
                                            col_acc <= col_hit ? (col_sum - {1'b0, img_w}) : col_sum;
                                            if (px == (img_w - 16'd1)) begin
                                                // row complete: book-keep the next row
                                                px       <= 16'd0;
                                                src_row  <= src_row + 15'd1;
                                                col_acc  <= col_init;
                                                k        <= 9'd0;
                                                pad_left <= row_pad;
                                                racc     <= racc_hit ? (racc_sum - {1'b0, img_h}) : racc_sum;
                                                sel_row  <= racc_hit;
                                                brow     <= m_sel;
                                                emit_row <= racc_hit && (m_sel <= 16'd143);
                                                // C9: EVERY picture keeps reading until
                                                // its LAST source row, because all four
                                                // now have a 1:1 copy (the sampled
                                                // 192x144 copy finishes a bit earlier).
                                                // Before C9 only cid 0 fell through here;
                                                // the other three stopped after the 144
                                                // sampled rows and their 1:1 copies lost
                                                // the bottom of the photo.
                                                if ({1'b0, src_row} + 16'd1 >= img_h) begin
                                                    bank_done <= 1'b1;
                                                    discard   <= 1'b1;
                                                end
                                            end else begin
                                                px <= px + 16'd1;
                                            end
                                        end
                                    endcase
                                end
                            end
                        end
                        if (sd_end) st <= S_FILE_NEXT;
                    end
                end

                S_FILE_NEXT: begin
                    if (bank_done) begin
                        bank_ok[cid] <= 1'b1;
                        phase <= P_PICK; st <= S_PICK;
                    end else if (discard) begin
                        f_bad[cid] <= 1'b1;
                        phase <= P_PICK; st <= S_PICK;
                    end else if ((sec_in_clu + 8'd1) >= spc) begin
                        sec_in_clu <= 8'd0;
                        req_done <= 1'b0;
                        phase <= P_CHAIN;
                        st <= S_FAT;
                    end else begin
                        sec_in_clu <= sec_in_clu + 8'd1;
                        req_done <= 1'b0;
                        st <= S_FILE;
                    end
                end

                // ---- FAT sector for the current cluster -------------------
                S_FAT: begin
                    if (!req_done) begin
                        // the FAT lives inside the volume too, so part_base applies
                        sd_lba <= {16'd0, rsv} + {11'd0, cur_clu[27:7]} + part_base;
                        sd_req <= 1'b1; req_done <= 1'b1; tmo <= 21'd0; retry <= 4'd0;
                        sb <= 16'd0; sec_bytes <= 8'd0;
                        fat_off <= {9'd0, cur_clu[6:0]} << 2;
                        fat_val <= 32'd0;
                    end else if (sd_valid) begin
                        sb <= sb + 16'd1;
                        sec_bytes <= (sec_bytes == 8'hFF) ? sec_bytes : (sec_bytes + 8'd1);
                        if ((sb >= fat_off) && (sb < (fat_off + 16'd4))) begin
                            fat_val <= {sd_data, fat_val[31:8]};
                        end
                    end else if (sd_end) begin
                        st <= S_FAT_NEXT;
                    end
                end

                S_FAT_NEXT: begin
                    // fat_val now holds {b3,b2,b1,b0} of this cluster's entry
                    if (fat_val[27:0] >= 28'hFFFFFF8) begin
                        if (bank_done) bank_ok[cid] <= 1'b1;
                        else begin
                            err <= E_CHAIN;
                            f_bad[cid] <= 1'b1;
                        end
                        phase <= P_PICK; st <= S_PICK;
                    end else if (fat_val[27:0] < 28'd2) begin
                        err <= E_CHAIN;
                        f_bad[cid] <= 1'b1;
                        phase <= P_PICK; st <= S_PICK;
                    end else begin
                        cur_clu <= fat_val[27:0];
                        sec_in_clu <= 8'd0;
                        mul_a   <= {12'd0, fat_val[27:0]} - 40'd2;
                        mul_b   <= {8'd0, spc};
                        mul_acc <= {8'd0, data_start};
                        mul_dst <= 2'd2;
                        mul_ret <= S_FILE;
                        req_done <= 1'b0;
                        st <= S_MUL;
                    end
                end

                // ---- (a-2)*spc / nfats*fatsz, 1 bit per cycle ------------
                S_MUL: begin
                    if (mul_b == 16'd0) begin
                        case (mul_dst)
                            2'd0: data_start <= mul_acc[31:0];
                            2'd1: root_lba   <= mul_acc[31:0];
                            2'd2: cur_lba <= mul_acc[31:0];
                            default: wav_lba <= mul_acc[31:0];
                        endcase
                        st <= mul_ret;
                    end else begin
                        if (mul_b[0]) mul_acc <= mul_acc + mul_a;
                        mul_a <= {mul_a[38:0], 1'b0};
                        mul_b <= {1'b0, mul_b[15:1]};
                    end
                end

                // ---- MUSIC.WAV: check the canonical 44-byte header ----------
                S_WAVH: begin
                    if (!req_done) begin
                        sd_lba <= wav_lba;
                        sd_req <= 1'b1; req_done <= 1'b1; tmo <= 21'd0; retry <= 4'd0;
                        sb <= 16'd0; wsb <= 16'd0; wfb <= 2'd0; req_done <= 1'b1;
                        hdr_ok <= 1'b1;
                    end else if (sd_valid) begin
                        case (sb)
                            16'd0:  if (sd_data != 8'h52) hdr_ok <= 1'b0;   // 'R'
                            16'd1:  if (sd_data != 8'h49) hdr_ok <= 1'b0;   // 'I'
                            16'd8:  if (sd_data != 8'h57) hdr_ok <= 1'b0;   // 'W'
                            16'd9:  if (sd_data != 8'h41) hdr_ok <= 1'b0;   // 'A'
                            16'd20: if (sd_data != 8'h01) hdr_ok <= 1'b0;   // PCM
                            16'd22: if (sd_data != 8'h02) hdr_ok <= 1'b0;   // 2 ch
                            16'd24: if (sd_data != 8'h80) hdr_ok <= 1'b0;   // 48000 = 0xBB80
                            16'd25: if (sd_data != 8'hBB) hdr_ok <= 1'b0;
                            16'd34: if (sd_data != 8'h10) hdr_ok <= 1'b0;   // 16 bit
                            16'd36: if (sd_data != 8'h64) hdr_ok <= 1'b0;   // 'd'
                            16'd37: if (sd_data != 8'h61) hdr_ok <= 1'b0;   // 'a'
                            16'd38: if (sd_data != 8'h74) hdr_ok <= 1'b0;   // 't'
                            16'd39: if (sd_data != 8'h61) hdr_ok <= 1'b0;   // 'a'
                            16'd40: wtmp[7:0]   <= sd_data;
                            16'd41: wtmp[15:8]  <= sd_data;
                            16'd42: wtmp[23:16] <= sd_data;
                            16'd43: wtmp[31:24] <= sd_data;
                            default: ;
                        endcase
                        sb <= sb + 16'd1;
                    end
                    if (sd_end) begin
                        if (!hdr_ok || wtmp < 32'd1024) begin
                            // no usable WAV: leave music_frames at 0 -> synth
                            music_ok <= 1'b0; err <= 8'd9; bank_ok[4] <= 1'b1; phase <= P_PICK; st <= S_PICK;
                        end else begin
                            words_left <= (wtmp >> 2 > 21'h1C0000) ? 21'h1C0000 : wtmp[20:2];
                            // S_WAVD re-reads this sector and skips the 44-byte
                            // header, so no PCM frame is lost at the join
                            wav_first_sec <= 1'b1;
                            sb <= 16'd0; wfb <= 2'd0; req_done <= 1'b0;
                            st <= S_WAVD;
                        end
                    end
                end

                // ---- MUSIC.WAV: sectors straight into SDRAM words ----------
                // Bytes arrive at ~780 kB/s (one every ~32 pixel clocks), so a
                // single hold register is enough to ride out wr_rdy.
                S_WAVD: begin
                    if (!req_done) begin
                        sd_lba <= wav_lba;
                        sd_req <= 1'b1; req_done <= 1'b1; tmo <= 21'd0;
                        sb <= 16'd0;
                    end else if (sd_valid) begin
                        sb <= sb + 16'd1;
                        // the file's first sector carries the 44-byte header and
                        // everything after it is word aligned, so skipping 44
                        // bytes once is enough
                        // stop exactly at the declared data length (the file
                        // is sector padded, so the tail would add ~13 frames)
                        if (!(wav_first_sec && (sb < 16'd44)) && (words_left != 32'd0)) begin
                            case (wfb)
                                2'd0: wtmp[7:0]   <= sd_data;
                                2'd1: wtmp[15:8]  <= sd_data;
                                2'd2: wtmp[23:16] <= sd_data;
                                default: begin
                                    // WAV_CAP keeps the audio below the
                                    // full-resolution picture copy at HI_BASE;
                                    // past the cap the pass keeps reading (so the
                                    // sector bookkeeping stays simple) but stops
                                    // writing, and music_frames stops growing.
                                    if (!hold_valid && (music_frames < WAV_CAP)) begin
                                        hold_data  <= {sd_data, wtmp[23:16], wtmp[15:8], wtmp[7:0]};
                                        hold_addr  <= music_frames;
                                        hold_valid <= 1'b1;
                                    end
                                end
                            endcase
                            wfb <= wfb + 2'd1;
                        end
                    end
                    if (sd_end) begin
                        wav_lba       <= wav_lba + 32'd1;
                        wav_first_sec <= 1'b0;
                        req_done      <= 1'b0;
                        if (words_left == 32'd0) begin
                            music_ok <= 1'b1; bank_ok[4] <= 1'b1; phase <= P_PICK; st <= S_PICK;
                        end
                    end
                end

                S_DONE: phase <= P_DONE;                S_ERR:  phase <= P_ERR;
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
