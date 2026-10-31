# 06 GitHub 仓库方案与步骤

> 作品名称：**基于双安路FPGA的双屏无缝拼接多媒体播放墙**
> 队伍：43927「中门鸟狙王」（丁许钊、喻展轩、周健峰）　指导老师：梁娇娇
> 赛道：2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 安路赛题「基于安路 EG4S20 的 HDMI 多媒体播放系统」
>
> **全文禁项**：仓库里任何地方都不出现学校名称（模板原文：「作品名称（不要出现任何涉及学校名称等内容）」）。README、提交信息、注释、`LICENSE`、Release 说明都算"任何地方"。

---

> **2026-10-31 23:0x 已执行**（这份方案的落地结果）：
> `winget install Git.Git` 装好 **git 2.56.0**；在 `wall\` 里 `git init -b main` 并完成**一次干净提交**
> （**165 个文件 / 6.87 MB**，Verilog 14,358 行、Markdown 4,508 行；
> 已核实**不含** `*.enc.v` / `*.bit` / `*.hex` / `*.ppm` / `docs/contest/_src/`）。
> 仓库名定为 **`dual-screen-fpga-wall`**，发布用 `tools/publish_github.ps1` 一条命令完成
> （建仓库 + 打 topics + push；token 现场输入、不落盘、不进 `.git/config`）。
> 两个 bitstream 已按 §9 归到 `build/release_assets/v1.0/WALL_A_20261031_211735.bit` /
> `WALL_B_20261031_212015.bit`，等建 Release 时直接拖上去。
## 0. 事实基线（动手前先认这 6 条）

| # | 事实 | 证据 | 后果 |
|---|---|---|---|
| 1 | **这台机器上没有 git** | `where git` 无输出；`Get-Command git` 为空；`where gh` 也为空 | 第 1 步先装 git，没有它后面所有步骤都做不了 |
| 2 | `wall\` **不是 git 仓库** | `Test-Path wall\.git` → `False` | 要 `git init` |
| 3 | **工作区根目录也不是仓库** | `Test-Path .git` → `False` | 但根目录下已经有 `eda_lab2`、`EDA_lab3`、`eda_report`、`fpga_hdmi`、`fpga_media_player`、`lab_ex5_i2s`、`murmur_d1`、`stopwatch_gw48`、`work`、`work_chk`、`wstemp`、`pkgs`、`.tmp` 共 13 个目录 |
| 4 | **绝对不能在工作区根目录 `git init`** | 见第 3 条 | 在根目录 init = 把 13 个项目、几十万个构建产物一次性拖进一个仓库，`git add` 会跑几十分钟并可能把磁盘塞满；而且以后谁 clone 都拿到一堆无关项目 |
| 5 | `winget` 可用 | `Get-Command winget` → `C:\Users\japsa\AppData\Local\Microsoft\WindowsApps\winget.exe` | 用 winget 装 git 最快 |
| 6 | `wall\` 现在 **10,698 个文件 / 1,475 MB** | `Get-ChildItem -Recurse -File` 统计 | 直接 `git add -A` 会得到一个 1.4 GB 的仓库，GitHub 直接拒收（单仓库建议 < 1 GB） |

**唯一正确的目标**：仓库根 = `C:\Users\japsa\Documents\deepseek-harness\default-workspace\wall`，只进源码/文档/脚本/图，**约 150 个文件、6 MB**。

---

## 1. 第 0 步：装 git + 配身份 + 确认网络

### 1.1 装 Git（三选一，按顺序试）

**首选：winget**

```powershell
winget install --id Git.Git -e --source winget
# 期望：Found Git [Git.Git] … 正在下载 … 已成功安装
# 装完必须新开一个 PowerShell 窗口（当前窗口的 PATH 不会自动刷新）
```

**次选：GitHub Desktop（自带 git，还有图形界面，适合不熟命令行的队友）**

```powershell
winget install --id GitHub.Desktop -e --source winget
# 期望：安装完成后开始菜单出现 GitHub Desktop
# 它的 git 在：C:\Users\<你>\AppData\Local\GitHubDesktop\app-*\resources\app\git\cmd\git.exe
```

**国内网络慢时用镜像**（winget 走微软 CDN，有时会卡在 0%）：直接用浏览器打开清华 TUNA 的 GitHub Release 镜像，下载 `Git-2.xx.x-64-bit.exe` 手动装。

```powershell
Start-Process "https://mirrors.tuna.tsinghua.edu.cn/github-release/git-for-windows/git/"
# 期望：浏览器打开目录列表，进 LatestRelease 找 Git-*-64-bit.exe
```

**验证（新开窗口后跑）**

```powershell
git --version
# 期望：git version 2.4x.x.windows.1
# 若报「无法将"git"项识别为 cmdlet」：关掉所有终端重开；仍不行就手动把
# C:\Program Files\Git\cmd 加进 PATH，然后重开终端
```

### 1.2 配身份（**必须用昵称 + noreply 邮箱**）

理由：提交记录里的邮箱会永久公开在 GitHub 上。用 GitHub 提供的 `noreply` 地址，既不暴露真实邮箱，也能正确关联到账号（`<数字ID>+<用户名>@users.noreply.github.com` 里的数字 ID 在 GitHub → Settings → Emails 页面能看到）。

```powershell
git config --global user.name "43927-dingxuzhao"
# 期望：无输出

git config --global user.email "43927-dingxuzhao@users.noreply.github.com"
# 期望：无输出（把 43927-dingxuzhao 换成你们自己的 GitHub 用户名）

git config --global core.quotepath false
# 期望：无输出。作用：中文/特殊字符路径在 git status 里正常显示，不会被转成 \344\270\255

git config --global core.autocrlf false
# 期望：无输出。作用：不做换行符自动转换，避免每个文件都显示"已修改"

git config --global init.defaultBranch main
# 期望：无输出。作用：以后 init 默认就是 main，省掉 git branch -M

