# 第三类：调试经验与故障复盘

遇到 ADC、eCAP、SCI、SPI、串口抓包、数据撕裂、寄存器读回、编译或下载异常时，从这里按 **器件 + 模块 + 现象** 检索。外设如何配置先查[第一类](device-platform.md)，算法库怎么调用先查[第二类](ti-algorithm-libraries.md)；诊断过程和实测结论写在第三类。旧记录保留原文，不因整理目录而删减。

## 已有经验索引

| 器件/范围 | 模块或环节 | 现象与检索词 | 记录 |
|---|---|---|---|
| DSP28335 实测 | ADC | 采样不更新、`ADCTRL2` 被覆写、结果为零、转换时序 | [C28x 踩坑清单 §一](c28x-pitfalls.md) |
| DSP28335 实测 | SPI / 外部 DAC | 发送完成标志、LOAD 脉冲、时序、波形削平 | [C28x 踩坑清单 §二](c28x-pitfalls.md) |
| DSP28335 实测 | SCI / 串口抓包 | FIFO 状态、多个发送者、帧错位 | [C28x 踩坑清单 §三](c28x-pitfalls.md) |
| DSP28335 工程实测 | CCS / 链接 / 文本编码 / 抓包工具 | include 路径、`.text` 空间、GBK、DSS、SerialPlot | [C28x 踩坑清单 §四](c28x-pitfalls.md)；[现场手册](field-guide.md) |
| DSP28335 工程实测 | PID / dq / 控制波形 | 噪声、误差来源、角度约定、母线前馈 | [C28x 踩坑清单 §五](c28x-pitfalls.md)；算法库选择另看[第二类](ti-algorithm-libraries.md) |
| DSP28335 实测 | ISR / 主循环共享数据 | 波形毛刺、原子快照、关中断、INTM | [C28x 踩坑清单 §六](c28x-pitfalls.md)；[TI 例程写法 §4.5](ti-official-style.md) |
| DSP28335 / F28379D 等，按各文适用范围 | JTAG / DSS / 读回 | 下载失败、就绪条件、读得太早、长时等待 | [DSS 调试](dss-debug.md)；[器件与探针记录](other-devices-and-probes.md) |
| 具体工程与工具链，按原文适用范围 | 构建 / 链接 / 自动化 | 旧 `.out`、失败分类、RAM/Flash 段 | [现场手册](field-guide.md)；[RAM 与链接](ram-and-linker.md) |

上表是旧资料的入口，**不表示每条旧结论已在所有列出的器件上验证**。尤其不要把 DSP28335 的 ADC、SPI、SCI 寄存器行为直接套到 F28379D。eCAP 的当前板实测故障见下表；先查当前器件例程，再按下面规则建立案例。

## 新案例索引

以后每个新的故障或可复用调试发现单独写一份 `debug-cases/<器件型号>/<日期>-<模块>-<简短现象>.md`，文件名用小写 ASCII，例如 `debug-cases/f28379d/2026-10-27-ecap-capture-zero.md`。按下表登记；模块可写 ADC、SCI、eCAP、CPU1/CPU2、JTAG、链接等，不预设固定清单。查找时同时搜器件、模块、现象词；跨器件问题在单一案例中写清逐个验证的型号，不能仅凭家族相似性推广。

