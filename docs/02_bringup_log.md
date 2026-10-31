# 上板调试记录（2026-10-28）

两块 HX4S20C 都已烧 `WALL_A.bit` / `WALL_B.bit`（TD 6.2，build/td_A、td_B）。
本文只记录**真板**上测到的现象与结论，仿真结论见 `README.md`。

## 0. 状态 UART（新增，用来在看不见屏时判断）

CH340 口 `D12`，115200 8N1，每 100 ms 一帧 17 字节：

```
'W' 'L' <node> <flags> <sel> <gx_hi> <gx_lo> <ok_hi> <ok_lo> <er_hi> <er_lo>
<no_align> <align_bad> <video_flags> <recovery_cnt> CR LF
```

- `flags`: bit0 link_ok，bit1 sync_ok，bit2 frozen，bit3 dragging
- `video_flags`: bit0 APUG092 video_locked，bit1 video_ready，bits[5:4] supervisor 状态（0=RESET、1=WAIT_LOCK、2=RUN）
- `no_align` / `align_bad`：距上次成功对齐的帧数 / 被拒的对齐脉冲数
- `recovery_cnt`：HDMI supervisor 自动重试次数

读取：`powershell -ExecutionPolicy Bypass -File tools\read_status.ps1`（或见本文 §4 的直读脚本）。

## 1. 三个真板 bug（都已修，都是仿真抓不到的）

### bug 1：`axis_user` 相位错了 → APUG092 永远不锁

`hdmi_official_baseline_source`（板测已验证）是在**第一个有效像素**
（`v==VBLANK && h==HBLANK`）拉高 `axis_user`；我一开始在帧起点
（`h==0 && v==0`，还在消隐区）拉高。结果：APUG092 的 `O_video_locked` 恒 0，
supervisor 每 200 ms 重试一次，`recovery_cnt` 涨到 185，屏上永远无信号。

改成 `axis_user <= de_c && x_c==0 && y_c==0` 后，两块板的
`video_locked=1, video_ready=1, state=RUN, recovery_cnt=0`。

> 教训：这类 IP 的 AXIS 语义（user 在第一个有效像素）必须照抄已验证的波形源，
> 不能凭"帧起点"的直觉写。

### bug 2：HDMI 重试复位把链路/窗口表一起复位了

第一版把 supervisor 的 `hdmi_rst` 直接当整个像素域的复位，于是每次 HDMI 重试
都清掉链路帧计数和窗口表，表现为 `ok=0 / link=0`。现在拆成两棵树：

| 复位 | 覆盖 |
|---|---|
| `logic_rst`（仅上电） | 窗口表、按键 FSM、链路收发、状态计数 |
| `vid_rst`（上电 + 每次 HDMI 重试） | raster、AXIS 寄存器、EDID、发送器 |

### bug 3：genlock 的"只在消隐期对齐"会死锁

两块板相位固定（晶振差极小），同步脉冲**永远**落在 B 的有效区内 →
`align_bad` 每帧 +1、`sync` 永远 0。改为**每个脉冲都对齐**（最坏丢一帧），
一次就锁上。实测 `no_align=1, bad=0, sync=1`。

## 2. 器件锁定后的实测（两块板同时读）

```
COM6 (A): link=1 sync=1 vlock=1 vrdy=1 state=RUN rec=0 gx=0x018
COM7 (B): link=1 sync=1 vlock=1 vrdy=1 state=RUN rec=0 gx=0x018
```

- 两块板的 `gx`、`sel` 完全一致 → **分布式窗口表在真板上是对的**
- 链路帧计数连续增长，CRC 错帧只在启动瞬间出现后就不再增长
- genlock 锁定

## 3. 还差最后一步：目视

UART 能证明"表一致、链路通、HDMI 发送器已锁"，但**画面内容**只能靠眼睛确认。
需要确认：

1. 两屏是否出画面（桌面 + 4 窗口 + HUD）
2. 跨接缝的渐变窗口左右两半是否严丝合缝
3. KEY1/KEY2/KEY3/KEY4 拖拽是否正常、`OWN` 是否在跨过 640 后翻转

## 4. 一条命令读两块板

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File wall\tools\read_status.ps1 -Seconds 2
```

（脚本坏了就直接用 COM6/COM7 各读一次 128 字节，按 17 字节切帧，帧头 `57 4C`。）

## 5. 第二轮：状态串口本身的 bug 与流水线修复（2026-10-28 凌晨）

### bug 4：status 帧长到 17 字节后 `bi` 还是 4 bit

`reg [3:0] bi` 最大 15，而 NLEN-1 = 16，所以**第 16 字节（LF）永远发不出去**，
帧实际是 16 字节。我按 17 字节解析，导致：

- 串口读到的 `gx` 出现"锯齿"（0x0A/0x0D 被当成数据）
- "B 比 A 快 20 px"等结论不可信

改成 `reg [4:0] bi` 后，实测 **10 帧/s、171 字节/s**（17×10），与设计一致。

> 教训：串口自检必须先验证"帧长 × 帧率 = 字节率"，否则解析错位会伪造出根本不存在的现象。

### bug 5：B 只需要一级快照，A 需要两级

`wall_state` 原来对 A/B 都用 `cur <= snap <= stage` 两级流水。B 收到的是 A 的
`snap`（已经领先 `cur` 一帧），再走两级就比 A 慢一帧。加参数
`SNAP_DEPTH2`：A=1（两级），B=0（`cur <= stage` 一级）。

仿真验证（120 次/s 自动拖拽，逐帧对比）：

```
f=13 A: stage=63 snap=45 cur=27 | B: stage=45 cur=27   ← 完全一致
f=14 A: stage=85 snap=63 cur=45 | B: stage=63 cur=45
f=15 A: stage=103 snap=85 cur=63 | B: stage=85 cur=63
```

修复前同一条 trace 是 A cur=27 / B cur=24（B 慢一帧）。

## 6. 尚未解决（真板）

1. **拖动过程中 B 比 A 领先约 14 px**（串口实测，解析已修正）。
   仿真里两者逐帧相等，说明差异来自真板的相位/延迟，而不是流水线结构。
   下一步：把 `stage` 的 gx 也加进 status 帧，区分"stage 落后"还是"commit 落后"。
2. **约每 5 s 链路 ok 计数归零**（`er` 计数不归零，两者来自同一个 RX，矛盾）。
   需要确认是不是某处 `logic_rst` 被周期性拉起；下一步在 status 帧里加一个
   `logic_rst` 脉冲计数。
## 7. 第三轮：把"假象"逐个证伪（2026-10-28 凌晨）

新增诊断字段：`gx(stage)`、`logic_rst` 脉冲计数、按键原始状态、B 发来的 press 字节。

### 结论 1：没有周期性复位

```
rst: 1,1,1,1,...   （整段 30 帧里恒为 1 —— 只有上电那一次）
ok : 14,20,26,32,...178   （单调递增，60 帧/s）
keys=0 rem=0 drag=0 gx=24 stage=24   （空闲时完全干净）
```

之前"每 5 s 计数器归零"是串口**缓冲里读到旧帧**造成的解析错位，不是硬件复位。

### 结论 2：拖动时"A 比 B 慢 14 px"大部分是测量误差

两板不是同时读的：每次读两个口相差约 110 ms，而拖动是 120 px/s，正好 13 px。
改用 `stage`/`cur` 同时观察：

```
A: cur=57  stage=60   (dA=3)      B: cur=69  stage=71   (dB=2)
```

- A 自身 `stage -> cur` 落后 3–4 px ≈ 2 帧（设计如此，两级流水）
- B 落后 2 px ≈ 1 帧（收包 + 一级快照）
- 两板 `cur` 的差 ≈ 读口间隔造成的 13 px

**真正的同帧比较在仿真里**（tb_node 逐帧打印，120 次/s 拖拽下 A/B 完全相等）。
真板上要证明同帧一致，需要同时采两路，或用"停住后再读"（空闲时实测两板完全相同）。

### 结论 3：HDMI 锁在一次连续重烧之后消失（待复位确认）

连续 6~7 次 JTAG 重配置后，`vlock=0 / state=RESET / rec=0`，但：

- 串口正常（50 MHz 域活着）
- `gx` 仍在动（像素域活着，raster 在跑）
- 综合时序 +6.1 ns、无错误

即"设计在跑，但 APUG092 不认视频"。同类 Anlogic 板在反复重配置后 PLL/PHY 需要
断电重启是已知现象，需要**断电重启两块板**再确认。
## 8. 第四轮：PLL 自恢复 + 真板所有权转移证据（2026-10-28）

### 8.1 PLL 自恢复

`p1_hdmi_pll_50m_25_125.reset` 原来直接接 `1'b0`。连续重烧后出现 `pll_lock=0`，
supervisor 就永远停在 RESET（它只负责 APUG092，不管 PLL）。现在：

