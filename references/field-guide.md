# 执行模式：工程修改与上板验证

执行顺序：**运行态读基线 → 分析 → 必要时修改、构建、下载运行 → 运行态复读验证**。读数步骤都按[只读模式](read-only-mode.md)执行，不停核、不复位、不借读数重新烧录。若目标已停，记录状态；只读脚本会失败，不会自行启动。

## 1. 修改前取证

确认实际工程、器件/核、探针和 `.ccxml`，核对符号 `.out` 与板上运行固件是否匹配。读取参数、寄存器或现有采样缓冲时用：

```powershell
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_runtime.ps1" -ProjectPath "<工程>" -Variables "<变量,寄存器>"
```

数组用[正式分批脚本](read-only-mode.md#最小命令)。周期数据先让固件录入并冻结完整窗口：50 Hz、1 kHz 的 10 周期是 200 帧；JTAG 传输可超过 200 ms，但目标必须继续运行。记录读数、条件和心跳计数；只看 `isHalted()==false` 不足以证明应用持续执行。

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

需要构建并上板运行时，使用同一调用，让脚本明确暂存新 `.out` 后下载：

```powershell
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_debug.ps1" -ProjectPath "<工程>" -Build -Run
```

已有匹配的 `.out` 可只用 `-Run`；若要运行单独构建产生的新文件，明确传 `-OutFile <构建日志中的 out 路径>`。`-Build` 单独使用只构建，`-LoadOnly` 明确要求下载后暂停；二者都不能替代运行态读取。源码或 `.cmd` 修改后必须有真实编译链接结果；旧 `.out` 不能充当新构建。每步成功均须 `RESULT: OK` 和退出码 0。
`-Build -Run` 内部也会在构建前复查探针。编译器选择先跨已安装的 CCS 查找 `.cproject` 声明的版本；找不到则报 `COMPILER_VERSION_MISSING`。仅在用户明确接受替代版本时使用 `-AllowCompilerFallback`。

## 4. 运行态复读与判定

程序启动后另起只读调用，必要时用 `-WaitFor "<只读条件>" -RunMs <上限毫秒>` 等初始化完成。就绪条件用外设寄存器或明确的阶段值；旧 RAM 全局变量非零可能只是残值。对照基线与新数据时保持同一器件、输入、采样率、窗口和换算方法；异常先核对符号、目标核、寄存器读法及固件身份。只读脚本拒绝 `-Build/-Run/-LoadOnly` 与 `-ReadVars` 同次调用。

## 失败时查哪里

| 现象 | 先查 |
|---|---|
| `COMPILE_ERRORS`、`LINK_ERRORS`、`.text` 装不下 | 构建日志、`.cproject` 的宏/排除项、源文件和 `.cmd`；内存问题见[RAM 与链接](ram-and-linker.md)及 `scripts/check_ram_layout.ps1`。 |
| `NO_PROBE`、`CONNECT_FAILED`、`LOADTI_ERROR/TIMEOUT` | 原始错误、探针型号/串号、`.ccxml`、供电、JTAG 和 CCS GUI 占用；见[探针与双核](other-devices-and-probes.md)。 |
| `TIMEOUT`、读回全零或数值矛盾 | 等待条件、`.out` 身份、运行状态、ADC 对齐和寄存器访问语义；见[只读规则](read-only-mode.md)与[DSS 诊断](dss-debug.md)。 |
| 波形、串口或外设现场故障 | 从[第三类案例索引](debugging-experience.md)按器件、模块、现象找，不直接推广其他工程的结论。 |

无探针时停止上板任务并询问用户；不声称上板通过。DSP28335 的[官方例程上板范围](board-tests-dsp28335.md)与 F28379D 的[探针/双核记录](other-devices-and-probes.md)分别保留；未验证的外设引脚或负载另行标注。
