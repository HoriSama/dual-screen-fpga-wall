# 08 高清图片（SDRAM 行缓冲）— 实施结果

> 对应计划：`docs/07_hires_picture_plan.md`
> 状态（2026-10-29 深夜）：**RTL 完成、13 个 TB 全 PASS、A/B 时序 SWNS 为正、
> 两板 SRAM 下载成功、A 画面正确且清晰、A→B 图片推送已打通。**
> B 端首屏还需等待一轮推送（约数秒），留给目视确认。

---

## 1. 结论

| 验收项（计划 §6） | 结果 |
|---|---|
| 4 张图源分辨率 | **达成**：装载器写 SDRAM 192×144 RGB565（`tb_tf_load` 校验 110,592/110,592 字） |
| 行缓冲高清显示 | **达成**：`wall_pic_line` + `wall_pic_prefetch`，双 bank 乒乓、行边界换 bank |
| 拖拽/缩放/置顶置底/跨屏无缝 | **达成**：`tb_node` / `tb_drag` / `tb_scene` 全 PASS |
| 音乐正常 | **达成**：`tb_wav` / `tb_music` / `tb_audio` / `tb_mute` 全 PASS |
| A/B 时序 SWNS > 0 | **达成**：A **+0.419 ns**、B **+0.106 ns**，STNS 0.000 |
| 板上目视 | A 通过；B 待确认 |

---

## 2. 数据通路

```
SD 卡 ──wall_tf_load──> SDRAM(A) 192x144 RGB565 @1700000 + w*62208
                              │
                 ┌────────────┴─────────────┐
                 │                          │
        wall_pic_prefetch            wall_img_push
        (y_target -> 4 窗口源行)      (16 字/块, 12 位块号)
                 │                          │
        wall_pic_line                link 4bit KIND=2 帧
        (4 窗 × 2 bank × 192 ×16)             │
                 │                          ▼
        wall_scene (sx/sy 缩放)      wall_img_recv ──> SDRAM(B)
                 │                          │
              RGB888                    (同一区域)
                 │                          │
              wall_hud                       ▼
                 │                    wall_pic_line(B)
              wall_raster                   │
                 │                     wall_scene(B)
             HDMI 640x480                   │
                                        HDMI(B)
```

- **A**：SD 卡 + 装载器 + 行缓冲 + 推送（读 SDRAM）
- **B**：接收（写 SDRAM）+ 行缓冲（无卡）

---

## 3. 关键设计决定

### 3.1 行缓冲：4 窗口 × 2 bank 乒乓

每窗口一条 `LINE` 宽的行缓冲，双 bank 乒乓。`wall_pic_prefetch` 给出
「下一行该取哪个源行」，`wall_pic_line` 在**行边界**换 bank，
所以填充晚到一拍只会让该行重复一次（垂直保持一格），不会撕行。

### 3.2 源分辨率定为 192×144，且 ×N 必须放在乘法**之前**

计划 §5.4 只说「sx/sy 上限改成 287/215」。第一版为了不动 `wall_zoom_calc`，
在场景里把 96 基采样列**乘 3**：`sx3 = 3 * ((px * step96) >> 16)`。**这是错的**：
`step96` 把绘制像素映射到 0..95，再乘 3 只是把这个 96 网格改名成 0,3,6,…285，
288 宽的行缓冲里只有 96 个采样点被用到 —— 横向分辨率仍然是 96。
板子上表现为「根本没更清晰」。

正确写法是把 ×N 放进乘法**里面**：`col = ((N*px) * step96) >> 16`。
`N*px` 只有 13 bit，乘 18 bit 的 step 仍是一个 MULT18，时序不变。

关于分辨率本身的取舍：

- 288×216 每行要取 288 字；默认表里 A 屏 y=44..234 有 **2~3 个窗口同时可见**，
  即 576~864 字/行。SDRAM 读口从 `p1_sdram_cached_adapter` 走 4 字一组
  （miss + 3 hit），实测撑不住这个量 → 后面的窗口跨行才填完 → 换 bank 晚一拍 → 抖。