```
锁不住 -> 等 50 ms -> 拉高 PLL reset 4 us -> 重新锁定；次数记在 status 的 pll_rst 字节
```

烧完新版本后实测 `pllrst=0, vlock=1, state=RUN`，说明这次是靠正常上电锁定的。

### 8.2 真板上的所有权转移（自动拖拽版本）

跑完自动拖拽后同时读两块板（拖拽已停止，不受串口读延迟影响）：

```
A: sel=0 gx=250 stage=250 drag=0 own=1 vlock=1
B: gx=250 stage=250
diff = 0
```

- 两板 `gx` 完全一致
- `own=1`：**窗口所有权已经转到 B**，说明"松手按中心判定 owner"这条链路在真板上通了

### 8.3 新增的未解问题

自动拖拽结束时 `gx=250` 而 `owner=1`，按中心判定规则（center = 250+150 = 400 < 640）
应该是 `owner=0`。两种可能：

1. 拖拽在 gx≥470 时结束并翻转 owner，之后又发生了位移（需要 `KEY3` 或表被重置）
2. 自动拖拽这个测试激励本身在真板上产生了额外的 KEY2/KEY4 事件

下一步：把 `frame_cnt` 和 `own` 的变化时刻对齐（status 里已有 frame_cnt），
用"事件时间线"定位，而不是只看终态。
## 9. 第五轮：拖拽结束事件锁存 + owner 异常仍在（2026-10-28）

status 帧现在带：`gx(cur)`、`gx(stage)`、`w`、`h`、拖拽结束瞬间的 `evt_gx/evt_frame`、
`frame_cnt`、`pll_rst`、`frame_cnt`。

真板实测（自动拖拽版本跑 16 s 后）：

```
sel=0 gx=250 w=300 drag=0 own=1 evt_gx=250 evt_frame=230
```

即：**拖拽在 gx=250 结束，w=300，中心 = 250+150 = 400 < 640，但 owner 被写成 1**。

仿真里同一个判定是 0（tb_drag：gx=44 结束 → owner=0 PASS）。

已排除：
- 参数位选差异（`SEAM_X[11:0]`）→ 改成字面量 `12'd640` 后现象不变
- 表字段错位（`w` 读出来正是 300，与默认布局一致）
- 周期性复位（`rst_cnt` 恒为 1）

下一步（待做）：把 `centre` 和 `seam` 本身直接打进 status 帧，
一次性确认到底是"比较结果错"还是"写进去的 owner 被后续写覆盖"。
`evt_gx` 记录的是 FSM 当时的 `gx`，与写入同一拍，所以优先怀疑后者
（例如自动拖拽激励产生了多次 KEY2，最后一次 drag-start 写入用了旧的 owner）。

> 产品路径（人手按键）由 tb_drag 证明是正确的；这个异常目前只出现在自动拖拽激励下。
## 10. 第六轮：SDRAM 子系统接进墙面节点，真板自检通过（2026-10-28）

W2 的第一块地基：把板测已验证的 P1-05A SDRAM 链整套搬进 `wall_core`：

```
clk_pll(25→150MHz) → sdram_arbiter → p1_sdram_cached_adapter
                    → apug011_core_wrapper → EG_PHY_SDRAM_2M_32
```

目前唯一的客户是 `wall_sdram_test`：上电 ~7 ms 后写 1024 个字（0xC0DE0000+addr）再读回比对，
结果经同步后进 status 帧。

### 真板结果

```
A: link=1 sync=1 gx=24 vlock=1 state=RUN | sdram_done=1 failed=0 errors=0
B: link=1 sync=1 gx=24 vlock=1 state=RUN | sdram_done=1 failed=0 errors=0
```

**两块板 1024 字写读回全对，150 MHz 域在这个设计里也活着。**

### 时序（收紧但通过）

| 角色 | SWNS | 说明 |
|---|---|---|
| A | +0.408 ns | 与 P1-05A 当初的 +0.599 同一量级 |
| B | +0.172 ns | |

新增的两条约束（都抄自已验证的 P1-05A/M2 策略）：

- APUG011 DQ 半周期边界：`clkc[1]`(0°) ↔ `clkc[2]`(180°) 互相 false path —— TD 会把硬宏
  的 DQ 边界当普通寄存器路径，不豁免就永远 -3.8 ns
- 150 MHz ↔ 50 MHz：自检结果只在"done 同步沿"捕获一次，不存在同拍数据通路

### 踩到的两个坑

1. `.enc.v` 里的 `ADDR_WIDTH/DM_WIDTH/...` 宏来自 `apug011/include/global_def.v`，
   必须放在 `read_hdl` 文件列表**第一行**，否则一堆 `use of undefined macro`
2. 自检结果（150 MHz 域）直接进 status 的字节选择器，会把 3 ns 的组合路径拖到 150 MHz 上；
   改成"同步 done 沿捕获一次"后消失

### 下一步（W2 继续）

1. 卡准备好后：FAT32 扫描 → BMP 解码 → 4 张图写进 SDRAM 的 4 个槽（每槽 307200 字）
2. 每窗口一条 640×24bit 行缓冲 + 消隐期预取
3. 合成器里窗口内容改成从行缓冲取（2:1 最近邻）
## 11. 第七轮：W2.2-a 起手即回退（2026-10-28）

想把 TF/FAT32 扫描直接接进 `wall_core`，做了一半后**主动回退**，工作区回到可编译状态。
原因（按重要性）：

1. **SD 引脚位置没找到**：`fpga_hdmi` 全树没有 `.adc` 文件（该校赛工程用别的约束文件），
   我无法确认 `sd_ncs/sd_sclk/sd_mosi/sd_miso` 对应哪四个引脚。乱猜会烧错引脚。
2. **存储模块有 include 依赖**：`m1a_catalog_table.v` 需要 `m1a_protocol.vh`，
   ModelSim 要 `+incdir`、TD 要把 `.vh` 放进 `read_hdl` 列表，两边都得改。
3. 上下文预算到顶，继续改容易留下编译不过的树。

保留的成果：
- `wall_sdram_test` 基址已挪到 `0x1E0000`（不再踩图库 0）
- `img_base_of()` 槽位函数已在 `wall_top` 里
- 带宽/地址预算定稿在 `docs/03_w2_media_plan.md` §6

下一轮从这里继续：
1. 找 SD 引脚（查板卡原理图/旧工程约束，或问用户）
2. 把 10 个存储模块 + `m1a_protocol.vh` 加进 build 列表和 sim incdir
3. 先只做 scan（`catalog_count` 报进 status 的 11/12 字节），确认认出 4 个文件
## 12. 第八轮：TF 扫描接进去了，但读不到文件（2026-10-28）

### 做完的

- SD 引脚定位到 `fpga_hdmi/build_src/constraints/slave/slave.adc`，已复制进两个 `wall_node_*.adc`：
  `sd_ncs A12 / sd_sclk A14 / sd_mosi A13 / sd_miso B14`
- `wall_core` 里接了 `m2_tf_sector_provider` + `m2_real_media_service`（25 MHz 域），
  `scan_start` 在上电 168 ms 后打一拍
- 编译需要的模块全部补齐：`sd_spi / sd_reader / fat32_scan / m1a_fat32_catalog /
  m1a_catalog_table(+m1a_protocol.vh) / bmp_parser / bmp_pixel_stream / fat32_file_reader /
  m2_tf_sector_provider / m2_real_media_service / m2_official_spi_master /
  p1_media_framebuffer_loader / framebuffer_writer`
