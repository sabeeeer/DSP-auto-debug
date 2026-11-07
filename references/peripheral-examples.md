# 第一类：从当前器件的 TI 外设例程写配置

本页只管片上外设及其板级连接；DCL、SolarLib 等算法仍走[第二类](ti-algorithm-libraries.md)，实际故障和波形证据走[第三类](debugging-experience.md)。例程源码以本机 SDK 为准，本页不复制大段 TI 代码。

## 先找同器件、同写法、同运行模式

1. 从当前工程的 `.cproject`、器件头文件、`.ccxml`、`.cmd` 确认**具体芯片、CPU1/CPU2、RAM/Flash、bitfield 或 driverlib、CCS/编译器与 ABI**。DSP28335 对应本机 SDK 的 `f2833x` bitfield；F28379D 对应 `f2837xd`，可有 bitfield 或 driverlib，双核例程须认清目标核。不要把 28335 和 28379D 的寄存器、时钟或引脚宏混用。
2. 列出所有命中例程，**不按前 N 条截断**：

   ```powershell
   pwsh -NoProfile -File "<skill>\scripts\list_peripheral_examples.ps1" -SdkRoot "F:\c2000ware-core-sdk" -DeviceFamily f2833x -Peripheral ecap
   pwsh -NoProfile -File "<skill>\scripts\list_peripheral_examples.ps1" -SdkRoot "F:\c2000ware-core-sdk" -DeviceFamily f2837xd -Peripheral adc
   pwsh -NoProfile -File "<skill>\scripts\list_peripheral_examples.ps1" -SdkRoot "F:\c2000ware-core-sdk" -DeviceFamily f2837xd -Summary
   ```

   脚本只读本地 SDK，返回 `device_support/.../examples` 和 `driverlib/.../examples` 下全部匹配的 `.c/.cpp/.cla/.asm` 源码路径；`-Summary` 按官方例程目录列出各组数量。换 SDK 后把 `-SdkRoot` 指向实际安装目录。某外设无命中时，查该器件是否具备该片上模块及同名缩写/功能路径，再查同器件头文件和 TI 手册；不能把其他器件例程直接当成可运行模板。
3. 选**同器件、同核、同 API 风格、同功能模式**的最接近例程。打开主源码、被调用的配置函数、头文件、对应 `.projectspec`/`.cproject`/`.project`/`.syscfg` 和所用 `.cmd`；特别核对 `.cproject` 的产品变量及 `.project` 的 `linkedResources`，它们可能指向 SDK 的 common 源文件和链接脚本。旧器件若没有项目文件，则到该器件 `common/cmd`、`headers/cmd` 和现有工程查。若例程要求特定 LaunchPad/controlCARD 跳线、外部器件或两核配对工程，一并记录。例程的 `board.c`/引脚宏只是其参考板配置，迁入用户板时重新核对原理图。

## 外设配置模板：每个字段都要落到当前工程

| 核对项 | 从官方例程提取并在当前工程确认 |
|---|---|
| 基础环境 | 器件头、bitfield/driverlib、CPU 所属、ABI、RAM/Flash、系统时钟与外设时钟分频 |
| 引脚与信号链 | GPIO mux/GMUX、方向/上拉/输入同步、输入 XBAR 或输出 XBAR、板级电平与连接；内部回环不等于外部引脚已通 |
| 初始化顺序 | 系统时钟、外设时钟、GPIO、外设寄存器/API、同步启动；ePWM 的 `TBCLKSYNC` 等顺序不能从另一器件照搬 |
| 工作参数 | 时基、触发源、采样窗/分辨率、极性/边沿、波特率、字长、FIFO/DMA、超时；写出由实际时钟推算的数值 |
| 中断与数据 | 外设标志清除、PIE/CPU 使能与应答、ISR 数据发布顺序、共享变量、DMA 缓冲；区分发送缓冲可写与线上发送完毕 |
| 工程接入 | `.cproject` 的宏与 include/source、`.project` 的 linked resources、`.projectspec`/SysConfig、`.cmd` 段与 RAM/Flash、driverlib 库和编译选项；不无故拷贝整套 SDK 源码 |
| 可观察结果 | 指定寄存器/变量读回、引脚波形或通信帧、预期范围和失败判据；写清当前板已验证到哪一步 |

生成或修改外设代码时，交付中列出**具体 TI 例程路径、沿用的初始化/ISR 顺序、因用户板而改的引脚和参数**。如果必须偏离例程，说明硬件或模式原因；不凭记忆拼装寄存器位和清标志代码。多个模块组合时，分别查其例程，再核对共享时钟、触发链、中断优先级及引脚冲突。

## 本机 v26 SDK 的快速入口

以下是候选目录，不代表各例程都适用于当前板。脚本输出的具体 `.c` 才是本次迁移的模板。`driverlib/f2837xd/examples/cpu1/<外设>/` 同时覆盖更多模式；未来新增器件/模块直接用脚本列目录，不靠这张表的固定名单。