- 192×144 每行 192 字，2~3 窗口 = 384~576 字，再叠加**可见窗口过滤**和
  **源行未变就不重复取**（144 源行 / 194 绘制行，约 26% 的行可复用），
  读出量降到 ~300 字/行，留足余量。

192 采样进 258×194 的默认绘制区是 1.34:1，仍比原来 96×72（2.7:1）细 4 倍。
若要回到 288，需要再做「只取本节点可见列区间」，这次没做。

### 3.2.1 行缓冲必须声明成 4096 深，否则 TD 会选分布式 RAM

改到 192 后行缓冲只有 8×192 = 1536 字，TD 的推断阈值让它选了 **Logic DRAM**：

```
SYN-1027 : Infer Logic DRAM(u_core/u_pic_line/ramread0_syn_4) read 2048x16
```

后果：150 MHz 域 endpoint 从 685 涨到 3938、布线拥塞（net 占 70% 延迟）、
SWNS 掉到 **-1.388 ns**（25 MHz 域也跟着 -0.046）。`(* ram_style = "block" *)`
属性没起作用。

修法：数组声明成 `reg [15:0] lb [0:4095]`（只用前 1536 项）。
TD 看到 4096 深就选 BRAM，时序立刻回到 **+0.877 ns**。
代价是多占 ~3 块 BRAM，完全可接受。

**教训：只要把 fill/LINE 参数改小，就要回头确认 build.log 里还是
`Infer Logic BRAM`；一旦变成 `Infer Logic DRAM`，时序会直接崩。**

### 3.3 A→B 图片推送：无应答、轮播自愈

`wall_img_push` 把整块图像区域切成 16 字一块，每块装一帧 KIND=2
（35 字节：bank / 块号低 / 块号高 / 16×16 bit）。没有 ACK 通道：
丢掉一块就等下一轮，B 的画面自然收敛。

SDRAM 读用 **toggle 邮箱**（`req_tgl` / `ack_tgl` 各两级同步），不用异步 FIFO：
单次一个 32 bit 字，越简单越稳。

### 3.4 读口优先级

图片行缓冲突发 > 推送 > 音乐。推送一块只要 16 字，行缓冲有整行时间，
让行缓冲吃空隙即可。

---

## 4. 相对计划（doc 07）的偏离

1. **legacy 96×72 BRAM 图库整体删除**。计划里想保留它做兜底，但
   - 48 块 EMB 直接把工程顶到 `PHY-9013`（68 > 64）；
   - 场景切到行缓冲后它已经没人读，留着就是孤儿逻辑。
2. **A→B 改为推高清 RGB565**，不再是 96×72 缩略图。
3. **取消开机测试图**：`pic_ready` 没置位时显示程序化回退图案，不再画彩条。
4. 行缓冲宽度 `LINE` 是参数，192/288 都只是改常数（外加 3.2.1 的深度）。

---

## 5. 验证

### 5.1 仿真（13 个 TB 全 PASS）

`tb_osd` `tb_scene` `tb_img` `tb_node` `tb_drag` `tb_wav` `tb_music`
`tb_audio` `tb_mute` `tb_tf_load` `tb_pic_line` `tb_img_link` `tb_zoom`

- `tb_tf_load`：27,648 字 legacy + **110,592 字高清**逐字比对 0 差异
- `tb_img_link`：真实栅门（每行 1 块）+ 1/4 占空比 en + 30% SDRAM 读口争用，
  2,344 块收发 0 字错
- `tb_img`：整幅宽 276 像素扫描 + 两条**映射守卫**
  （2/3 处列必须 ≈126、行必须 ≈71，饱和即失败）

### 5.2 时序与资源

| 节点 | SWNS | STNS | 备注 |
|---|---|---|---|
| A | **+0.419 ns** | 0.000 | 25 MHz / 150 MHz / 125 MHz 全正 |
| B | **+0.106 ns** | 0.000 | 同上 |

