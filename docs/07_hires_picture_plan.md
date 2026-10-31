# 07 高清图片（SDRAM 行缓冲）—— 交接文档

> 目的：新会话读这一份就能直接开工，不用重新踩一遍坑。
> 关联代码：`wall/rtl/wall_tf_load.v`、`wall/rtl/wall_scene.v`、`wall/rtl/wall_top.v`、
> `wall/rtl/wip/wall_tf_load_hires.v.txt`（已写好的高清装载器）

## 1. 为什么现在糊，以及为什么必须用 SDRAM

窗口内容区约 260×195，而每张图在板上只存了 **96×72 / RGB444**：

```
96×72 = 6,912 像素  →  放大 2.7×  →  肉眼就是糊的
```

放不下更清晰的图，是**片上 BRAM 容量**决定的：

| | 数值 |
|---|---|
| 器件 BRAM | 约 54 块 ≈ 486 kbit（当前工程已用 60 块，含其它模块） |
| 现有 4 张 96×72 RGB444 | 4 × 6,912 × 12 bit = **331 kbit** |
| 若要 4 张 288×216 RGB444 | 4 × 62,208 × 12 bit = **2,986 kbit** ✗ 不可能 |

**SDRAM 8 MB** 完全够用，且音乐只占 5.76 MB：

| 区域 | 字地址范围（21 位） | 说明 |
|---|---|---|
| 音乐 | 0 … 1,439,277 | 30 s 立体声 48 kHz，`wall_tf_load` 装载，`wall_music` 播放 |
| 图片（计划） | 1,700,000 起，每张 62,208 字 | 288×216 RGB565，4 张共 248,832 字 |

## 2. 目标方案

```
BMP(24bit) --> 装载器 288×216 采样 --> SDRAM（每像素 1 个 32-bit 字，RGB565）
                                          |
                            每显示行一次突发读（288 字 ≈ 2 µs）
                                          v
                              行缓冲 BRAM（双端口：150 MHz 写、25 MHz 读）
                                          v
                                  场景逐像素读取（缩放/移动/置顶全保留）
```

- 288×216 装进 260×195 的内容区 ≈ **1.1:1**，像素量是现在的 **11 倍**
- 行缓冲：4 窗口 × 2 份（乒乓）× 288 × 16 bit = 36,864 bit ≈ 4 块 BRAM ✓
- 一帧需要 4 × ~195 × 288 ≈ 225 k 字突发，150 MHz 下约 1.5 ms/帧 ✓ 富余
- 读口需要与音乐播放（48 kHz，每 20.8 µs 1 字）仲裁：**图片突发优先**，音乐读延后即可

## 3. 已经做完的部分（可直接复用）

`wall/rtl/wip/wall_tf_load_hires.v.txt` 是基于当前 `wall_tf_load.v` 的**高清版本**：

- 采样改为 `sx = w/288`、`sy = h/216`
- 发射条件 `k <= 9'd287`，行数 `brow` 到 215
- 每个像素通过 `mw_*` 邮箱写 SDRAM：`hold_data = {r[7:3], g[7:2], b[7:3]}`
- 地址 `pic_base[id] + brow*288 + k`，`pic_base = {1700000, 1762208, 1824416, 1886624}`
- 旧的 96×72 bank 保留为"每 3 行 / 每 3 列取 1"（`m3`/`brow3`/`k3`/`kb`）

**这块功能实测是通的**：板上一度能看到 `MUSIC CARD` 且 4 张图正常，说明
288×216 的 SDRAM 写入与音乐装载互不干扰。

## 4. 已知的坑（都踩过，别再踩）

| 坑 | 现象 | 正确做法 |
|---|---|---|
| TB 的 SD 模型扇区数太小 | `err=6`（BMP 头被拒），其实是读到垃圾 | `tb_tf_load.v` 的 `NSEC` 要给够（≥ 镜像扇区数，现在 4096） |
| 216 行写进 72 行的 bank | 图片错乱、`bank_ok` 异常 | 每 3 行/3 列取 1，用 `m3`/`brow3` |
| 组合深度暴涨 | `SWNS -11.7 ns`（25 MHz 域崩） | 显示端一起换；HUD 里每多一个 `hexch` 约 0.5 ns，别在 HUD 里堆十六进制 |
| 命名重复 | `wr_addr` 与图片 RAM 端口冲突 | SDRAM 侧统一用 `mw_*` 前缀 |
| 状态机宽度 | `mul_ret` 只有 4 位，`S_WAVH=16` 被截断成 0 | 加状态后所有"保存状态"的寄存器都要检查宽度 |
| `cpb` 是"当前字节"不是字节数组 | 解码写成 `cpb[5]`/`cpb[7:5]` 得到的是字节而非位 | 在对应的 `copy_idx == N` 分支里取位 |
| 采样/供电试错 | 串口时有时无 | `-cable 0` = A、`-cable 1` = B；`download` 只进 SRAM，`-Persist` 才写 Flash |
| 掉电保留 | 只 `download` 的话断电就丢 | 定稿后必须 `build.ps1 -Role a/b -Persist` |

