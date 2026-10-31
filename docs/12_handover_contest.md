# 交接：比赛材料（填表 / 介绍 / GitHub / 视频拍摄方案）

> 这份文档是给**全新会话**的。你不需要读上一轮的对话 —— 项目本体、证据、数字、
> 素材位置、以及"不能吹过头的地方"都写在下面。**读到 §3 结束就可以开工。**
> 上一轮（C9 四张 1:1 相册 + 轮播取图源修复）的实现记录在 `docs/10_album_plan.md`
> 的「C9 / C9-R1 / C9-R2」三节，需要细节再翻。

---

## 0. 一句话

**硬件和 RTL 已经做完并上板验证**。这一轮**不要再改 RTL**（除非用户明确要求），
产出是四件"包装"工作：

1. 比赛的**报名/评审表**（按要求逐项填）；
2. **项目介绍**（一页简介 + 答辩/路演讲稿）；
3. **GitHub 仓库**（目前**一个 git 仓库都还没有**）；
4. **演示视频拍摄方案**（分镜 + 按键脚本 + 拍摄注意事项）。

建议产物目录：`wall/docs/contest/`（表、简介、讲稿、分镜都放这里），
`wall/` 本身做仓库根（见 §6.3）。

---

## 1. 项目是什么（对外话术，可直接抄改）

**一句话**：两块 Anlogic **HX4S20C（EG4S20BG256）** 开发板各带一块 **640×480 HDMI 屏**，
并排拼成一个 **1280×480 的"桌面"**；桌面上有 4 个监控窗口，**用按键把一个窗口从左边那块板
拖到右边那块板**，跨接缝处**逐像素无缝**；拔掉板间排线两屏各自降级运行，插回来自动恢复。

**技术卖点（这是评审最该看的）**：

| 卖点 | 说明 | 证据 |
|---|---|---|
| **没有帧缓存** | 每个像素是 `f(x, y, 窗口表)` 现算的纯函数，所以接缝**天然**对齐；传统拼接是"每板一个帧缓冲 + 外部同步" | `docs/01_spec.md` 铁律 1/2；`tb_scene` 614,400 像素 0 差异 |
| **全局坐标窗口表** | 4 条 64 bit 记录 = 4 个窗口（位置/尺寸/层序/归属/标志），**每帧整份**从 A 广播给 B，B 不做任何决策 | `docs/01_spec.md` §3、链路 §4 |
| **自愈式图片分发** | 只有 A 有 TF 卡；A 把 4 张 192×144 缩略图 + **4 份 640×480 1:1 拷贝**切成 16 字一块，用**无应答**的方式在 4 bit 链路上循环推给 B，丢块下一个循环自动修好 | `tb_img_link`：8 个区域边界逐块逐字校验 |
| **相册模式（全屏 1:1）** | SW4 一拨：整面墙变成**一张 640×480 照片的实际像素**，跨接缝居中、左右黑边；KEY3/KEY4 在 **CAM1..CAM4 四张**之间切页，切页和进出都走 16 帧淡入淡出 | `tb_album`（1280 像素 1:1 逐点）、`tb_album_page`（切页时序） |
| **降级策略** | 拔线 → `LINK LOST` / 窗口 `FROZEN`；插回 ≤3 帧恢复；卡没了 → 自动回落到片上合成音 | `tb_node`（需要硬 IP，见 §5） |
| **可观测性** | 34 字节状态帧 @115200，两片都能读出 link/sync/窗口表/加载器阶段/SDRAM 自检/相册页码 | `tools/read_status.ps1` |

**别把它说成**：这不是"接摄像头的监控墙" —— 图像源是 **TF 卡里的 BMP**；
也没有以太网/AI 识别。话术请写"视频源与显示节点解耦，本次用图库素材演示"。

---

## 2. 硬件、环境、常用命令

| 项 | 值 |
|---|---|
| 板子 | 2 × HX4S20C（FPGA = Anlogic **EG4S20BG256**，Eagle S20） |
| 屏 | 每板一块 HDMI 屏，输出 **640×480@60**（800×525 总时序，25 MHz 像素时钟） |
| 板间链路 | 12 芯 J1 排线：4 bit 数据 + clk + sync + bvld/返回 4 bit，nibble 时钟 6.25 MHz，CRC8 |
| 存储 | 板上 SDRAM **2M×32**（图库/音乐），A 板插 TF 卡（FAT32，MBR 分区在 LBA 32） |
| 工具链 | **TD 6.2**（`D:/TD6.2/bin/run.exe`）、**ModelSim ASE**（`E:\Quartus.13.1\modelsim_ase\win32aloem`） |
| 下载器 | 老的 Anlogic **dl-cable**（`USB\VID_0547&PID_1002`），两片各一个 pod |
| 串口 | **COM7 = A，COM8 = B**，115200 8N1 |