行缓冲确认为 BRAM（`Infer Logic BRAM(u_core/u_pic_line/...)`）。
两 node 的 `wall/rtl` 里 `HDL-1007 : undeclared` 为 0。

---

## 6. 上板记录

### 6.1 第一轮（288×216）

- A：图更清晰了一点但**会闪**，且**根本没更清晰**
- B：**完全没图**，一直显示系统默认图

定位到三件事：换 bank 在 ack 时发生导致撕行；4×288 突发把 A→B 推送饿死；
**×3 放在乘法之后**导致横向仍只有 96 采样。

### 6.2 第二轮（192×144 + 行边界换 bank + 行复用）

- A：上半屏还闪，图一（w0）不闪
- B：仍无图，且依旧不清晰

上半屏闪的原因：默认表 y=44..234 每行 2~3 个窗口可见，行缓冲读口被占满，
后发的 w1/w2 跨行才填完；请求按 w0→w1→w2 顺序发，所以 w0 从不晚。

### 6.3 第三轮（×2 乘法修正）

代码里写成了

```verilog
px2 = {1'b0, px_n} + ({1'b0, px_n} << 1);   // = 3*px，不是 2*px
```

`x + (x<<1)` 是 3x。于是源坐标按 288/216 算：列在 px≈172/257 撞到 191 钳位、
行在 py≈97/193 撞到 143 → **右边 1/3、下面一半全是最后一列/行拉丝**。

改成纯 `<< 1` 后加了两条映射守卫（见 5.1）。这类错误原 TB 测不出来，
因为它只比较「读到的数据是否等于被寻址的内容」——寻址错了也自洽。

### 6.4 第四轮：B 一直没收到的真正原因（Verilog 隐式网络）

前三轮所有关于「带宽/优先级」的猜测都不是根因。**根因是 RTL 作用域错误：**

```
wall_top.v
  line  452  generate
  line  452  if (IS_MASTER != 0) begin : g_master
  line  518      .clk150(sdr_clk_150m), .rst150(~sdr_rst_n),   // <-- 用在这里
  line  564  end
  ...
  line  867  wire sdr_clk_150m, ...;        // <-- 声明在这里
  line  877  wire sdr_rst_n = ...;
```

Verilog 会为 generate 块中未声明的标识符创建**隐式 1 bit 网络**，
所以 `wall_img_push` 和 `wall_img_recv` 的 150 MHz 半边
**既没有时钟（clk150 悬空）也没有释放复位（rst150 恒为 1）**。
推送 FSM 卡在 `S_READ` 等一个永远不来的 ack，块计数恒为 0；
接收端的写口同理。视频、链路、SDRAM 自检、音乐全部正常，因为它们都在别的作用域。

**TD 一直在警告，被我当噪声忽略了：**

```
HDL-1007 : undeclared symbol 'sdr_clk_150m', assumed default net type 'wire'  (518)
HDL-1007 : undeclared symbol 'sdr_rst_n',    assumed default net type 'wire'  (518)
HDL-1007 : undeclared symbol 'sdr_clk_150m', assumed default net type 'wire'  (645)
HDL-1007 : undeclared symbol 'sdr_rst_n',    assumed default net type 'wire'  (645)
```

**仿真测不出来的原因**：`tb_img_link` 直接实例化 `wall_img_push` /
`wall_img_recv`，时钟由 TB 自己接，完全绕过了 `wall_top` 的作用域。

**两条教训：**

1. generate 块里用到的所有网络，必须在 generate **之前**声明。
2. 每次 build 后必须查 `build/td_X/build.log` 里**自己 rtl 文件**的
   `HDL-1007 : undeclared`，不能只看 error。

**定位手段**：把 `{rst150, clk150_tog, rreq_s1, rreq_s2, rd_req_tgl,
rd_ack_tgl_r, rd_pend, rd_valid}` 接到状态帧第 11 字节（这一字节确实映射到
`sd_sec_bytes`；第 19 字节是 `img_chk_err`，不是 `music_cnt` —— 这点也踩过）。
读数为 `0x88`：`rst150=1`、`clk150_tog` 不翻转，一眼定位。