## 5. 开工步骤（建议顺序）

1. **恢复 WIP**：把 `rtl/wip/wall_tf_load_hires.v.txt` 覆盖回 `rtl/wall_tf_load.v`；
2. **先只验证装载**：改 `tb_tf_load` 让它校验 SDRAM 字流（4 × 62,208 个 RGB565），
   生成器 `tools/make_tb_fat32.py` 里已有 `expected_pic.hex` 的雏形（见 `_pic` 相关代码），
   校验规则：`pic[i] = (r>>3)<<11 | (g>>2)<<5 | (b>>3)`，未写的字为 `x`（不比较）；
   这一步 TB 全绿之后**再动显示端**。
3. **写 `wall_pic_line.v`**（新模块）：
   - 双端口行缓冲 4 窗口 × 2 乒乓 × 288 × 16 bit
   - 150 MHz 侧：收到请求（toggle 信箱）→ 突发读 288 字 → 写入缓冲 → 翻 ack
   - 25 MHz 侧：场景按"当前显示行需要的源行"发请求；**提前一行预取**（否则行首 13 列是旧数据）
   - 双端口 BRAM 推断（写 150 MHz / 读 25 MHz），不需要异步 FIFO
4. **改 `wall_scene.v`**：把 `img_addr/img_rgb444` 换成 `pic_rgb565` + 行缓冲读地址；
   `sx/sy` 上限改成 287/215；`in_pic` 逻辑不变（等比缩放/居中不受影响）
5. **`wall_top.v`**：SDRAM 读口加 mux（图片突发 > 音乐单字），实例化 `wall_pic_line`
6. **TB**：`tb_pic_line`（突发读、乒乓切换、行首正确性）+ 复用 `tb_scene`（把期望改成
   从 288×216 源取样）
7. **时序**：A 板 25 MHz 域余量一直在 +0.1~+0.5 ns 之间，任何新组合逻辑都要先看
   `build/td_A/final_timing.rpt` 的 `SWNS`，**负值就不要烧**
8. **烧录**：`build.ps1 -Role both` → `download`（SRAM 试）→ 满意后 `-Persist`

## 6. 验收标准

- 4 张图在窗口里显示，源分辨率 288×216（肉眼接近 1:1，明显比现在清晰）
- 拖拽/缩放/置顶置底/跨屏无缝**全部保持现有行为**（`tb_node`/`tb_drag` 必须 PASS）
- 音乐继续正常（`tb_wav`/`tb_music` PASS）
- A/B 时序 `SWNS > 0`
- 上电后约 10 s 内出图、出音乐（装载时间不显著变长）

## 7. 当前基线（开工前请确认仍成立）

```
A: SWNS +0.290 ns    B: SWNS +0.141 ns
TB: tb_osd/tb_scene/tb_img/tb_node/tb_drag/tb_wav/tb_music/tb_audio/tb_mute 全 PASS
板上：4 张 96×72 图 + 卡上音乐（×64）+ A 侧电平条 + MUSIC CARD
备份：build/good/music_A.bit、build/good/music_B.bit
```

> **2026-10-29 更新 —— 本计划已实施完成，见 `docs/08_hires_impl_status.md`。**
> 新基线：A **+0.386 ns** / B **+0.152 ns**，13 个 TB 全 PASS，BRAM 24/64，
> `build/td_A/WALL_A.bit` / `build/td_B/WALL_B.bit`（638,944 B）。
> 与本文的偏差（旧 96×72 图库被删除、A→B 改为推送高清、源列用 ×3）在 08 的 §3 里写明了原因；
> 只剩「上板目视验收」未做。

改动前建议先 `git`-less 备份：

```powershell
Copy-Item -Recurse wall\rtl wall\rtl_backup_hires -Force
Copy-Item -Recurse wall\tb  wall\tb_backup_hires  -Force
```