```powershell
cd C:\Users\japsa\Documents\deepseek-harness\default-workspace\wall

powershell -ExecutionPolicy Bypass -File tools\read_status.ps1      # 读两片状态（最常用）
powershell -ExecutionPolicy Bypass -File tools\probe_flash.ps1      # 只读 node/link/phase
powershell -ExecutionPolicy Bypass -File build\build.ps1 -Role both # 重建两片（各 ~20 min）
powershell -ExecutionPolicy Bypass -File tools\probe_flash.ps1 -Flash  # 烧两片（cable 0=A,1=B）
```

> ⚠ **cable 编号会变**（跟着 USB 枚举走）。今天 **cable 0 = A（有卡那块）/ 1 = B**。
> 烧之前先 `-VerifyOnly` 或 `probe_flash.ps1`（不带 -Flash）确认哪块是 A。

---

## 3. 现在板上是什么、跑到什么程度（2026-10-31 17:0x 实测）

```
A: link=1 sync=1 video locked=1 sup_state=RUN sdram done=1 errors=0
   tf phase=6 err=0 found=000f bank_ok=000f        ← 4 张图 + 4 份 1:1 拷贝全部加载完
   album page=0 hi_ready=1                          ← 四份拷贝就绪
B: link=1 sync=1 video locked=1 sdram done=1 errors=0
   album hi_ready=1                                 ← 一整轮 83,712 块已收满
```

| 项 | 数字（填表直接用） |
|---|---|
| 资源 A / B | LUT **13112 / 8642**（66.9% / 44.1%）、reg 8099 / 6084、BRAM **31 / 64**、DSP 14 / 29 |
| 时序 A | 25 MHz **+0.220 ns**、150 MHz（SDRAM）**+0.140 ns**、50 MHz +10.9、125 MHz +5.1，**0 违例** |
| 时序 B | 25 MHz **+0.404 ns**、150 MHz **+0.578 ns**、链路 6.25 MHz +149.7，**0 违例** |
| 代码规模 | RTL **29 个文件 / 7,727 行**（`rtl/*.v`，另 + 4 个厂商 SD 栈在 `rtl/sd/`）；TB **34 个文件 / 4,645 行**，其中 **23 个在回归里全 PASS** |
| 帧率 | 两屏各 60 Hz；链路 ~60 帧/s 状态帧 + 一块图片数据（12.5 µs/块） |
| 上电启动 | → 照片就位约 **5~8 s**（`phase=6`）；B 收满一轮 83,712 块约 **1 s**，所以上电后 ~10 s 内两屏都齐 |
| 窗口/照片 | 4 个窗口；CAM1..CAM4 各 640×480，缩略图 192×144；相册 1:1 无缩放 |

**按键与模式（视频分镜要照着按）**：开关 SW1..SW4 决定模式，四个键 KEY4..KEY1 按模式变义。

| SW1 | SW2 | SW3 | SW4 | 模式 | 四个键 |
|---|---|---|---|---|---|
| 下 | x | x | x | **VIEW（观看）** | KEY4 轮播自动/停 · KEY3 手动切下一张 · KEY2 整体 UI 显隐 · KEY1 静音 |
| 上 | x | x | **上** | **全屏相册** | **KEY4 下一张 / KEY3 上一张**（CAM1..CAM4，淡入淡出） |
| 上 | 上 | 上 | 下 | **亮度/对比度** | KEY4/KEY3 亮度 ± · KEY2/KEY1 对比度 ±（同按一对 1 秒 = 复位 0x80） |
| 上 | 上 | 下 | 下 | MOVE | 上/下/左/右（按住 0.5 s 后每步 4 px） |
| 上 | 下 | 上 | 下 | ZOOM | 放大/缩小/快放/快缩（等比，围绕中心） |
| 上 | 下 | 下 | 下 | 基础层 | KEY4 选图 · KEY3 确认/解锁 · KEY2 置顶 · KEY1 置底 |

