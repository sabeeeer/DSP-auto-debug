# C2000Ware Core SDK 使用指南（本机 `F:\c2000ware-core-sdk`，v26.00.00.00.STS）

> **用途**：写代码 / 换型号 / 选 cmd / 配仿真器 / 用 SysConfig 之前，先在这里查"东西在哪、用哪个、怎么写"。
> 本文路径全部本机实测过；查不到的东西按 §1 的定位法找，**不要猜**。
>
> **离线备份（2026-09-27 已上传 GitHub）**：SDK 源码快照（`.c/.h/.cmd/.asm/.syscfg/.projectspec`，15465 文件 ≈ 182 MB）：
> - **Release（推荐下载）**：`https://github.com/sabeeeer/c2000ware-ref/releases/tag/v26.00.00.00-snapshot`
>   —— 附件 `device_support.zip`(10.9 MB) / `driverlib.zip`(20.1 MB) / `libraries.zip`(9.2 MB) /
>   `utilities.zip` / `boards.zip`（解压即用，目录结构与原 SDK 一致）
> - 仓库主页：`https://github.com/sabeeeer/c2000ware-ref`
> - 本机 git 快照（含完整文件树；网络通时可 `git push` 补推）：`C:\Users\Jordon\CodeBuddy\c2000ware-ref`
> - 原 SDK 丢失时：解压附件（或 clone 仓库），再用 `c2000ware_find.ps1 -SdkRoot <解压目录>` 继续查例程。
> - 注：2026-09-27 实测本机**直连 `github.com` 不通、`api.github.com` 通**；上传走 API/Release 通道，
>   `git push` 需等网络恢复或开本地代理（`git -c http.proxy=http://127.0.0.1:12450 push`）。
>
> **路径不要写死**：`scripts\c2000ware_find.ps1` 会自动探测参照源（`SOURCE:` 行会打印用的是哪个）：
> ① `-SdkRoot` 显式指定 → ② 环境变量 `C2000WARE_ROOT`/`C2000WARE` → ③ 常见安装路径
> （`C:\ti\c2000\C2000Ware_*`、`<盘>:\c2000ware-core-sdk`…）→ ④ 本机快照仓库
> （`%USERPROFILE%\CodeBuddy\c2000ware-ref`）→ ⑤ **GitHub 快照**（`-Source github` 强制，
> 自动把 Release 附件下载解压到 `%LOCALAPPDATA%\c2000ware-snapshot`，之后按本机方式检索）。
> 换机/换盘/删了 SDK 都不用改文档 —— 脚本找不到本机源时会自己去 GitHub 拉一份。

---

## 1. SDK 布局与三条定位法

```
F:\c2000ware-core-sdk\
├─ device_support\<器件>\        ← bitfield（寄存器式）官方包 + 例程 + 头文件 + 链接脚本
│   ├─ examples\                 f2837xd 分 cpu1\ 与 dual\；f2837xs 只有 cpu1\
│   ├─ headers\include\          器件头文件（F2837xD_device.h / DSP2833x_Device.h …）
│   ├─ headers\cmd\              Headers 链接脚本（F2837xD_Headers_nonBIOS_cpu1.cmd …）
│   ├─ common\include\           F28x_Project.h、driverlib.h、*_Examples.h
│   ├─ common\source\            CodeStartBranch.asm / SysCtrl.c / PieVect.c / DefaultISR.c / usDelay.asm
│   └─ common\cmd\               器件链接脚本（2837xD_RAM_lnk_cpu1.cmd …）
├─ driverlib\<器件>\             ← driverlib 库式 API：driverlib\(源码 + inc\hw_*.h + ccs\预编译库) + examples\
├─ libraries\                    ← math / dsp / control / communications / ai / calibration（.lib + 源码）
├─ utilities\
│   ├─ cmd_tool\                 ← SysConfig 的 "Linker CMD Tool"（生成 device_cmd.cmd；**不支持 F2833x**）
│   ├─ windows_drivers\          ← C2000 自身 USB 外设驱动（**不含 XDS 仿真器驱动**，XDS 驱动随 CCS）
│   └─ tools\ transfer\ dcsm_tool\ clb_tool\
├─ boards\                       ← LaunchPad / controlCARD 板级文件（board.c/h、原理图）
└─ docs\c2000Ware_quickstart_guide\html\index.html
```

