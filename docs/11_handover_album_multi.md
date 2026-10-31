# 交接：相册模式放 4 张 1:1 图（C9 / 任务 A）

> ✅ **2026-10-31 16:5x：任务 A 已实现并上板。** 实际做法、踩到的坑（`cur_blk` 也要 17 bit、
> 陈旧 TB `tb_carousel`、TB 卷四张底图必须不同）、时序/面积、板级数字都写在
> `docs/10_album_plan.md` 的 **「C9」** 一节；本文档保留当时的任务书与验收口径。
> 剩下的只有操作员目视验收（§12 最后两条）。

> 这份文档是给**新会话**的。你不需要读上一轮的对话，只要读这里 + 它指向的文件。
> 上一轮的完整实现记录在 `docs/10_album_plan.md`（C2a..C8），**先花十分钟扫一遍它的
> 「状态一览」和 C8 一节**，再动手。

---

## 0. 一句话任务

把相册（全屏）模式从**只能显示 CAM1 一张**，改成**CAM1..CAM4 四张、都能按键切换、都是
1:1 像素**。代价：MUSIC.WAV 的容量从 1.25 M 字缩到 ~620 k 字（约 26 s → 约 13 s）。

---

## 1. 现状（2026-10-31 15:5x，交接时）

| 项 | 状态 |
|---|---|
| 两片板在跑 | `build/td_A/WALL_A.bit` / `td_B/WALL_B.bit`（C8 版：接缝第一列已修） |
| 时序 | A 25 MHz **+0.888** / 150 MHz **+0.130**；B **+0.284** / **+0.582**，0 违例 |
| 面积 | A：LUT 12802(65%)、BRAM 31/64、DSP 14/29；B：LUT 8467(43%) |
| 回归 | 14 个 TB 全 PASS（`tb_tf_load` / `tb_wav` 需读 `tb/*.hex`） |
| 板上身份 | **cable 0 = A（有卡）、cable 1 = B** —— 和 `build/build.ps1` 里写死的 `A=1/B=0` **相反** |
| 相册模式 | SW4 上拨（C7 换过：SW4=全屏，SW1+SW2+SW3=亮度/对比度），进出各 16 帧淡入淡出 |

---

## 2. 目标行为（验收口径）

1. 加载器上电后把 **CAM1..CAM4 四张**都按 640×480 1:1 写进 SDRAM 的四个独立区域；
2. 相册模式（SW4）显示**其中一张**，居中跨缝、1:1、左右黑边，和现在一样；
3. 相册模式下 **KEY3 = 上一张、KEY4 = 下一张**（两个键可以反过来，你觉得顺就行），
   切换**瞬间**生效（不要求淡入淡出；想加也行，见 §8 可选）；
4. B 板跟着切（页码随窗口表广播，**不需要改链路协议**）；
5. 桌面的四张缩略图、轮播、亮度对比度、UI/静音、拔线降级**全部不变**；
6. 全套 TB 仍然 PASS，`tb_tf_load` 必须**逐字**比对 4 张 1:1 拷贝（不是抽查）。

---

## 3. SDRAM 新地址表（推荐「正好用满」版）

总容量 **2,097,152 字**（21 位地址，APUG011 = 2M×32）。

| 区域 | 地址 | 大小 | 说明 |
|---|---|---|---|
| MUSIC.WAV | 0 … **619,519** | 619,520 | 2.478 MB ≈ 48 kHz 立体声 16 bit **12.9 s** |
| **HI0 (CAM1)** | **619,520** … 926,719 | 307,200 | 1:1 拷贝 |
| **HI1 (CAM2)** | 926,720 … 1,233,919 | 307,200 | |
| **HI2 (CAM3)** | 1,233,920 … 1,541,119 | 307,200 | |
| **HI3 (CAM4)** | 1,541,120 … 1,848,319 | 307,200 | |
| 四张缩略图 | **1,848,320** … 2,097,151 | 4 × 62,208 = 248,832 | 槽间隔仍是 62,208（只用了前 27,648） |

`619,520 + 4×307,200 + 4×62,208 = 2,097,152` —— **正好用满**，没有空隙。

