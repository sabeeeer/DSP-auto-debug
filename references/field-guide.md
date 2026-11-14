# 执行模式：工程修改与上板验证

执行顺序：**可行时读现有固件基线 → 分析 → 必要时修改、构建 → 一次加载、运行并在同一 DSS 会话读取验证**。加载前的复位/停核只属于执行模式；程序运行后的读数不得主动停核或再次加载。DSP28335 的 RAM 工程已观察到另起只读读到 Flash 地址，不能用那次读数验收 RAM `.out`。

## 1. 修改前取证

确认实际工程、器件/核、探针和 `.ccxml`，核对符号 `.out` 与板上运行固件是否匹配。**本用户的调试工程都按 RAM 程序与 RAM 数据处理**，先核对 `.cmd`、`.map` 和当前固件身份。只有此前已验证该组合的独立 DSS 建连/断连不会破坏当前任务，才用下面的独立只读入口取得基线；否则记“基线不可安全取得”，直接规划新固件的单会话读取。独立只读绝不能作为一次已结束下载会话的新 RAM 固件验收。

```powershell
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_run_read.ps1" -ProjectPath "<工程>" -Variables "<变量,寄存器>"
```

数组用 `ti_c2000_read_dma.ps1 -FrozenBufferReady`（固件冻结缓冲）。周期数据先让固件录入并冻结完整窗口：50 Hz、1 kHz 的 10 周期是 200 帧；JTAG 传输可超过 200 ms，但目标必须继续运行。记录读数、条件和心跳计数；只看 `isHalted()==false` 不足以证明应用持续执行。

## 2. 查例程或现成库

- 外设配置先按[官方例程规则](peripheral-examples.md)选同器件、同核、同 bitfield/driverlib 风格的 TI 源码和 `.projectspec/.cmd`；DSP28335 与 F28379D 的例程不能互套。器件、探针、双核细节从[第一类入口](device-platform.md)继续读。
- 算法先查[第二类入口](ti-algorithm-libraries.md)中的 Core SDK、DCL、controlSUITE DMC、SolarLib 与当前工程。电网 PLL/SOGI 再读 [SolarLib PLL 文档](spll-pll-algorithms.md)，避免重写已有模块。
- 现场症状从[第三类入口](debugging-experience.md)找相同器件/模块的案例；历史读数不自动代表当前板。

## 3. 构建、下载、运行

若任务涉及上板运行或下载，先只检查探针，不启动 CCS 调试会话或编译器：

```powershell
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_debug.ps1" -ProjectPath "<工程>" -ProbeCheckOnly
```

仅当 `RESULT: OK` 且退出码 0 后继续。若为 `NO_PROBE`，停止并询问用户接线状态，收到回复前不构建、不下载、不自动重试。纯构建任务可直接构建。只在确需更新程序时修改工程。`-KeepLaunches` 保留工程中的 CCS GUI `.launch` 配置，否则构建脚本会将其备份到临时目录。运行前确认 `<工程>\Debug\auto_build\obj` 只含旧自动产物，因为构建脚本可能清理该目录。单独构建默认只把新 `.out` 留在报告的 `OutputDir`，不覆盖 `Debug` 下可能与板上固件匹配的 `.out`。

```powershell
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_build.ps1" -ProjectPath "<工程>" -KeepLaunches
```

需要构建并上板运行，同时验证变量时，把要读的变量一次列齐，让执行模式在同一 DSS 会话完成：

```powershell
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_run_read.ps1" `
  -ProjectPath "<工程>" -Build -Variables "<心跳变量>,<ADC或状态变量>" `
  -HeartbeatExpr "<该固件实际递增的计数器>" -Rounds 3
```

已有匹配的 `.out` 可省略 `-Build` 并显式传 `-OutFile`。每次调用 `ti_c2000_run_read.ps1` 都会重新加载一次；先规划所有变量、轮数和等待时间，不为补读反复调用。固件已冻结 RAM 数组时，沿用 `ti_c2000_read_dma.ps1 -FrozenBufferReady` 在一个会话内加载并搬运；该缓冲可由 ISR 或 DMA 填充。28335 的 `gAdcAllBuf[16][400]` 应显式传 `-ArrayName gAdcAllBuf -Rows 16 -Columns 400 -FrozenFlag gAdcBufFull -SeqVar '' -HeartbeatExpr gRunMs`，并核对 `.out`、范围和数组布局。`ti_c2000_debug.ps1 -Build` 只构建，`-LoadOnly` 会下载后暂停；`-Run` 只下载运行、退出即复位，**不能用于读取**。读取统一用 `run_read` / `read_dma` 的单会话入口。源码或 `.cmd` 修改后必须真实编译链接。每步成功均须 `RESULT: OK` 和退出码 0。

28335 的该缓冲已由源码核对为 ISR 录满后冻结时，单会话命令形状如下；执行前仍须确认当前 `.out` 与板卡、负载状态：

```powershell
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_dma.ps1" `
  -ProjectPath "<28335 工程>" -FrozenBufferReady `
  -ArrayName gAdcAllBuf -Rows 16 -Columns 400 `
  -FrozenFlag gAdcBufFull -SeqVar '' -HeartbeatExpr gRunMs `
  -Variables 'gBootStage,EPwm1Regs.TBPRD' `
  -ValueMin 0 -ValueMax 4095
```
执行脚本先查探针再构建。编译器选择按 `.cproject` 的声明；找不到时报告，只有用户同意才用替代版本。

## 4. 运行态复读与判定

同一 DSS 会话中 `runAsynch()` 后读取，至少检查一个实际递增的应用计数器；只看 `isHalted()==false` 或单次变量值不够。对照基线与新数据时保持同一器件、输入、采样率、窗口和换算方法。会话结束可能改变某些板上的运行状态，不能把脚本退出后的状态视为已验证。`ti_c2000_debug.ps1` 只做编译/下载/运行，`-ReadVars` 等读数参数已删除，读数走 `ti_c2000_run_read.ps1` 或 `ti_c2000_read_dma.ps1`。

## 失败时查哪里

| 现象 | 先查 |
|---|---|
| `COMPILE_ERRORS`、`LINK_ERRORS`、`.text` 装不下 | 构建日志、`.cproject` 的宏/排除项、源文件和 `.cmd`；内存问题见[RAM 与链接](ram-and-linker.md)及 `scripts/check_ram_layout.ps1`。 |
| `NO_PROBE`、`CONNECT_FAILED`、`LOADTI_ERROR/TIMEOUT` | 原始错误、探针型号/串号、`.ccxml`、供电、JTAG 和 CCS GUI 占用；见[探针与双核](other-devices-and-probes.md)。 |
| `TIMEOUT`、读回全零或数值矛盾 | 等待条件、`.out` 身份、运行状态、ADC 对齐和寄存器访问语义；见[只读规则](single-session-read.md)与[DSS 诊断](dss-debug.md)。 |
| 波形、串口或外设现场故障 | 从[第三类案例索引](debugging-experience.md)按器件、模块、现象找，不直接推广其他工程的结论。 |

无探针时停止上板任务并询问用户；不声称上板通过。DSP28335 的[官方例程上板范围](board-tests-dsp28335.md)与 F28379D 的[探针/双核记录](other-devices-and-probes.md)分别保留；未验证的外设引脚或负载另行标注。