| 模块 | DSP28335：`device_support/f2833x/examples/` | F28379D：`device_support/f2837xd/examples/cpu1/`；另查 `driverlib/f2837xd/examples/cpu1/` | 迁移时特别核对 |
|---|---|---|---|
| ePWM / HRPWM | `epwm_up_aq`、`epwm_deadband`、`epwm_trip_zone`、`epwm_timer_interrupts`、`hrpwm*` | `epwm_up_aq`、`epwm_deadband`、`epwm_trip_zone`；driverlib `epwm/`、`hrpwm/` | TBCLK、计数模式、AQ、死区、Trip 安全状态、同步与引脚 |
| ADC | `adc_soc`、`adc_seqmode_test`、`adc_seq_ovd_test`、`adc_dma` | `adc_soc_epwm`、`adc_soc_software`、`adc_ppb_*`；driverlib `adc/` | SOC 触发、采样窗、量程/参考、结果就绪与 ISR 清标志 |
| eCAP | `ecap_capture_pwm`、`ecap_apwm` | 同名例程及 `ecap_capture_pwm_xbar`；driverlib `ecap/` | 输入引脚/XBAR、边沿极性、计数复位、溢出、捕获值单位 |
| SCI | `sci_echoback`、`scia_loopback`、`scia_loopback_interrupts` | `sci_echoback`、`sci_loopback*`；driverlib `sci/` | 波特率基准、GPIO、FIFO、发送者和原始帧校验 |
| SPI | `spi_loopback`、`spi_loopback_interrupts` | `spi_loopback*`；driverlib `spi/` | CPOL/CPHA、字长与左对齐、FIFO/完成标志、外设时序 |
| I²C | `i2c_eeprom` | `i2c_eeprom`；driverlib `i2c/` | 7/10 位地址、上拉、ACK/NACK、重复 START/STOP、时序 |
| DAC | **无片上 DAC 例程**；TLV5620 等外部 DAC 走 SPI + 器件手册 | `buffdac_enable`、`buffdac_sine_dma`；driverlib `dac/` | 内/外 DAC 区分、参考与量程、同步更新、引脚或 LOAD |
| 其他片上模块 | `eqep_*`、`ecan_*`、`mcbsp_*`、`dma_*`、`watchdog`、`gpio_*` 等 | driverlib `can/cla/clb/cmpss/dma/dcsm/emif/eqep/gpio/ipc/mcbsp/sdfm/sysctl/timer/upp/usb/watchdog/` 等 | 按实际器件功能与目标核检索；缺模块时明确说明 |

F28379D 的 CPU2/双核示例也要查 `examples/dual/` 或 `cpu2/`，不能只看 CPU1。完整库和例程概览见[C2000Ware 索引](c2000ware-index.md)。

**实际选例**：F28379D 的 `driverlib/f2837xd/examples/cpu1/ecap/ecap_ex2_capture_pwm.c` 用 ePWM3A 作测试源，并把 GPIO16 经 Input XBAR7 送入 eCAP1；对应 `CCS/ecap_ex2_capture_pwm.projectspec` 声明 CPU1 RAM/Flash 配置与 driverlib 依赖。迁到用户板时先核对 GPIO16 是否接到了要测的信号、ePWM3A 是否需要保留、CPU1 的时钟与中断配置，不能只复制 `ECAP_*` 调用。DSP28335 当前板的实测模板与边界见 [DSP28335 上板记录](board-tests-dsp28335.md)。

## “跑几遍”的验证口径

- **静态比对**：逐项完成上表，确认例程、引脚、时钟和中断链对应当前板。此步可对本机 SDK 所有模块做目录盘点，**不是运行例程**。
- **构建链接**：只对当前目标器件和工程可用的例程/迁移代码构建。`ti_c2000_build.ps1` 已为本机 F2833x SDK 例程补上 `.cproject` 的 `INSTALLROOT_*` 变量与 `.project` linked resources 解析，见[回归案例](debug-cases/dsp28335/2026-10-27-sdk-example-build-macros.md)；换 SDK 或器件仍须核对不认识的宏、产品依赖和 linker `.cmd`。在 CCS 正确导入或迁入已配置工程后做完整构建；必要时再做增量构建。记录命令、退出码、`RESULT: OK`、`.map` 和固件标识；没有这些证据不写“构建通过”。
- **目标板重复运行**：对确实有该外设、探针和接线条件的目标功能，按同一配置至少进行 3 次独立启动或触发，记录每次预期/实测、失败次数、波形/抓包路径。涉及输出引脚时先确认板级连接和安全状态。SDK 中其他器件或缺少外设/外部设备的例程只列“未运行及原因”，不把 PC 检查或另一块板的结果写成上板通过。

当用户要求“按 TI 模板写某外设”时，选择与其工程相符的一到两个官方例程深入读和验证；不为了数量运行与目标板无关的全部示例。