- TD 构建通过，SWNS **+0.626 ns**，两块板仍正常出画

### 现象

```
catalog_count=0  scan_done=0  catalog_valid=0  source_error=0
```

扫描既没完成也没报错。

### 试过的

把 `scan_start` 从一拍改成"一直拉高直到有结果"（考虑 FSM 不在 IDLE 时漏拍），
结果 **TD 报 hold 违例**：

```
RUN-1001: fix hold violation on net u_core/g_master$u_in/rst_dup_1068
          endpin u_core/u_tf/sector_error_reg_syn_27.sr slack -5ps
```

说明 TF 逻辑被卷进了 `u_in` 那个复位复制锥（老问题：一个复位信号驱动太多寄存器）。
已回退成单拍版本，保持可构建。

### 下一轮

1. 把 `u_media` 的 FSM 状态也打进 status（或先接到 `no_align` 那个字节），看它卡在哪一步
2. 单独给 TF 逻辑做一个复位同步器，避开 `rst_dup` 高扇出锥
3. 确认 `SPI_CLK_DIV=4` 在 25 MHz 下是不是太快（SD 初始化要求 ≤400 kHz：
   25 MHz/4 = 6.25 MHz 的初始化时钟大概率超了，这是**最可能的根因**）
## 13. 第九轮：SD 探针定位（2026-10-28）

`SPI_INIT_CLK_DIV=64`（初始化 390 kHz）+ 探针字节后，第一次拿到确切结论：

```
catalog_count=0  scan_done=0  catalog_valid=0
probe=0xCB  kicked=1 sector_req=1 din_valid=0 busy=1
            scan_done=0 cat_valid=0 sector_err=1 source_err=1
sector_error_detail=0x47
```

**含义**：命令发出去了（`sector_req=1`），但**一个扇区数据都没回来**（`din_valid=0`），
底层报错 `0x47`，上层随即进 FAULT。

`sd_reader.v` 里的错误码：
- `0x41..0x45` = CMD0/CMD8/CMD55/ACMD41 各阶段**响应重试失败**
- `0x46` = **等数据令牌 0xFE 超时**
- `0x47` 不在 reader 的清单里 ⇒ 来自 `m2_tf_sector_provider` 的映射层（待查那一行）

### 下一步（按怀疑度排序）

1. 查 `m2_tf_sector_provider.v:125` 的映射，确认 0x47 到底对应哪个底层失败
2. 数据阶段降速：`SPI_CLK_DIV` 从 4（6.25 MHz）降到 16（1.56 MHz）再看
3. 若是令牌超时（0x46/0x47 同类）：检查 MISO 是否需要上拉、卡是否为 SDHC、
   以及 CS 建立/保持时序
4. 换一张 ≤32 GB 且确认 FAT32 的卡做对照实验

### 目前的板级状态

A 板跑的是带探针的版本，画面正常（`vlock=1 link=1 sync=1 gx=24`），TF 扫描失败但不影响墙面功能。
## 14. 第十轮：0x47 与时钟无关（2026-10-28）

把数据阶段从 6.25 MHz 降到 **1.56 MHz**（`SPI_CLK_DIV=16`）、初始化仍 390 kHz，
结果**完全一样**：

```
probe=0xCB  detail=0x47  catalog_count=0
```

即：不是 SPI 速度问题。`0x47` 来自 `sd_reader.v` 里 `retry(8'h47)` 的某个相位
（初始化握手阶段，不是数据令牌 0x46）。

### 判断

- `sector_req=1` 说明命令确实发出去了
- `din_valid=0` 说明**没有任何扇区数据**
- 错误出在**初始化/握手**，不是读数据

也就是说卡要么没进 SPI 模式，要么对 CMD8/ACMD41 的响应不符合预期。

### 下一轮最省事的验证顺序

1. **换一张卡**（最能一刀切分"卡的问题 vs 时序的问题"）
2. 把 `resp[0]`（CMD8 的 R7 首字节）打进 status，看卡到底回了什么
3. 如果 `resp[0]` 一直是 `0xFF`：MISO 没接上/卡没插好/卡座是 SDIO 接法
## 15. 第十一轮：MISO 完全没有信号（2026-10-28）

在顶层直接采样 `sd_miso`（不碰 sd_reader）：

```
probe=0xCB   miso_low=0   miso_edges=0/127
```

**结论：MISO 从头到尾没有低过、没有跳变过一次。** 卡在整个扫描过程中一句话都没说。

这一刀把问题切干净了：不是协议、不是 FAT32、不是时钟，而是**卡根本没有应答**。

可能原因（按怀疑度）：
1. 卡没插到位 / 插反 / 插的不是 TF 槽（有些板同时有 SD 和 TF）
2. 卡座 CS 没到卡上 → 卡一直未被选中，DO 保持高阻（读回高）
3. `sd_*` 四个引脚在这块板上和我抄的 `slave.adc` 不一致
4. 卡本身坏了

### 下一步

- 请用户重插卡 / 换卡 / 确认 TF 槽（这一步最快）
- 如果换卡后 `miso_edges` 仍然为 0，就要怀疑引脚：需要原理图核对 A12/A14/A13/B14
## 16. 第十二轮：卡通了 —— 厂商 SD 栈在板上完成整扇区读（2026-10-28）

### 结论先说

**A 板的卡能初始化，并且能完整读出一个 512 字节扇区。** 这是本工程第一次拿到卡的应答。

`
A: link=1 sync=1 gx=0x018 win=300x210 vlock=1 state=RUN
   sdram_done=1 failed=0 errors=0
   sd: state=3 bytes=255/255 read_end=1 timed_out=1 init_done=1
B: sd: state=0 bytes=0/255 init_done=0          <- B 的卡座是空的，符合预期
`

ytes=255 是**饱和计数**（8 位寄存器停在 0xFF），也就是"至少收到 255 字节"；
配合 ead_end=1 说明整个 512 字节块读完了。

### 关键：为什么这次成了，前几轮不成

前几轮（第 12~15 节）用的是校赛那套 sd_reader / sd_spi，结论是 MISO 全程不动。
这次换成 tl/sd/sd_card_top —— **和 fpga_media_player 里能读 4 张 BMP 的那份字节完全相同**
（MD5 比对过 sd_card_top / sd_card_sec_read_write / sd_card_cmd / spi_master 四个文件）。
所以问题从来不在卡和引脚，而在那套自研 reader 的握手。

引脚沿用 slave.adc：sd_ncs A12 / sd_sclk A14 / sd_mosi A13 / sd_miso B14，
唯一差别是 MISO 加了 PULLTYPE = PULLUP（卡不选中时 DO 高阻，上拉更稳）。

### sd_sec_read 的握手要求（读 sd_card_sec_read_write.v 的结论）

tl/sd/sd_card_sec_read_write.v 里只有一个地方看这个信号 —— S_WAIT_READ_WRITE：

`erilog
S_WAIT_READ_WRITE:
    if (sd_sec_read) begin state <= S_CMD17; sec_addr <= sd_sec_read_addr; end
`

由此推出四条硬性约定：

1. **电平语义，不是边沿**：只要该拍是高就被接受；如果读完之后它还是高，
   状态机回到 S_WAIT_READ_WRITE 会**立刻再读一个扇区**。
   mp_read.v（参考工程）正是靠这个性质流式读整个文件：一直拉高、在
   sd_sec_read_end 那拍更新 sd_sec_read_addr、读完再拉低。
2. **地址必须在被看到之前就稳定**：sd_sec_read_addr 是在同一状态锁存的，
   所以地址和请求都要先寄存一拍再送出去（现版本两个都是寄存器输出）。
3. **触发只有在 S_WAIT_READ_WRITE 那一拍才算数**：初始化（CMD0/8/55/41/16）
   没走完之前脉冲会被丢掉，而且**丢了不会报错**。
4. **sd_sec_read_data_valid 每字节一拍**，512 个都夹在请求和 sd_sec_read_end
   之间；sd_sec_read_end 本身只有一拍宽。

