# 06 背景音乐播放器（WAV）

**状态：已完成并上板。** 卡上的 `MUSIC.WAV` 前 30 s 被装进 SDRAM，由 `wall_music`
以 48 kHz 循环播出；没有可用 WAV 时自动回落到片上合成器，不会静音。

## 1. 素材与工具

| 项 | 位置 | 说明 |
|---|---|---|
| 4 张图片素材 | `wall/media/CAM1..4.BMP` | 640×480 / 24-bit，居中裁成 4:3 |
| 音乐 | `wall/media/MUSIC.WAV` | 《欢乐小调》前 29.98 s，48 kHz / 16-bit / 立体声 |
| AAC 解码 | `wall/tools/ffmpeg/ffmpeg.exe` | Media Foundation 和 WinRT 在 DSH 沙箱里一律 `E_ACCESSDENIED`（连纯 WAV 都读不了），libav.js 的所有变体又因为 MPEG 授权不带 AAC，最后用 npm 包 `@ffmpeg-installer/win32-x64` 里内嵌的原生 ffmpeg.exe。`tools/get_ffmpeg.ps1` 可重新获取 |
| 一键换歌 | `wall/tools/make_music.bat` | 找最新 `.aac` → 取前 30 s → 48 kHz/16-bit/立体声 → 覆盖 `wall\media\MUSIC.WAV` → 重写可移动盘 |
| 卡上成品 | `G:\MUSIC.WAV` + `CAM1..4.BMP` | 1,439,278 帧（装载器上限 1,835,008） |

**关键坑**：ffmpeg 默认会写一个 `LIST/INFO` 元数据块，`data` 就不在偏移 36 了，
装载器会拒收。必须带 `-map_metadata -1 -fflags +bitexact -flags:a +bitexact`。

**连续性**：装载器对 `MUSIC.WAV` 是**线性读**（不遍历 FAT 链），所以
`make_music.bat` 先写音乐、后写图片，保证文件在卡上连续。

## 2. 播放器实现

`wall/rtl/wall_music.v` —— 25 MHz（装载器 + 音频）与 150 MHz（SDRAM 客户端）
之间用**双相位 toggle 信箱**，不是 FIFO：数据率只有 192 kB/s（一个 32-bit 字
每 20.8 µs），一个信箱足够，而且两端的总线在握手期间保持稳定，不需要数据 FIFO。

* **写**：clk25 锁存 addr/data、翻转 `wreq` → clk150 收到后做一次写 → 翻 `wack`
  → clk25 释放信箱（`ld_rdy` 变回 1）
* **读**：clk25 在 48 kHz tick 上锁存帧地址、翻 `rreq` → clk150 做一次读 → 结果
  保持并翻 `rack` → clk25 锁存成 `left/right`，同时翻下一帧地址
* **循环**：`ptr` 计到 `frames` 回 0；`frames == 0` 时 `playing = 0`，走合成器

一个 SDRAM 字 = 一帧立体声：`[15:0]` 左、`[31:16]` 右。

`wall_top` 的接线：

* SDRAM 客户端在 `sdram_test_done` 之后从自检切给播放器
  （缩略图在 BRAM，没有别的模块争 SDRAM）
* `wav_en = 1'b1`，`mw_rdy` 接播放器的 `ld_rdy`
* 音频：`play_vld = IS_MASTER ? (mus_playing ? mus_vld : aud_vld) : 1'b0`
  —— **只有主板出声**，从板静音，避免两块板各放各的

## 3. 验证

* `tb_music`（新增）：8 个字跨 25→150 MHz 落到模型内存、12 个 tick 读回 8 帧并回卷、
  左右声道拆分与符号扩展、`frames=0` 时不 playing —— PASS
* 全套 11 个 TB：`tb_music / tb_node / tb_tf_load / tb_tf_load_mbr / tb_audio /
  tb_osd / tb_zoom / tb_scene / tb_img / tb_drag / tb_img_link` 全 PASS
* 时序：A `SWNS +0.253 ns`、B `+0.400 ns`；A 6081/9800 slices = 62%

## 4. 时间线（上电后）

```
0 s      两块板开始加载图像（CAM1..4.BMP，4 x 900 KB）
~2 s     四张图就位，视频墙正常
~2 s     装载器开始第二趟：找 MUSIC.WAV，把前 30 s 线性读进 SDRAM
~10 s    共 5.76 MB，SPI 6.25 MHz 下约 7~8 s，装完 music_frames != 0
~10 s    音频从合成器切到卡上的音乐，30 s 一循环
```

## 5. 已知取舍

* **只取前 30 s**：SDRAM 8 MB 决定的，循环播放。要整首就得边读卡边放（不需要
  SDRAM，但要实时 FAT 链 + 扇区 FIFO）。
* **线性读**：换歌时务必用 `make_music.bat`（它会先把文件写到连续空间）。
* **从板静音**：从板没有卡，也没有必要放第二份音频。
* **A 板串口还没接**（只有 COM7 能读），所以音乐状态目前只能靠听；需要的话可以
  在 STATE 帧加一个 `music_ok` 位，让 B 把 A 的状态一起上报。