git config --global --list
# 期望：列出 user.name / user.email / core.quotepath=false / core.autocrlf=false / init.defaultbranch=main
```

### 1.3 确认网络能到 GitHub

```powershell
Test-NetConnection github.com -Port 443
# 期望：TcpTestSucceeded : True
# 若 False：公司/校园网可能封了 443，换手机热点再试
```

```powershell
git ls-remote https://github.com/git/git.git HEAD
# 期望：一行 40 位 sha + HEAD
# 若卡住 > 30 秒：设置代理（端口按自己代理软件填）
#   git config --global http.proxy http://127.0.0.1:7890
#   git config --global https.proxy http://127.0.0.1:7890
# 若报 SSL certificate problem：git config --global http.sslBackend schannel
```

---

## 2. 体积治理：1,475 MB → 6 MB

### 2.1 钱都花在哪了（实测）

| 位置 | 文件数 | 体积 | 占 wall | 处置 |
|---|---|---|---|---|
| `build\release\`（80 个时间戳快照） | 6,665 | **1,090 MB** | 74% | 忽略。每次构建 +13.6 MB，永远追不上 |
| `build\` 其余（`td_sddemo` 等 TD 工程） | 176 | 181 MB | 12% | 忽略 |
| `wall\` **根目录 `td_*.log` / `.logw`** | **1,464** | **57 MB** | 3.9% | 忽略。1500 个时间戳日志，是"文件数爆炸"的主犯 |
| `tools\ffmpeg\ffmpeg.exe` | 1 | 61.5 MB | 4.2% | 忽略。`tools\get_ffmpeg.ps1` 能重新下 |
| `tb\*.hex`（7 个仿真数据） | 7 | 30.6 MB | 2.1% | 忽略。`tools\make_tb_fat32.py` / `make_tb_wav.py` 能重新生成 |
| `sim\` `sim_c3\` `sim_elab\` `sim_s1\` `simlib*\` `work\` `work_tf\` | ~1,700 | 23 MB | 1.6% | 忽略。ModelSim 库，`vlib/vlog` 一条命令重建 |
| `media\`（4 个 BMP 3.5 MB + MUSIC.WAV 5.5 MB） | 5 | 9.0 MB | 0.6% | 忽略。BMP 可由 `tools\make_camera_bmps.py` 重做 |
| `rtl_base_ok\` + `tb_base_ok\` | 60 | 13.7 MB | 0.9% | 忽略。这是"上一版能跑的备份"，不是源码 |
| **要提交的** | **~150** | **6 MB** | **0.4%** | 见 §4 |

### 2.2 `.gitignore`（完整版，直接覆盖落盘）

> **先说两个坑**：
> ① `.gitignore` **不支持行尾注释**。写成 `build/*   # 构建产物`，git 会把 `# 构建产物` 当成模式的一部分，结果匹配不上任何东西。所以下面每个模式都把注释放在**上一行**。
> ② `wall\.gitignore` **现在已经有一版**（1,515 字节）。那一版的思路和大部分模式可用，但有 **3 个必须修的问题**，所以不要保留它，直接用下面这份覆盖：

| 现有 `.gitignore` 的问题 | 后果 | 本文这一版的处理 |
|---|---|---|
| 中文注释是**双重编码的乱码**（`# wall 鈥斺€?鍙屾澘璺ㄥ睆…`） | GitHub 上打开全是乱码，看不出哪条规则管什么，以后改必错 | 全文 UTF-8 无 BOM，注释可读 |
| 有一条 **`*.sdc`** | `pin\wall_a.sdc`、`pin\wall_b.sdc` 被排除 → 别人 clone 下来构建**没有时序约束**，25 MHz / 150 MHz 全不约束，跑出来的 bit 不可信 | **删掉**。本文这一版里没有 `*.sdc`，这不是遗漏 |
| 缺 `__pycache__/`、`*.pyc`、`*.qor`、`*.bid`、`/rtl/wip/`、`/docs/contest/*.docx` | `tools\__pycache__\pdf_coords.cpython-314.pyc` 这类会混进仓库 | 全部补上 |

在 `wall\` 根目录用下面这份**整个覆盖** `.gitignore`（UTF-8 无 BOM）：

```gitignore
# ============================================================================
# wall —— 基于双安路FPGA的双屏无缝拼接多媒体播放墙
# 原则：只提交源码、文档、脚本、成品图；构建产物 / 仿真库 / 日志 / 二进制一律不进
# 注意：本文件不支持行尾注释，注释必须单独占一行
# ============================================================================

# ---------------- 构建产物：整个 build/ 排除 ----------------
# 6,841 个文件 / 1,271 MB，其中 release/ 下 80 个快照就占 1,090 MB
/build/*
# 但构建脚本本身是源码，必须留下（这一行必须紧跟在上面那行之后才生效）
!/build/build.ps1

# ---------------- ModelSim 仿真库与工作目录 ----------------
# ~1,700 个文件 / 23 MB，全是 _primary.dat / verilog.psm 这类编译缓存
/sim/
/sim_c3/
/sim_elab/
/sim_s1/
/simlib/
/simlib2/
/simlib3/
/work/
/work_tf/
# ModelSim 的库索引与配置（vlib 会自动重建）
worklib/
modelsim.ini

# ---------------- TD / ModelSim 日志 ----------------
# 根目录有 1,464 个 td_*.log / td_*.logw，共 57 MB，是文件数爆炸的主因
*.log
*.logw
td_*.log
td_*.logw

# vsim 每次跑完在 CWD 写一个无扩展名的 transcript
transcript

# ---------------- 波形与仿真数据 ----------------
# 波形文件，几十 MB 到几 GB
*.wlf
*.wstf
*.vcd
# tb_tf_load / tb_wav 要读的仿真数据，30.6 MB，用 make_tb_fat32.py / make_tb_wav.py 重新生成
*.hex
# tb_hud_dump / tb_album 输出的 PPM 图
*.ppm

# ---------------- 交付件与中间报告 ----------------
# 综合/布局/布线的中间物，随时会重新生成
*.qpf
*_db/
*.qor
*.rpt
*.svf
*.bid
# bitstream 走 GitHub Release 附件，不进仓库（见 §9）
*.bit

# ---------------- 媒体素材 ----------------
# 4 张原始 BMP 共 3.5 MB，可由 make_camera_bmps.py 重新生成
media/*.BMP
# 卡上的 WAV 5.5 MB，可由 tools/make_music.bat 重新生成
media/*.WAV

# ---------------- 历史备份与临时目录 ----------------
# "上一版能跑"的整目录备份，13.7 MB，不是源码
/rtl_base_ok/
/tb_base_ok/
# 媒体处理的临时输出
/tmp_media/
# 未完成的 RTL 草稿（*.v.txt，编译不进，留着只会误导别人）
/rtl/wip/

# ---------------- 工具链二进制 ----------------
# ffmpeg 61.5 MB，get_ffmpeg.ps1 能重新拉
/tools/ffmpeg/
# Python 缓存
__pycache__/
*.pyc
# 预编译的 aac2wav.exe（源码 aac2wav.cs 已在仓库里）
*.exe

# ---------------- 文档中间产物 ----------------
# 从组委会 PDF/DOCX 里抽出来的文字和临时脚本，含格式解析垃圾，不入库
/docs/contest/_src/
# 一次性生成脚本（_gen_figs.py / _md2docx.py / _gen_poster.py 等），产物在 figs/ 和 md 里
/docs/contest/_*.py
/docs/contest/*.log
# 交付用的 Word / PDF 由 _md2docx.py 从 md 生成，走 Release 或报名系统，不进仓库
/docs/contest/*.docx
/docs/contest/*.pdf
# 海报草稿（_gen_poster.py 的输出），成品按 §5.4 的正式命名另存
/docs/contest/poster_A3_draft.png

# ---------------- 厂商加密 IP（兜底） ----------------
# 正常情况下它们在 fpga_hdmi\ 里，不在本仓库；这条防止以后误拷进来（见 §3）
*.enc.v
fpga_hdmi/
vendor/

# ---------------- 操作系统垃圾 ----------------
.DS_Store
Thumbs.db
desktop.ini

# ---------------- 个人草稿 / 编辑器 ----------------
*.tmp
.vscode/
.idea/
*.swp
*~
```

**两个必须写对的地方**（否则会被自己坑）：

1. `/build/*` + `!/build/build.ps1` 是**唯一**能"排除目录但保留一个文件"的写法。写成 `build/` 会把 `build.ps1` 一起排掉，别人 clone 下来就没法构建。
2. `pin/*.adc` 和 `pin/*.sdc` **不能**忽略。它们是引脚约束和时序约束，是构建必需的输入（`wall_node_a.adc`、`wall_node_b.adc`、`wall_a.sdc`、`wall_b.sdc`）。上面这份 `.gitignore` 里**故意没有** `*.adc` / `*.sdc`——现有那一版有 `*.sdc`，那是个 bug，必须删。

### 2.3 加完 `.gitignore` 的自检

```powershell
cd C:\Users\japsa\Documents\deepseek-harness\default-workspace\wall
# 期望：提示符变成 ...\wall>
```

```powershell
(git status --short | Measure-Object).Count
# 期望：150 左右（允许 100–250）
# 报错「not a git repository」= 你还没 git init，先做 §5 的第 2 条
# 报出 5 位数（上千）= .gitignore 没生效：①确认文件在 wall 根目录 ②文件名是 .gitignore 不是 .gitignore.txt ③重开终端
```

```powershell
git status --short | Select-String 'build/|\.hex$|\.enc\.v$|\.BMP$|\.bit$|\.pyc$'
# 期望：零输出（只可能看到 build/build.ps1 那一行，它是脚本不是产物）
# 只要有别的输出，就说明对应规则没生效，回去改 .gitignore
```

```powershell
git status --short | Select-String '\.sdc$|\.adc$'
# 期望：4 行，正好是 pin/ 下的 wall_a.sdc / wall_b.sdc / wall_node_a.adc / wall_node_b.adc
# 如果是 0 行 → 你的 .gitignore 里还留着我警告过的 *.sdc，删掉重来
```

```powershell
git add -A
# 期望：无输出；最多出现 "warning: in the working copy of 'xxx', LF will be replaced by CRLF" 这类警告，无害
```

```powershell
$files = git ls-files
"文件数 = $($files.Count)"
"总体积 = {0:N2} MB" -f ((($files | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum) / 1MB)
# 期望：文件数 = 150 左右；总体积 = 6 MB 左右（硬指标：< 15 MB）
```

> **关于"只剩几十个文件"**：实际数出来是 **150 左右**，不是几十，原因是 `docs\contest\` 现在已经写到 8 篇（01 技术文档、02 平台填写、03 视频脚本、04 海报、05 拍摄清单、06 本篇、07 授权书、08 答辩 QA），加上 `docs\` 顶层的 12 篇和 17 张图。
> 这 150 的构成：`rtl\` 35 + `tb\` 35 + `tools\` 30 + `docs\` 34 + `pin\` 4 + `media\` 5 + `README.md` 1 + `build\build.ps1` 1 + `.gitignore` + `.gitattributes` + `LICENSE` + `LICENSES\`×2 + `third_party\README.md`。
> **它就该是这个量级**：99 个是 RTL / TB / 脚本，是真正要看要改的东西；剩下的是文档和图。
> 体积 6 MB 里：`media\` 5 张 PNG 3.3 MB、`docs\contest\figs\` 7 张框图 1.9 MB——都是给人看的，留着。`docs\contest\` 下只提交 `.md` 和 `figs\*.png`；`.docx` / `.pdf` / `_*.py` / 草稿图全部忽略（走 Release 或报名系统）。

---

## 3. 厂商加密 IP 不能公开

### 3.1 现状（已核实）

| 文件 | 大小 | 是什么 |
|---|---|---|
| `fpga_hdmi\build_src\src\vendor\anlogic\apug011\enc_file\sdr_as_ram.enc.v` | 7.3 KB | SDRAM 控制器加密网表 |
| `fpga_hdmi\build_src\src\vendor\anlogic\apug011\enc_file\sdr_init_ref.enc.v` | 8.8 KB | SDRAM 初始化参考 |
| `fpga_hdmi\build_src\src\vendor\anlogic\apug011\enc_file\sdr_wrrd.enc.v` | 15.3 KB | SDRAM 读写引擎 |
| `fpga_hdmi\build_src\src\vendor\anlogic\apug092\hdmi_1_4b_transmitter_core_wrapper.enc.v` | 321.3 KB | HDMI 1.4b 发送核（APUG092） |

另外 `wall\rtl\sd\` 下 4 个文件（`sd_card_cmd.v`、`sd_card_sec_read_write.v`、`sd_card_top.v`、`spi_master.v`）是**从安路 SD 卡例程改写**的，原始工程还留在 `wall\build\td_sddemo\`。

**好消息**：`build\build.ps1` 引用的是 `$hdmi/src/vendor/...`，也就是这些加密文件在 **`fpga_hdmi\` 里，不在 `wall\` 里**。所以只要仓库根是 `wall\`，`*.enc.v` 天然进不来（`.gitignore` 里那条 `*.exe` 之外，我再建议加一条兜底规则，见下）。

### 3.2 处置方案（照这个做）

**结论：仓库不放加密网表，放一个 `third_party\README.md` 说明来源。**

1. **不放** `*.enc.v`。它们是安路 APUG011/APUG092 的加密交付件，版权属安路，随 TD 安装包和官方例程发放，**没有开源许可**。放到公开仓库 = 二次分发厂商加密 IP，风险由队伍承担。
2. **也不放** `fpga_hdmi\` 整个目录。那是另一个项目，且含上面 4 个文件。
3. 在仓库里建 `third_party\README.md`，内容照抄下面这段（已写好，直接粘贴）：

```markdown
# third_party —— 本仓库不含的第三方件

## 安路（Anlogic）加密 IP

本作品在综合时依赖以下 **加密 Verilog 网表**，它们属于安路科技，随 TD 工具与官方例程发放，
**不在本仓库中**：

| 文件 | 所属 IP | 用途 |
|---|---|---|
| `sdr_as_ram.enc.v` | APUG011 | 片内 2M×32 SDRAM 控制器（当 RAM 用） |
| `sdr_init_ref.enc.v` | APUG011 | SDRAM 上电初始化 |
| `sdr_wrrd.enc.v` | APUG011 | SDRAM 读写引擎 |
| `hdmi_1_4b_transmitter_core_wrapper.enc.v` | APUG092 | HDMI 1.4b 发送核 |

**怎么拿到**：向安路科技（或赛题协办方）申请 EG4S20 的 HDMI + SDRAM 参考设计包，
或使用 TD 安装目录自带的 `ip` / `example` 工程。拿到后放到
`fpga_hdmi/build_src/src/vendor/anlogic/` 对应子目录，`build/build.ps1` 即可正常综合。

## 安路 SD 卡例程

`rtl/sd/` 下 4 个文件（`sd_card_cmd.v`、`sd_card_sec_read_write.v`、`sd_card_top.v`、
`spi_master.v`）改写自安路官方 SD 卡 demo，原始工程见 `build/td_sddemo/`（不入库）。
改写部分：接口改成 32 bit 字对齐、去掉数码管/LED 测试逻辑、加入多扇区连读。
原始版权归安路科技，此处仅作学习与参赛使用。

## 字体

`tools/font.json` 与 `rtl/wall_font_rom.v` 是 8×8 点阵字模，由 `tools/gen_font.py` 生成，
字模取自公共领域 8×8 点阵字体，不含商业字库。
```

4. **在 `.gitignore` 末尾补一条兜底**（防止以后误把 `fpga_hdmi` 拷进来）：

```gitignore
# 兜底：任何位置的安路加密网表都不许进仓库
*.enc.v
```

5. **如果坚持要公开加密 IP**：先确认两件事，缺一不可——
   - 赛题指南「其它」一节原文：**「本作品支持开源，允许主办方和赛道协办方将作品用于教育用途，鼓励后期参赛学生学习。使用时需满足：保留原始版权声明，教育用途需注明来源，不得用于商业培训。」** 这句授权的是**你们的作品**，不是**安路的 IP**，不能拿来当厂商授权。
   - 向安路书面确认"加密网表可否随参赛作品公开"。拿到书面答复再放。
   - 在拿到之前，公开仓库里只放 `third_party/README.md` 的说明，这一条没有折中。

---

## 4. 仓库结构（`git commit` 之后的真实目录树）

```
wall/                                   ← 仓库根（不是工作区根！）
├── README.md                           ← 门面，见 §5
├── LICENSE                             ← MIT，代码
├── LICENSES/
│   ├── CC-BY-4.0.txt                   ← 文档
│   └── CERN-OHL-P-2.0.txt              ← 硬件设计（pin/ 下的约束）
├── .gitignore
├── .gitattributes                      ← 固定换行符，见 §5.2
├── third_party/
│   └── README.md                       ← 说明加密 IP 与 SD 例程来源（§3）
│
├── rtl/                                ← 29 个 .v + sd/ 4 个
│   ├── wall_top.v                      顶层：A/B 节点、SDRAM 仲裁、HDMI 复位重试
│   ├── wall_scene.v                    桌面 + 4 窗口 + z 序 + HUD（输出寄存器打一拍）
│   ├── wall_raster.v                   640×480@60 时序 + genlock
│   ├── wall_window_eval.v              像素函数 f(x,y,窗口表)
│   ├── wall_paint.v                    窗口内容（图库取址 + 亮度/对比度）
│   ├── wall_textbox.v                  窗口标题栏与边框
│   ├── wall_hud.v                      HUD 两行（WALL A/B、SEL、GX、LINK、SYNC）
│   ├── wall_font_rom.v                 8×8 字模（tools/gen_font.py 生成）
│   ├── wall_state.v                    stage/snap/cur 三级流水
│   ├── wall_input.v                    按键去抖 + 模式解码 + 拖拽/连发 + 切页
│   ├── wall_link.v                     4 bit nibble 帧 + CRC8
│   ├── wall_status_tx.v                40 字节 STATE 帧
│   ├── wall_pic_line.v                 SDRAM 行缓存（2 bank ping-pong）
│   ├── wall_pic_prefetch.v             每行源行号 + 可见性 + 页码
│   ├── wall_img_push.v                 A→B 图块推送（8 区域）
│   ├── wall_img_recv.v                 B 端接收与落 SDRAM
│   ├── wall_album_seq.v                全屏相册：表快照/换表/还原 + 淡入淡出 + 页码
│   ├── wall_carousel.v                 轮播相位 + 淡入淡出包络
│   ├── wall_picadj.v                   每张图的亮度/对比度
│   ├── wall_zoom_calc.v                等比缩放步长
│   ├── wall_clock.v                    HUD 的 TIME（BCD）
│   ├── wall_music.v                    WAV 播放 + 片上合成器回退
│   ├── wall_audio.v                    I2S 输出
│   ├── wall_tf_load.v                  FAT32 → BMP → SDRAM 装载器
│   ├── wall_sd_dump.v                  TF 卡整片读自检
│   ├── wall_sdram_test.v               SDRAM 上电自检
│   ├── wall_hdmi_supervisor.v          HDMI 上电时序与锁定监督
│   ├── wall_autodrag.v                 自动拖拽演示
│   ├── wall_demo_a.v                   演示序列
│   ├── wall_scope.v                    片内逻辑分析（调试用）
│   ├── wall_uart_tx.v                  UART 状态输出
│   ├── wall_img_rom.v                  96×72 图库 ROM（已不参与综合）
│   ├── wall_img.mif                    图库初始化数据（469 KB，构建输入，必须留）
│   ├── sd/
│   │   ├── sd_card_top.v               ← 改写自安路 demo
│   │   ├── sd_card_cmd.v
│   │   ├── sd_card_sec_read_write.v
│   │   └── spi_master.v
│   └── unused/
│       └── wall_img_banks.v            已退役的片内图库，留作历史
│
├── tb/                                 ← 34 个 .v + fat32_img.txt
│   ├── tb_scene.v                      ★ 接缝 0 像素（614400 像素逐点比对）
│   ├── tb_img.v  tb_pic_line.v  tb_pipe_eq.v  tb_hud_dump.v
│   ├── tb_link.v  tb_img_link.v  tb_link_dbg.v  tb_link_probe.v
│   ├── tb_node.v                       双节点端到端（需安路硬 IP 源码，本机跑不了）
│   ├── tb_album.v  tb_album_tbl.v  tb_album_page.v  tb_carousel.v
│   ├── tb_carousel_ctrl.v  tb_zoom.v  tb_picadj.v  tb_drag.v
│   ├── tb_mute.v  tb_clock.v  tb_osd.v  tb_status*.v  tb_sd_dump.v
│   ├── tb_sd_sector.v  tb_tf_load.v  tb_tf_load_mbr.v  tb_wav.v
│   ├── tb_music.v  tb_audio.v  tb_models.v  stubs.v
│   └── fat32_img.txt                   空的标记文件（FAT32 布局，0 字节）
│
├── pin/
│   ├── wall_node_a.adc                 A 板引脚约束
│   ├── wall_node_b.adc                 B 板引脚约束
│   ├── wall_a.sdc                      A 板时序约束
│   └── wall_b.sdc                      B 板时序约束
│
├── build/
│   └── build.ps1                       TD 综合 + P&R + STA + bitgen（构建入口）
│
├── tools/                              ← 30 个脚本（ps1 / py / bat / cs / json）
│   ├── gen_font.py  font.json          字模生成
│   ├── render_preview.py               金标准渲染器（产出 docs/preview_*.png）
│   ├── make_camera_bmps.py             4 张 BMP 素材生成
│   ├── make_tb_fat32.py  make_tb_wav.py  生成 tb/*.hex（仓库不含 hex，改由脚本生成）
│   ├── make_music.bat  aac2wav.cs      WAV 素材
│   ├── make_img_mif.py  make_img_rom.py  图库
│   ├── flash_pair.ps1  persist_pair.ps1  probe_flash.ps1  烧录与自检
│   ├── read_status.ps1  status_all.ps1  parse_status.py   UART 状态解码
│   ├── peek_frames.ps1  read_dump.ps1  dump_root.ps1
│   ├── dupscan.py                      同名信号扫描（躲过 TD 的隐式网络坑）
│   ├── get_ffmpeg.ps1                  ffmpeg 下载（二进制不入库）
│   └── pdf*.py                         PDF 取图/取坐标辅助
│
├── docs/                               ← 12 篇 .md + 8 篇比赛材料 + 7 张框图 + 7 张预览图
│   ├── 01_spec.md                      ★ 接口与协议规范（地址、位段、帧格式）
│   ├── 02_bringup_log.md               ★ 5 万字调试日志，20+ 个真板 bug
│   ├── 03_w2_media_plan.md
│   ├── 04_acceptance.md                （W1 时代验收表，数字已过时）
│   ├── 05_w2_loader_design.md
│   ├── 06_music_player_plan.md
│   ├── 07_hires_picture_plan.md
│   ├── 08_hires_impl_status.md
│   ├── 09_c1_dda_status.md
│   ├── 10_album_plan.md                ★ 相册模式（C2a..C9-R2）实现与踩坑
│   ├── 11_handover_album_multi.md
│   ├── 12_handover_contest.md
│   ├── contest/                        ← 只提交 .md 和 figs/*.png
│   │   ├── 01_技术文档.md               ★ 主报告（Word/PDF 由 _md2docx.py 生成，不入库）
│   │   ├── 02_作品简介与平台填写稿.md
│   │   ├── 03_演示视频拍摄脚本.md
│   │   ├── 04_作品海报方案.md           本篇的姊妹文档（A3 排版说明书）
│   │   ├── 05_拍摄清单_全貌图与开发板图.md
│   │   ├── 06_GitHub仓库方案与步骤.md    本文件
│   │   ├── 07_参赛作品承诺及使用授权书.md
│   │   ├── 08_答辩QA与自检清单.md
│   │   └── figs/
│   │       ├── fig_system.png          系统框图
│   │       ├── fig_modules.png         模块划分
│   │       ├── fig_pipeline.png        像素流水线
│   │       ├── fig_link.png            4 bit 链路
│   │       ├── fig_window.png          窗口记录位段
│   │       ├── fig_boot.png            上电时序
│   │       └── fig_flow.png            上板流程（2400×720）
│   ├── preview_world.png               1280×480 金标准渲染
│   ├── preview_pair.png                两屏并排（8 px 模拟物理缝）
│   ├── preview_rtl.png                 RTL 仿真整幅
│   ├── w3_hud.png  media_preview.png  img_rom_preview.png  font_preview.png
│
└── media/
    ├── contact.png                     4 张素材 2×2 拼版（1.64 MB）
    └── CAM1_preview.png … CAM4_preview.png
```

**关于 `docs/contest/_src/`：不提交。**
里面是 `guide.txt`（68 KB，从组委会 PDF 抽的文字）、`auth.txt`、`tpl_docx.txt`、`mp4info.txt`、`log.txt`（0 字节）以及 3 个一次性抽文本脚本。理由三条：①它们是**组委会文档的摘录**，公开在你们仓库里有版权风险；②`guide.txt` 里混着 PDF 解析垃圾（每行都夹 `zh-CN` / `en-US`），别人看不懂；③随时能重新生成。`.gitignore` 里已经有 `/docs/contest/_src/`。

**关于 `build/td_sddemo/`：也不提交**（在 `/build/*` 的排除范围内）。那是安路 SD 卡官方 demo 的原样工程，含厂商文件，和 §3 同一个理由。

---

## 5. README.md 的 8 段结构

README 是评委打开仓库看到的**第一屏**，也是队友一年后回来看的**唯一入口**。按下面 8 段写，顺序不要改。

| 段 | 内容 | 硬要求 |
|---|---|---|
| ① 顶部 | 一张图 + 一句话 + 三个数字 + badges | **第一屏必须出现图和数字**，不许用"本项目实现了…"开头 |
| ② 这是什么 | 30 秒版：两块板、1280×480、4 个窗口可跨缝拖、全屏相册 | ≤150 字，外行能懂 |
| ③ 为什么接缝能对齐 | 无帧缓存 → 纯函数 → 天然对齐；A 是唯一表写者，每帧整份广播 | 3 小段，每段 ≤80 字 |
| ④ 目录导航 | 一张表：想看什么 → 去哪个文件 | 必须链 `docs/01_spec.md`、`docs/02_bringup_log.md`、`docs/10_album_plan.md` |
| ⑤ 怎么重建 | **一条命令** | `build\build.ps1`；附前置条件（TD 版本、加密 IP 从哪来） |
| ⑥ 怎么仿真 | **一条命令** | `vsim ... tb_scene`；附 hex 数据要先生成的提示 |
| ⑦ 已知限制 | 5 条，诚实写 | 缺加密 IP、TD 版本敏感、tb_node 跑不了、cable 编号会变、图是渲染 |
| ⑧ 致谢 + License | 安路例程、工具、老师；三种许可各自管什么 | 链 `LICENSE`、`LICENSES/` |

### 5.1 可直接粘贴的 README 开头

> 这是 ① 段全文，复制到 `README.md` 最上面即可。badges 用行内代码块实现——**不依赖任何外网图片**（shields.io 的图在校园网/断网时经常裂图，评委看到一堆裂图很难看）。

````markdown
# 基于双安路FPGA的双屏无缝拼接多媒体播放墙

**两块 640×480 HDMI 屏拼成一块 1280×480 的桌面；没有帧缓存，每个像素是 `f(x, y, 窗口表)` 现算出来的纯函数，所以接缝天然对齐 —— 不是"调"出来的。**

`安路 EG4S20BG256` · `HX4S20C ×2` · `1280×480 @60Hz` · `零帧缓存` · `RTL 仿真 614400 像素 0 差异` · `时序 0 违例` · `MIT`

![双屏桌面（仿真渲染，1280×480，非实拍）](docs/preview_world.png)

| 指标 | 值 |
|---|---|
| LUT 占用（A 板） | 13,811 / 19,600 = **70.46%** |
| 时序（最终 route） | **0 违例**（A +0.557 / +0.353 ns，B +0.347 / +0.185 ns） |
| 接缝误差 | **0 像素**（614,400 像素逐点比对） |
| 跨板链路 | 4 bit 数据 + sync + valid，无应答，CRC8 自愈 |
| TF 卡分发 | 4 张 BMP / 8 个区域 / 83,712 块 / ≈1 s 收满 |
| 全屏相册 | 一张 640×480 照片 1:1 跨缝，KEY4/KEY3 切 4 张，16 帧淡入淡出 |
| 窗口表 | 4 × 64 bit，A 板是唯一写者，每帧整份广播给 B |

> 2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 安路赛题
> 队伍 43927「中门鸟狙王」　丁许钊、喻展轩、周健峰　指导老师 梁娇娇
````

### 5.2 顺带建 `.gitattributes`

```gitattributes
# 让 git 不猜换行符：Verilog 在 Windows 上用 CRLF，脚本用 LF
* text=auto
*.v       text eol=crlf
*.vh      text eol=crlf
*.ps1     text eol=crlf
*.bat     text eol=crlf
*.py      text eol=lf
*.md      text eol=lf
*.png     binary
*.BMP     binary
*.bit     binary
```

不建也不会出错，但建了以后 `git status` 永远干净，不会因为"整个文件都改了"而误提交。

---

## 6. 逐步命令（逐条复制，每条后面写了会看到什么）

```powershell
# 1) 进到 wall 目录（不是工作区根目录！）
cd C:\Users\japsa\Documents\deepseek-harness\default-workspace\wall
# 期望：提示符变成 PS C:\...\default-workspace\wall>
# 注意：后面的命令全都在这个目录下执行
```

```powershell
# 2) 初始化仓库（只在这一层 init，绝不在 default-workspace 根目录 init）
git init
# 期望：Initialized empty Git repository in C:/Users/japsa/.../wall/.git/
# 副作用：wall\ 下多出一个 .git 文件夹（约 100 KB），不要删、不要提交
```

```powershell
# 3) 先把 .gitignore 落盘再 add（顺序反了就会把 1.4 GB 加进暂存区）
git add -A
# 期望：无输出（可能有少量 "LF will be replaced by CRLF" 警告，无害）
# 如果这一步跑了超过 30 秒还没结束：立刻 Ctrl+C，说明 .gitignore 没生效
```

```powershell
# 4) 看看到底会提交什么（这一条最重要，别跳过）
git status
# 期望：
#   On branch main (或 master)
#   Changes to be committed:
#     new file:   rtl/wall_top.v
#     new file:   tb/tb_scene.v
#     ...
#   列表应该在 150 行左右结束
# 必须确认：列表里没有 build/、没有 *.hex、没有 *.enc.v、没有 *.BMP、没有 *.bit
```

```powershell
# 5) 行数 + 体积双确认
"文件数 = $((git status --short | Measure-Object).Count)"
git add -A
"体积 = {0:N2} MB" -f ((git ls-files | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum / 1MB)
# 期望：文件数 = 150 左右；体积 = 6 MB 左右（硬指标 < 15 MB）
```

```powershell
# 6) 提交
git commit -m "feat: 双屏无缝拼接多媒体播放墙（C9-R2，两片 0 违例）"
# 期望：[main (root-commit) 3f9a1c2] feat: ... 150 files changed, 48000 insertions(+)
# 若报 "Please tell me who you are"：回 §1.2 配 user.name / user.email
```

```powershell
# 7) 分支名改成 main（GitHub 默认 main，老版本 git 默认 master）
git branch -M main
# 期望：无输出
git branch
# 期望：* main
```

```powershell
# 8) 加远端（把两个占位符换成你们自己的）
git remote add origin https://github.com/<用户名>/<仓库名>.git
# 期望：无输出
git remote -v
# 期望：origin  https://github.com/xxx/xxx.git (fetch) 和 (push) 两行
# 报 "remote origin already exists"：先 git remote remove origin 再重跑
```

```powershell
# 9) 推送（第一次要认证）
git push -u origin main
# 期望：Enumerating objects: 160, done. … Writing objects: 100% … To https://github.com/...
#       branch 'main' set up to track 'origin/main'.
# 会弹浏览器登录 GitHub（或用 PAT）；若报 "Support for password authentication was removed"，
# 说明它要的是 Personal Access Token 而不是账号密码：GitHub → Settings → Developer settings
# → Personal access tokens → Tokens(classic) → Generate new token → 勾 repo → 复制当密码用
```

```powershell
# 10) 收尾确认
git log --oneline
# 期望：3f9a1c2 feat: 双屏无缝拼接多媒体播放墙（C9-R2，两片 0 违例）
git status
# 期望：nothing to commit, working tree clean
git count-objects -vH
# 期望：size-pack 在 5~6 MiB 之间
```

### 没有 git 的替代方案（以及为什么这招对本项目不适用）

**GitHub 网页上传 ZIP**：仓库页 → `Add file` → `Upload files` → 拖文件夹或 zip。

它的硬限制：
- **单次最多 100 个文件**；
- **单个文件最大 25 MB**（网页上传；用 git 命令行是 100 MB）；
- ZIP 会被解压后上传，**空目录直接丢失**；
- 没有提交历史、不能打 tag、不能用 `.gitignore`（传什么就有什么）。

**对本项目不适用，原因很直接**：仓库是 **约 150 个文件**，超过 100 的上限 → 必须拆成 2 次上传；而拆包会打乱目录结构（第二次上传时 `docs/contest/figs/` 这种三级目录要手工重建），并且**无法保证两次上传的路径不串**。更麻烦的是 `.gitignore` 在这个流程里完全不起作用——一旦有人顺手把 `build\` 拖进去，就会撞上单文件 25 MB 和单次 100 文件的墙。

**如果今天必须有个链接先发出去**（比如报名表要填仓库地址），按这个降级方案做，5 分钟能出：
1. 只上传 `README.md` + `docs/`（12 篇 md + 图，共 26 个文件，1 MB 以内）——远低于 100 文件限制；
2. 仓库名先叫 `wall-docs`，后面装好 git 再补代码；
3. README 里写明「源码待补，构建需要安路加密 IP，见 `third_party/README.md`」。
4. 装好 git 后，把 `wall\` 的全部内容 push 到同一个仓库的 `main`，网页上传的那些文件会被正常覆盖，历史从这一刻开始记。

---

## 7. License 选择

### 7.1 三种许可，各管一块

| 对象 | 许可 | 为什么 |
|---|---|---|
| **RTL、TB、脚本（代码）** | **MIT** | 最短、最通用，评委/后来者一看就懂；比赛作品不需要专利条款，Apache-2.0 的专利授权对学校作品是多余负担 |
| **`docs/` 文档、图** | **CC BY 4.0** | 允许别人转载/改编但必须署名，正好对应赛题指南「教育用途需注明来源、保留原始版权声明」 |
| **`pin/`、约束、PCB 相关** | **CERN-OHL-P v2** | 开源硬件专用许可，比 MIT 更明确"改了就开源"的边界；比 CERN-OHL-S 宽松，适合参赛作品 |

> 不要用 GPL：GPL 的传染性会让"想拿这份代码做商业产品的厂商"直接绕开，而赛题的导向是"鼓励后期参赛学生学习"。
> 不要用"保留所有权利"：赛题指南明确写了「本作品支持开源」。

### 7.2 `LICENSE` 文件前 5 行（MIT，直接粘贴）

```
MIT License

Copyright (c) 2026 43927 中门鸟狙王（丁许钊、喻展轩、周健峰）

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
```

第 6 行往后是 MIT 标准全文（`in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software...`），逐字照抄，不要改写。

`LICENSES/` 目录里放两个全文文件（从官方站点下载原文本，不要手打）：
- `LICENSES/CC-BY-4.0.txt` → `https://creativecommons.org/licenses/by/4.0/legalcode.txt`
- `LICENSES/CERN-OHL-P-2.0.txt` → `https://ohwr.org/cern_ohl_p_v2.txt`

README 第 ⑧ 段加一行说明，避免"三种许可混在一个仓库"的歧义：

```markdown
## License

- 代码（`rtl/`、`tb/`、`tools/`、`build/`）：[MIT](LICENSE)
- 文档与图（`docs/`、`media/`）：[CC BY 4.0](LICENSES/CC-BY-4.0.txt)
- 硬件约束与引脚（`pin/`）：[CERN-OHL-P v2](LICENSES/CERN-OHL-P-2.0.txt)

第三方件（安路加密 IP、SD 卡例程）版权归安路科技，见 [third_party/README.md](third_party/README.md)。
```

---

## 8. 上传前自检 12 条

逐条跑，全部通过才 `git push`。

| # | 检查 | 命令 | 期望 |
|---|---|---|---|
| 1 | 没有 `build/` | `git ls-files | Select-String '^build/'` | 只应有 `build/build.ps1` 一行 |
| 2 | 没有 `.hex` | `git ls-files | Select-String '\.hex$'` | **零输出** |
| 3 | 没有 `.enc.v` | `git ls-files | Select-String '\.enc\.v$'` | **零输出** |
| 4 | 没有 `media/*.BMP` | `git ls-files | Select-String '\.BMP$'` | **零输出** |
| 5 | 没有 `.bit` / `.svf` | `git ls-files | Select-String '\.bit$\|\.svf$'` | **零输出** |
| 6 | `.gitignore` 生效 | `(git status --short | Measure-Object).Count` | 100–250（上千 = 没生效） |
| 7 | 仓库 < 20 MB | `"$([math]::Round(((git ls-files | %{ (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum/1MB),2)) MB"` | ≈ 6 MB，硬指标 < 20 |
| 8 | 没有 >5 MB 的单文件 | `git ls-files | %{ [pscustomobject]@{F=$_;MB=[math]::Round((Get-Item -LiteralPath $_).Length/1MB,2)} } | Sort-Object MB -Desc | Select-Object -First 5` | 最大是 `media/contact.png` 1.64 MB |
| 9 | **不含学校名称** | `git grep -n "学院\|大学"` | **只允许 1 类命中**：赛道名「全国大学生嵌入式芯片与系统设计竞赛」里的"大学"。出现任何「XX大学」「XX学院」都要删 |
| 10 | 不含队伍编号以外的个人信息 | `git log --format="%an <%ae>"` | 只有 1 行：`43927-xxx <...@users.noreply.github.com>`，不含真实邮箱/手机/学号 |
| 11 | README 首屏有图有数字 | 浏览器打开仓库首页 | 第一屏能看到 `preview_world.png` 和 70.46% / 0 / 0 |
| 12 | 许可文件齐 | `Test-Path LICENSE, LICENSES\CC-BY-4.0.txt, LICENSES\CERN-OHL-P-2.0.txt, third_party\README.md` | 四行全 `True` |

第 9 条的命令有个坑：`git grep` 默认只搜已跟踪文件，没问题；但"大学"会因为赛道名命中，**不要因为看到命中就慌，也别为了清零把赛道名删掉**——赛道名是必须写的。判断标准是：命中的行里只有「全国大学生嵌入式芯片与系统设计竞赛」这一个是合法的。

一次性跑完 1–8 条：

```powershell
# 上传前一键自检（在 wall 目录下）
"1) build/ 下被跟踪的文件:"; git ls-files | Select-String '^build/'
"2) hex:";                     git ls-files | Select-String '\.hex$'
"3) enc.v:";                   git ls-files | Select-String '\.enc\.v$'
"4) BMP:";                     git ls-files | Select-String '\.BMP$'
"5) bit/svf:";                 git ls-files | Select-String '\.bit$|\.svf$'
"6) 待提交文件数:";             (git status --short | Measure-Object).Count
"7) 总体积 MB:";               [math]::Round(((git ls-files | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum/1MB),2)
"8) 最大的 5 个文件:";          git ls-files | ForEach-Object { [pscustomobject]@{ F=$_; MB=[math]::Round((Get-Item -LiteralPath $_).Length/1MB,2) } } | Sort-Object MB -Descending | Select-Object -First 5
# 判读：1) 只出 build/build.ps1；2)~5) 全空；6) 100~250；7) < 15；8) 最大 1.64
```

---

## 9. Release 附件：两片 bitstream

### 9.1 取哪两个

`build\release\` 现在有 **80 个快照**，每次构建 +13.6 MB。**A/B 必须来自同一轮构建**（混版会导致两片窗口表位段不一致，表现为 B 板窗口乱掉）。

| 写法 | A | B | 说明 |
|---|---|---|---|
| **最新（权威）** | `20261031_211735_A` | `20261031_212015_B` | **用这一对**：写文档这一刻 `build\release\` 里最新的一对 |
| **选取规则** | 按目录名排序，取最后一个 `<时间戳>_A` | 取最后一个 `<时间戳>_B` | **重建后按这条重取，不要写死时间戳**；A/B 必须同一轮 |

每片 `WALL_A.bit` / `WALL_B.bit` 都是 **614.9 KB**，远小于 25 MB 限制，适合做 Release 附件。

不想记时间戳就用这三行，永远取最新的一对：

```powershell
$rel = "C:\Users\japsa\Documents\deepseek-harness\default-workspace\wall\build\release"
$a = (Get-ChildItem $rel -Directory | Where-Object Name -match '^\d{8}_\d{6}_A$' | Sort-Object Name | Select-Object -Last 1).Name
$b = (Get-ChildItem $rel -Directory | Where-Object Name -match '^\d{8}_\d{6}_B$' | Sort-Object Name | Select-Object -Last 1).Name
"A = $a"; "B = $b"
# 期望：A = 20261031_211735_A ; B = 20261031_212015_B（下次重建后会变成更新的时间戳）
```

```powershell
# 确认两片 bit 都在，并算 SHA256（贴进 Release 说明里）
Get-Item "C:\Users\japsa\Documents\deepseek-harness\default-workspace\wall\build\release\20261031_211735_A\WALL_A.bit",
        "C:\Users\japsa\Documents\deepseek-harness\default-workspace\wall\build\release\20261031_212015_B\WALL_B.bit" |
  Get-FileHash -Algorithm SHA256 | Format-List Path, Hash
# 期望：两行 64 位十六进制哈希，大小都是 614.9 KB
```

```powershell
# 顺手把两片的 LUT 占用抄出来，贴进 Release 说明当"这两片是什么版本"的证据
foreach ($d in "20261031_211735_A","20261031_212015_B") {
  $log = "C:\Users\japsa\Documents\deepseek-harness\default-workspace\wall\build\release\$d\build.log"
  "$d : " + (Select-String -Path $log -Pattern '#lut\s+\d+\s+out of' | Select-Object -First 1).Line.Trim()
}
# 期望：
#   20261031_211735_A : #lut  13811   out of  19600   70.46%
#   20261031_212015_B : #lut   9331   out of  19600   47.61%
```

### 9.2 网页操作（没装 gh CLI，用网页）

1. 打开 `https://github.com/<用户名>/<仓库名>/releases` → 右侧 `Draft a new release`。
2. `Choose a tag` 输入 **`v1.0-c9r2`** → 点 `Create new tag: v1.0-c9r2 on publish`。
3. `Release title`：`v1.0-c9r2 —— 两片 bitstream（C9-R2，0 违例）`。
4. `Describe this release` 粘贴：

```markdown
C9-R2：切页淡出淡入 + 每片只取自己半屏画得到的窗口。

| | A 板 | B 板 |
|---|---|---|
| 快照 | 20261031_211735_A | 20261031_212015_B |
| bit | WALL_A.bit (614.9 KB) | WALL_B.bit (614.9 KB) |
| LUT | 13811 / 19600 = 70.46% | 9331 / 19600 = 47.61% |
| 时序 | 0 违例，WNS +0.557 ns | 0 违例，WNS +0.347 ns |

烧录：cable 0 = A，cable 1 = B（换 USB 口会变，先跑 `tools\flash_pair.ps1 -VerifyOnly`）。
掉电自启需写 W25Q16：`tools\persist_pair.ps1`。

SHA256：
（把上面命令的输出贴进来）
```

5. 把 `WALL_A.bit` 改名成 **`WALL_A_20261031_211735.bit`**、`WALL_B.bit` 改名成 **`WALL_B_20261031_212015.bit`**（两个原名一样，附件列表里分不清谁是谁）。
6. 拖进 `Attach binaries by dropping them here` 区域。
7. **不要**勾 `Set as the latest release` 之外的选项；**不要**勾 pre-release。
8. `Publish release`。

### 9.3 为什么 bit 不进仓库

- 仓库里存二进制，每次构建都产生新版本 → 仓库体积线性膨胀，且 `git clone` 会把所有历史 bit 都拉下来。
- GitHub 对单文件 > 50 MB 会警告、> 100 MB 直接拒收；bit 虽小，但 80 个历史版本 × 615 KB = 49 MB，没必要。
- Release 附件**不受仓库体积统计**，且可以随时删旧版、留新版，是 bit / 视频 / 报告 PDF 的正确去处。
- `.gitignore` 里已有 `*.bit`，双保险。

---

## 附录 A：常见报错速查

| 报错 | 原因 | 修法 |
|---|---|---|
| `git : 无法将"git"项识别为 cmdlet` | 装完没重开终端 | 关掉所有终端重开；仍不行把 `C:\Program Files\Git\cmd` 加进 PATH |
| `fatal: not a git repository` | 不在 `wall\` 下，或还没 init | `cd wall` 后重跑，或先 `git init` |
| `fatal: detected dubious ownership` | 目录属主和当前用户不一致（换过电脑/盘） | `git config --global --add safe.directory "C:/Users/japsa/Documents/deepseek-harness/default-workspace/wall"` |
| `git status` 列出上万个文件 | `.gitignore` 没生效 | 确认文件名不是 `.gitignore.txt`、在 `wall\` 根目录、内容是 UTF-8；`git rm -r --cached .` 后重新 `git add -A` |
| `warning: LF will be replaced by CRLF` | Windows 换行符 | 无害；建了 §5.2 的 `.gitattributes` 后不再出现 |
| `Support for password authentication was removed` | GitHub 不支持账号密码 | 用 PAT（Settings → Developer settings → Tokens classic → 勾 repo）当密码 |
| `error: src refspec main does not match any` | 还没 commit，或分支叫 master | 先 `git commit`；再 `git branch -M main` |
| `remote origin already exists` | 之前加过 | `git remote remove origin` 后重加 |
| `Failed to connect to github.com port 443` | 网络 | 换热点；或 `git config --global http.proxy http://127.0.0.1:7890` |
| `fatal: The current branch main has no upstream branch` | 第一次推没带 `-u` | `git push -u origin main` |
| `RPC failed; HTTP 413` | 单次推送太大 | 本项目不会遇到（6 MB）；若遇到说明 `.gitignore` 失效 |

## 附录 B：一页速查

```powershell
# 从零到有链接，11 条
winget install --id Git.Git -e --source winget      # 装完重开终端
git config --global user.name  "43927-dingxuzhao"
git config --global user.email "43927-dingxuzhao@users.noreply.github.com"
git config --global core.quotepath false
git config --global core.autocrlf false
cd C:\Users\japsa\Documents\deepseek-harness\default-workspace\wall
git init
git add -A
git status --short | Measure-Object                  # 期望 150 左右
git commit -m "feat: 双屏无缝拼接多媒体播放墙（C9-R2，两片 0 违例）"
git branch -M main
git remote add origin https://github.com/<用户名>/<仓库名>.git
git push -u origin main
```

三件事不要做：

1. **不要**在 `default-workspace\` 根目录 `git init`（那里有 13 个项目和几十万构建产物）。
2. **不要**在 `.gitignore` 写好之前 `git add -A`（1,475 MB 会进暂存区，清起来要 `git rm -r --cached .`）。
3. **不要**把 `.enc.v`、`build\`、`*.hex`、`media\*.BMP` 提交上去——它们是厂商 IP、构建垃圾和可再生成数据。
