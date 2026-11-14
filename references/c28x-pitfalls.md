# C28x / DSP2833x 实测踩坑清单（外设时序 + 工程操作）

> **来源**：DSP28335 工程的多次记录（含 2026-11-06～07 的 4-1 两电平工程）；逐条核对适用工程。
> **用法**：写 ADC/SPI/SCI 代码或调试"数据不对"类问题前先扫一遍。
> 记录用于提出排查假设；执行前核对当前器件、源码、板级接线与运行固件。

---

## 一、ADC

### 1.1 主循环软件 SOC 与读取时刻失配；按工程选择同步触发

- **现象**：主循环里软件触发 SEQ1 后读结果，**同一组值连续 4 帧不变**
  （波形呈现"平顶 + 陡坡"的梯形，看着像数据没更新）
- **本例陷阱**：主循环触发和读回的时序未对齐，曾连续 4 帧读到旧值；这不能证明 C28x 的软件 SOC 不可靠。
- **可选解法**：经 TI 同器件例程核对后，使用 EPWM SOCA 硬件触发：
  ```c
  /* EPWM 侧 */
  EPwm1Regs.ETSEL.bit.SOCASEL = ET_CTR_ZERO;   /* CTR=0 产生 SOCA */
  EPwm1Regs.ETSEL.bit.SOCAEN  = 1;
  EPwm1Regs.ETPS.bit.SOCAPRD  = ET_1ST;        /* 每次都发 */
  /* ADC 侧 */
  AdcRegs.ADCTRL2.bit.EPWM_SOCA_SEQ1 = 1;
  ```
  MTG 参考工程则在 10 kHz 的 EPWM1 ISR 中写 `SOC_SEQ1=1`，同样能按 PWM 周期触发。两种路径选其一，验证触发频率、转换完成与读回时序。

### 1.2 `ADCTRL2` 会被"整体覆写" → 初始化顺序 + 兜底重设

- **现象**：ADC 彻底停摆，寄存器读到：
  - `ADCTRL2.all = 0x0100`（bit11 `EPWM_SOCA_SEQ1` 被清成 0）
  - `ADCST.all = 1`（`SEQ1_BSY` 永久为忙）
  - `ADCRESULT2 = 0`（第 3 通道从未转换完成）
- **根因**：初始化链路上存在 `AdcRegs.ADCTRL2.all = 0x2000;` 这种**整体赋值**。
  已知来源：
  - TI 库 `DSP2833x_Adc.c` 的 `InitAdc()`
  - 工程自带老例程（如 `APP/adc/adc.c` 的 `ADC_Init()`，写法是"连续运行 + 只读 CONV00"）
  - 两者都会把之前设好的位全部清掉，**谁最后生效难以保证**
- **解法**（两条一起做）：
  1. **把自定义 ADC 初始化放到所有 EPWM/外设初始化之后**
  2. **收尾再显式使能一次兜底**：
     ```c
     AdcRegs.ADCTRL2.bit.RST_SEQ1       = 1;
     AdcRegs.ADCTRL2.bit.EPWM_SOCA_SEQ1 = 1;
     AdcRegs.ADCTRL2.bit.INT_ENA_SEQ1   = 0;
     AdcRegs.ADCST.bit.INT_SEQ1_CLR     = 1;
     ```
- **同一工程里不要同时调用两套 ADC 初始化**（如 `ADC_Init()` 与自定义 `vCL_ADC_Init()`）

### 1.3 结果寄存器在"新序列开始"时会被清零 → 别在转换途中读

- **现象**：正弦波形上偶发尖刺，数据里频繁出现 `0`；**越靠后的通道越容易中招**
  （`RESULT2` 比 `RESULT0` 更容易是 0）
- **根因**：DSP2833x 的 ADC 在每个新序列开始时清结果寄存器。
  若在**转换途中**读，后面的通道读到的是 0。
  **"读两遍一致才采信"挡不住** —— 两次读可能落在同一瞬间
- **解法**：
  1. 读之前确认空闲：`while (AdcRegs.ADCST.bit.SEQ1_BSY == 1) { }`（最多等一轮 ~7us）
  2. **连读 5 次取中值**兜底（每次读之间给点间隔）
- **根治**：**在 ADC 完成中断或 EPWM 中断里读**，那时转换必定已完成

### 1.4 ADC 问题的最快诊断法

用 DSS 一把读这几个寄存器，能立刻定位：

```
AdcRegs.ADCTRL1.all, AdcRegs.ADCTRL2.all, AdcRegs.ADCTRL3.all,
AdcRegs.ADCST.all, AdcRegs.ADCMAXCONV.all, AdcRegs.ADCCHSELSEQ1.all,
AdcRegs.ADCRESULT0/1/2
```

| 读到的值 | 含义 |
|---|---|
| `ADCTRL2.all = 0x0100` | bit11 触发位被清（见 1.2）|
| `ADCST.all = 1` | `SEQ1_BSY` 永久忙（转换卡住）|
| `ADCRESULT2 = 0` 而 0/1 有值 | 第 3 通道没转完（见 1.3）|
| `ADCTRL1.all = 0x0F10` | 正常：ACQ_PS=15、CPS=0、CONT_RUN=0、SEQ_CASC=1 |
| `ADCMAXCONV.all = 2` | 3 个通道（`MAX_CONV1 = n-1`）|
| `ADCCHSELSEQ1.all = 0x0A98` | CONV00/01/02 = 8/9/10（即 ADCINB0/B1/B2）|

**采样静态验证法**（判断"通道/换算/接线"对不对）：让信号源固定输出已知电压，
读 `ADCRESULT0/1/2` 高 12 位 × (3.0/4095) 应等于实测电压。

---

## 二、SPI

### 2.1 `SPISTS.bit.INT_FLAG`：先区分 FIFO 模式和非 FIFO 模式

