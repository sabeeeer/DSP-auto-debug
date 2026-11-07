# CCS 详细操作手册

> 此文保留执行模式的命令、排错表和现场经验。只要读取当前板数据值且不编译、下载时，先看[只读模式](read-only-mode.md)。板级数值只适用于文中注明的工程；如与当前工程事实或主技能任务路由冲突，以后者为准。


# TI C2000 / DSP2833x 全自动开发 + 调试（CCS12 / CCS6）

执行模式流程：**运行态读取基线 → 分析 → 确需修改时写代码、编译、下载运行 → 运行态复读验证**。所有数据读取都调用[只读入口](read-only-mode.md)，不可停核或复位。周期信号先在固件侧录入完整窗口，例如 50 Hz、1 kHz 的 10 个周期为 200 帧、200 ms；随后可花更长时间在目标持续运行时传出并分析，不能声称 JTAG 必须在 200 ms 内完成传输。**交付代码改动前必须有真实构建证据**；只读模式仅交付实际读取的数据，不要求编译。

## 电网锁相任务入口

收到电网 PLL、SPLL、SOGI、SRF/DDSRF、SolarLib、并网相位/频率或 Park/Clarke 变换任务时，先区分片内时钟 PLL 与电网软件锁相。对后者，在设计或修改算法前：

1. 完整阅读 [references/spll-pll-algorithms.md](spll-pll-algorithms.md)，特别核对模块清单、SOGI 离散化、Park 符号约定、采样率与系数、踩坑记录和移植步骤。再核对工程已有的 SolarLib 源码、适配层及本机 TI 原始例程；记录所用文件和版本。
2. 先判断现有 TI 模块和工程实现能否满足需求，明确输入相位约定、角度单位、采样周期、系数和目标器件。能复用时优先适配；确需另写算法时，说明现有实现不适用的具体原因和验证方法。不要先重写变换或 PLL，再搜索已有资料。
3. 交付 PLL 代码变更时，说明采用的模块与依据、对现有实现的改动、系数来源，以及实际完成的构建和运行验证。找不到对应源码时如实说明，不把参考文档中的示例数值直接当作当前工程的配置。

## 铁律（违反 = 交付失败）

1. **没跑构建校验，不许说"改好了"**。任何 `.c/.h/.cproject` 改动后必须执行构建脚本，看到 `RESULT: OK` 才算通过。
2. **编译失败先改错误**，不允许"看起来没问题就交付"。
3. **链接报 `unresolved symbols` = 模块没进工程**（少源文件 / 少 include 路径 / 函数名拼错），先查这三点。
4. **读回值要对着源码核对**；与预期不符时先怀疑"程序没跑到那里"（RAM 程序 + OLED/I2C 初始化要几秒），再怀疑代码。
5. 只改该改的：不动 `DSP2833x_Libraries/`（TI 库）和 `Debug/`（自动生成）。
   自动生成物里的 `.launches\*.launch`（CCS GUI 调试启动配置，内含本机绝对路径）由自检脚本一并清出工程
   （移到 `%TEMP%\ti_c2000_launch_backup\<工程>\<时间戳>\`，可恢复；`-KeepLaunches` 可保留）。
6. **失败必须明说 + 必须给原因分类**：脚本失败时会打印 `FAILURE: <分类>` + `REASON: <原因>` 且退出码非 0。
   向用户转述时必须**原样保留分类与原因**（例如"失败：TIMEOUT，就绪条件 8 秒内没成立"），
   禁止把失败说成成功、禁止只说"有问题"不给原因、禁止在没看到 `RESULT: OK` 时说"已通过"。
7. **写任何 DSP 代码一律照 TI 官方例程写，不许乱写/凭印象臆造**。
   **参照源自动探测（不要写死单一路径）**：`scripts\c2000ware_find.ps1` 按优先级找 ——
   ① 本机 C2000Ware / controlSUITE（常见路径 + 环境变量 `C2000WARE_ROOT`）→ ② 本机快照仓库
   （`%USERPROFILE%\CodeBuddy\c2000ware-ref` 等）→ ③ **GitHub 快照** `sabeeeer/c2000ware-ref`
   （自动下载 Release 附件到 `%LOCALAPPDATA%\c2000ware-snapshot` 当缓存，之后本地高速检索）。
   例程位置（任何来源下都一样）：bitfield `device_support\<器件>\examples\`、
   driverlib `driverlib\<器件>\examples\`、链接脚本 `device_support\<器件>\common\cmd\`；
   2833x 另有 controlSUITE `...\f2833x\v142\DSP2833x_examples_ccsv5\` 与 `E:\2.28335资料\官方程序示例\`（49 个单文件）。
   写外设代码前先跑 `c2000ware_find.ps1 -Keyword <外设>`（或 `-GetFile <路径>` 看具体文件），
   照例程的寄存器顺序、TI 宏常量（`TB_COUNT_UP`/`AQ_SET`/`CC_SHADOW`…）、`EALLOW/EDIS`、
   中断四层 + `EINT; ERTM;`、ISR 里 `ETCLR` + `PieCtrlRegs.PIEACK.all = PIEACK_GROUPx` 来写；
   **找不到对应例程就先问用户，别猜寄存器**。
   规范/骨架/严禁清单见 `references/ti-official-style.md`；器件·库·需求映射见 `references/c2000ware-index.md`。
   ⚠ `E:\DSP8233x_ProjectExample\DSP2833x_Example\`、`E:\3.PZ-DSP28335-L开发板资料` 是开发板配套例程，只能当参考。
8. **"中断里更新、主循环里读"的变量，读取必须原子（快照）**。
   典型错误：波形回读时"一边慢慢发串口、一边反复读 `XxxCtrl.usCmpA/B/C`" ——
   8 字节 @460800 要 174us，而 10kHz 控制中断每 100us 就改一次变量，
   低/高字节会取自不同时刻，拼出一个不存在的数 → 波形上出现**垂直单边尖刺**（数据撕裂）。
   正确写法：`DINT; snap=…; EINT;`（≈20ns）先取快照，之后 174us 慢发全部用快照。
   ⚠ **提高读取频率 / 降低帧率 / 加 `volatile` 都无效**（串口带宽不够 5.75kHz<10kHz；且跨更新点照样撕裂）。
   规范见 `references/ti-official-style.md` §4.5；实测复盘与回归判据见 `references/c28x-pitfalls.md` §六。
   注：临界区只包"读"，**绝不把 `DELAY_US`/串口发送包进 `DINT…EINT`**；若在 ISR 里调用要改用保存/恢复 `INTM`。

## 一键命令

> **引擎要求：PowerShell 7.0+（本机 7.6.6）**，所有脚本首行都是 `#requires -Version 7.0`，示例统一用 `pwsh`。
> pwsh 装在 `%LOCALAPPDATA%\Microsoft\PowerShell\7\pwsh.exe`（已入用户 PATH）；老进程没重启时 PATH 可能没生效，用完整路径
> `& "$env:LOCALAPPDATA\Microsoft\PowerShell\7\pwsh.exe" -NoProfile -File <脚本>`。**不要再退回 Windows PowerShell 5.1**
> （7.x 默认 UTF-8、中文不乱码；5.1 会因 ANSI 读取中文脚本而报语法错误）。

