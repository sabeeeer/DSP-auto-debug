# CCS 下载与 DSS 运行态读取

## 所有器件的操作前提：会话边界

无论 DSP28335、F28379D 还是以后新增的 C2000 器件，**操作上先按最严格边界规划**：本用户调试阶段使用 RAM 链接程序和 RAM 变量/冻结缓冲，先核对当前 `.cmd` 与 `.map`。新固件的构建/加载/运行态验证在一个 DSS 会话中完成；加载一次后把计划的标量、冻结缓冲和心跳全部读完，不为补读频繁重新连接或烧录。程序开始运行后的读取、读取结束都不主动 `halt()`；DSS 必须使用实时访问，读数期间若发现目标停机就失败退出，不以停核读数冒充运行态读数。

只读模式可独立连接读取身份已核实的当前 RAM 固件，整个调用不编译、不下载、不主动停核/复位；它不能用来证明一次已结束的 RAM 下载会话仍在运行。“只读”只描述脚本请求的操作，不能保证新建/关闭 DSS 会话对目标零影响。**不能默认 `disconnect()` 后目标继续运行**：如任务要求程序在脚本退出后继续控制输出，应先在该器件、探针、CCS 组合验证断开行为，或保持同一调试会话；当前自动脚本退出时会断开。用户报告 CCS GUI 存在“断开不复位”设置；在本机 CCS 12.8 DSS 中尝试 `HaltOnDisconnect`、`ResetOnDisconnect`、`AutoResetOnDisconnect` 均返回 `Option not found`，目前没有找到脚本层等效控制。以上是跨器件的保守工作规则，**不是**“DSS 对所有 DSP 必然复位”或“最后必须 halt”的已证实 API 性质。TI 的 [CCS 12.8 实时模式说明](https://software-dl.ti.com/ccs/esd/documents/users_guide_12.8.0/ccs_debug-main.html)明确允许运行时访问；[DSS Target API](https://software-dl.ti.com/ccs/esd/documents/scripting_api/ccs_12.8.0/dss/docs/DS_API/com/ti/debug/engine/scripting/Target.html)分别定义 `disconnect()`、`reset()` 和 `halt()`。现场断开结果按器件逐项归档。

执行模式验证新 RAM 固件时，优先用 `ti_c2000_run_read.ps1` 在同一 DSS 会话内加载、运行、读取；固件已有冻结 DMA 缓冲时用 `ti_c2000_read_dma.ps1`。只读任务只观察身份已核实的当前固件。旧 `ti_c2000_debug.ps1 -Run` 用 `loadti -r -a` 下载并退出会话，**不适合直接作为 DSP28335 新 RAM 固件的读数验收路径**。旧包装脚本的 `-Build/-Run/-LoadOnly` 与 `-ReadVars` 同次使用仍会在连接前拒绝。

## 下载/运行边界

| 参数 | 效果 |
|---|---|
| `-Build` | 构建而不下载。 |
| `-Run` | 下载现有 `.out`，复位并异步运行。 |
| `-Build -Run` | 构建成功后下载运行。 |
| `-LoadOnly` | 显式下载后保持暂停；不得用来读取数据。 |

成功看 `RESULT: OK` 与退出码 0，下载还应有 `Done`，运行还应有 `Target running...`。失败先看原始错误、探针/串号、`.ccxml`、供电、目标核和 CCS GUI 是否占用 JTAG；双核与 F28379D 见[器件/探针记录](other-devices-and-probes.md)。

`loadti` 自身有 `-cpu/--cpu-name` 选核参数；本技能包装脚本当前未透传该参数，F28379D 下载前须确认实际加载核。`xds100serial.exe` 可在 `<CCS_ROOT>\ccs_base\common\uscif\` 下列出 XDS100 探针和串号；`dbgjtag.exe` 在同目录用于 JTAG 诊断。识别探针不需要下载程序；`loadti` 则会改变目标状态。

## DSS 只读入口

```powershell
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_runtime.ps1" `
  -ProjectPath "<工程>" -Ccxml "<当前目标配置.ccxml>" `
  -OutFile "<与运行固件匹配的.out>" -Variables "<变量,寄存器>"
```

`dss_template.js` 在 `connect()` **之前**设置 `HaltOnConnect=false`、`AutoResetOnConnect=false`、`RestartOnSymbolLoad=false`、`UseLegacyStopMode=false`、`AllowInterruptsWhenHalted=true`、`PoliteRealtimeMode=true`；之后仅 `symbol.load()` 并读取。固件中的 `ERTM` 与这些调试器选项配合。脚本发现目标已停或实时读取失败就报错，不调用 `halt()`、`runAsynch()`、复位或下载。详细边界见[只读规则](read-only-mode.md)。

用 `-WaitFor "gBootStage == 5" -RunMs 15000` 可在运行态轮询就绪条件；不指定时直接取当前值。条件要能证明**本次**初始化已到目标阶段，宽松的 `.bss != 0` 可能只是 RAM 残值。超时返回失败，超时后打印的变量值不能当作已就绪证据。目标显示 running 也不是应用心跳证明，若有单调计数器，应跨时间核对递增。

大数组用 `ti_c2000_read_array_runtime.ps1` 的固定下标分批读取；每批都在运行态，固件应先冻结缓冲或提供版本号。裸 `connect → halt → readData → runAsynch` 已造成程序中断和继电器释放；[读取事故案例](debug-cases/dsp28335/2026-11-07-read-halt-bulk-array.md)保留原因与证据边界。`readData` 的页、字地址、宽度和数值范围须与表达式读数交叉验证，不因速度快就默认可信。

## 必要的 DSS API 备忘

| 用途 | CCS 12.8 记录 |
|---|---|
| 只装载符号 | `session.symbol.load(out)`；不等于下载程序。 |
| 读表达式 | `session.expression.evaluate(name)`；高频变量逐项读取不是原子快照。 |
| 符号地址 | `session.symbol.getAddress(name)`；本机该版本没有 `lookupSymbol()`。 |
| 读块 | `session.memory.readData(page, address, typeSize, count)`；**`typeSize` 是位宽（8/16/24/32），不是字节**（实测传 1/2 会报 "Invalid type size"）。C28x 用 16 读 16 位字、32 读 long；`page=1` 为数据空间；地址按 16 位字递增。本次 XDS100v2 测得 16 位批量读取约比逐点 `evaluate` 快 39 倍。 |
| 延时 | `java.lang.Thread.sleep(ms)`；Rhino 没有 `env.sleep()`。 |

换 CCS 版本时可先运行不连接目标板的 `scripts/dss_api_probe.js` 查看 API，再按当前版本验证实时选项。历史只读停核、构建后隐式 `loadti -l` 与浮点读回问题分别见[模式修复案例](debug-cases/dsp28335/2026-11-07-realtime-read-implicit-loadonly.md)和[浮点读回案例](debug-cases/dsp28335/2026-10-28-fpu-dss-float-readback.md)。

## 高速数据：由固件采集，JTAG 搬运缓冲

**不要用 DSS 直接读寄存器来做高速采样。** 事实：

| 项 | 数值 |
|---|---|
| DSS/JTAG 单次 `expression.evaluate` | 毫秒级（本机 10 变量/轮约 130 ms，约 13 ms/变量） |
| 等效逐项读取速率 | 本次约 13 ms/变量，即单变量约 77 次/秒；随探针和 CCS 变化 |
| 寄存器历史 | **不保留**：`ADCRESULTx` 只存最近一次转换，下一次即覆盖 |
| 两次 JTAG 读之间 | 几十 µs ~ ms 空档，中间数据全部丢失 |

因此 500 ns / 1 µs / 100 µs 这类采样由固件侧完成；可用 ADC+DMA，也可在经过周期预算验证的中断里写缓冲：

```
独立触发源（ePWM2 / CPU Timer，不占用主发波 ePWM1）
  → ADC SOC → EOC → DMA → RAM 数组（连续采集：ping-pong 双缓冲；
                                单次录制：采满即冻结的单缓冲）
  → 采满冻结（gBufFull=1）→ JTAG 搬数组 → CSV
```

要点：
- 触发源必须独立，改采样率不能改到主发波频率；
- 500 ns 间隔要求 `ACQPS` 很小（当前 `ACQPS=14` 约 510 ns，已超）；
- DMA 源地址、权限和 ADC 结果对齐方式须按当前器件手册与例程核对，不能把 F28379D 寄存器写法套到 DSP28335；
- 1 µs × 0.1 s = 100000 点，16 位原始值为 200 KB/通道；先核对当前器件可用 RAM 和链接布局；
- 不要把 DMA 指向 `AdcMirror`（28335 时代的坑，见 `c28x-pitfalls.md` §4.8.1）。

**读取判据**：见 [data-read-verdict.md](data-read-verdict.md)。按用途分别核对身份、活性、冻结窗口和范围；未提供的证据不得写成通过。

## 下载后要"验证真的在跑"：必须单会话（2026-11-13，F28379D 实测）

`ti_c2000_debug.ps1 -Run` 走 `loadti.bat -r -a`，运行命令后退出该调试会话。此后目标执行路径取决于器件、链接位置、启动配置和会话退出行为；不能一概说“必然从 Flash 启动”。

F28379D + XDS100v2 的现场记录：在同一 DSS server 内调用 `disconnect()` 后，`gMsTick` 从 527 归零，重连看到 `isHalted=true`。在当时 CCS/DSS 配置里尝试 `HaltOnDisconnect`、`ResetOnDisconnect`、`AutoResetOnDisconnect` 均得到 `Option not found`；未找到能复现 CCS GUI“断开不复位”行为的 DSS 选项。这是该组合的实测边界，**不是对全部 CCS 版本、器件、探针的 API 断言**。TI 的 API 将 `disconnect()` 和 `reset()` 列成两个不同方法；不能归因于编译器。该板另起只读出现：

```text
SEVERE: C28xx_CPU1: Trouble Reading Register PC: (Error -1142) Device blocked
debug access because it is currently executing non-debuggable code.
READONLY_STATE_ERROR: target halted at connect; no resume attempted
FAILURE: READONLY_ACCESS_ERROR
```

要验证新加载的 RAM 固件，按执行模式在**同一个 DSS 会话里**连接、按需停核/复位、`memory.loadProgram(out)`、`runAsynch()`，然后运行态读数；至少两次读取应用计数器确认递增。程序启动后的读取阶段不再停核。每次调用单会话脚本都会重新加载，先规划好所需变量和数组，避免为补读重复调用。要点：

- 路径字符串用**正斜杠**（`E:/.../x.ccxml`）。JS 里 `\` 是转义符，`E:\3-1...` 会被吃成 `E:` + 制表符，报
  `Cannot read System Setup data from XML file`；
- `session.target.reset()` 在目标状态异常时会失败（`Error reseting target: Target reset failed. Error: -1`），
  改用 `session.target.halt()` + `loadProgram()` 即可；
- 结尾不要 `halt()`；在已出现断开后状态变化的板上，`disconnect()` 后**不能保证程序继续运行**，需要保留输出时应保持调试会话或另做实测；
- 判断"程序在跑"的三条实测判据（本板数值）：
  `gMsTick` 1 s 增量 ≈ 1000、`usMainLoop` 每秒数百万、外设寄存器与代码预期一致
  （如 `SciaRegs.SCICTL1.all == 0x23`、`SCILBAUD == 53`、`GPADIR.GPIO31 == 1`、`CpuTimer2Regs.PRD.all == 19999999`）；
- 输出类现象（LED）可每 200 ms 采样一次 `GpioDataRegs.GPADAT.bit.GPIO31`，序列里每段 2~3 个采样值
  同电平即对应 500 ms 翻转。