> 桌面上"跨接缝"的窗口是默认布局自带的（窗口 2 在 x=600..920），**上电第一帧就能演**，
> 不需要现场摆。

---

## 4. 素材在哪（写材料时直接引）

### 4.1 文档（`wall/docs/`）

| 文件 | 能拿来写什么 |
|---|---|
| `01_spec.md` | **接口规范**（坐标/窗口记录位段/链路帧/状态帧）——填表"技术方案"一节的主干；里面"铁律 1/2"是最好的卖点表述 |
| `02_bringup_log.md` | **5 万字调试日志**，20+ 个真板 bug 的现象→根因→修法 —— 评审问"难点"时从里面挑 3 个讲（HDMI 不锁、隐式网络、DDR 读口竞争…） |
| `03_w2_media_plan.md` | 媒体方案取舍（图库 vs 摄像头）——"为什么这么选" |
| `04_acceptance.md` | W1 时代的验收表（**已过时**，功能多了很多；结构可以复用，数字要更新到 §3） |
| `05_w2_loader_design.md` | TF 卡 → FAT32 → BMP → SDRAM 装载器设计 |
| `06_music_player_plan.md` | 音乐播放（卡上 WAV + 片上合成器回退） |
| `07/08/09` | 高分辨率图、DDA 采样、实现状态 |
| `10_album_plan.md` | **相册模式全记录**（C2a..C9-R2）：取舍、踩坑、时序/面积、板上数字 —— 写"创新点"最好用 |
| `11_handover_album_multi.md` | 上一轮的交接（历史） |
| `README.md` | 项目总览 + 状态表 + 按键表 + 目录树 + 构建烧录 —— **对外简介的骨架** |

### 4.2 图（可直接进 PPT / GitHub README）

| 图 | 内容 |
|---|---|
| `docs/preview_world.png` | 1280×480 世界的金标准渲染（Python 模型） |
| `docs/preview_pair.png` | A/B 两屏并排效果 |
| `docs/preview_rtl.png` | RTL 仿真的整幅输出 |
| `docs/media_preview.png` | 四张素材照片的缩略图集 |
| `docs/w3_hud.png` | HUD（TIME/CAR 两行字幕） |
| `docs/img_rom_preview.png`、`docs/font_preview.png` | 早期的图库/字模预览 |
| `media/CAM1..4_preview.png`、`media/contact.png` | 四张照片 + 拼版（contact 1.6 MB，做封面很合适） |
| `wall/scene_rtl.ppm` | 仿真整幅（PPM，可转 PNG） |

> ⚠ 这些是**模型/仿真**图，不是屏摄。视频里要真实屏摄，图可以当"设计示意图"用，
> **不要标成实拍**。

### 4.3 兄弟项目里现成的"答辩类"文档（格式可抄）

- `fpga_media_player/答辩演示卡.md`（5 KB）、`fpga_media_player/上板验证清单.md`、
  `fpga_media_player/交付报告_视频音频.md`（58 KB）
- `stopwatch_gw48/doc/答辩问答.md`（8 KB）—— Q&A 格式很成熟
- `EDA技术实验报告_丁许钊.docx/pdf` —— 报告排版参考

---

## 5. 已知欠账（**写材料时别吹过头**）

1. **卡上没有 MUSIC.WAV**：两片状态帧里 `music ok=0`，所以现在听到的是**片上合成器**的
   回退音。要拍"音乐"镜头/写"播放卡内 WAV"，先把 `wall/media/MUSIC.WAV` 拷到 TF 卡根目录
   （`tools/make_music.bat` 可重新生成），或干脆在材料里写"内置合成器 + 卡内 WAV 双通路"。
   注意 C9 之后 SDRAM 只留给 WAV **619,520 字 ≈ 12.9 s**。
2. ~~两片都是 JTAG 临时配置~~ → **2026-10-31 19:0x 已写入配置 Flash**（`tools/persist_pair.ps1`，两片 `PROG/VERIFY/REFRESH` 全 OK，最后一步 `refresh` 就是从 Flash 重配置、起来仍是 node=A / node=B）。**所以现在是掉电自启的**：拍视频/现场可以随便断电。
   ⚠ 两条注意：① **以后任何一次重建都要重新 persist**，否则掉电会回到现在这一版；② 万一 Flash 被擦坏（persist 中途断电），JTAG 仍然能烧，重跑 `persist_pair.ps1` 就能恢复。