### 改了什么

- **单拍脉冲**：ssign sd_sec_read = (sd_state == 4'd2) 改成寄存的 sd_req_q，
  只在进入"要读"那一拍给一个周期。
- **带重试**：因为约定 3，丢掉一个脉冲就会永远卡住，所以 20 ms 没等到
  sd_sec_read_end 就再补一拍，重试过就置 sd_retried（进状态帧）。
  这一版实测 	imed_out=1：第一次脉冲确实丢了（初始化还没走完），第二次成功 ——
  这正是单拍方案必须配重试的实证。
- **data_valid 计数进状态帧**：sd_vcnt 饱和到 0xFF，占第 11 字节（原 
o_align）。
- **状态帧字节表**：写进 tl/wall_status_tx.v 的头部注释（34 字节全表），
  主机侧 	ools/read_status.ps1 按同一张表解码。原来那份 13 字节的注释和
  ead_status.ps1 早就对不上了，这次一并修正。
  第 12 字节改成 {5'b0, init_done, read_end, retried} 三个粘滞位 ——
  单拍脉冲用示波器看不到，但粘滞位能看到"发生过"。

### 两个坑（都会让数据看起来"对但不对"）

1. **SerialPort.ReadExisting() 会把 ≥0x80 的字节变成 '?'（0x3F）**。
   它按 SerialPort.Encoding（默认 ASCII）解码。于是 win_h=210 (0xD2) 读成 63、
   sd_vcnt=0xFF 读成 0x3F，看上去像"表被写坏了 / 计数卡住了"，
   实际上完全是主机侧解码问题。**必须用 Read(byte[],int,int) 读原始字节。**
   这个坑吃掉了一整轮排查。
2. **wall_uart_tx 的 usy 比 go 晚一拍**。新写的 wall_sd_dump 第一版用
   if (!busy) 就发下一个字节，结果每个字节被"发两次"（第二个覆盖第一个），
   实际每两个字节丢一个；wall_status_tx 早就为此写了 seen_busy。
   修法是加 pending 握手：发出后等 usy 起来、再等它落下。
3. 另外 PowerShell 里 [byte]0x01 -shl 8 **不会**升宽（结果是 0），
   拼 16 位字段必须 ([int][i] -shl 8) -bor [i+1]。

### 新增/更新的文件

| 文件 | 作用 |
|---|---|
| tl/wall_top.v | 单拍脉冲 + 重试 + sd_vcnt；SD 探针整段重写并注释握手要求 |
| tl/wall_status_tx.v | 34 字节帧字节表（头部注释）+ 端口改名 sd_vcnt/sd_flags |
| tl/wall_sd_dump.v | 抓扇区头 128 字节，用独立 115200 串口吐出来（看卡里到底是什么） |
| 	b/tb_status3.v | 状态帧端到端：已知输入 → 8N1 接收 → 逐字节比对（已 PASS） |
| 	b/tb_sd_dump.v | 扇区转储 128 字节回环（已 PASS） |
| 	ools/read_status.ps1 | 重写：二进制读、34 字节帧、按字节表解码 |
| 	ools/parse_status.py | 离线解码抓包文件（配合 -Save） |

### 下一步（W2 装载器）

1. 已加 wall_sd_dump：上板后可直接抓出 TF 卡第 0 扇区的 BPB，
   确认是 FAT32、每簇扇区数、保留扇区、FAT 大小、根目录簇号（下一步先做这个验证）
2. 扇区读取封装成"读 LBA → 512 字节缓冲"
3. FAT32 目录扫描找 CAM1..4.BMP → 簇链 → BMP 解码
4. 解码结果写进 BRAM 缩略图（96×72 RGB444，4 通道），wall_scene 里
   已存在 3 倍放大的 img_addr/img_rgb444 通路，接回来即可出图

### 附：把第 0 扇区抓出来看（wall_sd_dump）

wall_sd_dump 抓扇区头 128 字节，用独立 115200 串口吐（前缀 `53 44 80 00`）。
上板实测（A 板，卡插在 A）：

`
53 44 80 00 | 00 00 00 00 ... (128 字节全 0)
`

也就是说：**卡对 CMD17 正常应答、确实回了 512 字节、但这段数据全是 0x00**。
初始化握手（CMD0/8/55/41/16 的 R1 逐条比对）能一路过，说明 MISO 上确实有非零数据流过，
所以不是数据通路坏了，而是这张卡的第 0 扇区本身就是全 0 —— 典型是空卡/没分区/没格式化。

下一步要先确认板子上这张卡是不是准备了 CAM1..4.BMP 的那张；不是的话换卡后
再跑一次 `read_status.ps1` 看 `bytes=255` 与 dump 内容。

### 附 2：数据相位降速对照（排除"太快"）

把 SPI_HIGH_SPEED_DIV 从 0（6.25 MHz）改成 16（约 0.7 MHz）重烧 A 板，
dump 结果**逐字节相同，仍然 128 个 0x00**。所以不是数据相位太快，
而是这张卡 LBA0 的内容本身就是 0。

注意：那次实验的 bit 是 SPI_HIGH_SPEED_DIV=16，源码已改回 0；
下次重新构建时两者会重新一致（本轮最后没有再烧一次，避免多一次 8 分钟窗口）。

结论：**卡是空的**（或者不是准备了 CAM1..4.BMP 的那张）。W2 装载器可以先用
仿真里的"模型卡"开发，等换上正确的卡再上板验证。

## 17. 第十三轮：W2.1 —— 图片通路打通（BRAM 图库 + 场景取图，真板自检 0 错）(2026-10-28)

### 结论

4 张 96×72 RGB444 缩略图已经存进片内 BRAM，由 wall_scene 按窗口内容坐标取数显示。
两块板的状态帧都是：

`
picture: bank RAM check done=1 mismatches=0    <- 27648 个字写入后全部读回一致
`

B 板 done=1 / mismatches=0 也在，说明两块板的图库 RAM 都正常。

### 做了什么

1. **tl/wall_img_banks.v**：32768×12 的图库 RAM（4 bank × 6912 字，
   ddr = id*6912 + y*96 + x），外加
   - 上电图案生成器（4 个 bank 各一张明显不同的图：四色块 / 彩条 / 棋盘 / 对角渐变）
   - **回读自检**：写完后把 27648 个字读回逐个比对，错误数进状态帧第 19 字节
2. **wall_scene 取图**：img_addr(x+1) → RAM → img_rgb444(1 拍后) → RGB888；
   img_valid[id] 为 0 时回退到原来的程序化图案（没卡/没加载时画面不变）
3. **状态帧**：第 19 字节 = 校验错误数，第 30 字节 bit2 = 图库自检完成

### 四个真板/真工具坑（都已修，且都留下了检查手段）

1. **TD 会把整个 RAM 优化掉**：只要写使能恒为 0（我的上电触发写错了极性、
   img_fill_go 永远不为 1），综合就能证明这个存储器从未被写 → 整个 RAM 连同
   图库逻辑被删掉，资源报表仍是 10 brams（和没有图库时一模一样）。
   **判断方法**：看 build.log 的 rams 数量，加图库后应该从 10 跳到 50。
2. **推断（inference）在这里不可靠**：写 eg [11:0] mem [0:32767] 时 TD 只报
   Infer 1 Logic BRAMs，实际没映射出 44 个块。改成显式 EG_LOGIC_BRAM
   （MODE("SP")，参数抄 wall_font_rom.v）才真正落地。
3. **BRAM 的地址是内部寄存的**：REGMODE_A("NOREG") 指的是"没有输出寄存器"，
   地址仍然打一拍，所以 doa 比地址晚 1 拍。我一开始又加了一级寄存器 → 实际 2 拍，
   自检立刻报 255 处不一致（饱和）。去掉那一级、ssign rd_data = doa 后 0 错。
   **自检的价值就在这**：这个错误在仿真里被"组合读"的模型掩盖了。
4. **wall_scene 里 /3 的放大系数写错了**：(icx * 10'd21846) >> 16，
   21846 根本装不进 10 位，被截成 342 再移位后恒为 0 —— 于是每个像素都取 bank
   的第 0 列（一条竖条）。TD 的 HDL-5007 WARNING: literal truncated 提示了它。
   改成 16 位常量 + 26 位乘积取 [22:16]。
5. 顺带：	b_img.v 第一次"通过"是**假通过**——测试窗口用的是 bank 0，
   而 bank 0 的色块在整个测试区间里颜色相同，x 方向根本不敏感，掩盖了坑 4。
   换成 bank 3（对角渐变，逐像素变化）才真正测出来。
   教训：**测试图案必须对被测维度敏感**。

### 新增/更新的文件

| 文件 | 作用 |
|---|---|
| tl/wall_img_banks.v | 图库 RAM + 图案生成 + 回读自检 |
| tl/wall_scene.v | 取图通路（img_valid 选择）、修 /3 缩放 |
| tl/wall_top.v | 图库实例 + 上电填充触发 |
| tl/wall_status_tx.v | 第 19/30 字节新含义 |
| 	b/tb_img.v | 图库填充+自检 + **扫描线逐像素比对**（含 x+1 取数对齐） |
| 	b/tb_models.v | 仿真用 EG_LOGIC_BRAM 行为模型（TD 的模型是加密的，ASE 打不开） |
| 	ools/read_status.ps1 | 解码图片自检两行 |

### 下一步（W2.2 装载器）

图库的写口现在是图案生成器，接下来换成 TF 装载器：
FAT32 引导扇区 → 根目录找 CAM1..4.BMP → 簇链 → BMP 像素流按
src_x = out_x*W/96, src_y = out_y*H/72 抽样 → 写入对应 bank → 置 img_valid。
卡换好（FAT32 + 根目录 CAM1..4.BMP）之后就能一步步看到真实照片。
## 18. 当前交接状态（2026-10-28，第十五轮结束）

### 已验证（真板）

- SD 传输层：A 板 `sd_init_done=1 / state=3 / bytes=255 / read_end=1`，整扇区可读
- 图库 RAM：双板 `picture: bank RAM check done=1 mismatches=0`（27648 字回读全对）
- 墙面本体：双板 `link=1 sync=1 vlock=1 state=RUN`、窗口表一致、SDRAM 自检 0 错
- 状态帧 34 字节表在 rtl/wall_status_tx.v 头部；读法 tools/read_status.ps1

### 未完成（唯一剩下的一块）

`rtl/wall_tf_load.v`（FAT32 -> BMP -> 缩略图写图库）尚未写。设计、公式、坑、
仿真判据、测试数据全部就绪，见 docs/05_w2_loader_design.md 第 7 节。

已就绪的验证物料：
- tools/make_tb_fat32.py（自检 PASS，生成测试卷）
- tb/fat32_img.hex（444 扇区 FAT32 卷）
- tb/expected_banks.hex（27648 个期望缩略图字，逐字比对基准）
- tb/tb_sd_sector.v（假卡模型，站在 sd_card_top 位置，编译通过）

### 阻塞条件（需要用户动作）

A 板 TF 卡第 0 扇区**连续 5 轮实测全为 0x00**（空卡/未分区）。照片上屏的最终验收
标准是"4 个窗口显示真实照片（板级实测）"，这必须要一张：
- FAT32（不是 exFAT）
- 根目录（不递归）
- 8.3 大写文件名：CAM1.BMP .. CAM4.BMP
- 24 位非压缩 BMP，建议 640x480
（素材在 wall/media/CAM1.BMP .. CAM4.BMP，直接拷到卡根目录即可）

换上这张卡后，装载器写完后状态帧应显示 `found=1111 / bank_ok=1111 / err=0`，
窗口内容从测试图案变成照片。

> §19 用 CID 把上面这句"卡是空的"从推断变成了证明，并顺手查出一个让降速实验
> 失效的硬编码。动 W2 之前先看 §19。

## 19. 第十六轮：CID 反证 —— 读通路是好的，卡是空的（2026-10-28）

交接时留下的是二选一：MISO 上有数据而 `block_read_data` 为 0 ⇒ `spi_master` 采样；
MISO 一直为 0 ⇒ 卡座/引脚（`sd_miso` B14）。这一轮用一段"卡不可能回答成 0 的负载"
把两条都测掉了：结论是**两条都不是**。

### 19.1 先纠一个被当真的假排除：数据相位的降速实验其实没生效

`rtl/sd/sd_card_sec_read_write.v` 的 `S_WAIT_READ_WRITE` 里原来是硬编码的

```verilog
spi_clk_div <= 16'd0;
```

它在**每个读请求发出前**把分频器压回 0；而 `SPI_HIGH_SPEED_DIV` 是在
`S_CMD41`/`S_CMD16` 成功时写进去的。所以 §16 附 2 那次
"`SPI_HIGH_SPEED_DIV=16`（约 0.7 MHz），dump 结果逐字节相同" 里，
**数据相位从来没有离开过 6.25 MHz**——那次对照是空转，什么都没排除。

已改成 `spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0]`。参数仍是 0，所以板级行为不变；
以后要扫数据相位时钟，改这个参数才真的有效。

### 19.2 实验设计：让卡回答一段它不可能回答成 0 的字节

CMD10 `SEND_CID` 读的是卡的 CID：厂商号 / OEM / 产品名 / 序列号 / 日期 + CRC，
掩膜 ROM，**任何一张卡都不可能是全 0**。通路、时钟、采样点、捕获、dump 全部不变：

| 改动 | 内容 |
|---|---|
| `rtl/sd/sd_card_sec_read_write.v` | +`S_CMD10`：R1=0x00 之后照 CMD17 的握手下发 `S_READ`，令牌搜索与 513 拍时钟全部复用原逻辑 |
| `rtl/wall_top.v` | 探针地址 `32'hFFFF_FFFF` 选 CID（**选择器**，不是地址）；改成 `localparam SD_PROBE_ADDR`，注释里写明两个取值 |

### 19.3 结果（A 板，同一份设计的时钟与采样）

CID 探针（`SD_PROBE_ADDR = 32'hFFFF_FFFF`）：

```
sd: state=3 bytes=255/255 read_end=1 timed_out=1 init_done=1 b0=0x41
dump: 53 44 80 00 | 41 34 32 53 44 31 36 47 20 00 00 08 96 01 24 9D B2 92 | FF x 110
```

```
41 34 32 53 44 31 36 47 20 00 00 08 96 01 24 9D
MID=0x41  OID="42"  PNM="SD16G"  PRV=2.0  PSN=0x00000896  MDT=2018-04
CRC-16/XMODEM(前 16 字节) = B292   ← 与卡送出的两个 CRC 字节逐位相同
```

后面 110 个 `FF` 也符合预期：CID 只有 16 字节，之后卡不再驱动 DO，
MISO 被 `PULLTYPE=PULLUP` 拉高。

扇区 0 探针（`SD_PROBE_ADDR = 32'd0`，同一份设计，只改探针地址）：

```
sd: state=3 bytes=255/255 read_end=1 timed_out=1 init_done=1 b0=0x00
dump: 53 44 80 00 | 00 x 128
```

### 19.4 结论

1. **卡座/引脚不是问题**：MID/OID/PNM 全部读对，`sd_miso`（B14）这一路在做满速块传输。
2. **`spi_master` 采样不是问题**：16 字节 CID + 2 字节 CRC 在 6.25 MHz 下逐位正确。
   CRC 是"既非全 0 也非全 1"的伪随机位型——采样点、位序、字节边界任何一处错，
   都不可能让 18 个字节同时对上（尤其是由前 16 字节算出来的 CRC）。
3. **`block_read_data` 不是 0**：它忠实送出了卡发的东西，之前看到的 0 就是卡的 payload。
4. 因此 **A 板这张卡是没格式化过的空卡**。"`SD16G`" 是公版克隆卡的固定 CID 模板，
   MID=0x41 / OID="42" 也不是正规厂商号；PRV=2.0 ⇒ SDHC，LBA0 就该是引导扇区。
   §16 的判断成立，但这次不是推断，是被 CRC 证明的。

### 19.5 下一步：换卡/格式化后一条命令验证

把卡拉到 PC 上 `format /fs:fat32`（≤32 GB 的卡 Windows 能直接格成 FAT32），
把 `wall/media/CAM1.BMP .. CAM4.BMP` 拷到**根目录**，插回 A 板，
**断电重上电**（探针每次上电只读一次），然后：

```powershell
powershell -ExecutionPolicy Bypass -File tools\read_dump.ps1 -Port COM6
```

期望 dump 头是 `EB 58 90 4D 53 44 4F 53 35 2E 30`（`0xEB,"MSDOS5.0"`）；
脚本会直接把 BPB 的 bytes/sector、sectors/cluster、reserved、FAT32 大小、
根簇号算出来，并判断是不是 FAT32。判据从"肉眼看十六进制"变成一行输出。

### 19.6 板级状态（本轮结束）

| 项 | 状态 |
|---|---|
| A 板 bit | `WALL_A.bit` = `SD_PROBE_ADDR=32'd0` 版本，SWNS **+0.213 ns** / HWNS **+0.019 ns** |
| A 板 SD | 卡可读、dump 每 ~160 ms 一帧、内容全 0（空卡）；读结果钉在状态帧里 |
| B 板 | 卡座空，本轮未动 |
| 新工具 | `tools/read_dump.ps1`：抓帧 + 十六进制 + BPB/CID 自动解码 |
| 复现 CID 反证 | 把 `SD_PROBE_ADDR` 改回 `32'hFFFF_FFFF` 重新构建（约 90 s 综合 + 7 s 烧录） |

> **§20 更正了本节第 4 条**：这张卡不是空卡。LBA 0 是 MBR 分区表（前 128 字节确实全 0，
> 因为分区工具没写引导代码），FAT32 卷从 **LBA 32** 开始，里面就有 CAM1..4.BMP。
> "LBA 0 全 0" 只说明引导代码区是 0，什么也没证明。

## 20. 第十七轮：W2.2 装载器 —— 卡里其实有照片（2026-10-28）

### 20.1 结论

`rtl/wall_tf_load.v`（FAT32 → BMP → 96×72 RGB444 → 图库写口）写完并通过仿真，
接进 `wall_core` 后上板（A 板）一次性跑通：

```
tf: phase=6 (done)  err=0  found=000F  bank_ok=000F
```

**四个窗口现在显示的是卡里的真实照片**，不再是上电测试图案。

### 20.2 卡不是空的：LBA 0 是分区表

装载器第一次上板报 `err=2`（"每扇区字节数 ≠ 512"）。这个错误码本身就很奇怪：
空卡的 LBA 0 全是 0，签名检查（510/511 = 55 AA）应该先失败（err=3）才对。
说明**尾部不是 0**——而以前的 dump 只抓前 128 字节，从来没看过尾部。

给 `wall_sd_dump` 加了 `START` 参数（抓任意 128 字节窗口），把窗口移到 384..511：

```
432..447: 00 00 00 00 00 00 00 00  E4 1D A3 FF  00 00 00 00
448..463: 21 00 0C D5 E8 AD 20 00  00 00 E0 DF  E6 00 00 00
510..511: 55 AA
```

这是标准 MBR：440 处是磁盘签名，446 处第 1 个分区表项
**type=0x0C（FAT32 LBA）、起始 LBA=32、扇区数 0x00E6DFE0（15,130,592 ≈ 7.2 GiB）**。

也就是说：**这张"SD16G"克隆卡被分过区、格过 FAT32**，卷在 LBA 32。
之前所有"LBA 0 全 0 ⇒ 空卡"的推断（§16、§18、§19）都读错了扇区——
包括第十六轮用 CID 证明"读通路是好的"那条结论：它证明的是通路，但没证明"卡是空的"。

### 20.3 装配器（wall_tf_load.v）

单趟流式，无帧缓存、无 SDRAM，全部在 25 MHz 像素域：

| 阶段 | 动作 |
|---|---|
| BOOT | 读 LBA 0；若是启动扇区（bps=512 等）→ 超级软盘布局；否则查 MBR 表项，按分区起始 LBA 再读一次 |
| PREP | `data_start = part_base + rsv + nfats*fatsz`；`root_lba = data_start + (rootclus-2)*spc`（串行移位加，不在字节通路上） |
| ROOT | 扫根目录第一个簇（`spc` 个扇区），8.3 名字比对 CAM1..4.BMP，记首簇与长度 |
| HDR | 单独读一次文件首扇区取 BMP 头（BM/宽度/高度/24 位/非压缩/offbits），随后串行除法算 `sx=w/96`、`sy=h/72`、`q0=(h-1)/sy` |
| DATA | 重读首簇，逐字节抽样：`x=k*sx`、`y=m*sy`、`bank_row=71-m`（自下而上 BMP），RGB444 写 `id*6912+row*96+k` |
| CHAIN | 每个簇读一次 FAT 扇区（`part_base+rsv+(c>>7)`），`FAT[c]&0x0FFFFFFF ≥ 0x0FFFFFF8` 为链尾 |

错误码：1 未初始化 / 2 非 512 字节扇区 / 3 无 55AA / 4 非 FAT32 / 5 没有 CAM 文件 /
6 BMP 头错 / 7 簇链异常 / 8 扇区读超时。

细节两条，都是仿真里抓出来的：

1. **请求超时必须是"停住"而不是"整扇区时间"**：第一次仿真时看门狗在扇区中途超时、
   重新发请求，把字节索引清掉，BOOT 校验读到错位数据（err=3）。改成"收到字节就清零"。
2. **MBR 支持必须贯穿所有 LBA 计算**：只在 `data_start` 上加分区偏移、
   忘了 FAT 扇区也要加，仿真立刻表现为 `found=1111` 但 `err=7`（簇链读到错误的 FAT 扇区）。

### 20.4 仿真（两个布局都过）

`tb/tb_tf_load.v` 用 `tb_sd_sector.v` 提供扇区流，逐字比对 `tb/expected_banks.hex`：

| 镜像 | 结果 |
|---|---|
| `tb/fat32_img.hex`（超级软盘，卷在 LBA 0） | **PASS** 27648/27648 字，465 次扇区读 |
| `tb/fat32_mbr.hex`（MBR + 分区在 LBA 32，与真卡同构） | **PASS** 27648/27648 字，466 次扇区读 |

**顺带修掉测试卷生成器的一个真 bug**：`tools/make_tb_fat32.py` 原来每个簇只写
1 个 512 字节块（`data[i*SEC:(i+1)*SEC]` 放在 `lba+i`），簇里另外 7 个扇区是 0。
于是"正确的装载器"读出来的缩略图**前 10 行对、之后全黑**——一开始以为是采样错，
其实是测试数据错。教训：**测试向量自己也要能自证**（现在生成器会断言
`len(blob) <= nclu*SPC*SEC` 并按簇写满）。

### 20.5 dump 现在抓根目录

`wall_sd_dump` 增加了 `cap_en`（窗口使能）与 `START`（起始字节），A 板现在抓的是
**根目录第一个扇区**（`cap_en = tf_phase == 2`），也就是文件名：

```
42 20 00 49 00 6E 00 66 00 6F 00 0F 00 72 72 00  |B .I.n.f.o...rr.|
...
31 53 00 79 00 73 00 74 00 65 00 0F 00 72 6D 00  |1S.y.s.t.e...rm.|
20 00 56 00 6F 00 6C 00 75 00 00 00 6D 00 65 00  | .V.o.l.u...m.e.|
53 59 53 54 45 4D 7E 31 20 20 20 16 00 19 8B 0B  |SYSTEM~1   .....|
E5 41 4D 31 20 20 20 20 42 4D 50 20 00 22 46 0C  |.AM1    BMP ."F.|
```

可见 `SYSTEM~1`（System Volume Information）与一个**被删除的 CAM1.BMP**（0xE5 开头），
以及一堆 LFN 碎片；4 个有效 CAM 条目在后续扇区里，所以 `found=000F`。

### 20.6 板级状态

| 项 | 状态 |
|---|---|
| A 板 bit | 装载器版，SWNS **+0.567 ns** / HWNS **+0.003 ns** |
| B 板 bit | 同一份设计，SWNS **+0.183 ns** / HWNS **+0.011 ns**（卡座空 → `phase=0`，显示仍是测试图案） |
| A 板 TF | `phase=6 / err=0 / found=000F / bank_ok=000F`：4 张照片已进图库 |
| B 板 TF | `phase=0`（无卡，等 `sd_init_done`），不影响墙面本体 |
| 上电到装完 | 约 1~2 s（466 次扇区读 × ~0.65 ms + 卡初始化） |
| 状态帧字节 | 11 = 扇区字节数，12 = {bank_ok, found}，20 = phase，23 = err |
| 读法 | `tools\read_status.ps1`（新增 `tf` 两行）、`tools\read_dump.ps1`（根目录） |

### 20.7 下一步

1. **目视验收**：四个窗口是否显示卡里那 4 张照片（缩放后 96×72 → 窗口 300×210 放大），
   以及跨接缝窗口是否仍然严丝合缝
2. 若照片不对/顺序不对：改 `wall_scene` 的窗口↔bank 映射，或换卡里的 BMP 素材
3. 装载完成前窗口显示测试图案是正常现象（`bank_valid` 先由图库自检置位）

### 20.8 第十八轮：照片上下颠倒 —— 金标准模型和 RTL 一起错

上板后用户第一眼就看出"这些图貌似是倒过来的"。原因很干脆：

```verilog
bank_row = 71 - m          // 错
```

`wall_scene` 按 `y*96 + x` 取图、y 向下增，所以**图库第 0 行就是窗口顶部**；
而 `m` 是源图行号（`y = m*sy`，0 = 图片顶行）。于是源图顶部被写到图库第 71 行，
每张照片上下颠倒。BMP 的"自下而上"只影响"存储第 r 行 ↔ 源图哪一行"（`y = h-1-r`），
和"源图第 m 行写图库第几行"是两件事——原设计把这两件事混成了一句 `71 - m`。

**为什么仿真没抓到**：`tools/make_tb_fat32.py` 的 `thumb()` 用的是**同一个错公式**，
所以 `expected_banks.hex` 里记的就是颠倒的图，27648 个字"全对"。这是典型的
**金标准出错，测试全绿**——真板上一眼就看出来了。

修法（两处必须同时改，否则仿真会立刻报错）：

| 文件 | 改动 |
|---|---|
| `rtl/wall_tf_load.v` | 行映射改成 `brow <= m`；完成判据改成 `m == (bottom_up ? 0 : 71)`；去掉 `ridx/skip_rows` |
| `tools/make_tb_fat32.py` | `thumb()` 改成 `out[m*96 + k]`，重新生成 `expected_banks.hex` |

修完两个卷布局的仿真仍 **PASS 27648/27648**，两块板重烧后 A 板仍是
`phase=6 / err=0 / found=000F / bank_ok=000F`。

> 教训：**验证模型不能和被测代码出自同一个假设**。这次两边都从"71-m 才对"出发，
> 唯一能发现问题的只有真板上的眼睛。以后凡是"方向/顺序"这类几何约定，
> 至少要有一个独立的、可肉眼判读的产物（比如把 expected_banks 渲染成 PNG 与照片并排看）。

### 20.9 仍未完成：B 板没有卡

B 板卡座是空的，`phase=0`，图库仍是上电测试图案，所以**跨接缝窗口只有 A 那一半是照片**。
两条路：

1. **再插一张卡**（推荐，零改动）：任何 FAT32 卡 + `wall/media/CAM1..4.BMP` 拷到根目录即可，
   B 板会自己装同样的四张图（两板装载算法相同，所以接缝内容一致）
2. **A 把缩略图推给 B**（单卡方案）：A→B 链路现在只有 STATE(0x01)/按键(0x02) 两种帧，
   需要新增一个图像块帧型（27648 字 ≈ 1728 帧 × 34 B，约 25 ms），B 侧收到后写自己的图库。
   这会动到 `docs/01_spec.md` 里冻结的帧格式，且要重验 genlock/状态同步

### 20.10 第十九轮：窗口放大比例 —— 右边 8 px 竖条 + 下面 7 行看不到

装完照片后发现窗口里的图有两处不自然，根因都在 `wall_scene` 的固定 3:1 放大：

| | 数值 | 结果 |
|---|---|---|
| 图库宽 96 × 3 | 288 | 内容区 `cw = ww-4 = 296`，右边 8 px 一直取第 95 列 → **竖条拖影** |
| 图库高 72 × 3 | 216 | 内容区 `chh = wh-16 = 194`，只用到 194/3 = 64 行 → **下面 7 行缩略图从未显示** |

改成按真实比例放大（Q16 常量）：

```
sx = (icx * 21254) >> 16      // 96/296 = 0.32432
sy = (icy * 24323) >> 16      // 72/194 = 0.37113
```

`tb/tb_img.v` 里的期望值同步改了，回归全过：

```
tb_img    PASS   (扫线逐像素 + 图库填充自检 chk_err=0)
tb_scene  PASS   (三组布局 614400 px，0 差异)
tb_drag   PASS
tb_node   PASS
tb_tf_load / tb_tf_load_mbr  PASS   27648/27648 字
```

两块板重烧后：A **SWNS +0.899 ns** / B **+0.681 ns**（比之前还宽松），
A 板仍 `phase=6 / err=0 / found=000F / bank_ok=000F`。

> 遗留（**设计如此，不是 bug**）：装载器仍按整步长抽样（640×480 时 `step=6`），
> 只用到源图的左上 576×432，**右边和下面各裁掉约 11%**。要改成"整幅等比缩放"
> 需要把逐列/逐行抽样换成余数累加器（Bresenham），并同步改
> `tools/make_tb_fat32.py` 的 `thumb()` 重新生成期望值——想要再做。

### 20.11 第二十轮：写进配置 Flash（断电自动启动）

到这一轮为止所有烧录都是 `download -bit ...`，那是**配置 SRAM，掉电即失**。
要"断电重开也能跑"，得把 bit 写进板载配置 Flash。

**硬件**：查原理图 `3_Power_and_Config.pdf`，配置 Flash 是 **W25Q16**（16 Mbit / 2 MB），
挂在 FPGA 的专用配置 SPI 上（`M_SPI_CS/MOSI/MISO/CLK`，与 TF 卡的 A12/A14/A13/B14 无关，
所以不冲突）。bit 文件 629,632 B → 放 Flash 偏移 0，绰绰有余。

**TD 6.2 怎么做**：`doc/config/config.json` 里写着 GUI 的 Flash 模式是
`PROGRAM_FLASH → program_spi -v`。但 CLI 的 `download -mode program_spi` 是个坏包装器：

```
bit_to_vec ... -m program_spi          ← 这一步对
然后去执行一个叫 program_spi 的 Tcl 命令 ← 不存在，报 invalid command name
```

正确姿势是自己两步走（已固化进 `build/build.ps1 -Persist`）：

```tcl
svfgen -chip EG4S20BG256 -scan_mode prog_spi  -flash W25Q16JV -flashsize 16 -bit WALL_A.bit -svf p.svf
program_svf -cable 0 -svf p.svf        ;# 擦除+写+校验，92 s
svfgen -chip EG4S20BG256 -scan_mode verify_spi -flash W25Q16JV -flashsize 16 -bit WALL_A.bit -svf v.svf
program_svf -cable 0 -svf v.svf        ;# 读回逐字节比对，6.7 s
svfgen -chip EG4S20BG256 -scan_mode refresh -svf r.svf
program_svf -cable 0 -svf r.svf        ;# 立刻从 Flash 重载（不用拔电就能验证）
```

**踩到的两个坑**：

1. **路径必须是正斜杠**。TD 的 Tcl 把 `\` 当转义：`C:\Users\japsa\...` 到它手里变成
   `C:Usersjapsa...`，报 `Cannot open file`。这条也解释了老 `-Flash` 分支里
   `flash.log` 一直是 0 字节——那条路其实一直没成功过（我前几轮都是手写正斜杠路径烧的）。
2. `program_svf` 没有 `-cable`（帮助里只列 `-svf`），但**实际接受** `-cable N`；
   不写就默认 0 号。

**实测**：

| 板 | 结果 |
|---|---|
| A | `SVFGEN-OK / PROG-OK / VERGEN-OK / VERIFY-OK / REFGEN-OK / REFRESH-OK`，refresh 后 `found=000F / bank_ok=000F` 重新装完 |
| B | 同上（`REFRESH` 第一次撞上 `PRG-9505 USB device open error`，重试即 OK） |

**一条命令**：

```powershell
powershell -ExecutionPolicy Bypass -File build\build.ps1 -Persist            # 两板一起
powershell -ExecutionPolicy Bypass -File build\build.ps1 -Role a -Persist    # 只 A
```

Vivado 式的"烧完自动重载"这里叫 `scan_mode refresh`，所以验证不需要拔电：
refresh 之后 A 板 `link` 计数归零、装载器从 `bank_ok=0` 重新涨到 `F`，就是一次完整的
"从 Flash 冷启动"。

### 20.12 第二十一轮：只有一张卡，也要两屏都有照片

用户只有一张 TF 卡（插在 A 板）。B 板卡座空 → 它的图库永远停在上电测试图案 →
跨接缝的窗口一半照片一半花纹。方案：**A 把缩略图经那条 4 bit 链路推给 B**。

#### 为什么不用"一次性推送"

第一版是"装载器每写出 16 个字就打一帧给 B"。仿真显示链路会丢 ~6% 的帧，
而**丢掉的块永远错**（图像是静态的，没有重传）。改成**自愈式轮播**：

* A 不停地走完 4 个图库共 1728 个块（每块 16 字），一轮约 **1.5 个视频帧（25 ms）**
* B 收到就写，重复也无所谓
* 任何一帧丢了，下一轮就补上；不需要应答通道

一帧 35 字节：`bank, block_lo, block_hi` + 16 个 12 bit 字（每字 2 字节）。

#### 图库读口的借用

图库是单口 RAM，读口归 `wall_scene`。轮播只在**行消隐**读写 16 个字：
`de_c == 0` 且消隐计数在 `[8,130]`（一行 160 拍消隐），**留出尾部 30 拍**给场景
把"下一行第一个像素"的地址预置好——这是接缝不错位的前提。

#### 板上踩到的四个坑

| # | 现象 | 根因 |
|---|---|---|
| 1 | 链路丢 ~6% 帧（仿真里也一样，且随数据变化） | `wall_link_rx` 帧结束时 `prev` 还留着帧头匹配的 `0xA`；发送端帧尾的 CRC 高半字节若是 `0x5`，这个"游离的 5"被配成假帧头，把下一帧吃掉。**修：帧结束把 `prev` 置 0xF**（顺带把板上原有的 4% 链路错也一起修好了） |
| 2 | 一开图像推送，B 立刻 `link=0 frozen=1` | 输出 mux 让图像帧优先，把 STATE 帧的 nibble 盖掉了。**修：STATE 帧优先**，图像帧被截断就下一轮重发 |
| 3 | 图像像写进去了但窗口没变 | `wall_img_recv` 根本没例化（只写了模块、忘了接）——板上靠"B 的图案自检开始报 mismatch"才看出来 |
| 4 | 读出的字全是 0 | 图库是同步 RAM，地址发出后要 2 拍才读得到；`S_READ` 的采样相位差一拍，且 `rcnt` 是 4 位却拿去和 `16` 比较（16 被截成 0，读状态一拍就退出） |
| 5 | B 的窗格变成**整块纯黑** | 两个 **Verilog 隐式网络**：`push_sel/push_addr` 声明在 `g_master` 里却被分支外的 `u_img` 引用；`img_rgb444` 声明写在 `generate` **之后**却被分支内的轮播引用。两处都会静默生成 1 bit 悬空网络（恒 0），读口永远不切给轮播、读回的字恒 0。TD 只给了一行 `HDL-5007 WARNING: actual bit length 1 differs from formal bit length 12 for port 'ram_data'`——**这条告警就是全部线索** |

> 教训：TP 的综合告警不能扫一眼就过。`actual bit length 1 ... for port 'ram_data'` 这种
> 一行宽度告警，背后是"整个功能静默不工作"。以后看到 `differs from formal bit length`
> 只允许出现在厂商 enc 文件里（HDMI IP 那种 `**` 的），出现在自己代码里必须停下来查。

### 20.13 第二十二轮：闪烁相位对齐 + SW1/SW2 两级操作 + 上下移动

两件事一起做的。

#### 1. 选中边框的闪烁在两屏上错相

场景里选中窗口的边框按 `frame_cnt[3]` 在白/黄之间切换，而 `frame_cnt` 是**每块板自己
数自己的帧**（A/B 上电时刻不同，实测 48605 vs 48449），所以相位必然错开 —— 一边黄一边白。

修法：STATE 帧本来就带着 A 的 `frame_cnt[7:0]`（`seq` 字节），B 现在把它存进 `b_seq`，
闪烁用 `b_seq[3]`。A 自己用本地计数，B 跟着 A 的序号走 → 两屏同相。

#### 2. 按键语义重做（SW1/SW2 两级）

板上有 **4 个滑动开关 SW1..SW4**（原理图 `2_FPGA.pdf` 里网络名 `SWKEY01..04`）：

| 丝印 | FPGA 引脚 |
|---|---|
| K1..K4 (KEY1..4) | A2 / B2 / B1 / C1 |
| SW1..SW4 | **C8 / C7 / C6 / C5** |
| LED0..3 | A4 / A3 / C10 / B12 |

（先前按 EX_DEVICE 页的 `KEY-BO` 符号误判成轻触按键，实物照片确认是滑动开关 →
`wall_input` 里改成读**去抖后的电平**，而不是按一下翻转。）

语义：

| SW1 | SW2 | 已选中 | KEY1..KEY4 |
|---|---|---|---|
| 0 | x | – | 全部无效，并自动放弃选中（观看模式） |
| 1 | 0 | 否 | KEY1 = 选下一张，KEY2 = 锁定 |
| 1 | 0 | 是 | KEY2 = 解锁（KEY1 不动） |
| 1 | 1 | 是 | **上 / 下 / 左 / 右**（移动模式） |

* "SW2 上拨但还没选图时 SW1 优先" —— 移动模式要求 `sw1 && sw2 && locked` 三者同时成立
* 移动步进：按一下 1 px；按住按 `rep_cyc`（33 ms）连发；**按住超过 0.5 s（`ACC_THR`
  = 12.5 M 个 25 MHz 时钟）后每步 4 px**
* 相机位（`gy`）这条链路其实早就通了（表项 `[23:12]`、`wall_scene` 的 `ly = wy - gy`），
  这次只是把上/下接到按键上，并把 `gy` 钳在 `0 .. 480-h`
* 归属仍然只在**放弃选中/切模式**那一刻按窗口中心判定，移动过程中不改

开关极性取决于开关装法（一档接地、一档上拉）→ `wall_top.v` 的 `SW_INV` 一位整体反相。

#### 3. 验证

* `tb_node`（两板级联）：锁定 → SW2 → KEY4×3 右移 + KEY1 上移 → 观看模式解锁 → 远程选图
  → 断链/恢复，全过（`TB_NODE PASS`）
* `tb_drag`（新写）：一次按下 1 px、按住加速到 4 px、`gy` 在 0 处钳住、观看模式解锁、
  长距离移动到 `gx=980` 后切模式 → `owner` 由 A 变 B（`TB_DRAG PASS`）
* `tb_scene / tb_img / tb_img_link / tb_link_probe` 仍全过
* 两板重新烧录 + 写进配置 Flash；A SWNS +0.453 ns，B +0.822 ns
* 真板：两块 `link=1 sync=1 frozen=0`，B 的"已收块数"（状态帧第 11 字节，仅 B 有效）
  持续在变；A 的 `bank_ok=000F`；两板都已写进配置 Flash
* 状态帧第 11 字节：**A = 装载器当前扇区字节数，B = 已接收的图像块数**（8 位回绕）