```powershell
# ① 编译+链接自检（几秒出结果，不打开 CCS、不碰硬件）
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ti_c2000_build.ps1" -ProjectPath "<工程根目录>"
#   ... -IgnoreExclusions   把 .cproject 里 "exclude from build" 的源码/.cmd/.lib 也算进来（默认照 CCS 跳过）

# ② 构建 + 下载运行（自动检测仿真器与 CCS 安装位置）
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ti_c2000_debug.ps1" -ProjectPath "<工程根目录>" -Build -Run

# ③ 程序运行后，单独用只读模式等就绪、读变量/寄存器：不再停核
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_runtime.ps1" -ProjectPath "<工程根目录>" `
  -WaitFor "EPwm1Regs.TBPRD != 0" -RunMs 15000 `
  -Variables "EPwm1Regs.TBPRD,EPwm1Regs.CMPA.all,EPwm1Regs.TBCTL.bit.CLKDIV,SciaRegs.SCILBAUD"
# ★判据别写太宽松：程序进 main 之后可能还要好几秒初始化（本类工程常有"上电闪灯标记"阻塞 ~3.5s）。
#   用 "!= 0" 或 .bss 变量做判据容易"一进 main 就满足"，于是读回一堆"尚未配置"的状态
#   （TBPRD/ETSEL/ETPS/PIEIERx/IER 全 0、串口抓包"数据恒定"），被误判成"EPWM 没配/中断没跑/
#   我的改动没生效"。**判据优先用外设寄存器，或用变量的"具体目标值"**：
#   ... -WaitFor "gBootStage == 5"     ← 5 = 已进主循环（推荐在 main 里埋这种"阶段追踪变量"）
#   详见 references/dss-debug.md 的「判据怎么选」和「读太早的典型误判清单」

# ④ 后续继续读当前运行程序：不编译、不下载、不主动停核；见 references/read-only-mode.md
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_runtime.ps1" -ProjectPath "<工程根目录>" -Variables "EPwm1Regs.TBCTR"
```

`ti_c2000_debug.ps1 -Build` 单独使用只构建；下载后运行用 `-Build -Run` 或已有 `.out` 的 `-Run`。只有明确指定 `-LoadOnly` 才会下载后暂停。`-Build/-Run/-LoadOnly` 与 `-ReadVars` 同时出现会被拒绝，读取必须分成第二次只读调用。旧脚本无动作参数时曾隐式调用 `loadti -l`，现在也会拒绝。