> **为什么缩略图要挪**：不挪（保持 1,700,000）的话，四份 1:1 拷贝塞不进去，
> 音乐只能留 400,000 字（8.3 s）。挪一次多 4.6 s 音乐，代价是改 5 处常量（见 §4.1），
> 全是机械改动。**如果你更想少改代码，就用「缩略图不动、WAV=400,000」的版本**，
> 其余步骤完全一样。
>
> **自检**：`wall_sdram_test` 实际是从地址 0 开始写读 1,024 字的（不是 README 里写的
> 1,966,080，那是旧记录），它在 `sdram_test_done` 之前完成，之后装载器才会写 WAV，
> 所以不冲突。**不要**把自检区算进上面的表。

---

## 4. 逐文件改动清单

### 4.1 常量（5 个文件，必须一致）

| 文件 | 改什么 |
|---|---|
| `rtl/wall_tf_load.v` | `pic_base()` 里 4 个 `21'd17xx` → 1,848,320 / 1,910,528 / 1,972,736 / 2,034,944（= 1,848,320 + n×62,208）；`HI_BASE` → **619,520**；`WAV_CAP` → **619,520**（正好等于 HI_BASE，注释里那句 "WAV 必须在 HI_BASE 以下" 仍然成立）；`hi_addr` → `HI_BASE + cid*307200 + hi_off + px` |
| `rtl/wall_img_push.v` | `PIC0` → 1,848,320；`HIB` → 619,520；新增 `HI_STRIDE = 307200`；`BLK_HI` → 起 4 份（`HI_N=4`） |
| `rtl/wall_img_recv.v` | 同上三个常量（两边必须一模一样） |
| `rtl/wall_pic_line.v` | `PIC0` → 1,848,320；`HIB` → 619,520；新增 `HI_STRIDE` |
| `rtl/wall_top.v` | `B_HI_BLOCKS` 6,912 → **83,712**（见 §6）；`img_rx_got` 要加宽（见 §6） |

> `PIC_STRIDE = 62208` **不要动**（缩略图槽间隔不变，只是整体挪了基址）。

### 4.2 加载器写四份 hi（`rtl/wall_tf_load.v`）

1. 第 ~684 行：`if ((cid == 3'd0) && !hi_valid && (px < HI_W) && (hi_y < HI_H))`
   → 去掉 `(cid == 3'd0) &&`，地址改成 `HI_BASE + {cid,18'b0}*…`（用 `cid * 307200`，
   例：`HI_BASE + ({18'd0, cid} * 21'd307200) + hi_off + px`）；
2. 第 ~725 行「picture 0 要多走一会儿」那段（`if ((cid == 3'd0) && (src_row + 1 >= img_h))`）
   → 改成对**所有 cid** 都生效：`if (src_row + 1 >= img_h) begin bank_done <= 1; discard <= 1; end`，
   把外面 `if (sel_row && emit_row && m_done)` 里的 `if (cid != 3'd0)` 保护也一并简化。
   **这一条最要紧**：现在只有 cid0 会读到图底，其余三张在 144 个保留行后就 `bank_done`，
   不放开的话三张 1:1 拷贝会缺下半部分。
3. `bank_ok[cid]` 的置位时机要和「该 cid 的 1:1 拷贝写完」对齐 —— 放开后天然满足，
   但**要在上板时确认**：A 的 `hi_ready` 现在取 `tf_bank_ok[0]`，改成**四张都完成**才置位
   （`&tf_bank_ok[3:0]`），否则相册可能在只有一张就绪时显示另一张。

### 4.3 页码要写进窗口表（协议不用改）

相册记录的 `rsv` 是 `[63:58]`，现在只用 bit58 做 `frameless`。新增 **`[60:59] = pic_idx[1:0]`**：

```
ALBUM_REC = {2'b00, idx[1:0], 1'b1,   // [63:61] [60:59] 页码 [58] frameless
             4'd0, 3'd0, 1'b0, 2'd3, 4'd0, 10'd480, 10'd1023, 12'd0, 12'd0};
```