3. **"上下移动图片时抖动"已定位并修了两轮**：行缓冲的 SDRAM 读口预算不足（4 个窗口 × 192 字 burst ≈ 一行的 95%），
   C9-R2 让每片板只取自己半屏画得到的窗口，C9-R3 又把"跨缝窗口"的 burst 截短到本节点能显示的列宽
   （A 板每行 576→429 字）。状态帧能读出诊断：**byte 11 = 4 秒内最差一帧的挨饿行数，byte 19 bits[6:3] = 哪几个窗口挨饿**，
   `tools/read_status.ps1` 会打印 `starved-mask=0100 (w3..w0)`。改前 A 是 `0100`/13、B 是 0；改后两片静止都是 `0000`/0。
   **2026-10-31 18:4x 操作员已确认不再抖动**（按住上下键、并移动别的图），所以这一条可以按"已修复"写；
   拍视频时不用再特意避开上下移动（单次按住短一点只是为了镜头稳）。增量说明见 `docs/13_delta_after_c9r3.md`。
4. **`tb_node` / `tb_link_dbg` / `tb_link_probe` / `tb_osd` 不在回归里**（需要 `fpga_hdmi` 的
   硬 IP，`tb_carousel` 的旧版本曾在 C3 之后悄悄腐烂）。对外写"23 个 TB 全 PASS"时，
   指的就是 `sim_c3/run.ps1` 里那一套。
5. **相册只有 4 张固定图**，靠 `[60:59]` 页码切换；没有"任意图片"加载路径（卡里就是 CAM1..4）。

---

## 6. 任务清单（新会话按这个干）

### 6.1 比赛填表

先把"表"拿到手（用户会贴题目/字段），然后逐字段从下面取料：

| 常见字段 | 从哪取 |
|---|---|
| 项目名称 | 现名"方案 3 · 跨屏窗口拖拽的监控墙"；可考虑改成更响亮的名字（如"无缝拼接监控墙""零帧缓存双屏拼接"），**改名前先问用户** |
| 项目简介（100~300 字） | §1 的一句话 + §3 三个数字 |
| 技术方案/创新点 | §1 技术卖点表 + `01_spec.md` 铁律 + `10_album_plan.md` 的取舍 |
| 关键指标 | §3 表（资源/时序/TB/启动时间/帧率） |
| 完成度 | "两片已上板，全部功能实测" + `docs/04_acceptance.md`（更新数字后） |
| 难点与解决 | 从 `02_bringup_log.md` 挑 3 个：HDMI 不锁（消隐区采样）、隐式网络让整条通路恒 0、SDRAM 读口竞争导致行缓冲错过截止时间 |
| 图片 | §4.2 |
| 团队/分工 | **问用户**（我不知道） |

⚠ 表里凡是"实时""AI""摄像头"之类的词**都不要写**，本项目是 TF 卡素材 + 纯逻辑拼接。

### 6.2 项目介绍 / 答辩讲稿

建议结构（10 分钟版；压缩到 3 分钟就砍 ③④）：

```
① 问题（30 s）  多屏拼接要么靠帧缓存+外部同步，要么接缝有缝/有撕裂
② 方案（1 min） 全局坐标窗口表 + 每帧广播 + 两板各自裁剪；两条铁律
③ 关键实现（3 min）
   · 窗口表 64 bit 位段 / 状态帧 34 B / 4 bit 链路 CRC8
   · SDRAM 行缓冲（2 bank ping-pong）+ 每行换行在"首像素前 3 拍"（C8 的教训）
   · 图片分发：8 个区域 83,712 块，无应答自愈
   · 相册 1:1：四份 640×480 拷贝 + 页码写进窗口表 [60:59]，协议零改动
④ 工程化（2 min） 23 个 TB、每次改动都重建看 STA、两片余量 +0.14/+0.58
⑤ 演示（2 min）  §6.4 的分镜
⑥ 已知限制（1 min）  素材是图库、WAV 需拷卡、JTAG 临时配置
```

素材：`README.md` 的状态表、`10_album_plan.md` 的"踩到的坑"、`02_bringup_log.md`。

### 6.3 GitHub

**现状**：`wall/` **不是 git 仓库**，整台机器上也没有任何 `.git`；没装 `gh` CLI。

必须做的事（按顺序）：

