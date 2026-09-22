# 其他 C2000 型号 与 其他仿真器

> 本文件说明本 skill 的**通用程度**：哪些是自动适配的、哪些必须手动给参数。
> 已在 **DSP28335 + XDS100 + CCS12.8/CCS6** 上实测；下表其他型号的差异点来自 TI 官方结构惯例，**换型号首次使用请先跑一次编译自检再做调试**。

## 1. 自动适配的部分（换型号通常不用改脚本）

`ti_c2000_build.ps1` 全部从 `.cproject` 反推，不再硬编码 2833x：

| 项目 | 来源 | 说明 |
|---|---|---|
| 汇编器版本 | `compilerID.SILICON_VERSION` | C28x 用 `-v28`，C29x 用 `-v29`（F29H85x） |
| 内存模型/统一内存 | `LARGE_MEMORY_MODEL`、`UNIFIED_MEMORY` | 自动加/不加 `-ml`、`-mt` |
| 浮点支持 | `FLOAT_SUPPORT` | `fpu32` / `fpu64`（F2838x）/ `softlib`（F2802x 等无 FPU） |
| 输出格式 | `OUTPUT_FORMAT` | COFF / EABI 决定运行库后缀 `_eabi` |
| 运行库 | 上两项 + `lib` 目录实际文件 | `rts2800_fpu32(_eabi).lib`、`rts2800_fpu64_eabi.lib`、`rts2800_ml.lib` |
| 编译器 | `OPT_CODEGEN_VERSION` → 对应 CCS 的 `ti-cgt-c2000_<ver>` | 声明的版本没装则用该 CCS 自带最新版并打 NOTE |
| 包含路径 | `INCLUDE_PATH` | 解析 `${workspace_loc}`、`${CG_TOOL_ROOT}`，缺失目录只打 NOTE |
| 链接脚本 | 工程里**全部非 exclude 的** `.cmd` | CCS 托管构建会把工程里每个 `.cmd` 都交给链接器（`LINKER_COMMAND_FILE` 只是其中一个），所以别的器件的 cmd 必须在 `.cproject` 里 "exclude from build"；被 exclude 的自动跳过并打 `EXCLUDED:` |
| 库文件 | 工程里**全部非 exclude 的** `.lib` | 同 `.cmd`；工程自带同名运行库时优先用工程的，不再重复塞编译器自带的 |
| 编译开关 | `DEFINE` / `OPT_LEVEL` / `OPT_FOR_SPEED` / `FP_MODE` / `LANGUAGE_MODE` / `DIAG_*` / `OTHER_FLAGS` | 与 CCS 编同一批 `#ifdef` 分支（否则校验的代码和板子上跑的不是一套） |
| 构建配置 | `<configuration name="...">` | 多配置工程按"工程下存在同名输出目录"选，其次名字/父配置含 `Debug` 的；`CONFIG:` 行会打印用了哪个 |
| exclude 列表 | `<sourceEntries><entry excluding="a\|b\|dir/">` | 源码 / `.cmd` / `.lib` 一律照 CCS 跳过；需要"全都算进来"时加 `-IgnoreExclusions` |
| 器件指纹 | 头文件存在性 | 打印 `DEVICE: F2837xD_Device.h` 之类，driverlib 工程提示 EABI |

`ti_c2000_debug.ps1` 从 `.ccxml` 读器件与仿真器，硬件检查覆盖多种探针；模拟器目标自动跳过硬件检查。

## 2. 型号族差异对照

| 家族 | 典型器件 | 器件头文件 | 常见链接脚本 | 运行库 | 关键注意 |
|---|---|---|---|---|---|
| F2833x / F2823x（Delfino） | F28335/28334/28332、F28235 | `DSP2833x_Device.h`、`DSP2823x_Device.h` | `28335_RAM_lnk.cmd` + `DSP2833x_Headers_nonBIOS.cmd` | `rts2800_fpu32.lib`（COFF） | 本项目即此类；FPU32；可 COFF 或 EABI |
| F2834x | F28346/F28345 | `DSP2834x_Device.h` | `*_RAM_lnk.cmd` + `DSP2834x_Headers_nonBIOS.cmd` | `rts2800_fpu32.lib` | |
| F2802x / F2803x / F2805x（Piccolo） | F28027、F28035、F2805x | `F2802x_Device.h` 等 | `F2802x_Headers_nonBIOS.cmd` 等 | `rts2800_ml.lib`（**无硬件 FPU**，纯软件浮点） | RAM 小，注意栈与链接脚本；浮点运算慢 |
| F2806x（Piccolo + FPU） | F28069/F28062 | `F2806x_Device.h` | `F2806x_Headers_nonBIOS.cmd` | `rts2800_fpu32.lib` | 有 FPU32 |
| F2837xD / F2837xS | F28379D/F28377D/F28377S | `F2837xD_Device.h` / `F2837xS_Device.h` | `F2837xD_RAM_lnk_cpu1.cmd` + `*_Headers_nonBIOS_cpu1.cmd` | `rts2800_fpu32_eabi.lib` | **双核**（D 系列）、**EABI only**、常见 driverlib+SysConfig、带 CLA |
| F2807x | F28075/F28076 | `F2807x_Device.h` | `*_RAM_lnk.cmd` | `rts2800_fpu32_eabi.lib` | EABI |
| F2838x | F28388D | `F2838x_Device.h` | `F2838x_*_lnk_cpu1.cmd` | `rts2800_fpu64_eabi.lib` | 双 C28 核 + Cortex-M4，**三核各自建工程** |
| F28004x / F28003x / F28002x | F280049C、F280039C | `F28004x_Device.h` 等 | `*_lnk*.cmd` | `rts2800_fpu32_eabi.lib` | EABI；几乎都是 driverlib/SysConfig 工程 |
| F28M35x（Concerto） | F28M35H52C | `F28M35x_Device.h` | | | C28 + Cortex-M3，两个核分别建工程 |
| C29x（新一代） | F29H85x | `F29H85x_Device.h` | | | CGT 较新，汇编器 `-v29`（脚本按 `.cproject` 自动选） |