脚本输出英文（避免 PowerShell 中文编码问题）；成功须同时有 `RESULT: OK` 和退出码 0。
失败会打印前 25 条错误、错误原因和完整日志路径（`%TEMP%\ti_c2000_build\<工程名>\build.log`）。

自检输出先看这几行：`CONFIG:` = 所用构建配置（多配置工程按"工程下存在同名输出目录"选）、
`DEFINES:`/`OPTIONS:` = 与 CCS 一致的宏与优化开关（同名 `#ifdef` 分支才会被编到）、
`EXCLUDED:` = 按 `.cproject` 的 "exclude from build" 跳过的源码 / `.cmd` / `.lib`（照 CCS 的真实构建行为，
所以工程里堆着别的器件的 `*Headers*.cmd`、被排除的 `.c` 也不会再误报 `LINK_ERRORS`）。

## 全自动闭环 SOP

1. **写代码**：**先照 TI 官方例程写**（铁律第 7 条 + `references/ti-official-style.md`：先翻对应的
   `Example_2833x*.c`，照它的寄存器顺序 / TI 宏 / `EALLOW-EDIS` / 中断四层 / `EINT; ERTM;` / ISR 应答写）。
   **找例程/库的固定动作**：`scripts\c2000ware_find.ps1 -Keyword "<功能关键词>"`（在 C2000Ware 全量
   例程/库/API 里定位）→ 查 `references/c2000ware-index.md` 的「我要做 X」速查表 → 打开命中的
   examples 照它写（含 math/dsp/DCL/ai 各库的实际例程）。
   新模块放 `APP/<模块名>/<模块名>.c|.h`；`main` 只放 `User/main.c`。
   新增目录**必须**把路径加进 `.cproject` 的 `compilerID.INCLUDE_PATH`，否则 `cannot open source file`。
2. **自检**：跑 ① 。编译错误按 `文件, 行号: error #xxx` 定位；链接错误看未定义符号名。
   先扫 `CONFIG:` / `DEFINES:` / `EXCLUDED:` 三行：配置或宏不对 = 读错了 `.cproject` 的配置段；
   `EXCLUDED:` 是照 CCS 的 "exclude from build" 跳过的源码 / `.cmd` / `.lib`（别的器件的 cmd 就在这一步被挡掉）。
3. **产物**：obj / map / log / `.out` 落在 **`%TEMP%\ti_c2000_build\<工程名>\`**，并同步一份 `.out` 到
   `<工程>\Debug\<工程名>.out`（调试器/loadti 加载它）。
   **产物绝对不能放进工程目录树**：CCS 托管构建会把工程里每个 `.obj` 也当链接输入，与它自己编出来的
   目标文件撞名 → 满屏 `error #10056: symbol "..." redefined`。脚本默认写 %TEMP%，且启动时自动清掉旧版
   留在 `<工程>\Debug\auto_build\obj` 的残留；用 `-OutputDir` 指到工程内只会打 WARNING，别这么干。
4. **下载并运行**：跑 ②，脚本检测 XDS 仿真器后才下载、复位并启动新程序。只在这一步允许因更新程序而改变板上状态。
5. **运行态只读**：跑 ③。DSS 在连接前关闭自动停核和自动复位，仅载入 `.out` 符号；在目标运行时轮询就绪并逐条打印 `VAR xxx = 值`，对着源码核对
   （本工程实测：`TBPRD=65535`、`CMPA.all=0xCCCC0000`(即 CMPA=0xCCCC=52428=65535×80%)、`CLKDIV=3`、`SCILBAUD=39`(115200bps)、`GPADIR.bit.GPIO8=1`，就绪点约 3.25 s）。
   若一直读回 0：先核对正在运行的固件与 `.out` 是否匹配，再加大只读调用的 `-RunMs`（默认预算 8000 ms）或换 `-WaitFor` 判据；不可通过停核读数来补救。
   ★ **就绪判据优先用外设寄存器**（如 `EPwm1Regs.TBPRD == 14999`、`SciaRegs.SCILBAUD != 0`），**别用 .bss 全局变量**：
   `loadProgram()` 不清 .bss，上次运行留下的 RAM 值会让判据瞬间成立（症状：`ready after 250 ms` 但 `TBPRD=0 / SCILBAUD=0`，
   其实程序还没跑到初始化）。脚本对"≤500 ms 就就绪"会打 NOTE 提醒；实测换寄存器判据后 3500 ms 才是真就绪。

## 调试时长（大程序 / 长时间等待）

就绪是**轮询**出来的，命中就立刻返回，所以 `-RunMs` 只是"上限"，设大不会白等。