**定位法**：例程 → `device_support\<器件>\examples\`（bitfield）或 `driverlib\<器件>\examples\`（driverlib）；
驱动/API → `driverlib\<器件>\driverlib\`；链接脚本 → `device_support\<器件>\common\cmd\` 与 `headers\cmd\`；
板级定义 → `boards\<板名>\`。器件名写法：`f2833x`、`f2837xd`、`f2837xs`、`f2838x`、`f28004x`、`f28p65x`…

> F2833x（DSP28335）在 C2000Ware 里与 controlSUITE v142 是**同一套代码**（仅目录改名、个别例程增删）；
> 28335 的例程/头文件两边都能用，cmd 见 §4。

---

## 2. 两种官方写法：bitfield vs driverlib

| | **bitfield**（device_support） | **driverlib**（库式，TI 对新器件主推） |
|---|---|---|
| 写法 | 直接读写寄存器位域 `EPwm1Regs.TBPRD = ...` | 调 API `EPWM_setTimeBasePeriod(...)` |
| 头文件 | `F28x_Project.h`（含 `<器件>_Device.h`） | `driverlib.h` + `device.h` + `board.h` |
| 初始化 | `InitSysCtrl(); InitPieCtrl(); IER=0; IFR=0; InitPieVectTable();` | `Device_init(); Device_initGPIO(); Interrupt_initModule(); Interrupt_initVectorTable();` |
| 中断注册 | `EALLOW; PieVectTable.EPWM1_INT = &isr; EDIS;` | `Interrupt_register(INT_EPWM1_TZ, &isr);` |
| 中断使能 | `IER \|= M_INT3; PieCtrlRegs.PIEIER3.bit.INTx1 = 1;` | `Interrupt_enable(INT_EPWM1_TZ);` |
| 总开关 | `EINT; ERTM;`（两者一样，**必须成对**） | `EINT; ERTM;` |
| ISR 应答 | `EPwm1Regs.ETCLR.bit.INT = 1; PieCtrlRegs.PIEACK.all = PIEACK_GROUP3;` | `EPWM_clearTripZoneFlag(...); Interrupt_clearACKGroup(INTERRUPT_ACK_GROUP2);` |
| 库 | 无 | `driverlib\<器件>\driverlib\ccs\{Debug\|Release}\driverlib_coff.lib` / `driverlib_eabi.lib`（也可把源码编进工程） |
| 何时用 | 2833x/28335 **只有这条路**；要寄存器级极致控制、移植老代码 | 2837x/28379x/2800x/2838x 等新器件默认；要可读、可移植、配合 SysConfig |

---

## 3. F2837xD / F2837xS（= DSP28377D / 28377S / 28379D）专章

### 3.1 bitfield 骨架（照 `device_support\f2837xd\examples\cpu1\epwm_up_aq\cpu01\epwm_up_aq_cpu01.c`）

```c
#include "F28x_Project.h"                       // = <器件>_Device.h + <器件>_Examples.h

__interrupt void epwm1_isr(void);

void main(void)
{
    InitSysCtrl();                              // 时钟/看门狗/外设时钟
    InitEPwm1Gpio();                            // GPIO 复用（用 TI 写的 Init*Gpio()）
    InitPieCtrl();
    IER = 0x0000;
    IFR = 0x0000;
    InitPieVectTable();
    EALLOW;  PieVectTable.EPWM1_INT = &epwm1_isr;  EDIS;

    EALLOW;  CpuSysRegs.PCLKCR0.bit.TBCLKSYNC = 0;  EDIS;   // ★2837x 是 CpuSysRegs（2833x 是 SysCtrlRegs）
    InitEPwm1Example();
    EALLOW;  CpuSysRegs.PCLKCR0.bit.TBCLKSYNC = 1;  EDIS;

    IER |= M_INT3;                              // ③ CPU 级
    PieCtrlRegs.PIEIER3.bit.INTx1 = 1;          // ② PIE 级
    EINT;   // ④ 全局
    ERTM;
    for(;;) { asm("  NOP"); }
}

