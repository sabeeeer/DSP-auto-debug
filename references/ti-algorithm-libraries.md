# 第二类：查找并复用 TI 库与算法

用于 PID/数字控制、MPPT、SPLL、坐标变换、滤波、测量、FIR/IIR/FFT、定点或浮点数学、CLA、VCU、AI、校准和协议库等任务。**先检索现成 TI 库、示例和工程已有实现，再决定适配或自研。**`driverlib` 和 `device_support` 里的外设配置例程归第一类；调试中发现的故障经验归第三类。

## 本机 C2000Ware 库入口

本机核对的 SDK 是 `F:\c2000ware-core-sdk\`。换电脑先定位实际 SDK，不把此绝对路径当成依赖。该版本的 `libraries/` 有六类：

| 类别 | 本机子库/内容 | 典型用途 |
|---|---|---|
| `control/` | `DCL` | PI/PID、数字补偿器等控制算法 |
| `dsp/` | `FixedPoint`、`FPU`、`VCU` | FIR/IIR/FFT、向量运算、CRC/编解码 |
| `math/` | `IQmath`、`CLAmath`、`FPUfastRTS`、`FASTINTDIV` | 定点、CLA、浮点和整数数学 |
| `calibration/` | `hrpwm`、`hrcap` | 对应高精度外设的校准库；具体器件适用性需核对 |
| `communications/` | `PMBus`、`usb` | 协议和设备栈 |
| `ai/` | `common`、`examples` 等 | 边缘 AI 示例与支持代码 |

**在本机这份 Core SDK 中能找到 DCL，DMC 则要到另一份已安装的 controlSUITE 查**。路径已核对：

| 名称 | 本机位置 | 查找重点 |
|---|---|---|
| DCL（Digital Control Library） | `F:\c2000ware-core-sdk\libraries\control\DCL\c28\` | `include\DCL.h`、`docs\`、`examples\`；PI/PID、数字补偿器等。 |
| DMC（Digital Motor Control） | `F:\controlSUITE\libs\app_libs\motor_control\` | `math_blocks\v4.0\` 中的 `clarke.h`、`park.h`、`svgen.h` 等，以及器件相关 `drivers\`；移植时核对当前器件外设与数值格式。 |

**SolarLib v1.2 是另一个重要的算法库**：`F:\controlSUITE\libs\app_libs\solar\v1.2\`。它不只提供 SPLL，还包括 MPPT、PI/2P2Z/3P3Z、坐标变换、滤波、正弦测量、数据记录和斜坡生成。遇到这些需求先读 [SolarLib 全库目录](solarlib-catalog.md)，再按模块读 `SolarLib.pdf`、头文件和源码；只有 PLL/SOGI 任务才进一步读 [SPLL 专题](spll-pll-algorithms.md)。

`F:\c2000ware-core-sdk\README.md` 标明该下载为 Core SDK v26.00.00.00.STS；本机 `libraries\control` 有 DCL，没有 DMC。不能据此判定 GitHub 下载不完整；DMC 的旧版宏库本来从 controlSUITE 取，且不应把其中的器件驱动直接套到别的 C2000 型号。换电脑或 SDK 版本时重新核对实际安装路径。

**包的边界**：`c2000ware-core-sdk` 是 TI 官方发布的 C2000Ware 基础包，不是全部 C2000 应用软件的合集。[TI 的软件指南](https://software-dl.ti.com/C2000/docs/software_guide/c2000ware/index.html)列出 Core 库；[MotorControl SDK](https://www.ti.com/tool/C2000WARE-MOTORCONTROL-SDK)则是另一个面向电机控制的包，内附一份 C2000Ware，不能倒推 Core 包也含全部电机库。旧 DMC 宏库以本机 controlSUITE 为准；不要仅凭“SDK”字样推断任意库必在 `libraries/` 下。

完整库名、实例和需求映射见 [C2000Ware 库索引](c2000ware-index.md) §3–4；每个库以本机 `docs/`、`examples/`、`include/`、`source/`、`lib/`、`cmd/` 的实际内容为准，不能假定每个库都有所有子目录。可用只读本地检索：

```powershell
pwsh -NoProfile -File "<skill>\scripts\c2000ware_find.ps1" -SdkRoot "F:\c2000ware-core-sdk" -Source local -NoDownload -List libs
pwsh -NoProfile -File "<skill>\scripts\c2000ware_find.ps1" -SdkRoot "F:\c2000ware-core-sdk" -Source local -NoDownload -Kind library -Keyword "<算法或库名>"
```

## 选库与移植

1. 明确算法功能、目标器件与核心、采样率、数值格式（IQ/float/CLA）、编译器 ABI、性能及内存约束。搜工程现有模块和 SDK 库，避免重复实现。
2. 读候选库的文档、头文件、示例和其 `.cmd`/`.lib` 变体；核对目标器件是否有适用示例或构建配置。算法正确性与可链接性都要验证。
3. 能复用时优先写薄适配层；确需自研时，记录查过哪些库、为什么不适用及对照验证办法。交付时说明库版本、具体源路径、参数/系数来源与构建结果。

**PLL 名称辨别**：本机 Core SDK 的 `libraries/` 清单中没有 SolarLib SPLL；处理电网 PLL、SOGI、SRF/DDSRF 时使用上面的 SolarLib 入口及 [SPLL 专题](spll-pll-algorithms.md)，核对实际 TI 源码与工程适配层；片内时钟 PLL 则按第一类查器件例程。

## 正弦 / 波形生成：先看器件有没有 TMU

| 方案 | 适用器件 | 每次调用代价 | 说明 |
|---|---|---|---|
| **`__sinpuf32()` TMU** | 当前器件与编译器支持 TMU 时 | 本次反汇编为 1 条 `SINPUF32`；TI 资料给出 1 周期发射、4 周期结果延迟 | 输入 per-unit 角（1.0 = 2π）；需相应 `--tmu_support`，按工程编译结果核对 |
| `__sin()` | 同上 | `DIV2PIF32` + `SINPUF32` | 输入弧度；需 `--fp_mode=relaxed` 且 `--tmu_support` |
| **离线查表** | 包括无 TMU 的 F28335 | 查表及可选插值，成本随实现变化 | 表长度按精度、RAM 与插值方式选；改输出频率通常只改相位增量 |
| IQmath `_IQsin` | 工程链接的 IQmath 版本支持时 | 依赖 Q 格式与库实现 | F28335 可考虑，需核对版本、精度与周期预算 |
| `sinf()` 库调用 | 工程所用编译器与运行库支持时 | 本次严格模式反汇编为库调用；周期数须实测 | 是否满足 ISR 预算由目标采样率、优化级别与实测决定 |

要点：
- **F28335 没有 TMU**。正弦可比较查表、IQmath 和 `sinf()` 的误差与周期预算，按本工程采样率选择。
- 用 TMU 的工程必须在 `.cproject` 里选 TMU（`--tmu_support=tmu0`），并且**命令行构建也要传这个选项**，
  否则本次工程曾出现 `___sinpuf32 unresolved`；具体报错和反汇编见[坑表 §九](c28x-pitfalls.md)。
- 判断"到底编译成了什么"用 `dis2000` 反汇编核对，别看源码猜（同 [坑表 §九](c28x-pitfalls.md)）。
- SPWM 里正弦的用法：相位用 per-unit 累加（每次更新加 `Fmod/Fupdate`），`duty = 0.5 + 0.5·m·sin`，
  改调制波频率只改相位增量，不需要重新生成表。

TI 依据：[C28x 优化指南：TMU 编译选项](https://software-dl.ti.com/C2000/docs/optimization_guide/phase1/compiler_options.html)、[F2837xD TMU 指令吞吐与延迟](https://software-dl.ti.com/trainingTTO/trainingTTO_public_sw/F2837xD/C28x_Microcontroller_ODW_2-0.pdf)。