| 场景 | 用法 |
|---|---|
| 程序大、初始化慢，可能要等 5 分钟 | `-RunMs 300000`（预算 5 分钟）+ 用 `-WaitFor "<表达式>"` 指定更靠谱的就绪判据 |
| 只想关键变量变了就采 | `-WaitFor "g_state == 3"`（表达式非 0 视为就绪） |
| 下载本身就慢（大 `.out`、慢 JTAG） | `-TimeoutSec 600`（loadti 超时，默认 180 s） |
| 上层命令 5 分钟会被打断 / 想边等边干别的 | 加 `-Background`：立即返回并打印日志路径 |

```powershell
# 第一步下载运行；第二步等待就绪并只读（可后台跑，随时查日志）
pwsh -NoProfile -File "...\ti_c2000_debug.ps1" -ProjectPath "<工程根目录>" -Build -Run
pwsh -NoProfile -ExecutionPolicy Bypass -File "...\ti_c2000_debug.ps1" `
  -ProjectPath "<工程根目录>" -ReadOnly -RunMs 300000 -WaitFor "EPwm1Regs.TBPRD != 0" `
  -ReadVars "EPwm1Regs.TBPRD,SciaRegs.SCILBAUD" -Background
# 之后轮询日志（出现 RESULT: 即结束）
Select-String -Path "<日志路径>" -Pattern 'RESULT|^VAR |ready'
```

超时相关事实：CCS12 的 DSS 默认 `scriptTimeout = -1`（不超时），模板仍会显式设成 `预算 + 300 s`；
会真正打断长等待的是**上层命令超时**，用 `-Background` 规避。

## 写代码前的防错清单

| 检查项 | 规则 |
|---|---|
| 模块位置 | `APP/<模块>/<模块>.c/.h`，文件名=模块名；**也可以放工程顶层（与 `APP` 同级）**，如 `<工程>\OpenLoop\` —— CCS 按 `sourceEntries`(整个工程) 扫源码，两种位置都编得到，不一定非得塞进 `APP` |
| 新增目录 | 必须补 `.cproject` include 路径（`${ProjName}/<目录>`），顶层目录同理，否则报头文件找不到 |
| 头文件保护 | `#ifndef XXX_H_ / #define XXX_H_ / #endif` |
| 符号唯一 | 别重复定义已有函数（如 `uart.c` 的 `error()`、各 `InitXxx()`、`xxx_isr()`） |
| 命名前缀 | 同一外设统一前缀（`OLED_`、`EPWM1_`、`UARTa_`、`TIM0_`、`ADC_`） |
| 引脚冲突 | 查 `references/project-map.md` 引脚表（GPIO8/9=OLED、GPIO0/1=EPWM1、GPIO28/29=SCI-A） |
| 寄存器保护 | 改 `SysCtrl/GpioCtrl/EPwm` 受保护寄存器必须 `EALLOW; ... EDIS;` |
| 浮点 | F28335 有 FPU32，用 `float`；避免 `double`，ISR 内别做浮点/除法 |
| 中断 | `EALLOW; PieVectTable.X = &isr; EDIS;` + 使能 `PIEIERn`/`IER` + ISR 内清 `PIEACK` |
| **并发读**（波形回读 / 观测）| 中断里更新的量（`XxxCtrl.usCmpA/B/C`、`fDuty*`、`fVd`…）在主循环读时**必须先快照**：`DINT; snap=…; EINT;`（≈20ns）再用快照。**绝不许"一边慢慢发串口、一边反复读全局变量"** → 波形会出现垂直毛刺（见 `references/ti-official-style.md` §4.5）|
| 看门狗 | `InitSysCtrl()` 内部已 `DisableDog()`，不要再手写 `WDCR` |
| 链接脚本 | 默认 `28335_RAM_lnk.cmd`（RAM 调试，掉电丢失）；要脱机运行需换 Flash 链接 |
| **RAM 空间**（加模块前必查） | `.text` 撞顶 = 链接报 `#10099-D`。先跑 `scripts\check_ram_layout.ps1` 判定是"跨片"还是"真不够"；本工程已合并成连续大块（`RAMCODE`=L0~L3 16K 字、`RAMDATA`=L4~L7 16K 字）。详见 `references/ram-and-linker.md`。⚠️ C2000 编译器**默认不按函数分段**：一个 `.c` 里只要有一个函数被引用，**整份 `.c`** 都会进程序段 —— 所以"临时/自测/可选"功能要**单独成文件** |
| `.cmd` 编码 | TI 例程的 `.cmd` 常是 **GBK**，PowerShell 默认按 UTF-8 读写会把中文注释打成乱码（不可逆）。改 `.cmd` 必须按 936 读写（见 `ram-and-linker.md` §5） |
| 目录名 | **必须 ASCII**：TI 编译器打不开含中文的路径（`Fatal error #1965`）|
| 工具函数 | `DELAY_US()` 依赖 `DSP2833x_Examples.h` 的 `CPU_RATE` |
| 主循环 | `main()` 里 `while(1)` 常驻；不要新增第二个 `main` |

