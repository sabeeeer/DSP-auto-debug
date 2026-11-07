# 第一类：器件、外设与 CCS 工程

用于换 C2000 器件/板卡、接探针、建工程、配置 CPU1/CPU2、外设、编译器和链接脚本。这里的“器件”包括 DSP28335、F28379D 等；eCAP/ADC/SCI 的寄存器和驱动配置也从这里进入。具体故障复盘归第三类。

## 先确认当前工程

1. 从实际 `.cproject`、`.ccsproject`、`.ccxml`、链接 `.cmd`、源码头文件和板卡资料确认器件、核心、CCS/编译器、COFF/EABI、bitfield/driverlib、RAM/Flash 配置。不要仅凭工程文件夹名推断。
2. 写 ePWM、ADC、eCAP、SCI、SPI、I²C、DAC 或其他外设前，读[官方例程模板规则](peripheral-examples.md)。用 `scripts/list_peripheral_examples.ps1 -SdkRoot <SDK目录> -DeviceFamily <器件族> -Peripheral <模块>` 列全同器件例程，再打开选中的源码和工程配置；`c2000ware_find.ps1` 可作跨 SDK 的辅助检索，但其默认输出有条数上限。eCAP 例如在本机 SDK 的 `driverlib/f2837xd/examples/cpu1/ecap/` 有捕获及 APWM 例程；换器件时应重新定位。
3. 在现有工程中匹配引脚、时钟、PIE/中断、`.cmd` 内存段、库路径和被排除的源文件。只改当前工程需要的部分。

## 按问题继续读

| 问题 | 资料 |
|---|---|
| 28335 bitfield 写法、ISR、原子快照 | [TI 例程写法](ti-official-style.md)；具体例程从本机 TI SDK 核对 |
| F28379D + XDS100v2、`f28379d.xml`、CPU1/CPU2、探针串号 | [器件与探针对照](other-devices-and-probes.md) §3.2、§4；[实机记录](environment.md) |
| 新器件、driverlib、SysConfig、器件例程结构 | [C2000Ware 指南](c2000ware-guide.md) 与 [例程索引](c2000ware-index.md) |
| 按 TI 模板写或迁移任意外设 | [官方例程模板规则](peripheral-examples.md)：同器件源码、配置契约、构建及上板重复验证 |
| `.cmd`、RAM/Flash、链接内存、编码 | [RAM 与链接](ram-and-linker.md)；必要时用 `scripts/check_ram_layout.ps1` |
| 构建、下载、DSS、寄存器读回 | [现场操作手册](field-guide.md) 与 [DSS 调试](dss-debug.md) |
| 示例 F28335 工程的模块和引脚 | 只有确认是该工程后才读 [工程地图](project-map.md)；其他板以自身源码和原理图为准 |

本技能有 DSP28335 + XDS100v1（`2-1SOGI_PLL`）、DSP28335 + XDS100v2（旧工程）和 F28379D + XDS100v2 的记录。探针型号以当前板的硬件描述、序列号和 `.ccxml` 为准；家族表里列出的其他型号表示有适配资料，不表示已上板验证。
