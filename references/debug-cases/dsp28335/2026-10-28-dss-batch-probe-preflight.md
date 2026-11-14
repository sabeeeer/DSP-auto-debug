# DSS 批处理启动与探针预检误报

## 身份与适用范围

- TMS320F28335 当前 `2-1SOGI_PLL` 板；CCS 12.8.1、CGT 22.6.1.LTS；XDS100v1，序列号 `TI1P9CM8`。
- 模块：`scripts/ti_c2000_debug.ps1` 的 Windows/PowerShell 7 外部工具调用与探针预检。
- 状态：**待上板回归**。2026-10-28 的旧路径曾上板回归；2026-11-07 修订后的 `-Run` 路径仅完成离线回归，尚未再次下载。

## 现象与原始证据

- 首次只读探测在启动 `dss.bat` 前失败，PowerShell 报 `StandardOutputEncoding is only supported when standard output is redirected`，脚本给出 `FAILURE: CONNECT_FAILED`。原始日志位于当时任务工作区的 `work/board-tests/probe-readonly.log`。这次没有下载、复位或访问目标板。
- `Get-CimInstance Win32_PnPEntity` 在本机报“更具体的错误代码不包含发生的常规错误”，导致原脚本的预检可能误判“无探针”。CCS 自带 `xds100serial.exe -l` 同时明确列出 `0403/a6d0 XDS100v1/v2 TI1P9CM8 Texas Instruments XDS100+RS232 V1.0`。

## 定位、修复与回归

- 用 `cmd.exe /d /s /c` 启动 CCS 的 `.bat` 包装器，分别给批处理和脚本路径加引号；先以只打印 `DSS_SMOKE_OK` 的 JS 验证进程能启动、退出码 0，再做只读板上连接。`loadti.bat` 分支采用同样的调用方式，已用 CPU Timer 固件做 `-LoadOnly` 上板回归：日志 `work\board-tests\loadti-smoke.log` 出现连接、加载、`Done`、`RESULT: OK`、退出码 0；目标保持加载后暂停。
- 预检先尝试 Windows CIM；失败时调用 CCS 自带 `xds100serial.exe -l` 识别 XDS100。跳过预检的 `-NoProbeCheck` 不再触发无用的 CIM 查询。
- 修复后只读探测出现 `DSS: connected`、寄存器读回、`DSS: done`、`RESULT: OK`、退出码 0：`work\board-tests\probe-readonly-retry.log`。随后不带 `-NoProbeCheck` 的探测也读到探针和目标变量，`RESULT: OK`、退出码 0：`work\board-tests\probe-fallback.log`。
- 之后 eCAP APWM、DMA、eCAN、McBSP 共 12 次板上运行均由自动预检发现探针，并完成下载、运行和读回；全套 9 类 27 次上板记录见[第一类上板记录](../../board-tests-dsp28335.md)。

这属于自动化调用层问题；不应把 `CONNECT_FAILED` 文本直接解释为板卡掉线。先查看报错是否发生在 `DSS: connected` 之前，再检查 USB 枚举、`.ccxml` 和真正的 JTAG 连接结果。

## 2026-11-07：下载分支回归与构建顺序

- 工程 `4-1Two_Level_CloseLoop`、F28335、XDS100v2、CCS 12.8.1。原始日志在工程 `work/run-20261107-loadrun.log`、`work/run-20261107-loadrun-retry.log`、`work/run-20261107-loadti-direct.log`。探针未插时 `-Run` 返回 `NO_PROBE`；此前构建已经执行，违反“运行前先确认探针”的期望。
- 探针接入后，`ti_c2000_debug.ps1 -Run` 在 PowerShell 7 直接调用 `loadti.bat` 的第 406 行抛 `StandardOutputEncoding is only supported when standard output is redirected`，批处理未启动，却被误分类为 `LOADTI_TIMEOUT`。相同 `loadti` 参数经 `cmd.exe /d /c` 实际完成 `Done`、`Target running...`、退出码 0，说明问题在脚本调用层。
- 修订脚本：新增 `-ProbeCheckOnly`；`-Build -Run` 在编译前查探针，缺失即 `NO_PROBE`/退出码 3；`loadti.bat` 经 `ProcessStartInfo` 启动 `cmd.exe` 并分别捕获标准输出和错误，启动异常分类为 `LOADTI_LAUNCH_ERROR`。离线测试 `tests/test_debug_preflight.ps1`（该文件随后续调试脚本重构**已移除**，现行对应覆盖见 `tests/test_run_modes.ps1`）用含空格路径的假 `loadti.bat` 验证 `RESULT: OK`、退出码 0，并验证无探针时未调用假构建器。真实板上尚未用修订后的脚本再次下载。
- 构建器此前在较新的 CCS 安装中找不到工程声明的 `15.12.1.LTS` 后立即退到 `22.6.1.LTS`，漏查另一处旧版 CCS 安装。修订后先跨所有安装查找精确版本；本工程离线构建实际选中 `ti-cgt-c2000_15.12.1.LTS`，编译链接 `RESULT: OK`、退出码 0。若精确版本不可用，默认 `COMPILER_VERSION_MISSING`，需明确传入 `-AllowCompilerFallback` 才换版本。此次构建没有下载，板上运行固件与新暂存 `.out` 的符号身份不能混用。
