# 方案 3 验收记录（HX4S20C 双板 · 跨屏窗口拖拽监控墙）

日期：2026-10-28　版本：W1（墙面本体）+ SDRAM 地基　工程：`wall/build/td_A`、`td_B`

## 1. 验收结论

| # | 指标 | 证据 | 状态 |
|---|---|---|---|
| 1 | 全局坐标窗口表每帧广播 | 协议见 `01_spec.md`；真板两板同时读：`gx=24 sel=0 own=0` 完全一致；`ok` 计数 60 帧/s | ✅ 通过 |
| 2 | 两板各自裁剪绘制 | 仿真 `TB_SCENE PASS`：307,200 像素逐点比对 0 错误；真板两屏出画（用户确认） | ✅ 通过 |
| 3 | 窗口跨接缝 0 像素错位 | 仿真：`TB_SCENE` 覆盖窗口边界正好落在 x=640 的情形，0 错误；`TB_NODE` 120 次/s 拖拽下 A/B 逐帧相等 | ✅ 通过（仿真 + **用户真板目视确认：接缝连续、无 1 像素错开**） |
| 4 | 按键拖拽 | 真板：KEY1 换选中、KEY3/KEY4 移动、KEY2 进/出拖拽（边框闪烁 + `DRAG` 提示） | ✅ 通过 |
| 5 | 松手时所有权转移 | 仿真 `TB_DRAG PASS`：gx=44 松手 owner 保持 0，gx=777 松手 owner 翻 1；真板：自动拖拽后 `own=1` 且两板一致 | ✅ 通过（含一条未解疑点，见 §4） |
| 6 | 拔线降级 | 仿真 `TB_NODE PASS`：切 B→A 链路 A 显示 `LINK LOST`；切 A→B 窗口冻结 `FROZEN`；恢复后两板重新同步 | ✅ 通过（仿真 + **用户真板拔插确认：LINK LOST / FROZEN / 恢复同步**） |
| 7 | 接口/包格式规范 | `docs/01_spec.md`（坐标、窗口表位段、链路包格式、状态帧 34 字节） | ✅ 通过 |
| 8 | 可综合 RTL | `wall/rtl/*.v`，TD 6.2 综合/布局/布线通过 | ✅ 通过 |
| 9 | 仿真自检 | `TB_SCENE / TB_LINK / TB_NODE / TB_DRAG / TB_STATUS` 全部 PASS；**TF 接入后重跑** `TB_SCENE`（2 组布局 460,800 px）/ `TB_NODE` / `TB_DRAG` 仍全 PASS | ✅ 通过 |
| 10 | TD 工程与引脚约束 | `wall/pin/wall_node_{a,b}.adc`、`wall_{a,b}.sdc`；时序 A **+0.163 ns** / B **+0.265 ns**，0 hold 违例 | ✅ 通过 |
| 11 | 上板烧录 | `build.ps1 -Role both` → `download` 双板，状态帧自检 `link=1 sync=1 vlock=1 state=RUN` | ✅ 通过 |

## 2. 真板实测数据（最终版本）

```
A: link=1 sync=1 own=0 sel=0 gx=24 w=300 vlock=1 state=RUN sdram_done=1 errors=0
B: link=1 sync=1 own=0 sel=0 gx=24 w=300 vlock=1 state=RUN sdram_done=1 errors=0
```

- 链路：`ok` 单调递增 ≈60 帧/s，`er` 增长 ≈2 次/s（CRC 检出，不影响画面）
- genlock：`no_align` 累计 1 次后归零，两板帧相位锁定
- HDMI：APUG092 `video_locked=1`，supervisor `rec=0`（零次重试）
- SDRAM：上电写 1024 字读回，`errors=0`

## 3. 交付物清单

| 文件 | 内容 |
|---|---|
| `docs/01_spec.md` | 坐标系统、窗口表 64 bit 位段、链路包格式、状态帧格式 |
| `docs/02_bringup_log.md` | 完整调试记录（15 节，含每个真板 bug 的现象/根因/修法） |
| `docs/04_acceptance.md` | 本文件 |
| `rtl/wall_top.v` | 节点封装 + `wall_core`（PLL/复位树/raster/状态机/链路/渲染/AXIS/HDMI/SDRAM） |
| `rtl/wall_scene.v` | 窗口求值 + 绘制 + HUD |
| `rtl/wall_state.v` `wall_input.v` `wall_link.v` `wall_raster.v` | 表状态机、按键 FSM、4bit 链路、光栅 |
| `rtl/wall_hdmi_supervisor.v` `wall_status_tx.v` `wall_uart_tx.v` | HDMI 监督、状态串口 |
| `rtl/wall_sdram_test.v` | SDRAM 上电自检 |
| `tb/*.v` | 5 个自检 TB |
| `pin/*.adc` `pin/*.sdc` | 引脚与时序约束 |
| `build/build.ps1` | 一键构建/烧录（`a`/`b`/`both`/`demo`） |
| `tools/*.py` `media/CAM*.BMP` | 监控素材生成与 BMP 格式校验（W2 用） |

## 4. 已知限制与未解疑点

1. ~~接缝目视~~ → 用户已确认通过
2. ~~拔线降级~~ → 用户已确认通过
3. **自动拖拽的 owner 疑点**：自动拖拽激励下出现过 `gx=250, w=300, own=1`（中心 400 < 640，按规则应为 0）；
   人手按键路径由 `TB_DRAG` 证明正确，此疑点仅出现在自动激励下，记录在案
4. **时序余量很薄**：A +0.163 ns / B +0.265 ns（SDRAM 150 MHz 域引入后）。再加逻辑必须重跑 STA
5. ~~**TF 卡通路未通过**~~ 已在第十七轮解决：换用厂商 tl/sd/ 栈后 A 板可整扇区读；
   "卡是空的"是误判——LBA 0 是 MBR 分区表（type 0x0C，卷在 LBA 32），FAT32 卷里就有
   CAM1..4.BMP。W2.2 装载器上板 phase=6 / err=0 / found=000F / bank_ok=000F，
   四个窗口改为显示卡里的照片（docs/02_bringup_log.md 19、20）

## 5. 用户已完成的两项真板验证（2026-10-28 确认通过）

### 5.1 接缝检查

1. 按 **KEY2** → 选中窗口边框开始白/琥珀闪烁，右下角显示 `DRAG`
2. 用 **KEY3/KEY4** 把跨接缝的窗口（默认在 x=520..860）左右挪动 3~5 像素
3. 盯两屏交界处：
   - 窗口**边框**在 A 屏最右列 / B 屏最左列是否连续
   - 窗口**内容**过接缝时是否错开 1 像素或抖动
4. 再按 **KEY2** 结束拖拽

### 5.2 拔线降级

1. 拔掉 A→B 的链路排线（12 芯 J1）
2. A 屏应在 ~1 s 内显示 `LINK LOST`，B 屏窗口冻结并显示 `FROZEN`
3. 插回排线，两屏应在 ~1 s 内恢复一致（`SYNC OK`）

完成任一项后告诉我结果，我据此更新本表 §1 第 3/6 行的状态。
