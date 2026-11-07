# SolarLib v1.2 全库入口（controlSUITE）

本机位置：`F:\controlSUITE\libs\app_libs\solar\v1.2\`（另有同版本副本 `C:\Users\Jordon\Desktop\contr\v1.2`）。
`2-1SOGI_PLL` 工程已把 float 版拷到 `Library/solarlib/{include,source}` 并加了 include path，
调用前先看那一份和 `Library/solarlib/README.md`，不要重复拷贝出第二套模块。

这是 **第二类：TI 库与算法** 的资料入口，不限于 PLL。先按目标功能查下表，再读该目录的 `SolarLib.pdf`、对应 `include/<模块>.h` 和 `source/<模块>.c`，确认调用约定、参数、数值范围及所需依赖；不要只从模块名推断实现。另有 `RevisionHistory.txt` 与 `spll_coeff_compute.xlsx`。移机时重新定位实际目录和版本。

## 模块索引

下列名称以 `float/include/` 的 `_F` 版本为例；同名 `_IQ`、`_CLA` 变体见各自目录。每组列的是本机已核对的头文件名，不表示它们可无修改地用于所有器件。

| 需求 | 模块（省略 `_F` 后缀） | 先核对 |
|---|---|---|
| 单相/三相并网锁相 | `SPLL_1ph`、`SPLL_1ph_SOGI`、`SPLL_3PH_SRF`、`SPLL_3ph_DDSRF` | 采样频率、系数、相位/符号约定；详见 [SPLL 专题](spll-pll-algorithms.md) |
| MPPT | `MPPT_PNO`、`MPPT_INCC`、`MPPT_INCC_I` | 扰动观察或电导增量方式、输入量单位、控制方向和限幅 |
| 坐标变换 | `ABC_DQ0_POS`、`ABC_DQ0_NEG`、`CLARKE`、`PARK`、`iCLARKE`、`iPARK`、`DQ0_ABC` | 正负序、角度单位、d/q 符号和归一化 |
| 数字控制与滤波 | `CNTL_PI`、`CNTL_2P2Z`、`CNTL_3P3Z`、`PID_GRANDO`、`NOTCH_FLTR`、`MATH_EMAVG` | 系数来源、采样周期、状态初始化、饱和与数值格式；也比较 Core SDK 的 DCL |
| 测量、记录与激励 | `SINEANALYZER_DIFF`、`SINEANALYZER_DIFF_wPWR`、`DLOG_1CH`、`DLOG_4CH`、`RAMPGEN` | 窗口/缓冲区长度、触发方式、功率与频率计算前提 |

共 25 个算法模块；每种数值版本另有一个聚合头文件 `Solar_F.h`、`Solar_IQ.h` 或 `Solar_CLA.h`。本机 `float/` 和 `IQ/` 各有 26 个头文件、25 个对应 `.c` 源文件和一份 `.lib`；`CLA/` 有 26 个头文件及 `Solar_Lib_CLA.lib`，`source/` 只见 `test.c`，不要误认为 CLA 模块源码也逐个提供。实际使用时按器件的 FPU/CLA 能力、工程 ABI、编译器及链接格式选择变体，并做构建和目标验证。

## 调用前的检索顺序

1. 先搜当前工程是否已带 SolarLib 或适配层，避免重复拷贝和两套状态变量并存。
2. 按功能选模块和 `float/IQ/CLA` 变体；打开对应头文件、源码（若有）、`SolarLib.pdf` 中的模块说明。核对数据结构默认值、初始化、每次 ISR 的调用顺序及必要系数。
3. 结合目标器件、采样率、数值格式与编译链路验证。旧库中的 `.lib` 能否直接链接当前工程应以真实构建为准；不能把本机曾用某模块等同于整库已在 DSP28335/F28379D 上验证。
