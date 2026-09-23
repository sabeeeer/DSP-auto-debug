# 工程地图 / 约定（DSP28335 + CCS6）

## 目录结构

```
<工程根>/
├─ APP/<模块名>/<模块名>.c|.h     # 外设驱动模块（每个外设一个目录）
├─ User/main.c                    # 唯一的 main
├─ DSP2833x_Libraries/            # TI 库源码 + 链接脚本 + IQmath.lib（不要改）
│   ├─ DSP2833x_*.c / *.asm
│   ├─ 28335_RAM_lnk.cmd          # RAM 链接（.cproject 指定）
│   └─ DSP2833x_Headers_nonBIOS.cmd
├─ targetConfigs/TMS320F28335.ccxml   # XDS100v1 + TMS320F28335
├─ Debug/                         # CCS 自动生成；只放脚本同步来的 <工程>.out（obj/map/log 都在 %TEMP%）
├─ .cproject / .project
```

## 现有模块与接口速查

| 目录 | 关键接口 | 备注 |
|---|---|---|
| `APP/leds` | `LED_Init()`、`LED_On/Off/Toggle` 风格 | GPIO10/11 |
| `APP/beep` | `BEEP_Init()` | GPIO6 |
| `APP/relay` | `Relay_Init()` | GPIO15 |
| `APP/key` | `KEY_Init()`、按键读取 | GPIO12/13/14 + 48/49/50 |
| `APP/time` | `TIM0_Init(psc, prd)`、`TIM1/TIM2` | CPU 定时器 |
| `APP/exti` | 外部中断初始化 + `xxx_isr` | 映射 `PieVectTable` |
| `APP/uart` | `UARTa_Init(baud)`、`UARTa_SendByte/SendString`、`UART_AutoBaud_Test()` | SCI-A，GPIO28/29；内含 `error()`（名字很通用，别重复定义） |
| `APP/spi` | SPI 初始化/收发 | |
| `APP/iic` | I2C 初始化/读写 | |
| `APP/adc` | ADC 初始化/读取 | |
| `APP/dma` | DMA 通道初始化 | |
| `APP/tlv5620` | DAC 输出 | |
| `APP/lcd1602` / `APP/lcd12864` | 液晶驱动 | lcd12864 用 GPIO48/49/60 |
| `APP/smg` | 数码管 | GPIO54/56 |
| `APP/step_motor` | 步进电机 | GPIO2/3/4/5 |
| `APP/oled`（本次新增） | `OLED_Init()`、`OLED_Clear()`、`OLED_ShowString(行,列,串)`、`OLED_ShowFloat(...)` | 模拟 I2C：SCL=GPIO9、SDA=GPIO8，地址 0x78 |
| `APP/epwm`（本次新增） | `EPWM1_Init(tbprd)`、`EPWM1A_SetCompare(val)`、`EPWM1B_SetCompare(val)` | GPIO0=EPWM1A、GPIO1=EPWM1B；约定 `TBCTR < CMPA` 输出高，占空比=`CMPA/TBPRD` |

## 引脚占用表（新增代码前必查）

> 这张表是**当前这块 DSP28335 开发板**的实际情况，换型号/换板必须按新工程的 `APP/*` 源码重新整理；
> 其他 C2000 型号的头文件名、链接脚本、运行库等差异见 [other-devices-and-probes.md](other-devices-and-probes.md)。

| GPIO | 用途 | 来源 |
|---|---|---|
| 0 / 1 | EPWM1A / EPWM1B | `APP/epwm` |
| 2 / 3 / 4 / 5 | 步进电机 | `APP/step_motor` |
| 6 | 蜂鸣器 | `APP/beep` |
| 8 / 9 | OLED SDA / SCL | `APP/oled` |
| 10 / 11 | LED | `APP/leds` |
| 12 / 13 / 14 | 按键 | `APP/key` |
| 15 | 继电器 | `APP/relay` |
| 28 / 29 | SCI-A RX / TX | TI `InitSciaGpio()` |
| 48 / 49 / 60 | LCD12864 | `APP/lcd12864` |
| 48 / 49 / 50 | 按键（另一组） | `APP/key` — **与 LCD12864 冲突，两者别同时用** |
| 54 / 56 | 数码管 | `APP/smg` |

新增外设前先在这张表里挑空闲脚；用 `GPAMUX1/GPAMUX2/GPBMUX1/GPBMUX2.x = 0` 设为通用 IO，
输出方向 `GPADIR/GPBDIR.x = 1`，输出电平用 `GPASET/GPACLEAR`（读回用 `GPADAT`）。

## 新增模块的标准动作

1. 建目录 `APP/<模块>/`，写 `<模块>.c` / `<模块>.h`（头文件用 `#ifndef X_H_` 保护，`#include "DSP2833x_Device.h"` + `"DSP2833x_Examples.h"`）。
2. **把 `APP/<模块>` 加进 `.cproject`**：在 Debug 配置的 `compilerID.INCLUDE_PATH` 选项里追加
   `<listOptionValue builtIn="false" value="&quot;${workspace_loc:/${ProjName}/APP/<模块>}&quot;"/>`，
   否则报 `cannot open source file "xxx.h"`。
3. 在 `User/main.c` 里调用；然后跑 `ti_c2000_build.ps1` 验证。
4. 模块函数统一前缀，避免与既有模块（尤其 `error()`、`Init()`、`xxx_isr()`）撞名。

## 工具链（实测）

- `.cproject` 声明 `OPT_CODEGEN_VERSION = 15.12.1.LTS`、`OUTPUT_FORMAT = COFF`、`LINKER_COMMAND_FILE = 28335_RAM_lnk.cmd`。
- 该工程**两个编译器都验证通过**：CCS12 自带的 `ti-cgt-c2000_22.6.1.LTS`（日常用它）与 CCS6 的 `15.12.1.LTS`（`C:\ti\ccsv6`）。
- 自动构建脚本按"**.cproject 声明的版本优先，没有就用该 CCS 自带的新版**"选择编译器，并自动挑运行库（COFF→`rts2800_fpu32.lib`，EABI→`*_eabi.lib`）。
- `Debug/` 里的 `makefile / subdir_*.mk` 是 CCS 自动生成的，不要手改；已被清理过一次，CCS GUI 构建时会重新生成。

## 平台约定与易错点

- `DSP2833x_Examples.h` 里 `CPU_RATE 6.667L`（150 MHz）、`PLLCR=10`、`DIVSEL=2`；`DELAY_US(x)` 依赖它。
- `InitSysCtrl()` 内部已 `DisableDog()`（关看门狗）；不用再手动写 `WDCR`。
- SCI-A 波特率算法：`BRR = 37500000/(8*baud) - 1`（LSPCLK=37.5 MHz）。
- 受保护寄存器（`SysCtrlRegs`、`GpioCtrlRegs`、`EPwm*Regs` 的配置位）必须 `EALLOW; ... EDIS;`。
- FPU32：`float` 才有硬件加速，避免 `double`；ISR 里别做浮点/除法/字符串输出。
- 自定义 ISR：`EALLOW; PieVectTable.Xxx = &isr; EDIS;` → 使能 `PieCtrlRegs.PIEIERn` 和 `IER` → 全局 `EINT` → ISR 内 `PieCtrlRegs.PIEACK.bit.ACKn = 1`。
- 当前链接脚本是 **RAM 版**（`28335_RAM_lnk.cmd`），掉电即失；要脱机运行需换 Flash 链接脚本并做 Flash 初始化。
- `main()` 用 `while(1)` 常驻；`User/main.c` 是工程唯一入口，别新增第二个 `main`。