**driverlib / SysConfig 型工程**：`.syscfg` 生成的文件（`ti_drivers_config.c/h` 等）是 CCS 构建时产出的。
本脚本只会编译磁盘上已有的 `.c/.asm`，所以这类工程请先在 CCS 里构建一次（或用 SysConfig CLI 生成）再用本脚本做回归自检；本机未实测该流程。

## 3. 仿真器对照

| 仿真器 | Windows 里的枚举名（硬件检查用） | `.ccxml` 里的连接名 | 备注 |
|---|---|---|---|
| XDS100v1/v2/v3 | `XDS100 Class ...` / `Texas Instruments XDS100...` | Texas Instruments XDS100v1/v2/v3 USB Emulator | **本项目实测**：`XDS100 Class USB Serial Port (COM9)` + `XDS100 Class Debug Port` + `XDS100 Class Auxiliary Port`；免驱版/FTDI 版枚举名会不同 |
| XDS110 | `Texas Instruments XDS110 USB Debug Probe` | Texas Instruments XDS110 USB Debug Probe | 免驱；LaunchPad 板载即此类 |
| XDS200 | `Texas Instruments XDS2xx USB Debug Probe` | Texas Instruments XDS2xx USB Debug Probe | |
| XDS560v2 | `Texas Instruments XDS560v2 ...` | Texas Instruments XDS560v2 USB System Trace Emulator | 也有网络版（-ccxml 里填 IP） |
| XDS510 / XDS510USB | `Spectrum Digital XDS510...` | Spectrum Digital XDS510 USB Emulator | 老器件需要，驱动较旧 |
| Blackhawk | `Blackhawk USB...` | Blackhawk ... | |
| SEGGER J-Link | `J-Link ...` | SEGGER J-Link Emulator | 需 CCS 版本支持该器件 |
| TI 模拟器 | 无硬件 | `Texas Instruments Simulator`（tisim_*） | 脚本检测到 simulator 会自动跳过硬件检查，纯软件验证逻辑 |

**决定连什么的是 `.ccxml`，不是脚本**：换仿真器在 CCS 里建/改 target configuration，然后 `-Ccxml <文件>`（默认取 `targetConfigs\` 下第一个）。
驱动器没枚举出来时：`-NoProbeCheck` 可跳过前置检查（连接失败时 loadti/DSS 仍会明确报错）。

## 4. 双核 / 多核器件怎么办

1. 每个核建自己的工程与 `.out`（cpu1/cpu2 分开）。
2. `.ccxml` 里把目标核选成默认；DSS 侧本 skill 提供 **`-CorePattern ".*CPU1.*"`** 选择会话（默认 `.*` 取第一个核心）。
   `loadti` 没有选核参数，它按 `.ccxml` 的默认核加载 → **为每个核准备各自的 `.ccxml`**。
3. 读变量时 `-ReadVars` / `-WaitFor` 里的符号必须在**该核**的符号表里；跨核读取要用 IPC/共享内存变量。
4. F2838x 还有 Cortex-M4 核：它的工程是 ARM 编译器（`ti-cgt-arm*`），本 skill 只覆盖 C28x 侧。

## 5. 换型号/换板后 skill 需要你补充的信息

- **引脚分配**：`project-map.md` 的引脚表只适用于当前这块 28335 板；新板子按新工程的 `APP/*` 源码重新整理（skill 会按新工程读源码找 GPIO 配置）。
- **Flash 脱机运行**：把链接脚本换成 Flash 版（`-LinkCmd` 或改 `.cproject` 的 `LINKER_COMMAND_FILE`），并确认 boot 引脚/CSM 设置。
- **时钟与看门狗**：不同器件 `InitSysCtrl()` 内容不同（本项目 `DSP2833x_SysCtrl.c` 已 `DisableDog()`）。
- **头文件来源**：实测工程的器件头文件放在工程外的 `<TI_C2000_EXAMPLES>\DSP2833x_Libraries\...`（TI 官方 example 包），
  换机器/换 SDK 要同步更新 `.cproject` 的 include 路径（脚本会打印缺失的路径）。