1. `git init wall/`（或在 `default-workspace/` 初始化一个只含 wall 的仓库 —— **问用户想要哪种**；
   注意工作区根目录还有 `eda_lab2/ fpga_media_player/ stopwatch_gw48/ murmur_d1/ pkgs/ .tmp/`
   等一堆**别的项目**，绝不能整个根目录初始化）。

2. **`.gitignore` 是第一步**，否则一提交就是 1.4 GB：

   ```gitignore
   build/
   sim_c3/work*/
   sim_*/work*/
   transcript
   *.wlf
   *.hex
   *.ppm
   tb/*.log
   media/*.BMP          # 3.7 MB，可另放 release 附件
   rtl_base_ok/         # 历史快照目录（base_ok 时代的旧 RTL）
   tb_base_ok/
   work/ work_tf/
   ```
   现状体积：`wall/` **1,407 MB**，其中 `build/release` **1,023 MB / 78 个快照**、
   `build/`（其余）181 MB、`tb/*.hex` 30.6 MB、`media` 12.3 MB、`sim_c3` 4.4 MB。
   真正要提交的只有：`rtl/*.v`（+`rtl/sd`）、`tb/*.v`、`tools/*`、`docs/*.md`+`docs/*.png`、
   `pin/*`、`build/build.ps1`、`README.md` —— **几 MB**。

3. **厂商加密 IP 不能公开**：`fpga_hdmi/build_src/src/vendor/**/*.enc.v`
   （`sdr_as_ram` / `sdr_init_ref` / `sdr_wrrd` / `hdmi_1_4b_transmitter_core_wrapper`）
   是 Anlogic APUG011/APUG092 的加密网表。仓库里**要么不放**，要么放个说明
   "从安路官方例程获取，见 `docs/` 里的器件说明"。`wall/rtl/sd/*.v`（4 个文件）是从安路
   例程改的，公开前要确认许可，或写清来源。

4. 依赖 `fpga_hdmi/build_src`（645 文件 / 66.9 MB）—— 只提交 `build.ps1` 里
   `$common` 需要的那些 `.v`（约 20 个：framebuf / storage / top / vendor 的**明文**部分），
   其余（图片、bit、报告、加密 IP）排除；`$common` 是唯一权威来源，照它抄即可。
5. README 首位放：一张 `media/contact.png` 或屏摄、一句话简介、三个数字、
   `docs/` 导航、以及"如何重建/如何仿真"两条命令。
6. （可选）把 `build/release/` 里最新一版的两片 bitstream 作为 **Release 附件**，
   仓库里不存 bit。

### 6.4 视频拍摄方案

**先确认**：用户要几分钟、横屏还是竖屏、要不要说话（旁白）。

建议 **3 分钟 / 横屏 / 无旁白 + 字幕**，分镜如下（每格 15~25 s）：

| # | 时间 | 画面 | 操作（照着按） |
|---|---|---|---|
| 1 | 0:00 | 两屏全景（稍俯拍，避免正对反光） | 上电，等 5~8 s 到 `phase=6`（照片出现） |
| 2 | 0:20 | 中景：网格背景 + 4 个窗口 + 跨接缝的那个窗口 | 不动，让轮播自己走一轮（约 4.3 s 换一张，带淡入淡出） |
| 3 | 0:45 | 特写接缝：窗口边框**跨两屏连续** | 基础层：**KEY4** 选到跨缝那个窗口 → **KEY3** 确认（边框闪烁）→ SW2 上 = MOVE：**KEY2/KEY1** 左右、KEY4/KEY3 上下（小步、别长按）→ 结束回基础层再按 **KEY3** 解锁 |
| 4 | 1:10 | 缩放 + 层叠 | 锁住后 SW2 下+SW3 上 = ZOOM：KEY4 放大 / KEY3 缩小；回基础层 KEY2 置顶 / KEY1 置底 |
| 5 | 1:30 | 亮度/对比度 | SW1+SW2+SW3 全上 → KEY4/KEY3 亮度、KEY2/KEY1 对比度（同按一对 1 s 复位） |
| 6 | 1:50 | **相册模式**：整面墙一张 1:1 照片，跨接缝居中 | SW4 上（16 帧淡入）→ KEY4 切 CAM2/3/4（每切一次淡出淡入 ≈0.57 s）→ KEY3 回切 → SW4 下退出 |
| 7 | 2:20 | **拔线降级** | 拔 J1 排线 → A 屏 `LINK LOST`、B 窗口 `FROZEN` → 插回 ≤3 帧恢复 |
| 8 | 2:40 | 收尾：两屏全景 + 数字字幕（LUT 66.9%、0 违例、23 个 TB） | 静止 |