`wall_input` 每次写记录时高 6 位填 0（`{6'd0, wid, ...}`），所以只有相册时序器能设这几位；
`wall_album_seq` 的 `ALBUM_REC` 里 `idx` 变成一个寄存器。

**B 板自动跟随**：窗口表每帧整份广播（STATE 帧 bytes 5..36），不用加任何字段。

### 4.4 取图源按页码选（`rtl/wall_pic_line.v`）

现在是「`w[2]` 为 1 → `HIB`」。改成：

```verilog
// 25 MHz 侧（请求扫描那一段）算好基址，和现在算 req_base 的方式一样：
wire        fw  = tbl[sch*64 + 58];
wire [1:0]  idx = tbl[sch*64 + 59 +: 2];
wire [20:0] base = fw ? (HIB + ({19'd0, idx} * 21'd307200))
                      : (PIC0 + sch * PIC_STRIDE);
```

**不要**把页码塞进 `rd_win`（那是行缓冲槽号，只有 2 bit）。现在的做法是 25 MHz 侧把
`req_base[心]` 算好、150 MHz 侧只做 4 选 1 —— 保持这个结构，只是把 `req_addr()` 换成上面这段。
`req_last` 不用变（还是 639 / 191）。

### 4.5 相册模式下按键切图（`rtl/wall_input.v` + `rtl/wall_album_seq.v`）

- `wall_input`：`else if (album) begin ... end` 这个分支（第 ~421 行）现在**所有键都不响应**。
  加两个单周期脉冲输出 `alb_next` / `alb_prev`（照抄 VIEW 分支里的边沿检测写法：
  `ev3_d`/`ev2_d` 那种），**不要**在这个分支里写表（表归时序器）。
  映射建议：KEY4 = 下一张、KEY3 = 上一张。
- `wall_album_seq`：新增输入 `nxt`/`prv`，内部 2 bit `idx` 寄存器。状态 `S_ALBUM` 里收到脉冲就
  **重写一次相册记录**（4 个时钟，和现有 `S_SWAP` 一样的写法，但只写 slot0；
  或者干脆 4 条都重写，复用 `swap_data`）。不要求淡入淡出。
- `wall_top`：把这两个脉冲从 `wall_input`（g_master）接到 `wall_album_seq`。B 板上这两个信号拉 0。

### 4.6 「就绪」判断（`rtl/wall_top.v`）

```verilog
wire        hi_ready  = (IS_MASTER != 0) ? (&tf_bank_ok[3:0]) : b_hi_ready;
```
（现在是 `tf_bank_ok[0]`：只等 CAM1。）

---

## 5. 链路：区域表从 5 个涨到 8 个

现在：区域 0..3 = 四张缩略图，区域 4 = 唯一的 1:1 拷贝（`BLK_HI = 19,200` 块）。

改成：**区域 4..7 = HI0..HI3**，每块 16 字、每区 19,200 块：

```verilog
// wall_img_push / wall_img_recv
localparam integer BLK_4PIC = 4 * BLK_PER_BANK;          // 6,912
localparam integer BLK_ALL  = BLK_4PIC + 4 * BLK_HI;     // 83,712
// 区域解码（现在是 4 个阈值 + "region 4"，要扩成 8 段）
wire [2:0] region_n = (cur_blk >= BLK_4PIC) ? (3'd4 + (cur_blk - BLK_4PIC) / BLK_HI) : ...;
```
`region`/`bank` 字段在字节 0 里占 3 bit（`{5'b0, region[2:0]}`），**够用，不用改帧格式**；
块号仍是 15 bit（19,200 < 32,768），字节 1/2 不变。

地址：`pic_base(region) = (region >= 4) ? HIB + (region-4)*307200 : PIC0 + region*PIC_STRIDE`。

---

## 6. ⚠️ 一个容易漏的坑：`img_rx_got` 会溢出

`wall_img_recv` 的 `got` 是 **16 bit**，每收一块 +1。一整轮现在是 26,112，改成 **83,712** ——
**超过 65,535 会绕回**，B 的 `b_hi_ready` 就永远等不到。

