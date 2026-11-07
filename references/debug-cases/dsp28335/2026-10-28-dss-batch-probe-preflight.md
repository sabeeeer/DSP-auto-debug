# DSS 批处理启动与探针预检误报

## 身份与适用范围

- TMS320F28335 当前 `2-1SOGI_PLL` 板；CCS 12.8.1、CGT 22.6.1.LTS；XDS100v1，序列号 `TI1P9CM8`。
- 模块：`scripts/ti_c2000_debug.ps1` 的 Windows/PowerShell 7 外部工具调用与探针预检。
- 状态：**已回归**。仅实测此 Windows 安装、CCS 和探针组合；其他 CCS 版本、XDS 型号需另测。

## 现象与原始证据

- 首次只读探测在启动 `dss.bat` 前失败，PowerShell 报 `StandardOutputEncoding is only supported when standard output is redirected`，脚本给出 `FAILURE: CONNECT_FAILED`。原始日志：`C:\Users\Jordon\Documents\Codex\2026-10-27\ti-c2000-ccs-auto\work\board-tests\probe-readonly.log`。这次没有下载、复位或访问目标板。
- `Get-CimInstance Win32_PnPEntity` 在本机报“更具体的错误代码不包含发生的常规错误”，导致原脚本的预检可能误判“无探针”。TI 自带 `F:\ccs\ccs_base\common\uscif\xds100serial.exe -l` 同时明确列出 `0403/a6d0 XDS100v1/v2 TI1P9CM8 Texas Instruments XDS100+RS232 V1.0`。

## 定位、修复与回归

- 用 `cmd.exe /d /s /c` 启动 CCS 的 `.bat` 包装器，分别给批处理和脚本路径加引号；先以只打印 `DSS_SMOKE_OK` 的 JS 验证进程能启动、退出码 0，再做只读板上连接。`loadti.bat` 分支采用同样的调用方式，已用 CPU Timer 固件做 `-LoadOnly` 上板回归：日志 `work\board-tests\loadti-smoke.log` 出现连接、加载、`Done`、`RESULT: OK`、退出码 0；目标保持加载后暂停。
- 预检先尝试 Windows CIM；失败时调用 CCS 自带 `xds100serial.exe -l` 识别 XDS100。跳过预检的 `-NoProbeCheck` 不再触发无用的 CIM 查询。
- 修复后只读探测出现 `DSS: connected`、寄存器读回、`DSS: done`、`RESULT: OK`、退出码 0：`work\board-tests\probe-readonly-retry.log`。随后不带 `-NoProbeCheck` 的探测也读到探针和目标变量，`RESULT: OK`、退出码 0：`work\board-tests\probe-fallback.log`。
- 之后 eCAP APWM、DMA、eCAN、McBSP 共 12 次板上运行均由自动预检发现探针，并完成下载、运行和读回；全套 9 类 27 次上板记录见[第一类上板记录](../../board-tests-dsp28335.md)。

这属于自动化调用层问题；不应把 `CONNECT_FAILED` 文本直接解释为板卡掉线。先查看报错是否发生在 `DSS: connected` 之前，再检查 USB 枚举、`.ccxml` 和真正的 JTAG 连接结果。
