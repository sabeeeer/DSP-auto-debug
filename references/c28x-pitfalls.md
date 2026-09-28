# C28x / DSP2833x 实测踩坑清单（外设时序 + 工程操作）

> **来源**：4-1 两电平闭环工程（DSP28335 + CCS12 + XDS100）实测，2026-09。
> **用法**：写 ADC/SPI/SCI 代码或调试"数据不对"类问题前先扫一遍。
> **每条都写了：现象 → 根因 → 解法 → 诊断方法**，照做即可。

---

## 一、ADC

### 1.1 软件触发（写 `ADCTRL2.bit.SOC_SEQ1`）不可靠 → 优先用 EPWM 触发

- **现象**：主循环里软件触发 SEQ1 后读结果，**同一组值连续 4 帧不变**
  （波形呈现"平顶 + 陡坡"的梯形，看着像数据没更新）
- **陷阱**：即使写成"先等 `ADCST.bit.SEQ1_BSY` 置起、再等它清零"两段式等待，
  **仍然拿不到新值** —— 这条路在 C28x 上不可靠
- **解法**：**改用 EPWM SOCA 硬件触发**
  ```c
  /* EPWM 侧 */
  EPwm1Regs.ETSEL.bit.SOCASEL = ET_CTR_ZERO;   /* CTR=0 产生 SOCA */
  EPwm1Regs.ETSEL.bit.SOCAEN  = 1;
  EPwm1Regs.ETPS.bit.SOCAPRD  = ET_1ST;        /* 每次都发 */
  /* ADC 侧 */
  AdcRegs.ADCTRL2.bit.EPWM_SOCA_SEQ1 = 1;
  ```

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

### 2.1 `SPISTS.bit.INT_FLAG` 是"只写 1 清除"位，读回恒为 1

- **现象**：`while (SpiaRegs.SPISTS.bit.INT_FLAG == 0) { }` 想等 SPI 发完，
  实际**立即通过、什么也没等**
- **根因**：该位不是"传输完成标志"，读回恒为 1
- **解法**：**用固定延时**（按波特率算：`位数 / SPI时钟频率`），或
  `while (BUFFULL_FLAG == 1)` 等数据进移位寄存器 **+ 足够延时**

### 2.2 SPI 波特率与"LOAD 脉冲"的时序（DAC/移位型外设通用）

- **现象**：DAC 输出的正弦"有大体趋势，但顶部削平、有台阶、偶发尖刺"
- **根因**：写完 `SPITXBUF` 后只等 `BUFFULL_FLAG` 清零（≈数据进移位寄存器）
  就拉 LOAD 锁存，而 SPI 在 0.75MHz 下发 11 位要 **14.7us**，紧接着 `DELAY_US(2)` 远不够
  → **锁进 DAC 的是残缺数据**
- **解法**：
  1. 提高 SPI 波特率：`SpiaRegs.SPIBRR = 9;`（37.5MHz/10 = 3.75MHz，11 位仅 2.9us）
  2. 等待给足：`DELAY_US(5)`
  3. 然后才拉 LOAD 脉冲（低脉冲 ≥ 2us 再拉高）
- **验证**：`BUFFULL_FLAG`、`SPICCR`（字符长度）、`SPIBRR` 三个都读出来核一遍

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

## 六、快速诊断流程（遇到"数据不对"时照这个走）

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
```

**核心思路**：**先用"静态已知值"把链路钉死，再查动态时序。**
不要在动态数据上猜 —— 静态测试能一次性排除"通道/换算/接线"三大类问题。