拍摄注意事项：

- 屏摄**别用相机的自动曝光/自动白平衡**，锁 1/60 s 以下快门会拍到刷新带 →
  用 **1/50 s 或更慢 + 手动白平衡**，或直接让相机 1080p60 拍；
- 显示器若是 1080p 面板显示 640×480，会做缩放 —— 尽量把显示器设成 **点对点/1:1**（否则
  接缝特写会看到显示器自己的插值）；
- 拍"接缝"镜头用**微距/长焦**，让 A 屏最右列和 B 屏最左列同时入画；
- 提前把两片状态读一遍并截图（`read_status.ps1`）当"证据镜头"；
- 相册模式切页有 0.57 s 淡出，**不要连按**（淡入淡出期间的按键会被忽略）；
- 想要干净的画面：VIEW 模式（SW1 下）按 **KEY2** 可以把 HUD/标签整体藏掉，拍完再按回来；
- 音乐：卡上没有 WAV 时是合成音，若要"有音乐"的镜头先拷卡（见 §5 第 1 条）；
- 拍完记得 `probe_flash.ps1` 确认两片还在（拔插排线容易碰掉 JTAG/USB）。

---

## 7. 干这活儿时最容易踩的坑（本项目血泪）

1. **中文文件不要用 `Get-Content -Raw | Set-Content` 改**（PowerShell 5.1 会按 ANSI 解码再写回，
   中文变 `?`，不可逆 —— 这个项目的 README 和 `wall_top.v` 都被毁过）。
   改文件一律用编辑器的 edit/write，或 `[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)` +
   `[IO.File]::WriteAllText($p,$s,[Text.UTF8Encoding]::new($false))`，改完按 UTF-8 解码验一遍。
   > 另外：本机 `pwsh` 其实是 **PowerShell 5.1**，`Get-Content README.md` 显示中文会乱码
   > **但文件是好的** —— 别被唬到，用 `[IO.File]::ReadAllText` 看才是真内容。
2. **TD 比 ModelSim 严**：隐式网络（`undeclared symbol`）会让整条通路恒 0 而构建"成功"；
   `build.ps1` 里已有这项检查（`== implicit-net check: clean`）。
3. **cable 编号会变**；`build.ps1` 默认 `A=0/B=1`，烧反了两块板会都变成同一节点。
4. **别同时开两个 TD**：`run.exe` 会抢同一个 license/工作目录。
5. 文档里的数字**以 `build/td_A|B/final_timing.rpt` 和 `area.rpt` 为准**，
   `build/release/<stamp>_<A|B>/` 里每一版都留了当时的报告。

---

## 8. 一键自查（写材料前跑一遍，确保数字是新的）

```powershell
cd C:\Users\japsa\Documents\deepseek-harness\default-workspace\wall

# 1) 板上状态（贴进材料当证据）
powershell -ExecutionPolicy Bypass -File tools\read_status.ps1

# 2) 资源与时序
Select-String build\td_A\final_timing.rpt -Pattern "^\tSWNS|^\tHWNS"
Get-Content build\td_A\area.rpt | Select-String "^#(lut|reg|bram|dsp) "
# B 同理

# 3) 回归（14 个快的，约 2 min；再单独跑 tb_tf_load / tb_tf_load_mbr / tb_wav）
cd sim_c3; powershell -ExecutionPolicy Bypass -File run.ps1

# 4) 仓库体积自查（提交前）
cd ..; Get-ChildItem -Recurse -File | Measure-Object Length -Sum
```

---

## 9. 交付判据（这一轮的"做完了"）

- [ ] 表格逐项填好，且每个数字都能在 `docs/` 或 `final_timing.rpt` 里指到出处
- [ ] 一页简介 + 10 分钟讲稿（3 分钟精简版）落盘
- [ ] `.gitignore` 生效后 `git status` 里没有 `build/`、没有 `.hex`、没有厂商 `.enc.v`
- [ ] 仓库能 `git clone` 后按 README 重建（或至少能看懂怎么重建/什么拿不到）
- [ ] 分镜表 + 按键脚本 + 拍摄注意事项落盘，且**用户照着能一次拍完**
- [ ] 材料里没有 §5 那些"欠账"被写成已完成