改法（任选一）：
- 把 `got` 加宽到 **17 bit**（`output reg [16:0] got`，`wall_top` 的 `img_rx_got` 跟着加宽）；
- 或者让接收器自己出一个「四个 HI 区都收过一轮」的 sticky 标志。

推荐前者，改动最小。**改完记得把 `B_HI_BLOCKS` 设成 83,712**（`wall_top` 里现在的 6,912/26,112）。

---

## 7. TB 改动

| TB | 改什么 |
|---|---|
| `tools/make_tb_fat32.py` | `expected_hi.hex` 从 307,200 字变成 **4 × 307,200 = 1,228,800 字**（约 8.6 MB）。嫌大就只生成 CAM1 和 CAM3 两份（各 2.15 MB），TB 里比对这两张 —— 但要在文件头写清楚"另外两张只验证地址，不验证内容" |
| `tb/tb_tf_load.v` | 按新的 `expected_hi.hex` 分段比对；同时检查四张的**地址不重叠** |
| `tb/tb_img_link.v` | `BLK_HI`、区域数、跳转点（现在跳的是 1,728/3,456/5,184/6,912/26,110）→ 改成 8 个区域边界 + 结尾 83,711 |
| `tb/tb_pic_line.v` | hi 突发改成从 `HIB + idx*307200` 取；加一段 idx=2 的用例 |
| `tb/tb_album.v` | 相册记录的 `ALBUM_REC` 字面量要带 idx；断言 `step=65536 / dw=640 / dh=480` 不受 idx 影响 |
| `tb/tb_album_tbl.v` | `ALBUM_REC` 字面量 + 断言：切页后 `cur_tbl` 的 `[60:59]` 变成新页码，且**其余 63 bit 不变** |
| 新增（建议） | `tb_album_page.v`：给 `wall_album_seq` 喂 next/prev 脉冲，断言页码 0→1→2→3→0 回绕、且只在 `S_ALBUM` 里响应 |

跑法见 `docs/10_album_plan.md` 的「怎么跑这套 TB」一节（`sim_c3` + `run.ps1`，`tb_tf_load`
要读 `tb/*.hex`，需要一个 `tb` 目录链接）。

---

## 8. 可选（不做也行）

- **切页也走淡入淡出**：复用 `S_FADE_O → S_SWAP → S_SETTLE → S_FADE_I` 那条路径，
  把「换表」变成「只换 slot0 的页码」。会多 533 ms，但和进出相册的手感一致。
  代价是 `wall_album_seq` 的状态机要区分"换页"和"进出"。
- **页码显示在 HUD 上**：相册模式现在 HUD 是关的；可以在切页后 1 秒内显示一行
  "ALBUM 2/4"，然后自动消失（`wall_hud` 里已经有类似的时间控制）。
- **把 `hi_ready`/`pic_ready`/页码塞进状态帧**：`byte 19`（`img_chk_err`）现在恒 0，
  可以放 `{5'b0, idx[1:0], hi_ready}`，这样从串口就能看出"相册为什么没图"。

---

## 9. 这一轮踩过的坑（**重要，别重复**）

1. **绝对不要用 `Get-Content -Raw | Set-Content` 改含中文的文件**（PS 5.1 会按 ANSI 解码再
   按 ANSI 写回，中文变成 `?`，不可逆 —— 已经把 `README.md` 和 `wall_top.v` 各毁过一次）。
   **改文件只用 edit/write 工具**；改完用「按 UTF-8 解码是否报错」验一遍。
2. **TD 比 ModelSim 严格**：新写 RTL 先跑一次 TD，常见两类错：
   - `HDL-8007 concurrent assignment to a non-net`：被子模块输出驱动的信号要声明成 `wire` 不是 `reg`；
   - `net 'xxx' is constantly driven from multiple places`：同一个 reg 在两个 always 里赋值。
3. **TD 的布局是确定性的**：同样的网表每次得到同样的余量。所以「余量负了」重跑没用，
   要**改网表**（这一轮的 −0.112 就是给 `y_target` 打一拍解决的）。偶尔会出现
   `RUN-8102/PHP-8023` 布线失败，那个**是** flaky，重跑能过。