__interrupt void epwm1_isr(void)
{
    EPwm1Regs.ETCLR.bit.INT = 1;                // 清外设标志
    PieCtrlRegs.PIEACK.all = PIEACK_GROUP3;     // 应答 PIE（官方写法）
}
```

要点：套路与 2833x **完全一致**（四层中断 + `EINT; ERTM;`），差异只有：
- 头文件 `F28x_Project.h`（2833x 是 `DSP28x_Project.h`）、器件头 `F2837xD_device.h`；
- `TBCLKSYNC` 在 **`CpuSysRegs.PCLKCR0`**；GPIO 宏用 `DEVICE_GPIO_PIN_*` / `GPIO_*` 定义；
- 双核（D 系列）：CPU1 / CPU2 各自一份工程 + 各自 cmd（见 §4）；双核通信用 `F2837xD_Ipc_drivers.h`；
- CLA：`F2837xD_Cla_typedefs.h`、`MemCfgRegs.LSxCLAPGM/MSGxINIT`（2833x 无 CLA）；
- 例程清单：`examples\cpu1\`（98 个，含 `epwm_up_aq / epwm_deadband / epwm_trip_zone / adc_soc_epwm / sci_echoback / external_interrupt / sw_prioritized_interrupts / empty_project`）+ `examples\dual\`（16 个 cpu01/cpu02 双核例程）。

### 3.2 driverlib 骨架（照 `driverlib\f2837xd\examples\cpu1\epwm\epwm_ex1_trip_zone.c`）

```c
#include "driverlib.h"
#include "device.h"
#include "board.h"

__interrupt void epwm1TZISR(void);

void main(void)
{
    Device_init();                                  // 时钟 + 外设（内部 SysCtl_setClock(DEVICE_SETCLOCK_CFG)）
    Device_initGPIO();                              // 解锁引脚 + 内部上拉
    Interrupt_initModule();                         // = InitPieCtrl + 关 CPU 中断
    Interrupt_initVectorTable();                    // = InitPieVectTable
    Interrupt_register(INT_EPWM1_TZ, &epwm1TZISR);  // 注册向量（不用手写 EALLOW）

    Board_init();                                   // SysConfig 生成的板级/引脚配置（app.c 里不再手写 GPIO_setPadConfig）

    SysCtl_disablePeripheral(SYSCTL_PERIPH_CLK_TBCLKSYNC);
    initEPWM1();                                    // 内部全是 EPWM_xxx API
    SysCtl_enablePeripheral(SYSCTL_PERIPH_CLK_TBCLKSYNC);

    Interrupt_enable(INT_EPWM1_TZ);                 // ② + ③ 一次搞定
    EINT;  ERTM;                                    // ④ 全局
    for(;;) { NOP; }
}

