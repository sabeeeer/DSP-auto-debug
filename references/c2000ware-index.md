# C2000Ware 全量索引：器件 · 例程 · 库 · API（写功能前的第一站）

> **参照源（自动探测，不要写死路径）**：`scripts\c2000ware_find.ps1` 依次找
> 本机 C2000Ware/controlSUITE → 本机快照仓库 → **GitHub 快照** `sabeeeer/c2000ware-ref`
> （自动下载到 `%LOCALAPPDATA%\c2000ware-snapshot` 缓存）。本文件里的相对路径（`device_support\...`、
> `libraries\...`）在任何来源下都一样，**根目录以脚本打印的 `SOURCE:` 行为准**。
>
> **固定动作**（写任何"某功能"的 DSP 代码前，按顺序做）：
> ① 跑 `scripts\c2000ware_find.ps1 -Keyword "<关键词>"` 定位官方例程 / 库；
> ② 查本文件 §4「我要做 X」速查表；
> ③ 打开命中的 `examples\`，**照它的初始化顺序 / API / 中断写法写**；
> ④ 找不到就先问用户，**不许凭印象发明寄存器用法**。
>
> SDK 宏观用法（bitfield vs driverlib、cmd、SysConfig、仿真器）见 `c2000ware-guide.md`。

---

## 1. 器件总表（SDK v26.00.00.00.STS，本机 `F:\c2000ware-core-sdk`）

| 器件包 | device_support（bitfield + headers + cmd） | driverlib（库式 API） | 说明 |
|---|---|---|---|
| **f2833x** | ✓（74 .c） | ✗ | **DSP28335/28334/28332**；只有 bitfield，与 controlSUITE v142 同一套 |
| f2823x | ✓（70） | ✗ | 2833x 精简型号 |
| **f2837xd** | ✓（175） | ✓（210） | **DSP28377D / 28379D**；双核 CPU1/CPU2 + CLA；例程分 `examples\cpu1\` 与 `examples\dual\` |
| **f2837xs** | ✓（131） | ✓（168） | DSP28377S / 28379S；单核（只有 cpu1 例程） |
| f2838x | ✓（74） | ✓（439） | F28388D：双 C28 核 + Cortex-M4 |
| f2807x | ✓（116） | ✓（165） | F28075/76/77 |
| f28004x | ✓（35） | ✓（241） | F280049C 等，driverlib 主推 |
| f28003x / f28002x / f280013x / f280015x | ✓ | ✓ | 新一代 Piccolo |
| f2806x / f2805x / f2803x / f2802x / f2802x0 | ✓ | ✗ | 老 Piccolo（多为 bitfield） |
| f28e12x / f28p551x / f28p55x / f28p65x | ✓ | ✓ | 最新一代 |
| f280x / f281x | ✓ | ✗ | C28x 老器件（无 driverlib） |

实时列：`c2000ware_find.ps1 -List devices`；库清单：`-List libs`。

---

## 2. 例程在哪、叫什么

### 2.1 bitfield 例程（`device_support\<器件>\examples\`）

命名 = `Example_2833x<外设>.c`（2833x）或 `<外设>_<功能>\cpu01\*.c`（2837x 双核）。
常见主题（各器件大同小异）：gpio_setup / gpio_toggle / timed_led_blink / cpu_timer / external_interrupt /
sw_prioritized_interrupts / epwm_up_aq / epwm_updown_aq / epwm_deadband / epwm_timer_interrupts /
epwm_trip_zone / epwm_dma / hrpwm* / adc_soc / adc_seqmode_test / adc_seq_ovd_test / adc_dma /
scia_loopback / sci_loopback_interrupts / sci_echoback / sci_autobaud / spi_loopback(_interrupts) /
i2c_eeprom / dma_ram_to_ram / dma_xintf_to_ram / ecap_apwm / ecap_capture_pwm / eqep_* / ecan_* /
watchdog / lpm_* / flash_* / f28335_flash_kernel / cla_* / clb_* / cmpss_* / sdfm_* / dac_* / emif_* /
upp_* / empty_project（f2837xd）。

### 2.2 driverlib 例程（`driverlib\<器件>\examples\cpu1\`）

按**外设目录**分（f2837xd 31 个）：adc / can / cla / clb / cmpss / dac / dcsm / dma / ecap / emif /
empty_projects / epwm / eqep / gpio / hrpwm / i2c / interrupt / ipc / led / lpm / mcbsp / pinmux / sci /
sdfm / spi / sysctl / timer / upp / usb / watchdog。
例程文件命名：`<外设>_exN_<功能>.c`（如 `epwm_ex1_trip_zone.c`、`adc_ex1_soc_software.c`）。
双核例程在 `examples\dual\`（cpu01 + cpu02 各一份）。

---

## 3. libraries 全库索引（`libraries\<类>\<库>\c28\` 下设 include / lib / source / examples / docs，部分有 cmd / ccs / reference / models）

| 库 | 路径 | 头文件 | 预编译库 | examples 里有什么 | 用途 |
|---|---|---|---|---|---|
| **IQmath** | `libraries\math\IQmath\c28` | `include\IQmathLib.h` | `lib\IQmath*.lib` | `C\`、`Cpp\`、`cmd\`、`bootROM_symbols\`、`graph_properties\` | Q 格式定点数学（sin/cos/sqrt/除法/饱和） |
| **CLAmath** | `libraries\math\CLAmath\c28` | `include\CLAmath.h` | `lib\CLAmath.lib` | acos/asin/atan/atan2/atan2PU/cos/cosPU/div/sin/sqrt、cla_cfft_256/512/1024、cla_rfft_512/1024 … | **CLA** 上的浮点数学 + FFT（仅带 CLA 器件） |
| **FPUfastRTS** | `libraries\math\FPUfastRTS\c28` | `include\` | `lib\` | atan_f32 / atan2_f32 / atan2_f64 / div_f32 / exp_f32 / isqrt_f32 / log_f32 / pow_f32 / sincos_f32 / sin_f32 / sqrt_f32（+28E12x_* 版） | FPU 快速运行时（三角/开方/除法/幂） |
| **FASTINTDIV** | `libraries\math\FASTINTDIV\c28` | —（汇编级） | — | `f28002x\`、`f28003x\`、`f2838x\` | 整数快速除法 |
| **dsp\FixedPoint** | `libraries\dsp\FixedPoint\c28` | `include\` | `lib\` | **2833x**_FixedPoint_BRevAcq / CFFT / FIR16 / FIR16_Alt / FIR32 / IIR16 / IIR32 / RFFT / Win（+28E12x/F28P55x 版） | 定点 FIR / IIR / FFT（**有 2833x 版**） |
| **dsp\FPU** | `libraries\dsp\FPU\c28` | `include\` | `lib\` | `fft\`、`filter\`、`vector\` | 浮点 FFT / FIR / 向量运算 |
| **dsp\VCU** | `libraries\dsp\VCU\c28` | `include\` | `lib\` | `crc\`、`deinterleaver\`、`fft\`、`reed_solomon\`、`viterbi\` | VCU 硬件加速（CRC/维特比/RS/交织） |
| **control\DCL** | `libraries\control\DCL\c28` | `include\DCL.h` | 源码 | F28069_PID、F28069_PI_CLA、F28069_DF22、F28069_DF23_CLA、F28069_NLPID、F28069_SMITH、F28069_GSM、F28069_TCM、F280049_ERAD、28E12x_*、F280013x/15x_DF22 | 数字控制库：PID / 2P2Z / 3P3Z / 非线性 / 史密斯预估… |
| **communications\PMBus** | `libraries\communications\PMBus\c28` | `include\` | — | 280015x / 28002x / 28003x / 28004x…_pmbus_controller / _target / _over_i2c | PMBus 协议栈 |
| **communications\usb** | `libraries\communications\usb\<器件>` | — | — | 各器件 USB 示例 | USB 设备栈（2837xd/2837xs/2838x…） |
| **calibration\hrpwm** | `libraries\calibration\hrpwm\<器件>` | — | — | 按器件（f2833x、f2837xd、f2800x…） | HRPWM 高精度自动校准（SFO） |
| **calibration\hrcap** | `libraries\calibration\hrcap\<器件>` | — | — | f2803x / f2806x | HRCAP 校准 |
| **ai** | `libraries\ai\` | — | — | `examples\`：motor_fault、arc_fault、blower_imbalance、fan_blade_anomalydetection、forecasting_pmsm_rotor_temp、generic_timeseries_{anomalydetection, classification, forecasting, regression}、hvac_indoor_temp_forecast、torque_measurement、washing_machine_load_weighing | 边缘 AI（电机故障 / 电弧 / 负载识别…） |

---

## 4. 「我要做 X」→ 用哪个库 / 哪个例程

| 需求 | 首选 | 参照路径（尾部） |
|---|---|---|
| 定点 PID / 电流环 | `control\DCL`（`DCL_runPID` 等） | `DCL\c28\examples\F28069_PID` |
| 浮点 PID / 2P2Z / 3P3Z | `control\DCL` | `F28069_DF22`、`F28069_DF23_CLA`、`F28069_PI_CLA` |
| 非线性 PID / 史密斯预估 / ERAD 采样 | `control\DCL` | `F28069_NLPID`、`F28069_SMITH`、`F280049_ERAD` |
| 定点 FIR / IIR | `dsp\FixedPoint` | `2833x_FixedPoint_FIR16`、`2833x_FixedPoint_IIR32` |
| 定点 FFT（CFFT / RFFT） | `dsp\FixedPoint` | `2833x_FixedPoint_CFFT`、`2833x_FixedPoint_RFFT` |
| 浮点 FFT / 向量 | `dsp\FPU` | `dsp\FPU\c28\examples\fft`、`vector` |
| sin/cos/atan/sqrt 快算（浮点） | `math\FPUfastRTS` | `sin_f32`、`atan2_f32`、`sqrt_f32` |
| Q 格式定点数学 | `math\IQmath` | `IQmath\c28\examples\C` |
| CLA 上算数学 / FFT | `math\CLAmath` | `cla_cfft_256`、`cos`、`sqrt` |
| 整数快速除法 | `math\FASTINTDIV` | `examples\f28002x` … |
| CRC / 维特比 / RS 编解码 | `dsp\VCU` | `crc`、`viterbi`、`reed_solomon` |
| PMBus 电源通信 | `communications\PMBus` | `28004x_pmbus_controller` |
| HRPWM 高精度 + 自校准 | `calibration\hrpwm\<器件>` | 按器件目录 |
| 电机故障 / 电弧 / 负载识别 | `libraries\ai\examples` | `motor_fault`、`arc_fault`、`washing_machine_load_weighing` |
| 双核通信 | driverlib `ipc.h` | `driverlib\f2837xd\examples\cpu1\ipc` |
| 外设怎么配（任意外设） | 该器件的 `device_support\...\examples\` 或 `driverlib\...\examples\` | 用 `c2000ware_find.ps1 -Keyword <外设>` 定位 |

---

## 5. driverlib API 模块与前缀（f2837xd 为例，36 个头）

`driverlib\<器件>\driverlib\`：adc / asysctl / can / cla / clb / cmpss / cpu / cputimer / dac / dcsm /
debug / dma / ecap / emif / epwm / eqep / flash / gpio / hrpwm / i2c / interrupt / ipc / mcbsp / memcfg /
pin_map / sci / sdfm / spi / sysctl / upp / usb / xbar / version（+ `hw_*.h` 寄存器位定义）。

| 前缀 | 常用 API（示例，完整用 `-Kind api -Keyword xxx` 搜） |
|---|---|
| `EPWM_` | setTimeBasePeriod / setTimeBaseCounterMode / setClockPrescaler / setCounterCompareValue / setActionQualifierAction / enableTripZoneSignals / setTripZoneAction / clearTripZoneFlag / enableInterrupt / setInterruptSource |
| `GPIO_` | setPadConfig / setPinConfig（`GPIO_0_EPWM1A`）/ setDirectionMode / setQualificationMode / writePin / togglePin / readPin |
| `Interrupt_` | initModule / initVectorTable / register / enable / clearACKGroup（全局还是 `EINT; ERTM;` 宏） |
| `SysCtl_` | setClock / disablePeripheral / enablePeripheral / setLowPowerMode |
| `ADC_` | setMode / setResolution / setSignalMode / configureSOC / setSOCTriggerSource / forceSOC / enableInterrupt |
| `SCI_` | setConfig / enableModule / writeChar / readChar / enableInterrupt |
| 其余 | `DMA_`、`XBAR_`、`MemCfg_`、`Flash_`、`CPU_`、`IPC_`、`DCSM_`、`CLB_`、`Cmpss_`、`SDFM_`、`DAC_`、`EMIF_`、`I2C_`、`McBSP_`、`UPP_`、`USB_`、`ECap_`、`EQEP_`、`HRPWM_`、`CPUTimer_` —— 都是 `<外设>_<动作>` 规律 |

---

## 6. 用库/例程的硬规则

1. **先看该库的 `docs\` 与 `cmd\`**：`_IQMATH` / `_TMU` / `_SGEN` / `_CLA` 这些 cmd 变体就是给数学库/CLA 准备的，
   别直接套默认 RAM/Flash cmd；
2. 头文件只加库的 `include\`；`.lib` 按输出格式选（COFF 用 `*_coff.lib`，EABI 用 `*_eabi.lib`）；
3. 库的 `examples\` 就是**用法原型** —— 照抄它的 include 组合、初始化顺序、cmd 选择；
4. 器件没有的能力别硬套：CLAmath/CLA 例程只适用于带 CLA 的器件（2833x 没有 CLA）；
   `dsp\FixedPoint` 有 2833x 版例程可直接参考；
5. 把库加进工程 = 工程里加 `.lib` + `INCLUDE_PATH` 加库的 `include\`（照 §3 路径），
   **不要改 TI 库源码**；本 skill 的构建脚本会按 `.cproject` 把工程里的 `.lib` 一起链进去。