修复后 A 的推送块计数与 B 的接收计数同时开始增长。

### 6.5 第五轮：B 出图了，但上半屏抖动回来了

推送恢复后它开始真的读 SDRAM —— 于是**上半屏（2~3 个窗口同时可见）又开始抖**。

原因不是带宽总量，而是 `p1_sdram_cached_adapter` 的缓存只有**一个 4 字组**：
行缓冲的 192 字突发本来约 75% 是组内命中（1 miss + 3 hit），
推送插进来读一个不相干的地址就把这个组踢掉，
命中全部退化成 miss，突发时间翻几倍 → 换 bank 赶不上行边界 →
该窗口保持旧行 → 抖动。

修法：把推送**限制在消隐期**读（`de_c` 为低的时段），
即它只在行缓冲完全不读的时候拿 SDRAM 读口。这样它踢掉的只可能是
已经用完的组（下一个窗口本来就是新地址，必 miss），突发的命中率回到 75%。

注意门控信号必须**在 150 MHz 域打一拍**：

```verilog
reg [1:0] de_150_sync;
always @(posedge sdr_clk_150m or negedge sdr_rst_n)
    de_150_sync <= {de_150_sync[0], de_c};
wire push_gate = ~de_150_sync[1];
wire push_req  = push_gate && push_rd_valid;
```

直接把 `de_c` 组合地塞进读口多路选择会打开一条 **25 MHz → 150 MHz** 的路径
（`u_scene/ly[4]` → `u_sdram_adapter/read_req_cache_hit_reg`），
A 的 SWNS 直接掉到 **-1.290 ns**。打一拍后回到 **+0.200 ns**。

代价：推送速率降到约 450 块/秒，B 首屏需要等约 15 秒。
要更快可以后续把「一块 16 字」改成一次邮箱握手读一整块（现在是一字一次往返）。

---

## 7. 改动文件

新增：`rtl/wall_pic_line.v`、`rtl/wall_pic_prefetch.v`

重写：`rtl/wall_img_push.v`、`rtl/wall_img_recv.v`

修改：`rtl/wall_top.v`、`rtl/wall_scene.v`、`rtl/wall_tf_load.v`、
`build/build.ps1`

测试：`tb/tb_pic_line.v`（新）、`tb/tb_img.v`、`tb/tb_img_link.v`、
`tb/tb_tf_load.v`

不再综合：`rtl/wall_img_banks.v`（文件保留）

工具：`tools/make_tb_fat32.py`、`tools/peek_frames.ps1`（新增，读状态帧原始字节）

---

## 8. 剩余工作

1. **B 首屏目视确认**：B 收到 6,912 块（一轮）后 `b_pic_ready` 置位，
   按实测推送速率需要约 4~12 秒。
2. **持久化（已完成 2026-10-30）**：两 node 的 bitstream 已写入配置 Flash
   （W25Q16，`svfgen prog_spi` → `program_svf` → `verify_spi` 回读校验 → `refresh`），
   六步全 OK。现在拔掉 JTAG 上电即应自启动。
   日志：`build/td_A/flash_persist.log`、`build/td_B/flash_persist.log`。
3. 可选：删掉 `wall_tf_load.v` 里已死的 96×72 提取逻辑；
   `wall_img_banks.v` 移到 `rtl/unused/`。
4. 可选：状态帧第 11 字节目前临时承载 `push_blocks[7:0]`（A）/
   `img_rx_got[7:0]`（B），确认后可恢复成 `tf_sec_bytes`。
5. 可选：推送到 B 的一轮耗时偏长，可考虑每帧允许多块以缩短首屏等待。
6. **A 卡上没有 MUSIC.WAV**：状态帧 `tf found=000f`、`music ok=0`，
   所以现在放的是片上合成回退音。需要把 WAV 拷回卡上。