## 外设写法速查（工程惯例；细节一律以 TI 官方例程为准 → `references/ti-official-style.md`）

- **EPWM**：`EPWM1_Init(tbprd)` → `EPWM1A_SetCompare(cnt)`；模块约定 `TBCTR < CMPA` 输出高 → 占空比 = `CMPA/TBPRD`；频率用 `TBCTL.CLKDIV/HSPCLKDIV` 分频。
- **SCI/串口**：`UARTa_Init(baud)`（`BRR = 37500000/(8*baud)-1`）→ `UARTa_SendByte/SendString`；发二进制曲线用小端两字节。
- **GPIO**：`GPxMUX = 0`（通用 IO）+ `GPxDIR = 1`（输出）；输出用 `GPxSET/GPxCLEAR`，读用 `GPxDAT`。
- **ADC/定时器/外部中断/DMA**：`APP/adc`、`APP/time`、`APP/exti`、`APP/dma` 已有模板，抄接口不要另起一套。

## 报错 → 处置对照

| 现象 | 原因 / 处置 |
|---|---|
| `cannot open source file "xxx.h"` | 新目录没加进 `.cproject` include 路径，或头文件名拼错 |
| `error #10234 unresolved symbols remain` | 源文件没被编译（不在 APP/User 下）或函数名不匹配；按未定义符号名反查 |
| `error #29 expected an expression` 等 | 按 `文件, 行号` 直接改；脚本会一次列出所有文件错误 |
| `redefinition of symbol` | 两个模块同名函数/变量（常见 `error()`、`Init()`），改前缀 |
| 找不到编译器 / `.cproject` 声明的版本没装 | 脚本会自动退回该 CCS 自带的 C2000 编译器并打印 NOTE |
| 下载失败 `no probe / cannot connect` | 仿真器没插/板上电，或 CCS GUI 已占用 JTAG（先关 GUI 里的调试会话） |
| `Error -151` / `Error -1135`（探针连接失败） | 先读具体错误文本，核对当前探针型号、`xds100serial` 串号、ccxml 连接类型和 `Emulator Selection`、CCS GUI 会话占用，以及板子供电和 JTAG 链路。需切换类型时运行 `scripts\ti_c2000_set_probe.ps1 -ProjectPath <工程> -Probe v2 -Serial <当前串号>`；原配置按串号选探针却未给 `-Serial` 时脚本会拒绝写入。错误码变化不能单独证明连接配置正确。现场细节见 `references/other-devices-and-probes.md` §3.1。 |
| 读回全是 0 | 程序还没跑到（加大 `-RunMs`）、外设时钟未开（`InitSysCtrl()` 没执行）、或没连上目标 |
| `ready after 250 ms` 但 `TBPRD`/`SCILBAUD` 读回 0 | 就绪判据用了 `.bss` 全局变量，被上次运行的 RAM 残留值误触发（`loadProgram()` 不清 .bss）；改用外设寄存器判据，见 SOP 第 5 点 |
| 自检 `LINK_ERRORS: unresolved symbols`，且 `SOURCES` 数量比预期少 | 源码在"脚本没扫到的目录"里：脚本按 CCS 规则扫 `APP`/`User`/`DSP2833x_Libraries` + 工程顶层其它目录；若新目录在更深层，或名字在 `$nonSrcDirs` 排除表里，就得调整脚本或用顶层目录 |
| `error #10099-D: program will not fit into available memory`（报错位置指向 `.cmd` 的 `.text` 行）| **两种完全不同的原因**：① `.text` 段真的太小；② 该段被放在**多个不连续内存块**（`> A \| C`）—— 此时报错文本会带 **`trampoline`** 字样，**再扩空间也没用**。先跑 `scripts\check_ram_layout.ps1` 判定，再照 `references/ram-and-linker.md` 合并成连续大块（`RAMCODE`/`RAMDATA`）或改 Flash 链接 |
| 只加了一个小模块，`.text` 却突然多出 2~3K 字 | C2000 编译器**默认不按函数分段**（`--gen_func_subsections` 关）：一个函数被引用 → **整份 `.c`** 被链进来。解法：把"临时/自测/可选"功能**单独成文件**（没人引用就整份不占空间）|
| `Fatal error #1965: cannot open source file "...\乱码\x.c"` | 工程里有**中文目录名**，TI 编译器不认。目录/文件名一律改 ASCII |
| 改了代码但板子现象完全没变 / 上位机没波形 | **先确认构建真的 OK**：构建失败时 `.out` **不会更新**，下载/运行的还是上一次的产物（现象=旧代码），极易误判成"改动无效"。盯住第一条编译错误——`xxx.h, line 1: error #7: unrecognized token` / `#171: expected a declaration` 常见于**文件行首混入非法字符**（反引号 `` ` ``=0x60、零宽字符、BOM 之外的杂字节）：`[IO.File]::ReadAllBytes($f)[0..7]` 看首字节即可定位并删掉（实测 2026-09-30：spwm.h 行首一个反引号 → 3 个文件编译失败 → 板子里跑旧程序 → SerialPlot 全白）|
| DSS 读回的浮点/结构体成员与实际不符 | 实测（2026-09-30）：`SvpwmYjbVsCtrl.fModul/fDa/fDb/fDc` 读回 0，但串口实测帧证明运行值非 0（m=0.7、d=75~925）。**不要只凭一次 DSS 读数下结论**，用"外设寄存器 / 串口实测帧"交叉验证；同一次读数里整数成员（usEnable/usSmallN/usCmpA）是正常的 |
| 下载成功但现象不对 | 先看 RAM/Flash 链接脚本、看门狗、时钟；再用 `-ReadVars` 读关键寄存器对照源码 |
| `The script 'x.ps1' cannot be run because it contained a "#requires" statement for Windows PowerShell 7.0`（`ScriptRequiresUnmatchedPSVersion`）| 用 Windows PowerShell 5.1（`powershell.exe`）跑了要求 PS7 的脚本。**本机统一用 pwsh 7.6**（`%LOCALAPPDATA%\Microsoft\PowerShell\7\pwsh.exe`）：自己执行命令时用 `pwsh`；脚本内部启动子进程也要用 `$PSHOME\pwsh.exe` 而不是 `powershell`（`ti_c2000_debug.ps1` 的 `-Build` 与后台实例早先踩过，已修）|

| **ADC 数据不变或卡住**（连续多帧读回同值、或结果寄存器恒为 0）| ① 核对 SOC 触发是否与 PWM/读回时序同步；本板 MTG 参考工程在 EPWM1 ISR 内写软件 `SOC_SEQ1`，硬件 EPWM SOCA 是另一种可选路径，不能一概断言软件 SOC 不可靠；② 检查 `ADCTRL2` 是否被后续整体赋值覆写。只读核对触发位、忙位和结果，单次全 0 不足以定位。详见 `references/c28x-pitfalls.md` §1 |
| **波形偶发尖刺 / 数据里频繁出现 0** | ADC 在**新序列开始时清结果寄存器**，在转换途中读就会拿到 0（越靠后的通道越容易中招；"读两遍一致才采信"也挡不住）。解法：读前等 `SEQ1_BSY == 0`，再**连读 5 次取中值**；根治是在 ADC/EPWM 中断里读。详见 §1.3 |
| **SPI 外设（DAC 等）输出畸变**（趋势对但有台阶/削顶/尖刺、码值翻倍、看着像“通道串扰/某路坏了”）| ① `SPISTS.bit.INT_FLAG` 是**只读**的整字完成标志，只能靠**读 `SPIRXBUF`** 清（写 1 清的是 `OVERRUN_FLAG`）；不清就直接 `while(INT_FLAG==0)`，第 1 次之后恒为 1 → 立即通过 → LOAD 提前锁残字（实测 `0xFF` 锁成 `0x80`）；② 只等 `BUFFULL_FLAG` 同理不够。解法：**读 `SPIRXBUF` 清标志 → 写 `SPITXBUF` → 等 `INT_FLAG`**，再拉 LOAD；时钟顶到器件手册上限（TLV5620 ≤1 MHz，不要提 3.75 MHz）。详见 §2.1~§2.3 与[案例](debug-cases/dsp28335/2026-10-26-tlv5620-load-timing.md) |
| **串口帧偶发错位**（上位机数据每 N 帧整体偏移一个通道）| `SCIFFTX.TXFFST` 只有 **4 位**，FIFO 满 16 时读回 0 → "判断有空位"的写法会往满 FIFO 写、数据被静默丢弃。改回逐字节发送；用**帧头间隔分布**诊断（间隔不单一就是丢字节）。详见 §3.1 |
| **改了 `.ini`/配置但界面没变**（SerialPlot 通道名等）| 程序退出时把窗口状态写回配置文件并**覆盖**你的修改 → 换用**全新配置文件名**（别反复改同一个）。详见 §4.5 |
| **PID 静差消不掉 / 加了 Kd 反而更差** | ① 采样噪声让增量式积分**净增为 0** → 给反馈加一阶低通（状态变量**必须放文件作用域**，放函数里会被每拍清零）；② 对象无惯性时 Kd 只放大噪声（实测峰峰 +50%）。详见 §5.1/5.2 |
| 误差分不清是"随机噪声"还是"系统性偏差" | 拿一阶低通试：**低通后变小 = 随机噪声**；**低通无效 = 系统性偏差**（要从采样同步/前馈/结构上解决，调 PID 没用）。详见 §5.3 |

## 无硬件时的降级验证

仿真器不在线时**不要**反复重试下载：
1. 构建脚本 `RESULT: OK`（编译+链接两关能挡掉绝大多数写错的情况）；
2. 静态核对：引脚冲突、寄存器位定义、中断向量、时序参数；
3. 明确告诉用户"编译链接已验证，硬件现象需插上 XDS100 才能确认"，不要谎称已上板。

## 换型号 / 换仿真器 / 双核

**不用改脚本**——构建脚本已把型号相关的部分全部改成从 `.cproject` 反推（汇编器版本 `-v28/-v29`、`-ml/-mt`、浮点 `fpu32/fpu64/softlib`、输出格式 COFF/EABI、运行库 `rts2800_*`、**全部非 exclude 的 `.cmd`/`.lib`**、`DEFINE`/`OPT_LEVEL`/`OPT_FOR_SPEED`/`FP_MODE` 等编译开关），并在日志里打印 `DEVICE:` / `CONFIG:` / `DEFINES:` 便于确认。

| 需求 | 参数 |
|---|---|
| 换仿真器 / 换板 | 在 CCS 里改 target configuration，然后 `-Ccxml <文件>`（默认取 `targetConfigs\` 下第一个） |
| F28379D + XDS100v2 | 使用 `f28379d.xml`、CPU1 port `0x10`；序列号必须按 `xds100serial` 实际输出填写；见 `references/other-devices-and-probes.md` §3.2 |
| 换探针型号（XDS100v1/v2/v3、XDS110...） | 核对实物型号与串号后用 `scripts\ti_c2000_set_probe.ps1 -ProjectPath <工程> -Probe v2 -Serial <当前串号>`（`-List` 列本机可选项、`-DryRun` 只报告、自动备份 .bak）；原配置按串号选择时必须传 `-Serial`，切完只读核对 ccxml。 |
| 双核 / 多核器件（F2837xD/F28379D/F2838x） | `-CorePattern ".*CPU1.*"` 选核；每个核各自一份 `.ccxml` 与 `.out` |
| 用模拟器（无硬件） | ccxml 选 tisim，脚本自动跳过硬件检查；也可 `-NoProbeCheck` |
| 追加链接脚本（Flash 版等） | `-LinkCmd "F2837xD_Flash_lnk_cpu1.cmd"` |
| 指定编译器 / CCS | `-CompilerRoot <ti-cgt-c2000_x.y.z.LTS>`、`-CcsRoot <CCS安装目录>` |

各型号的头文件名/链接脚本/运行库差异、仿真器枚举名对照、driverlib+SysConfig 工程的注意事项：
见 [references/other-devices-and-probes.md](other-devices-and-probes.md)；
C2000Ware 里 cmd 怎么选、2837x/28379x 的 bitfield/driverlib 骨架、SysConfig 与库用法：
见 [references/c2000ware-guide.md](c2000ware-guide.md)。

> 诚实边界：本 skill 已在 **DSP28335 + XDS100v2** 和 **F28379D + XDS100v2** 上做过硬件实测；其他型号/仿真器按 TI 通用结构自动适配，
> 第一次用请先跑 `ti_c2000_build.ps1` 自检，再上 `ti_c2000_debug.ps1`。

## 失败分类（照实说失败，并给出分类+原因）

每个失败都会输出 `FAILURE: <分类>` + `REASON: <原因>`，退出码非 0。**这五类都已用真实实例验证过**：

| FAILURE | 含义 | 先做什么 |
|---|---|---|
| `COMPILE_ERRORS` | C 语法/头文件错误 | 按 `文件, 行号: error #xxx` 改代码，完整日志 `%TEMP%\ti_c2000_build\<工程名>\build.log` |
| `LINK_ERRORS` | 未定义符号等链接错误 | 按未定义符号名反查：源文件没进工程 / 函数名不符 / 少 include 路径 |
| `memory range has already been specified` / `symbol "..." redefined` | "把不该参与构建的东西链进来了"。脚本已按 `.cproject` 的 exclude 列表跳过这类源码 / `.cmd` / `.lib`（输出里有 `EXCLUDED:` 行）；仍出现就核对 `.cproject` 是否漏 exclude，或用 `-IgnoreExclusions` 复现原组合对比 |
| `#10056 symbol "X" redefined`（同一符号在两个 `.obj` 里各定义一次） | 工程目录树里有**多余的 `.obj`**：CCS 会把工程里每个 `.obj` 都交给链接器（和 `.cmd`/`.lib` 同规则）。常见来源：脚本/手工编译的残留（`<工程>\Debug\auto_build\obj`、随手 `cl2000 -c` 的 obj）。自检脚本现已把产物写到 `%TEMP%\ti_c2000_build\<工程>\` 并自动清理旧残留；仍报错就 `Get-ChildItem -Recurse -Filter *.obj` 搜一遍，只留 `<工程>\<配置名>\` 下 CCS 自己的，然后 CCS 里 Project→Clean 重建 |
| `TIMEOUT` | 就绪条件在上限内没成立 | 加大 `-RunMs` 或修 `-WaitFor`；若确实卡住，用「读 PC + map 文件」定位卡在哪个函数 |
| `CONNECT_FAILED` | 打不开调试会话（连 ccxml 都没解析成功） | 查 ccxml 是否有效、JTAG 是否被 CCS GUI 占用、板子是否上电、`-CorePattern` 核是否选对 |
| `LOADTI_ERROR` / `LOADTI_TIMEOUT` | loadti 报错 / 超时没出现 `Done` | 看打印出的原始错误行；加大 `-TimeoutSec`；确认探针与板子。**若原始行是 `'""F:\...\loadti.bat" "-c' is not recognized as an internal or external command`，那不是探针问题**：工程路径含空格（如 `...\Working Folder`）时，脚本曾把参数拼成一整串交给 `cmd /s /c`，PS7 会把内嵌引号转义成 `\"` 而 cmd 不认，于是根本没启动 loadti。已在 `ti_c2000_debug.ps1` 改为数组传参（`& $loadti @ltArgs`、`& cmd.exe /d /c $dss $js`）；再遇到同类拼接报错先查引号，不要先怀疑硬件 |
| `NO_PROBE` | 系统没枚举到仿真器 | 插好探针并上电；模拟器目标（tisim）不受影响；必要时 `-NoProbeCheck` |
| `NO_OUT_FILE` / `NO_CCXML` / `ENV_*` / `BUILD_FAILED` | 环境或参数不对 | 先 `-Build` 生成 `.out`；补 `-Ccxml`；检查 CCS/编译器安装 |