| 器件/目标核 | 模块 | 现象与检索词 | 状态 | 案例 |
|---|---|---|---|---|
| DSP28335 | SPI / 外部 DAC（TLV5620） | LOAD 拉早、残字锁存、码值翻倍/串道、DAC 假损坏、`BUFFULL_FLAG`/`INT_FLAG`、`SPIRXBUF`、FIFO 不适用、`SPIBRR` | 已回归 | [2026-10-26-tlv5620-load-timing](debug-cases/dsp28335/2026-10-26-tlv5620-load-timing.md) |
| DSP28335 | SCI / 共享数据 | 波形垂直毛刺、帧错位、原子快照、`DINT` | 排查中 | [2026-10-26-sci-shared-data-tearing](debug-cases/dsp28335/2026-10-26-sci-shared-data-tearing.md) |
| DSP28335 | ADC / 接线判据 | 悬空引脚读数稳定、误判通道损坏、历史 `0.95V` 读数 | 待复核 | [2026-10-27-adc-floating-misjudge](debug-cases/dsp28335/2026-10-27-adc-floating-misjudge.md) |
| DSP28335 | SolarLib SPLL / 三相 SOGI | sine 型输入的 d/q、硬编码 B0/B1、半拍补偿、DSOGI 正负序分离、不平衡下 vq 纹波 0.262→0.001 pu | 已回归 | [2026-10-27-solarlib-spll-integration](debug-cases/dsp28335/2026-10-27-solarlib-spll-integration.md) |
| DSP28335 | CCS / SDK 例程构建 | eCAP、`INSTALLROOT_*`、linked resources、通用构建脚本失败 | 已回归（构建适配） | [2026-10-27-sdk-example-build-macros](debug-cases/dsp28335/2026-10-27-sdk-example-build-macros.md) |
| DSP28335 / XDS100v1 | JTAG / DSS 自动化 | PowerShell 调用 `.bat` 失败、CIM 误报无探针、`xds100serial` | 已回归 | [2026-10-28-dss-batch-probe-preflight](debug-cases/dsp28335/2026-10-28-dss-batch-probe-preflight.md) |
| DSP28335 | eCAP / GPIO 连通性 | GPIO4 翻转、GPIO24 恒高、eCAP 捕获计数为零、跳线 | 排查中 | [2026-10-28-ecap-gpio24-no-edge](debug-cases/dsp28335/2026-10-28-ecap-gpio24-no-edge.md) |
| DSP28335 / CCS 12.8 DSS | FPU / 浮点读回 | `expression.evaluate` 截断、浮点显示整数、原始位型、误判超时 | 已回归（读回方法） | [2026-10-28-fpu-dss-float-readback](debug-cases/dsp28335/2026-10-28-fpu-dss-float-readback.md) |
| DSP28335 / 本机 SDK | FPU software / 工程选项 | 源码写软件浮点、`.cproject` 仍启用 `fpu32`、错误验收 | 待复核 | [2026-10-28-fpu-software-project-options](debug-cases/dsp28335/2026-10-28-fpu-software-project-options.md) |

新案例按[案例模板](debug-cases/CASE-TEMPLATE.md)记录，原始日志/波形优先保存在对应工程或用户指定位置，案例中写稳定路径与关键读数，避免把大量原始数据复制进技能。

## 每次调试结束时的归档判定

1. 先按器件、模块、现象查本页、`debug-cases/` 和旧记录。新故障、新证据、新根因，或**可复现但尚未定位**的问题，都建立案例；已有案例则补充新器件的验证结果或反例，不制造重复案例。纯操作且没有新证据时不建空案例。
2. 案例写清器件/板卡/目标核、模块、环境、现象、复现条件、原始证据、排查过程、原因或假设、修复与回归结果。用“排查中 / 待复核 / 已定位 / 已回归 / 已证伪”标状态；PC 数值验证与目标板回归分别写明。把实测事实与推测分开；缺失的参数写“未知”，不要补造。
3. 登记上面的新案例索引，状态和文件一致。运行 `pwsh -NoProfile -File "<skill>\scripts\check_debug_catalog.ps1" -SkillRoot "<skill>"`，确认每个案例都入索引、每条案例链接都存在。交付时告知用户新增或更新的案例；无法写入技能时，把证据和待归档事项明确交给用户。

**结论晋级门槛**：标“已定位”须有能区分竞争原因的原始读数/抓包/波形及对应源码版本；标“已回归”还须有修复前后同条件结果、实际构建标识和目标板运行记录。工程注释、旧 `.out`、口述截图、PC 仿真各自只能支持其实际覆盖范围。算法或外设建议与旧案例冲突时，先核对当前器件 TI 手册和真实寄存器配置，修正冲突后再归档。目录检查脚本只校验收录、链接与状态一致性，**不校验技术结论是否正确**。
