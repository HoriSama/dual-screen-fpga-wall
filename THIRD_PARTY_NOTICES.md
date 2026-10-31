# 第三方组件与厂商 IP 说明 / Third-Party Notices

本仓库是参赛作品「双屏无缝拼接多媒体播放墙」的**自有逻辑与文档**。
以下组件不属于本项目，或按其原始许可使用，特此说明。

## 1. 安路（Anlogic）加密 IP —— **不在本仓库**

| 组件 | 用途 | 为什么不在仓库里 |
|---|---|---|
| `APUG092` HDMI 发送器（`fpga_hdmi/build_src/src/vendor/anlogic/apug011/enc_file/*.enc.v` 等） | HDMI 输出时序与 TMDS 编码 | 安路官方以**加密源码**分发，许可证不允许再分发或公开 |
| `EG_PHY_PLL`、`EG_LOGIC_BRAM`、`SDR_AS_RAM` 等原语/宏 | 时钟、ROM、SDRAM 控制器 | 随 TD（Tang Dynasty）工具链提供，属厂商工具的一部分 |

因此：**clone 本仓库不能直接综合出比特流**。构建方法见 README「快速开始」第 3 步，
需要自备安路官方例程（`fpga_hdmi/` 目录）并放在与本仓库同级的位置。
`.gitignore` 里保留了 `*.enc.v` / `fpga_hdmi/` / `vendor/` 三条兜底规则，防止误提交。

## 2. 安路 SD 卡驱动例程

`rtl/sd/`（4 个文件，约 889 行）改编自安路官方 SD 卡例程（SPI 模式初始化 + 整扇区读写），
本项目在其上补了 FAT32/MBR 解析与 BMP 逐行读取（`rtl/wall_tf_load.v`）。
如再分发，请保留原例程的版权声明。

## 3. 字体

| 用途 | 来源 | 说明 |
|---|---|---|
| HUD 8×8 ASCII 字模 `rtl/wall_font_rom.v` | `tools/gen_font.py` 从 **Lucida Console** 光栅化生成 | 只包含字形位图，随代码以 MIT 发布 |
| 滚动字幕 16×16 中文字模 `rtl/wall_font_cn.v` | `tools/gen_font_cn.py` 从 **SimHei（黑体）** 光栅化生成 | 同上；仅 17 个字形，用于演示"跨屏连续滚动" |

字体**文件本体**未包含在本仓库中，仓库里只有从字体渲染出来的点阵位图；
如需商用请自行确认系统字体的授权。

## 4. 开发工具

- **Tang Dynasty 6.2**（安路综合 / 布局布线 / 时序分析）—— 商业 EDA，不在仓库内。
- **ModelSim ASE**（仿真）—— 不在仓库内。
- Python 脚本用到 `Pillow`（生成字模与预览图）。

## 5. 图片素材

`media/` 下的窗口图案（彩条 / 棋盘 / 渐变 / 十字）由 RTL 自己生成；
`media/CAM*_preview.png` 是 `tools/make_camera_bmps.py` 生成的示意图片，不是第三方素材。
`media/wall_1280x480.png` 由 `tb/tb_hero.v` 仿真渲染得到。