超时相关的两个旋钮：`-RunMs`（就绪轮询上限，默认 8000 ms）与 `-TimeoutSec`（loadti 超时，默认 180 s）。
`TIMEOUT` 时会额外提示"上面打印的 VAR 值是在超时之后采样的，可能无效"，不要拿它当结论。

## 环境与参考

- 本机实测环境/已验证项/已知坑：`references/environment.md`（本机已装 **PowerShell 7.6.6**，
  路径 `%LOCALAPPDATA%\Microsoft\PowerShell\7\pwsh.exe`；**统一用 `pwsh` 执行**，脚本首行 `#requires -Version 7.0`）
- **TI 官方例程写法规范（写代码前必读）**：`references/ti-official-style.md`
- **C2000Ware Core SDK 使用指南**（SDK 布局 / bitfield vs driverlib / 28377-379 / cmd 链接脚本怎么选 / SysConfig / 仿真器）：`references/c2000ware-guide.md`
- **C2000Ware 全量索引**（22 个器件 / 例程类别 / 13 个库（math·dsp·DCL·PMBus·ai…）的实际例程 / 「我要做 X」速查表 / driverlib API 前缀）：`references/c2000ware-index.md`
- **RAM 布局 / 链接脚本改造**（`#10099-D` 装不下、跨片 trampoline、函数分段陷阱、`.cmd` 是 GBK、大工程上 Flash）：`references/ram-and-linker.md`
- **★锁相环 PLL 算法**（TI SolarLib `SPLL_1ph_SOGI` / `SPLL_1ph` / `SPLL_3ph_SRF` / `SPLL_3ph_DDSRF`：
  原理、离散系数、环路整定公式、符号约定、10 条踩坑记录、移植到 28335 的最小步骤）：`references/spll-pll-algorithms.md`