__interrupt void epwm1TZISR(void)
{
    Interrupt_clearACKGroup(INTERRUPT_ACK_GROUP2);  // 应答，不用 PIEACK 寄存器
}
```

API 命名规律：`<外设>_<动作>` —— `EPWM_setTimeBasePeriod` / `setPhaseShift` / `setTimeBaseCounterMode` /
`setClockPrescaler` / `setCounterCompareValue` / `setActionQualifierAction` / `enableTripZoneSignals` /
`setTripZoneAction` / `clearTripZoneFlag`；GPIO 用 `GPIO_setPadConfig` / `GPIO_setPinConfig(GPIO_0_EPWM1A)` /
`GPIO_setDirectionMode` / `GPIO_writePin` / `GPIO_togglePin`。
driverlib 的 API 内部已 `EALLOW/EDIS`，但**直接写寄存器的部分仍要自己包**。

### 3.3 driverlib 工程怎么组织进 CCS（.projectspec / 库）

- 官方例程用 `.projectspec` 描述工程（`driverlib\f2837xd\examples\...\*.projectspec`、`driverlib\ccs\driverlib.projectspec`）：
  含 `-I${C2000WARE_DLIB_ROOT}`、`--define=DEBUG --define=CPU1`（Flash 配置再加 `--define=_FLASH`）、
  `--entry_point code_start`、链接 `${C2000WARE_DLIB_ROOT}\ccs\Debug\driverlib.lib`；
- 预编译库：`driverlib\f2837xd\driverlib\ccs\{Debug|Release}\` 下 `driverlib_coff.lib` / `driverlib_eabi.lib` /
  `driverlib.lib`（索引）；也可以把 driverlib 源码（`driverlib\<器件>\driverlib\*.c`）直接编进工程；
- 统一入口头 `driverlib.h` 在 **`device_support\<器件>\common\include\driverlib.h`**（逐行 include 各外设 h）。

### 3.4 SysConfig（新器件工程的图形化配置）

- 例程带 `.syscfg`（如 `driverlib\f2837xd\examples\cpu1\...\*.syscfg`），构建时由 SysConfig 生成
  `board.c/h`、`c2000ware_libraries.h`（`.xdt` 模板在 `driverlib\.meta\`、`libraries\.meta\`）；
- `.projectspec` 里的关键两行：`enableSysConfigTool="true"`、
  `sysConfigBuildOptions="--product ${C2000WARE_ROOT}/.metadata/sdk.json --device F2837xD --package F2837xD_176PTP"`；
- **坑**：① SysConfig 版本必须匹配 SDK 的 `.metadata\sdk.json`（本机 26.01.00.00），否则模块 js 解析报错、
  `board.h` 版本不对；② `C2000WARE_ROOT` 指错 → "product not found"；
- 本 skill 的构建脚本只编译磁盘上已有的 `.c`，**SysConfig 生成代码要先在 CCS 里构建一次**（或用 SysConfig CLI）再做回归自检。

---

## 4. cmd 链接脚本怎么用（含多核 / 多配置）

### 4.1 三类 cmd，各管什么

| 类型 | 作用 | 例子（绝对路径见 §1） |
|---|---|---|
| **器件链接脚本** | 内存布局（MEMORY/SECTIONS）：代码放哪、栈多大、RAM 还是 Flash | 2833x：`28335_RAM_lnk.cmd`、`F28335.cmd`；2837xD：`2837xD_RAM_lnk_cpu1.cmd`、`2837xD_FLASH_lnk_cpu1.cmd` |
| **Headers 脚本** | 把外设寄存器地址"钉"到固定地址（`*_Headers_nonBIOS*.cmd`） | 2833x：`DSP2833x_Headers_nonBIOS.cmd`；2837xD：`F2837xD_Headers_nonBIOS_cpu1.cmd`、`_cpu2.cmd` |
| **变体脚本** | 特定用途的内存布局 | `_far`（远地址）、`_CLA`（CLA 用）、`_IQMATH`/`_TMU`/`_SGEN`（数学库表）、`_USB`、`_IPC`（双核通信）、`_DCSM`（双码安全）、`_crc`、`_shared`、`_SWPrioritizedISR` |

### 4.2 怎么选 / 怎么换

- **RAM 调试用 `*_RAM_lnk*.cmd`，脱机跑用 `*_FLASH_lnk*.cmd`**（换 Flash 后记得 boot 模式/CSM 设置）；
- 2833x 现有工程用的就是 `28335_RAM_lnk.cmd` + `DSP2833x_Headers_nonBIOS.cmd`；
- 2837xD 是**双核**：CPU1 用 `*_cpu1.cmd`（+ `F2837xD_Headers_nonBIOS_cpu1.cmd`），CPU2 用 `*_cpu2.cmd`
  （+ `_cpu2.cmd`）；**两个核各自一份工程**，不能共用；
- 2837xS（单核）没有 cpu1/cpu2 之分：例程用 `2837xS_Generic_RAM_lnk.cmd` / `2837xS_Generic_FLASH_lnk.cmd`
  + `F2837xS_Headers_nonBIOS.cmd`；
- 在 CCS 里换：工程属性 → C2000 Linker → File Search Path / 或在工程树里换 `.cmd` 文件；
  命令行自检脚本换：`ti_c2000_build.ps1 -LinkCmd "<文件名>"`（脚本默认按 `.cproject` 的 `LINKER_COMMAND_FILE` 找，
  **并把工程里全部非 exclude 的 `.cmd`/`.lib` 都当链接输入**——所以别把别的器件/别的配置的 cmd 留在工程里，必须
  "exclude from build"，否则报 `memory range has already been specified`）。

### 4.3 SysConfig 的 CMD Tool（可选，注意不支持 2833x）

`utilities\cmd_tool\` 不是命令行工具，而是 **SysConfig 的 "Linker CMD Tool" 模块**：在 CCS 里勾选所需存储块
（RAM/Flash 多实例用 `CMD_RAM`/`CMD_FLASH` 预定义宏切换），生成 `device_cmd.cmd/.c/.h/.opt/.genlibs`。
支持的器件：F2837x / F2807x / F2800x / F2838x / F28P5x 等（**不含 F2833x**，28335 老老实实用 §4.1 的静态 cmd）。
参考手册 `sprad49.pdf`。

---

## 5. 仿真器 / 探针

- **XDS 驱动不在 C2000Ware 里**：`utilities\windows_drivers\` 只有 C2000 自身 USB 外设的驱动
  （`usb_dev_serial.inf` 等，VID_1CBE），**XDS100/110/200/560 驱动随 CCS 安装**；
- 连接配置在工程 `targetConfigs\*.ccxml`，改探针型号/机型用 `scripts\ti_c2000_set_probe.ps1 -Probe v1|v2|v3|xds110`
  （一次改齐 ccxml + `.ccsproject`，详见 `references/other-devices-and-probes.md` §3）；
- 板子自带 USB CDC/DFU 的器件（F2806x 等）：DFU 烧写工具在 `utilities\tools\f2806x\dfuprog\`。

---

## 6. libraries（数学 / 控制 / 通信库）

`libraries\` 下按类分：`math`（IQmath、FPUfastRTS、CLAmath…）、`dsp`（FFT/FIR）、`control`（PID 等）、
`communications`、`ai`（神经网络）、`calibration`。每个库都有 `lib\`（预编译 .lib，含 COFF/EABI 版本）+
`source\` + `docs\`；用法与库表（`_IQMATH`/`_TMU` cmd 变体就是给它们准备的）。用之前先看该库的 docs 与
对应 cmd 变体，别自己乱配内存段。

---

## 7. 速查：我要 X → 去哪找

| 我要… | 去哪 |
|---|---|
| 某器件的例程（寄存器式） | `device_support\<器件>\examples\` |
| 某器件的例程（driverlib 式） | `driverlib\<器件>\examples\` |
| 器件头文件 / 寄存器位定义 | `device_support\<器件>\headers\include\`、`driverlib\<器件>\driverlib\inc\hw_*.h` |
| RAM / Flash 链接脚本 | `device_support\<器件>\common\cmd\`（+ `headers\cmd\`） |
| driverlib 头与预编译库 | `device_support\<器件>\common\include\driverlib.h`、`driverlib\<器件>\driverlib\ccs\` |
| 板级（LED/按键/引脚名）定义 | `boards\<板名>\`、例程里的 `board.h`（SysConfig 生成） |
| 数学/控制库 | `libraries\<类>\<库>\`（看 docs + cmd 变体） |
| 快速上手/目录说明 | `docs\c2000Ware_quickstart_guide\html\index.html`、SDK 根 `README.md` |