- **已实测确认（2026-10-27，DSP28335 + TLV5620，修复前后同条件回归）**：正确写法是 **先读一次 `SPIRXBUF` 清掉上次的 `INT_FLAG` → 写 `SPITXBUF` → 再 `while (INT_FLAG == 0)`**。不清就直接等，第 1 个字符还对，之后**恒为 1 → 立即通过 → LOAD 提前锁存残字**：同一码值 `0xFF` 被锁成 `0x80`，读数看着像“码值翻倍 / 通道串扰 / 某路 DAC 引脚坏了”，实测四路回归均值 997.7/1001.7/996.6/996.6（理论 988）。完整复盘见 [TLV5620 LOAD 时序案例](debug-cases/dsp28335/2026-10-26-tlv5620-load-timing.md)。
- **原工程现象**：直接写 `while (SpiaRegs.SPISTS.bit.INT_FLAG == 0) { }` 时立即通过，未等到新的传输完成；这条现象本身不能证明该位“读回恒为 1”。
- **TI 手册定义**：F2833x 的 `INT_FLAG` 是**只读**的完整字标志，非 FIFO 模式下在最后一位收发完成时置 1，读 `SPIRXBUF`、SPI 软件复位或系统复位可清除。**FIFO 模式下不要用这个位**：搬运到 RX FIFO 的内部过程会清它，应查 FIFO 状态/中断标志。`OVERRUN_FLAG` 才是写 1 清除；不要用 `SPISTS.bit.INT_FLAG = 1`。
- **排查**：先读实际 `SPIFFTX.SPIFFENA`、`SPICCR.SPICHAR`、`SPIBRR`，确认模式、字长、时钟和旧标志状态。`BUFFULL_FLAG` 清 0 仅代表 TXBUF 已交给移位寄存器，**不代表最后一位已出线**。对 DAC 的 LOAD 时序以 SCLK 实测或能表示完整字接收的状态为准；若用延时，按实际时钟数和频率计算并留器件手册要求的裕量。
- 依据：[TI F2833x 技术手册 SPISTS §9.5.2.3](https://www.ti.com/lit/ug/sprui07/sprui07.pdf)。

### 2.2 SPI 波特率与"LOAD 脉冲"的时序（DAC/移位型外设通用）

- **现象**：DAC 输出的正弦"有大体趋势，但顶部削平、有台阶、偶发尖刺"
- **根因**：写完 `SPITXBUF` 后只等 `BUFFULL_FLAG` 清零（≈数据进移位寄存器）
  就拉 LOAD 锁存，而 SPI 在 0.75MHz 下发 11 位要 **14.7us**，紧接着 `DELAY_US(2)` 远不够
  → **锁进 DAC 的是残缺数据**
- **解法**：先确认 DAC 的**实际型号**和手册。若为 **TLV5620**，数据手册规定 CLK 频率最高 **1 MHz**，不能把本例的 SPI 提到 3.75 MHz；在 0.75 MHz 下，11 个时钟本身约需 14.7 µs，还须核对工程实际字长及 CLK 最后一沿到 LOAD 的建立时间。等完整字传完，再给 LOAD 符合手册的脉冲。
- **验证**：读 `SPICCR` 字长、`SPIBRR`、FIFO 配置，并用示波器/逻辑分析仪看 SCLK 最后一沿与 LOAD 的关系；不要仅凭 `BUFFULL_FLAG` 或一次波形好转判定时序正确。[TLV5620 数据手册](https://www.ti.com/lit/gpn/tlv5620)规定 CLK 上限及 LOAD 时序。
- **实测字符时长（DSP28335，LSPCLK = 37.5 MHz，11 位，含轮询开销）**：`SPIBRR=0x31`(0.75 MHz) → 17.0 µs；`0x25`(0.987 MHz) → 12.6 µs；`0x18`(1.5 MHz) → 8.5 µs。理论值分别为 14.7 / 11.1 / 7.3 µs，差值 ≈ 1~2 µs 是判据轮询与 GPIO 操作开销。
- **不用逻辑分析仪也能量**：把空闲的 EPWM `TBCTR` 当 150 MHz 计时器（1 计数 = 6.667 ns，量程 = `TBPRD+1` 个计数），读前读后相减并做回绕修正即可测 µs 级外设时序。同一方法标定 `DELAY_US(16)` 得 16.06 µs，可先证明延时宏本身没问题，再怀疑等待逻辑。

### 2.3 FIFO 能不能优化这类“外部 DAC 的 SPI”？——TLV5620 这种结构不行

- TLV5620 是**单移位寄存器 + LOAD 上升沿锁存**：每个 11 位字后面必须紧跟一次 LOAD。FIFO 的价值是让 SPI 连续吐字、中间不留间隔，正好把唯一的 LOAD 插入点消掉。
- 想在 FIFO 下恢复 LOAD，只能①每写一字就等 `TXFFST` 降一级再拉 LOAD（本质还是逐字等，没省时间还多了状态判断），或②按固定时间盲拉 LOAD（依赖波特率绝对精确，中断一插就错位）。
- 再加一条硬伤：FIFO 模式下 `INT_FLAG` 语义改变（内部搬运会清它），而它正是非 FIFO 模式下唯一可靠的“整字完成”判据。
- 实测收益上限 ≈ 1 µs/字的轮询开销，四路合计省 ~4 µs → **不值得，保持阻塞式逐字写**。
- 真要压时间只有压缩传输本身：时钟顶到器件手册上限（TLV5620 为 1 MHz）、缩短 LOAD 脉宽（手册 ≥250 ns，现用 1 µs）、或流水线（LOAD 拉高后立刻启动下一字）。

---

## 三、SCI（串口）

### 3.1 `SCIFFTX.TXFFST` 只有 4 位 → 别用它判断"FIFO 有空位"

- **现象**：串口帧偶发丢字节；抓原始字节流统计**帧头间隔出现 14 字节**（正常应恒为 8）；
  上位机解析的数据每 N 帧**整体错位一个通道**
- **根因**：FIFO 深度 16，而 `TXFFST` 是 **4 位（0~15）** —— **满 16 时读回 0**，
  于是 `while (TXFFST > 8)` 这类判据失效，往满 FIFO 里写的数据被静默丢弃
- **解法**：**用逐字节发送**（每字节等 `TXFFST == 0`），不要自己往 `SCITXBUF` 连灌多字节
- **★诊断方法（强烈推荐）**：抓一段原始字节流，**统计帧头出现位置的间隔分布**
  ```powershell
  # 正常应全部是 8（3通道×2字节数据 + 2字节帧头 = 10? 按实际帧长核对）
  $pos=@(); for ($i=0;$i -lt $got-1;$i++){ if($buf[$i] -eq 0xAA -and $buf[$i+1] -eq 0x55){ $pos += $i } }
  $gaps=@(); for ($j=1;$j -lt $pos.Count;$j++){ $gaps += ($pos[$j]-$pos[$j-1]) }
  $gaps | Group-Object | ForEach-Object { "$($_.Name)字节×$($_.Count)" }
  ```
  **间隔分布不单一 = 有丢字节**，一眼就能判定。

### 3.2 同一时间只能有一个发送者

- **现象**：三路数据周期性错位、波形完全看不出正弦
- **根因**：主循环里同时调用了两个"发同格式帧"的函数，**互相插帧**
- **解法**：同一时刻**只留一个发送者**，另一个注释掉（别信"它不会触发"这种注释）

---

## 四、工程与工具链

### 4.1 `.cproject` 的 include 路径是**逐目录列举**的

- **现象**：新建目录放头文件后，编译报"找不到头文件"
- **根因**：include 路径不是通配，而是一个目录一条 `<listOptionValue>`
- **解法**：新建模块目录后往 `.cproject` 的 `includePath` 里加同样格式的条目：
  ```xml
  <listOptionValue builtIn="false" value="&quot;${workspace_loc:/${ProjName}/新目录}&quot;"/>
  ```
  （注意保持原有缩进层级）
- **验证**：改完编译，`SOURCES` 数量应增加

### 4.2 `.text` 段空间不足 → 链接失败

- **现象**：`error #10099-D: program will not fit into available memory`，指向链接脚本的 `.text`
- **根因**：`.text` 只分到一块小 RAM（本项目 `RAML1` 只有 8K 字）
- **解法**：把相邻未使用的 RAM 段合并扩容（如 `RAML1: length = 0x002000` → `0x003000`），
  并确认 `SECTIONS` 里没有别处引用被合并的段
- **★注意**：工程自带的 `.cmd` 往往是 **GBK 编码**（含中文注释），改法见 4.3

### 4.3 PowerShell 读写 GBK 文件会毁掉中文注释

- **现象**：用 `[IO.File]::ReadAllText` + `WriteAllText` 改 `.cmd`/`.c`，
  里面的中文注释变乱码（`//修改RAM大小` → `//�޸�RAM��С`）
- **根因**：文件是 **GBK** 编码，PowerShell 默认按 UTF-8 处理
- **解法**：
  ```powershell
  $gbk = [Text.Encoding]::GetEncoding(936)
  $t = $gbk.GetString([IO.File]::ReadAllBytes($f))
  # ... 修改 $t ...
  [IO.File]::WriteAllBytes($f, $gbk.GetBytes($t))
  # 回读校验：不含 U+FFFD 替换符才算没坏
  ```
- **保险做法**：改之前 `git status` 确认干净，坏了能 `git checkout -- 文件` 恢复
- **判断文件编码**：分别用 GBK 和 UTF-8 解码，看哪个能正确读出中文、哪个含 `U+FFFD`

### 4.4 DSS 读寄存器与变量

- 读全局变量：`-ReadVars "MyVar1,MyVar2"`（最快、最可靠）
- 读外设寄存器：`-ReadVars "AdcRegs.ADCTRL2.all"` **也可以**（DSS 支持 C 表达式求值）
- 读结构体位域：`"GpioCtrlRegs.GPADIR.bit.GPIO8"` 也能用
- **读不到时先查**：符号是否真在 `.out` 里（`static` 可能被优化掉/改名）
- 详细用法见 `references/dss-debug.md`

### 4.6 `Select-String` 的输出带 ANSI 高亮 → 抓取后像"乱码"

- **现象**：用 `pwsh ... | Select-String -Pattern 'xxx'` 抓编译/脚本输出，显示成
  `□[7mSOURCES□[0m : 48 file(s)` 这类"乱码"（`□` 其实是 ESC 字符 0x1B）。
- **根因**：**PowerShell 7 的 `Select-String` 默认把匹配片段用"反显"高亮**（`ESC[7m … ESC[0m`），
  把 `MatchInfo` 对象当纯文本打印时这些控制符就现形了。**不是被调用脚本的问题**（脚本里没有颜色代码）。
- **解法（任选其一）**：
  ```powershell
  $PSStyle.OutputRendering = 'PlainText'    # ★推荐：写在命令开头，整条命令输出都干净
  # 或： ... | Select-String xxx | ForEach-Object { $_.Line }   # 只取纯文本行
  # 或： ... | Select-String xxx -Raw
  ```
- **注意**：这只影响"抓取后再显示"。用户在真终端里跑是**彩色且正常**的，
  **不要去改脚本的着色逻辑**（那是给人看的）。

### 4.5 SerialPlot 的 `MainWindow.state` 会覆盖通道名

- **现象**：改了 `.ini` 里 `[Channels] channel\N\name=xxx`，界面上还是旧名字
- **根因**：SerialPlot 退出时把窗口状态（含图例缓存的通道名）写回
  `[MainWindow] state=@ByteArray(...)`，下次启动时它**覆盖** `[Channels]`
- **解法**：**用全新的配置文件名**（不要反复改同一个），或启动时用 `-c 新文件.ini`
- **配置要点**：
  ```ini
  [DataFormat_CustomFrame]
  numOfChannels=4
  numberFormat=int16        ; ★否则负值显示成 65496 之类的大数
  endianness=little
  frameStart=AA 55
  fixedSize=true
  frameSize=8               ; = 通道数 × 2（★不含帧头）
  ```
- **端口参数**：`-p COM8 -b 460800 -o`（`-o` = 打开串口）
- **抓包前先关 SerialPlot**，否则串口被占用（`Access to the path 'COM8' is denied`）

### 4.7 TI 的 `InitEPwmGpio()` 是"全家桶" → 会抢走 GPIO6~11（OLED / 蜂鸣器 / LED6-7）

- **现象**：OLED 全黑、屏上停在旧内容或直接黑屏；程序本身正常（`gBootStage = 5`、`TBPRD = 14999`、PWM 有输出）。
- **根因**：`DSP2833x_EPwm.c` 的 `InitEPwmGpio()` **不是**"只配 EPWM1/2/3"，它内部依次调用
  `InitEPwm1Gpio() … InitEPwm6Gpio()`（后三个受 `#if DSP28_EPWM4/5/6` 控制），其中：
  - `InitEPwm4Gpio()`：GPIO6/7 → EPWM4A/4B（**蜂鸣器脚**）
  - `InitEPwm5Gpio()`：GPIO8/9 → EPWM5A/5B（**OLED 的 SDA/SCL**）
  - `InitEPwm6Gpio()`：GPIO10/11 → EPWM6A/6B（**LED6/7**）

  于是只要调用方写 `EPWM3Ph_Init()`（注释本意"GPIO0~5"），内部就会把前面 `OLED_Init()` 刚抢回来的
  GPIO8/9 又设回 EPWM5 —— **谁最后写 MUX 谁赢**，而发波初始化排在 OLED 之后。
- **判据（2026-11-06 实测，DSP28335 两电平工程）**：
  ```
  GpioCtrlRegs.GPAMUX1.bit.GPIO8 = 1   ← EPWM5A（错，应为 0 = 通用 IO）
  GpioCtrlRegs.GPADIR.bit.GPIO8  = 1
  GpioDataRegs.GPADAT.bit.GPIO8  = 0   ← I2C 空闲应为 1
  ```
  修复后：`GPAMUX1 = 0` / `GPADIR = 1` / `GPADAT = 1`，屏立即恢复。
- **解法**：调用方**逐个只调自己用到的**：
  ```c
  InitEPwm1Gpio();   /* GPIO0/1 */
  InitEPwm2Gpio();   /* GPIO2/3 */
  InitEPwm3Gpio();   /* GPIO4/5 */
  ```
  这三者无条件定义；4/5/6 的版本在 `#if` 里，需要时单独调。
- **通用规则**：工程里同时有"模拟 I2C OLED / 蜂鸣器 / LED"与外设复用引脚（GPIO6~11）时，
  用 TI 库的"外设引脚初始化"前**先打开库源码看它到底配了哪几个脚**，别信注释和函数名的字面意思。
- **补充判读坑**：`-ReadOnly` 模式读 `GpioCtrlRegs.GPADIR.all` 可能读到 `0`（与一次旧版下载后逐位读到的 `1` 矛盾）。
  只读任务先核对符号与运行固件是否一致、逐位/整字读法、目标核和采样时机；仍矛盾就报告“未确认”。只有执行模式任务需要修改程序时，才下载运行作交叉验证。

---

## 四·补、移植参考工程时的采样链问题（2026-11-06～07）

背景：把 MTG_Logic_New 的 ADC 采样链移植到 4-1 工程，因为**自作聪明地"补全"参考工程**，
先出现 6 个错误和 3 次误判，随后又补充校准、探针与引脚复用的问题；以下按症状列出，完整逐项核对见[ADC 采样链案例](debug-cases/dsp28335/2026-11-07-adc-chain-port-audit.md)。

### 4.8.1 `AdcMirror`（0x0B00）是**硬件自动镜像**，不要用 DMA 去填
- 现象：同一变量读出来一会儿 2134、一会儿 31984，标定全错。
- 原因：`AdcMirror` 是 ADC 结果镜像区，**转换完硬件自己写入，且是右对齐 12 位**。
  我"补"了一段 DMA 把 `AdcRegs.ADCRESULT0~15`（左对齐 16 位）搬进同一地址，
  与硬件镜像互相覆盖。
- 判据：参考工程里 `StartDMACH1()` **有定义但无人调用** —— 这就是"不需要 DMA"的证据。
- 规则：参考工程"看起来缺一环"时，先确认是不是硬件特性/库已实现，**再决定补不补**；
  补了必须能解释"原工程为什么不需要它"。

### 4.8.2 `AdcMirror.ADCRESULTn` **不要右移 4 位**
- MTG 的宏：`#define GridVolt_L_AB (AdcMirror.ADCRESULT0)` —— 直接读；
  被注释掉的备选 `(AdcRegs.ADCRESULT0>>4)` 才需要移位。
- 我按"ADCRESULT 左对齐"的常识加了 `>>4`，数据缩小 16 倍（2135 → 133），
  连带零点、标定、保护全部错。
- `AdcRegs.ADCRESULTn` 左对齐(0~65520)；`AdcMirror.ADCRESULTn` 右对齐(0~4095)。

### 4.8.3 零点校准里的 `×0.0625`（÷16）同理
`fZeroRaw = sum/N × 0.0625` 会把零点算成 131 而不是 2135 → `fOffset` 偏 16 倍。
读镜像时不要除。

### 4.8.4 选通道**不能靠单点读数**，必须看峰峰值/整流平均
- 我靠几次单点读数判断"信号在 B0/B1/B2"，把三相改到 8/9/10 —— 完全错。
- 单点读数经常落在正弦过零点附近，看起来和"没信号"一样；而噪声偏置也能凑出 30V 的假象。
- 正确做法：**16 路全采 + 逐路统计峰峰值**，一次就能定位：
  ```
  通道0/1/2 = 500/440/528 码  ← 真实信号
  通道8~15  = 6~10 码         ← 噪声
  ```

### 4.8.5 `min/max` 会被开关噪声尖峰污染，判幅值要用整流平均
本次记录中 `min/max` 峰峰 A=645/B=532/C=693，易被少数开关尖峰拉大；
最终 200 ms（50 Hz 下 10 周期）窗口记录的逐相去零点整流均值为 45/44/42 码，折算峰值为 27.6/27.0/25.8 V。旧技能另记 73/74/70 码，采样条件未明，**不能与最终窗口当成同一批结果**。
三相相差 120° 本身不妨碍对每相各取完整周期极值；这里弃用 `min/max` 的关键是尖峰污染。
纯正弦、零点正确且窗口覆盖整数周期时，`峰峰值 = meanAbs × π`、`峰值 = meanAbs × π/2`；非正弦波要另验波形/频谱和仪表读数。

### 4.8.6 SOC 要放在 EPWM 中断里，不是主循环
MTG 是 `EPWM1_ISR(){ AdcRegs.ADCTRL2.bit.SOC_SEQ1 = 1; }`（10kHz，与 PWM 同步）。
放主循环（1kHz、时刻随机）既慢又与开关不同步。

### 4.8.7 一次 `-ReadOnly` 外设寄存器读数全 0，不能单独下结论
本次两次中招（`GpioCtrlRegs.GPADIR.all = 0`、`EPwm1Regs.TBPRD = 0`、`ADCCHSELSEQ1 = 0`），
据此得出“发波没输出/ADC 没配置”的错误结论。先核对符号、目标核、寄存器读法和运行状态，再在只读模式重复/交叉读取；证据不足时保持“未确认”。**不要因旧案例建议就把用户指定的只读任务切成 `-Run` 下载任务**；执行模式需更新程序时才用 `-Run`。

### 4.8.8 非 volatile 全局变量做等待循环，`-O2` 下会变死循环
```c
while (ClAdcCtrl.usZeroDone == 0) { }        /* ✗ 编译器只读一次内存，永远出不来 */
while (*(volatile Uint16 *)&ClAdcCtrl.usZeroDone == 0) { }   /* ✓ 仍需有超时处理 */
```
表象很有迷惑性：`usZeroDone` 明明已为 1，但后续 `vSPWM_Enter()` 没执行、
`AQCSFRC` 一直封波，容易误判成"发波模块坏了"。
共享标志建议在声明处使用 `volatile`；等待要有按实际时钟估算的上限。**超时若仍未校准成功，应保持封波并报错，不能直接调用 `vSPWM_Enter()`。**

### 4.8.9 硬件事实不要按读数反推去改
变比 533:1 是硬件决定（用户确认）。我按"±30V 对应 548 码"反推出 150:1 并改了 `fScale` —— 错。
读数和硬件参数矛盾时，先怀疑**读数方法**（尖峰/单点/移位），最后才怀疑硬件参数本身。

### 4.8.10 校准顺序、零点和超时门槛

这块板先初始化 ADC 与 EPWM（输出保持封波），启动同步 SOC，逐相完成零点校准，再放波。曾先放波后校准，把约 30 V 输出当零点；写死 2048 也偏离现场记录的 A/B/C 零点 2066/2074/2075 码。零点与变比须记录来源和时间，不能拿此板值套到另一块板。
当前工程的 `CL_ADC_ZERO_LPF_N=15000`、`CL_ADC_ZERO_SHORT_N=256`、采样 10 kHz，对应约 **1.526 s**，但 `main.c` 注释仍写 250 ms；等待循环超时后仍无条件 `vSPWM_Enter()`，不构成安全门槛。复核校准完成标志与等待时间，再判断是否允许放波。

### 4.8.11 引脚复用与主循环时间基准

在这块带 OLED 的板上，`InitEPwmGpio()` 配置 EPWM1~6，EPWM5 会占 GPIO8/9，与 OLED SDA/SCL 冲突；只配置实际使用的 EPWM1~3 仍不够，当前 `vOpenLoopInit()` 所调的 `vBoard_Gpio_Init_MTG()` 也把 GPIO8/9 设为 EPWM5。若要恢复 OLED，必须核对并修正整个板级 GPIO 调用链。移除 OLED/串口发送后，主循环空转会改变按调用次数计算的 `vCL_ADC_Check()` 超时；现场把 `DELAY_US(200)` 改到 `DELAY_US(1000)`。优先改成真实定时器/时间戳判据；若沿用调用次数，须验证实际循环周期。

### 4.8.12 探针与读回工具不应改变被测状态

换 XDS100 探针时先核对实物版本、当前串号、`.ccxml` 串号选择和 CCS GUI 会话；`-151` 不应盲目重试。旧 `-ReadOnly` 的全 0 寄存器读数只说明那次读取链路不可信；实时只读路径已读到 `EPwm1Regs.TBPRD=7500`，但当前运行固件与本地 RAM `.out` 的身份尚未匹配。只读任务不得改用会加载并重启的 `-Run`。

---

## 五、控制算法（工程经验）

### 5.1 增量式 PID 的"噪声使积分失效"

- **现象**：DSS 看误差瞬间是 0，但抓包 N 帧的**均值**偏 1V，**加大 Ki 也消不掉**
- **根因**：误差在相邻拍之间快速正负跳（采样抖动/量化噪声），
  增量式的 `Ki·e(k)` **净增为 0** → 平均误差永远消不掉
- **解法**：**给反馈加一阶低通**（`fF += α(f − fF)`，α≈0.2），积分才重新有效
- **★陷阱**：低通状态变量**必须放文件作用域**（放函数里会被每拍清零、低通直接失效）

### 5.2 Kd 在"无惯性对象"上是负收益（实测数据）

- **实测**：某对象（DAC→跳线→ADC 直连，纯比例、无惯性）上
  `Kd = 0.005` 时 `Vq/ErrD` 峰峰从 **270/150 涨到 419/203**
- **根因**：D 项作用在误差二阶差分 `e0−2e1+e2` 上，**噪声被放大**；
  而对象没有惯性、没有超调可抑制，D 项无事可做
- **结论**：
  - 对象无惯性（纯比例）→ **Kd 保持 0**
  - 真实系统（LC 滤波/电机，需抑超调）→ Kd 有效，但**必须**配以下之一：
    ① 误差先低通再微分；② 不完全微分 `Kd·s/(1+τs)`；③ 微分只作用在反馈上

### 5.3 误差要分清"随机噪声"还是"系统性偏差"

这是调试时最有用的一个判别：

| 特征 | 类型 | 对策 |
|---|---|---|
| 快速随机跳、低通后变小 | **随机噪声** | 滤波、降采样率、加屏蔽 |
| 周期性、低通无效、与角度/负载相关 | **系统性偏差** | 同步采样、前馈、结构改进 |

**实例**：某工程 `Vq` 偏置 -1V，低通无效、加大 Ki 无效 →
查明是"ADC 自由触发与 θ 不同步"导致采样相位在网格上跳，
变换出的 `Vq` 是周期函数、平均不为 0。
**解法是让 ADC 与 θ 在同一中断里严格同步**（而不是调 PID）。

### 5.4 dq 变换的角度约定（写代码时先定死）

- **d 轴 = 0° 轴，取 cos**；q 轴超前 90°
- 正变换（等幅值）：
  ```
  α = (2/3)(Va − 0.5Vb − 0.5Vc)
  β = (1/√3)(Vb − Vc)
  d = +α·cosθ + β·sinθ
  q = −α·sinθ + β·cosθ
  ```
- 零序（可选）：`o = (Va+Vb+Vc)/3`（三相平衡时恒为 0，是很好的对称性检查量）
- **要让"设定落在 d 轴"**：Vref 三相必须与 θ **同相**且用 **cos** 型
  （`vref_x = A·cos(θ+φ_x)`），变换后恒为 `(A, 0)`。若用 sin 型会得到 `(0, −A)` 落在 q 轴上
- **独立运行（不并网）时 θ 由内部累加器给出**（`θ += 2π·f·Ts`），**不需要 PLL**

### 5.5 电压闭环里"母线前馈"不可少

- 三相两电平（半桥）：`Vout_peak = (Vdc/2) × m`  ⇒  **`m = 2·Vout_peak / Vdc`**
- **母线一变（带载跌落/直流源波动），同样调制比就输出不同电压**
- **做法**：把 PID 输出的调制量**实时除以 `Vdc/2`** 归一化，再算占空比
  ```c
  fModD = (2.0f * fUd) / fVdc;
  fModQ = (2.0f * fUq) / fVdc;
  ```
- 前馈给稳态值可让 PID 只补小偏差；母线电压建议再做一阶低通后再用

---

## 六、并发与数据一致性（中断 vs 主循环）

### 6.1 波形上的“垂直毛刺”：检查是否跨中断读到不同拍

以下代码和数值来自旧现场记录，可作为**候选机制**；缺少对应工程的修复前源码和原始抓包，不能把毛刺根因或下表的“修复后”数值当成已独立复核。`2-1SOGI_PLL` 的当前调查见[SCI 共享数据案例](debug-cases/dsp28335/2026-10-26-sci-shared-data-tearing.md)，其环形缓冲所有权需单独分析。

**现象**：SerialPlot 上曲线整体形状正确，但**某一条（或几条）有垂直尖刺** ——
某帧突然跳变几千个码值，下一帧立刻弹回；三相里往往"某一条特别多"。

**可能机制**：10kHz 控制中断每 100us 更新 `XxxCtrl.usCmpA/B/C`；主循环 1kHz 发串口
（8 字节 @460800 = **174us**）。原来是**逐字节直接读全局变量**：

```c
UARTa_SendByte(XxxCtrl.usCmpA & 0x00FF);        /* 读低字节 → 花 21.7us 发出去 */
UARTa_SendByte((XxxCtrl.usCmpA >> 8) & 0x00FF); /* 再读高字节（已是 21.7us 之后）*/
```

若低/高字节在两个时刻重新读取同一共享值，就**可能**分别来自第 N 拍和第 N+1 拍，拼出不存在的数。须先核对真实源码是否重复读取、ISR 更新时间和发送实现；不能从尖刺形状直接断定。

**时间尺度**：8 字节 @460800 的串行线速约 174 µs（尚未计软件开销），与 100 µs 中断周期相近；这只能提示检查交错，不能直接换算毛刺概率。

**适用时的修法**（模板见 `ti-official-style.md` §4.5）：若确认共享字段会在发送期间被改写，发送前在短临界区取一致快照，
之后 174us 慢发全部用快照。

**旧记录给出的验证数值（尚缺本次独立原始证据）**：

| 指标 | 修复前 | 修复后 | 理论值 |
|---|---|---|---|
| 相邻帧跳变 > 1000 的次数 | 每 20 帧约 1~2 次 | **0** | 0 |
| 最大相邻跳变 | 数千 | **89** | ≤ 118（CMP 在过零点的斜率上限）|
| 三相值范围 | — | 2126 ~ 5374 | 中点应 = TBPRD/2 = 3750 |

**判据用法**：抓 ~700 帧算"最大相邻跳变"与"跳变 > 1000 次数"，
需用同一固件、接线和抓包条件重测，才能作为回归判据。

### 6.2 对跨拍读取问题无充分保证的做法

| 想法 | 为什么不行 |
|---|---|
| 提高读取频率（让读周期 < 更新周期） | ① **带宽不允许**：8 字节 @460800 = 174us → 帧率上限 5.75kHz < 更新率 10kHz，永远追不上；② **就算读得再快，只要"一次读的过程"跨过更新点，照样撕裂** |
| 降低帧率 | 10Hz 发一帧，那 174us 里照样被打断 |
| 加 `volatile` | 只禁止编译器把读写优化掉，**完全不防撕裂** |
| 改用 `float` | 类型变为 32 位不能保证单次原子读取；C28x 上应核对实际指令和共享数据发布方式，多值仍可能不同拍。 |

**判断准则**：慢过程读取可能被 ISR 改写的数据时，先核对缓冲所有权及读写时序；确有跨拍风险时取快照或采用带序号的发布协议。

### 6.3 别用关中断去包住"慢操作"

`DINT` 窗口必须 ≪ 更新周期。曾有过"把 `DELAY_US` / 串口发送包进 `DINT…EINT`"的想法 ——
那会丢掉 1~2 个控制周期，比撕裂更严重。
**正确分工：需要快照时只把短读取放进临界区，串口发送等慢操作留在外面；实际耗时按当前编译结果核对。**

### 6.4 在中断上下文里调用时：保存/恢复 INTM，别用裸 `EINT`

`DINT … EINT` 会把中断**强行打开**。若这段代码可能在 ISR 里被调用（或调用前中断本来是关的），
裸 `EINT` 会破坏上层临界区语义。那种场合要写成：

```c
Uint16 usWas = __disable_interrupts();   /* C28x 内建，返回原 INTM 值 */
... 读取 ...
if (usWas == 0) { __enable_interrupts(); }
```

（本工程 6 处波形发送函数目前都只在主循环调用，故直接用 `DINT…EINT`；
若将来挪进 ISR，必须先改成上面的写法。）

---

## 七、快速诊断流程（遇到"数据不对"时照这个走）

```
① 抓原始字节流，统计帧头间隔分布
   ├─ 间隔不单一 → 【SCI 丢字节】见 3.1
   └─ 全是固定值 → 串口没问题，往下
② DSS 读关键寄存器
   ├─ ADC 相关 → 见 1.2 / 1.4 的对照表
   ├─ SPI 相关 → 见 2.1 / 2.2
   └─ EPWM 相关 → 看 TBCTR 是否在计数、TBPRD、ETSEL.SOCAEN
③ 静态验证（输出固定值/已知电压）
   ├─ 读数正确 → 链路通，问题在动态/时序
   └─ 读数不对 → 通道号、变比、偏置、接线有问题
④ 分"随机噪声" vs "系统性偏差"（见 5.3）选对策
⑤ 波形形状对、但有"垂直单点尖刺" → 【数据撕裂】见 6.1
   （判据：跳变 > 1000 次数 > 0；且"提高读取频率 / 降低帧率 / 加 volatile"都无效）
```

**核心思路**：**先用"静态已知值"把链路钉死，再查动态时序。**
不要在动态数据上猜 —— 静态测试能一次性排除"通道/换算/接线"三大类问题。

---

## 八、C28x 数值与类型陷阱

### 8.1 `int` 是 **16 位**：两个 `Uint16` 直接相减会静默溢出

- **现象**（2026-10-28，`2-1SOGI_PLL` 相位误差统计）：把两个 0.01° 表示的角度（`Uint16`，范围 0~35999）直接相减，
  再做 `±180°` 归一化，统计出的相位误差 max = +5.7°（正确）、**min = −59°（假值）**，
  而同一时刻直接读两个角度相减明明是 +2°。锁相环 vq 纹波只有 0.011 pu，根本不可能差 59°。
- **根因**：C28x 上 `int` 只有 16 位。`Uint16 a - Uint16 b` 先提升为 16 位有符号，结果超出 ±32767 就回绕。
  跨 0/360° 时差值本应是 −359.7°，回绕后变成 +295.6°，再被 `if (de > 180) de -= 360;` 做成 **−64.4°**。
- **修法**：**角度/大范围量一律用 `float`（或 `long`）相减，别用 `Uint16` 差值**：
  ```c
  float de = (theta_a_rad - theta_b_rad) * 57.29578f;   /* 直接拿弧度算 */
  if (de > 180.0f)  { de -= 360.0f; }
  if (de < -180.0f) { de += 360.0f; }
  ```
- **同源坑**：`Uint16` 计数器差值、编码器计数、时间戳相减都要留意；`int32_t`/`float` 才是安全的中间类型。
  写统计代码时先问一句"这个差值最大能到多少？超过 32767 吗？"

### 8.2 SOGI 频率自适应：别把带纹波的 `fo` 直接喂给 `coeff_update`

- **现象**（2026-10-28，谐波场景 THD 13.75%）：DSOGI 每 20 ms 用 `s_loop.fo` 重算 `osg_coeff`，
  结果稳态相位误差 **5.4°**（vq 纹波仍只有 0.011 pu，说明环路本身是锁住的）。
  改成用 20 Hz 低通后的频率后，相位误差降到 **1.97°**。
- **根因**：谐波下 `fo = fn + ylf` 本身带 6 次纹波；拿它去重算 SOGI 系数等于周期性把带通滤波器调偏，
  相位被来回拉，稳态偏置随之变大。
- **修法**：自适应用**低通后的频率**（本项目 `s_freq_lp`），并给 ω 加限幅（40~60 Hz）；
  更新周期 20~200 ms 均可，别每拍更新。
- **判据**：锁相环"锁住了但相位有固定偏差"时，先分三块查——① 采样延迟补偿 ② 环路稳态误差 ③ 自适应/参数更新的输入是否干净。

## 七、ePWM 频率只有一半：EPWMCLK 默认是 SYSCLK/2（2026-11-14，F28379D 实测）

`PERCLKDIVSEL.EPWMCLKDIV` 复位默认值为 **1**，即 `EPWMCLK = PLLSYSCLK / 2`（实测读数 1，200 MHz 器件上是 100 MHz）。
按 `TBPRD = SYSCLK/Fsw - 1` 算就会得到**一半**的开关频率：

```text
实测：SYSCLK=200 MHz（IMULT=40, DIV=2 已确认）、TBPRD=9999、TBCLK 分频全 0
      期望 20 kHz，实际 10 kHz；50 Hz 正弦调制变成 25 Hz（400 点表 / 10 kHz）
修正：保持 EPWMCLKDIV=1（EPWMCLK=100 MHz），增计数且 TBCLK 分频为 /1 时
      TBPRD 改为 100 MHz / 20 kHz - 1 = 4999。
```

排查顺序（本次有效）：① 读 `ClkCfgRegs.SYSPLLMULT.bit.IMULT` / `SYSCLKDIVSEL.bit.PLLSYSCLKDIV` 确认 SYSCLK；
② 读 `PERCLKDIVSEL.bit.EPWMCLKDIV`；③ 再读 `EPwm1Regs.TBCTL.all`（分频/计数模式）与 `TBPRD`。
判断"实际开关频率"的可靠办法：在 SOCA/中断里递增一个 `volatile Uint32` 计数器，隔 1 s 读数求差，
不要靠外设配置反推。

**器件上限**：F28379D 数据手册规定 EPWMCLK 最高 100 MHz；当 SYSCLK 超过 100 MHz，EPWMCLK 必须是 SYSCLK 的一半。SYSCLK=200 MHz 时不能为了恢复 20 kHz 把 `EPWMCLKDIV` 改为 0（/1）。

## 八、ePWM 频率是"两级分频"，不是"设成 200 MHz"

`PLLSYSCLK = 200 MHz` **不等于** ePWM 跑 200 MHz。完整链路：

```text
XTAL 10 MHz ──PLL(IMULT=40, ÷2)──► PLLSYSCLK/SYSCLK = 200 MHz   (InitSysPll)
   ├─ ClkCfgRegs.PERCLKDIVSEL.EPWMCLKDIV ──► EPWMCLK     复位默认 = /2 = 100 MHz (!)
   │        └─ EPwm.TBCTL.HSPCLKDIV × TBCTL.CLKDIV ──► TBCLK
   │                └─ TBPRD ──► 开关频率 = TBCLK/(TBPRD+1)  (增计数)
   └─ LOSPCP(÷4) ──► LSPCLK = 50 MHz  (SCI/SPI 波特率按它算)
```

| 级 | 寄存器 | 取值 | 写错/不写的后果 |
|---|---|---|---|
| ① | `PERCLKDIVSEL.EPWMCLKDIV` | 200 MHz SYSCLK 时保持 **1 = ÷2** | F28379D 的 EPWMCLK 不得超过 100 MHz |
| ② | `TBCTL.HSPCLKDIV` / `TBCTL.CLKDIV` | 0 / 0 = ÷1÷1 | TBCLK = EPWMCLK / (HSPCLKDIV × CLKDIV)；实际分频须读回 |
| ③ | `TBPRD`（16 位） | 增计数时 `TBCLK/Fsw - 1` | EPWMCLK=100 MHz、两级分频 /1 时，最低约 1.53 kHz；更低频率须按器件手册选择分频 |

本次 200 MHz SYSCLK、20 kHz 增计数、TBCLK 两级分频均为 /1 的计算例：

```c
ClkCfgRegs.PERCLKDIVSEL.bit.EPWMCLKDIV = 1;   /* /2，EPWMCLK = 100 MHz */
EPwm1Regs.TBCTL.bit.HSPCLKDIV = TB_DIV1;
EPwm1Regs.TBCTL.bit.CLKDIV    = TB_DIV1;
EPwm1Regs.TBPRD = (100000000UL / 20000UL) - 1UL; /* 4999 */
```

判定"实际开关频率"不要靠配置反推：在 SOCA/中断里递增 `volatile Uint32` 计数器，隔 1 s 读数求差最可靠。

TI 依据：[F28379D 数据手册 ePWM 时钟上限](https://www.ti.com/lit/ds/symlink/tms320f28379d.pdf)、[F2837xD ePWM 分频与计数模式](https://software-dl.ti.com/trainingTTO/trainingTTO_public_sw/c28x28379/F2837xD_Microcontroller_MDW_2-0.pdf)。

## 九、用反汇编核查编译器/库的实际行为（dis2000）

判断题（"这行代码到底编译成了什么"）不要靠印象，直接反汇编：

```powershell
$bin='C:\ti\ccsv6\tools\compiler\ti-cgt-c2000_15.12.1.LTS\bin'
& "$bin\dis2000.exe" <工程>.out | Select-String -Pattern '_(函数名):' -Context 0,40
# 只想看某段：先找标签行号，再打印后面 N 行
```

本次反汇编记录（2026-11-14，F28379D + CGT 15.12.1；周期成本尚未在板上计时）：

| 写法 | 反汇编结果 | 含义 |
|---|---|---|
| 查表 + `float32` 乘加 | `UI16TOF32` / `MPYF32` | 纯 FPU 指令，0 次三角函数 |
| `sinf(x)`（默认严格浮点模式） | `LCR ___sinf` | **库调用**；具体周期数须按当前工程计时，不凭调用形式判定能否满足 20 kHz 预算 |
| `__sin(x)`（`--fp_mode=relaxed` + `--tmu_support=tmu0`） | `DIV2PIF32` + `SINPUF32` | TMU 两条指令（输入弧度） |
| `__sinpuf32(x)`（只要 `--tmu_support=tmu0`） | `SINPUF32` | TMU **单条**指令，输入 per-unit（1.0 = 2π） |

配套坑：工程里选了 TMU 但构建命令没传 `--tmu_support=tmu0` 时，`__sinpuf32` 会退化成
隐式声明 + 外部调用，链接报 `___sinpuf32 unresolved`（本项目构建脚本已修：读 `.cproject` 的
`compilerID.TMU_SUPPORT` 并传 `--tmu_support`）。同理 `math.h` 要让 `__sin` 生效需
`--fp_mode=relaxed`，而 `__sinpuf32` 在严格模式下也可用——优先用后者。
