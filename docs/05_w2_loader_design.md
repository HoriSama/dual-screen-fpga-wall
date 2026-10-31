# W2.2：TF 装载器设计（下一轮照这个写）

> 现状（2026-10-28，第十三轮后）：传输层 ✅（A 板能读整扇区）、图库 RAM ✅（双板自检 0 错）、
> 缺的只有"把卡里的 BMP 变成图库里的缩略图"这一块。本文是它的完整设计，
> 避免下一轮重新推导。

## 1. 接口

```
输入：sd_card_top 的字节流（sd_valid / sd_data / sd_end）+ 请求（sd_req 脉冲 + sd_lba）
输出：wall_img_banks 的写口（wr_en / wr_addr / wr_data）+ bank_ok[3:0]
状态：phase[3:0]、err[7:0]、found[3:0]、sec_bytes[7:0]
```

全部在 25 MHz 像素域，不碰 SDRAM、不碰 150 MHz、不需要行缓冲。

## 2. 状态机

| phase | 名称 | 干什么 |
|---|---|---|
| 0 | IDLE | 等 `sd_init_done` |
| 1 | BOOT | 读 LBA0，抓 BPB（+0x0B/0x0D/0x0E/0x10/0x24/0x2C）与 0x55AA |
| 2 | ROOT | 扫根目录第一个簇（最多 `spc` 个扇区），收 `CAM1..4.BMP` 的簇号与长度 |
| 3 | PICK | 选下一个待装 bank（无文件则跳过） |
| 4 | CHAIN | 读当前簇的 FAT 表项（4 字节，0x0FFFFFF8 以上为链尾） |
| 5 | DATA | 按扇区流式读簇数据 → BMP 采样器 |
| 6 | DONE | 四个 bank 全部完成 |
| 15 | ERR | `err` 报原因 |

`err` 编码：1 未初始化 / 2 扇区大小≠512 / 3 引导扇区签名错 / 4 非 FAT32（FAT size=0）/
5 一个 CAM 文件都没找到 / 6 BMP 头错（`BM`、24 位、非压缩）/ 7 簇链异常 / 8 扇区读超时。

## 3. 关键推导（写代码时直接用）

- `data_start = rsv + nfats * fatsz`
- `cluster_lba(c) = data_start + (c-2) * spc`
- 根目录从 `rootclus` 开始，第一个簇若不够再按 FAT 链走（**简化：只看第一个簇**）
- FAT 表项：`fat_sector = rsv + (c*4)/512`，`offset = (c*4)%512`，读该扇区时按 `sec_idx` 抓 4 字节
- BMP 头（24 位、非压缩）：`BM`@0、`offbits`@10、`width`@18、`height`@22（负数=自上而下）、
  `bitcount`@28、`compression`@30
- 行内 3 字节一个像素、B G R 顺序；行尾按 4 字节对齐（`pad = (4-(W*3)%4)%4`）
- 采样：`step_x = max(1, W/96)`、`step_y = max(1, H/72) |负 H 取绝对值|`，
  取 `col % step_x == 0`、`row % step_y == 0` 的像素；
  640×480 时 `step_x = step_y = 6`，用到 570×426 的源区域（轻微裁切，不放大）
- 图库地址：`addr = id*6912 + bank_row*96 + k_col`，
  **`bank_row = m_row`**（即源行 `y = m_row*sy` 的行号本身）
  ⚠️ 这里原来写的是 `71 - m_row`，理由是"BMP 自下而上"——**错的**：BMP 自下而上只影响
  "存储第 r 行对应源图哪一行"（`y = h-1-r`），不影响"源图第 m 行放到图库第几行"。
  `wall_scene` 按 `y*96 + x` 取址、y 向下增，所以图库第 0 行就是窗口顶部，
  源图第 0 行（顶部）必须写图库第 0 行。写成 71-m 的结果是**真板上每张照片都上下颠倒**
  （见 docs/02_bringup_log.md 20.8）。

## 4. 三个必须小心的点

1. **不要用变量位选写 `{"CAM"[i]}`**：Verilog 不允许对字面量做变量索引。
   名字比较改成逐字节 `if (sd_data == 8'h43 /* 'C' */)` 之类，或者用 11 字节移位寄存器
   `name <= {name[79:8], sd_data}`，最后整字比较。
2. **`sd_req` 是单拍脉冲**（第 12 节），每次请求后必须等 `sd_end` 或 20 ms 超时重发；
   不要写成电平，否则一次读取失败会连锁重复读。
3. **一个 `always` 块里同时写"字节消费者"和"扇区结束处理"**，
   但**不要**在同一个块里再写"phase 入口"逻辑（我第一版就是这么写崩的：
   前向引用 + 重复 case 分支）。建议拆成三个 always：
   `st_req`（请求/超时）、`st_bytes`（按 phase 消费字节）、`st_fsm`（phase 与状态量）。

## 5. 仿真计划（不需要真卡）