- **★C28x 外设时序实测坑清单**（ADC 触发方式/结果寄存器清零、SPI `INT_FLAG` 与 LOAD 时序、SCI `TXFFST` 丢字节、
  工程文件 GBK 编码、SerialPlot 配置缓存、增量式 PID 抗噪、dq 角度约定、母线前馈）：
  `references/c28x-pitfalls.md` —— **写 ADC/SPI/SCI 代码、或排查"数据不对/波形畸变"之前先扫一遍**，
  末尾还有一份「数据不对」的快速诊断流程（先静态钉死链路，再查动态时序）
- 工程结构、模块接口、引脚占用表：`references/project-map.md`
- DSS/loadti 自动调试用法与排错：`references/dss-debug.md`
- 脚本：`scripts/ti_c2000_build.ps1`（编译链接自检）、`scripts/ti_c2000_debug.ps1`（下载/运行/读回）、
  `scripts/c2000ware_find.ps1`（★在 C2000Ware 里定位官方例程/库/API，写代码前先跑）、
  `scripts/check_ram_layout.ps1`（★链接脚本/RAM 布局诊断：先判"跨片"还是"真不够"）、
  `scripts/dss_template.js`（DSS 会话模板）、`scripts/dss_api_probe.js`（换 CCS 版本时先探测 API）

**不要用** CCS 的无界面构建（`eclipsec ... managedbuilder.core.headlessbuild`）：本机会生成编译器路径为空的 `subdir_rules.mk`（Error 87）。自动构建一律走本 skill 的脚本，或在 CCS GUI 里点 Build。