4. **烧录**：`tools/flash_pair.ps1` 的 `-cable` 默认值和现在的枚举是**反的**。
   用 `tools/probe_flash.ps1 -Flash`（它按电缆 0 烧 A、1 烧 B），或者先 `-VerifyOnly`
   看"哪块有卡"再决定。**一次 TD 调用只烧一块板**。
5. **JTAG 偶发 `USB device open error`**：先给板子断电重上电 / 拔插一次 USB，
   **不要**去改 Windows 的安全设置（上一轮为此白改了三处，最后全还原了）。
6. **25 MHz 域的余量很薄**（C8 之后 +0.284 ~ +0.888，但历史上出现过 −0.1）：
   任何加到 `x → 窗口求值 → z 选择 → 内容/HUD` 这条链上的逻辑，都要先重建看 STA。
7. **「行起点」类信号要按"首像素前 N 拍"算**（C8 的教训，见 `docs/10_album_plan.md` C8）：
   有输出寄存器的渲染器里，`de` 上升沿已经太晚。

---

## 10. 构建 / 烧录 / 验证命令

```powershell
cd C:\Users\japsa\Documents\deepseek-harness\default-workspace\wall

# 仿真（先建库；tb 要读 tb/*.hex，所以要么在 wall/ 下跑，要么给库目录做 tb 链接）
cd sim_c3; vlog -work work <rtl...> <tb...>; vsim -c -do "run -all; quit -f" tb_tf_load

# 构建（两片；A 偶尔会 RUN-8102，重跑即可）
powershell -ExecutionPolicy Bypass -File build\build.ps1 -Role both
# 看余量：build/td_A/final_timing.rpt、build/td_B/final_timing.rpt 的 Clock Summary 段

# 烧录 + 自检（按 cable 0=A、1=B）
powershell -ExecutionPolicy Bypass -File tools\probe_flash.ps1 -Flash
powershell -ExecutionPolicy Bypass -File tools\probe_flash.ps1        # 读 node/link/gx/win_w/win_h
```

板级验收：
1. 上电后等 `phase=6`（约 5~8 s，四张 1:1 拷贝比现在慢一倍左右）；
2. 桌面四张缩略图、轮播、亮度/对比度、UI/静音、拔线降级都要和现在一样；
3. SW4 上拨 → 全屏照片 1:1；**KEY4/KEY3 切页**，四张都能看，接缝那一列要对齐；
4. B 那半屏要等一整轮（83,712 块）才会跟着切；
5. 两片 `probe_flash.ps1` 读回来 `link=1 sync=1`。

---

## 11. 状态写回哪里

- `docs/10_album_plan.md`：**新增 `## C9 —— 四张 1:1 相册` 一节**（做法、踩坑、时序/面积、
  板上验收结果），并把顶部「状态一览」表更新；
- `README.md`：按键表里补「相册模式下 KEY3/KEY4 切页」；时序表加一行 C9；
  目录树里如果新增 TB 也补上；
- `docs/01_spec.md`：**窗口记录 `[60:59]` 现在是 `pic_idx`**（原来写的是 rsv 全 0），
  这是冻结接口，必须先改它再改 RTL（spec 第 3.1 节）。

---

## 12. 交付判据

- [x] `tb_tf_load` 逐字比对 4 张 1:1 拷贝全对（不是抽查）—— `1228800/1228800`
- [x] 其余 13 个 TB 全 PASS —— C9-R1 后回归 **22 个全 PASS**（原 14 + `tb_tf_load_mbr` + 新增 `tb_album_page` + 修好位宽后重新纳入的 `tb_carousel`）
- [x] A/B 两片 STA 全正、0 违例（把两片的 25/150 MHz 余量记下来）—— A +0.265 / +0.518，B +0.504 / +0.247
- [x] `build.ps1 -Role both` 通过（A 可能要重跑一次）—— 这一次一次过
- [x] 两片烧录后 `phase=6`、`link=1 sync=1`
- [ ] 板上：四张都能切、接缝对齐、桌面功能无回归 —— **待操作员目视**（KEY4/KEY3 切页时串口 byte19 会跟着变）
- [x] 文档写回（§11）