- `tb/tb_tf_load.v`：一个 **扇区服务器模型**（不是 SPI 卡！）——
  收到 `sd_req/sd_lba` 后从一个数组里把该 LBA 的 512 字节按 `sd_valid/sd_data` 流出来，
  最后打一拍 `sd_end`。数组从 `tb/fat32_img.hex` 读入。
- `tools/make_tb_fat32.py`：用 Python 造一个最小 FAT32 卷：
  - 512 B/扇区、`spc=1`、`rsv=1`、2 个 FAT、FAT 1 个扇区、根簇=2
  - 根目录：`CAM1.BMP`…`CAM4.BMP`，各占若干连续簇
  - 图片内容：96×72 或 192×144 的 24 位 BMP，像素值 = f(x,y) 便于逐点比对
  - 同时输出 `expected.hex`（每 bank 期望的 6912 个 12 位字），TB 直接比对
- 通过判据：`bank_ok=1111`、`err=0`、图库内容与 `expected.hex` 完全一致。
- 之后上板：真卡（FAT32 + 根目录 CAM1..4.BMP）→ `found=1111`、`bank_ok=1111`、
  窗口里出现照片。

## 6. 状态帧里给它留的位置

| 字节 | 现在 | 换成 |
|---|---|---|
| 11 | 扇区字节数（饱和） | 不变（判断读是否成功） |
| 14 | HDMI rec_cnt | `found[3:0]`（低 4 位，bit4..7 保留 rec_cnt 的高 4 位） |
| 20 | sd 探针 FSM | 装载器 `phase[3:0]` |
| 23 | `sd_b0`（第 0 字节） | 装载器 `err[7:0]` |

`wall_sd_dump`（扇区头转储）保留：排查"卡里到底是什么"时非常有用。

## 7. 进展（第十四轮）

- `tools/make_tb_fat32.py` **已写并自检通过**：生成 444 扇区的 FAT32 测试卷
  （`tb/fat32_img.hex`：512 B/扇区、8 扇区/簇、1 保留扇区、2 个 FAT、根簇=2、
  4 个 `CAMx.BMP` 连续簇链），以及期望缩略图 `tb/expected_banks.hex`
  （27648 个 12 位字）。两张 96×72（step=1）+ 两张 192×144（step=2）覆盖缩放分支。
  脚本末尾把自己写出的镜像**重新解码**一遍（BPB / 0x55AA / 目录名），打印
  `SELF-CHECK PASS`。
- 装载器 RTL 与 `tb/tb_tf_load.v` 仍未写（第十三轮的第一版有前向引用等结构错误，已删）。

### 下一轮的最小任务序列

1. 写 `rtl/wall_tf_load.v`（严格按第 2、3 节公式，三个 always 块分开）
2. 写 `tb/tb_tf_load.v`：直接例化 **`tb/tb_sd_sector.v`**（已就绪，编译通过）
   —— 它站在 `sd_card_top` 的位置说同一套字节流接口，从 `tb/fat32_img.hex`
   服务任意 LBA，前面插几拍延迟以触发装载器的超时/重发路径
3. 仿真判据：`bank_ok=1111`、`err=0`、`phase=6`，图库写口序列与
   `tb/expected_banks.hex` 逐字一致
4. 加进 `build.ps1`，替换 `wall_top` 里的图案生成器，上板看 `found/err/phase`

> 第十四/十五轮已就绪：`tools/make_tb_fat32.py`（自检 PASS）、
> `tb/fat32_img.hex`、`tb/expected_banks.hex`、`tb/tb_sd_sector.v`（编译通过）。
> 剩下只有装载器 RTL 和它的 TB 收尾。

## 8. 已完成（第十七轮）：装载器上板跑通

上面 1~4 全部做完，A 板实测 `phase=6 / err=0 / found=000F / bank_ok=000F`。
实现与踩坑记在 `docs/02_bringup_log.md` §20，这里只补两条**设计时没写、写代码才发现**的：

1. **必须支持 MBR 分区**（本设计第 1 节漏了）。真卡的 LBA 0 是分区表
   （type 0x0C，卷在 LBA 32），不是启动扇区；`part_base` 要同时加到
   `data_start`、根目录 LBA **和 FAT 扇区 LBA** 上——漏掉最后一处时仿真表现为
   `found=1111` 但 `err=7`。
2. 测试卷生成器原来每个簇只写 1 个扇区（`data[i*SEC:(i+1)*SEC]` 放在 `lba+i`），
   会让**正确的**装载器读出"前 10 行对、之后全黑"。生成器现在按簇写满并断言长度。

新增文件：

| 文件 | 作用 |
|---|---|
| `rtl/wall_tf_load.v` | FAT32（含 MBR）→ BMP → 96×72 RGB444 → 图库写口 |
| `tb/tb_tf_load.v` | 超级软盘卷的端到端比对（27648 字） |
| `tb/tb_tf_load_mbr.v` | MBR 分区卷的同一套比对（与真卡同构） |
| `tb/fat32_mbr.hex` | 生成器新产出的"分区在 LBA 32"镜像 |
