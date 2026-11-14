# F28379D：单会话 RAM 心跳上板验证

- 状态：**待复核**（本次单会话运行态读数通过；断开后目标状态未在本次测量）
- 器件/目标核：LAUNCHXL-F28379D，CPU1；只接 XDS100v2 与测试板，无功率负载（用户 2026-11-14 确认）。CPU2 未测试。
- 环境：CCS 12.8.1，XDS100v2 序列号 `TI90I42A`，编译器 `ti-cgt-c2000_15.12.1.LTS`，CPU1 RAM/COFF 工程。
- 模块：DSS 连接、RAM 下载、运行态表达式读取与会话边界。

## 现象与原始证据

2026-11-14 用隔离副本中的 `User/main.c` 编译最小心跳程序：只执行 `InitSysCtrl()`，不调用原工程的 `Hardware_Init()` 或设置 GPIO/ePWM/ADC/DAC 输出；每约 1 ms 使 `gBoardPulse` 增 1，固定 `gBoardTestSignature=0x28379D`。原工程未修改。隔离副本与原始记录位于 `C:/Users/Jordon/Documents/Codex/2026-10-27/ti-c2000-ccs-auto/work/board-tests/f28379d-heartbeat-20261114/`；本次原始命令输出为该目录的 `board_run.log`，CSV 与 verdict 在 `readout_20261114_134408_717_56adbe40/`。

运行 `ti_c2000_run_read.ps1 -Build -Variables 'gBoardTestSignature,gBoardPulse' -HeartbeatExpr gBoardPulse -Rounds 3 -IntervalMs 1000 -WarmupMs 500`。探针预检、真实编译/链接、单次 `memory.loadProgram()` 均成功；编译、读数脚本各输出 `RESULT: OK` 且退出码 0。编译警告仅为隔离副本 `main.c` 末尾无换行；另有 TI 公共源码的性能 advice。

对应链接 map 中 `_c_int00=0x8533`、`_main=0x861A`，均在 RAMLS；`_gBoardPulse=0xAC60`、`_gBoardTestSignature=0xAC62`，均在 RAMLS5。这样本次读取的程序与变量位置都有 RAM 证据；不把 Flash 的旧程序视为本次固件。

```text
DSS: connected
DSS: reset failed (... Target reset failed. Error: -1), fallback halt
DSS: halted (load only)
DSS: loaded
DSS: running
VAR gBoardTestSignature@T1/T2/T3 = 2635677 (0x28379D)
VAR gBoardPulse@T1 = 544
VAR gBoardPulse@T2 = 1589
VAR gBoardPulse@T3 = 2650
DSS: target still running before disconnect
DSS: disconnected
HEARTBEAT: OK
RESULT: OK
EXIT_CODE=0
```

`reset()` 失败的具体原因未查明；停核回退只发生在**下载前**。加载后的三轮读取没有主动停核、复位或再次加载。读数之间的心跳递增证明这个 `.out` 的 CPU1 主循环在本次连接期间前进；签名与该构建一致。本次没有在断开后重新连接，所以不能据此判定程序在 `disconnect()` 后继续运行或复位。此前同板的断开后计数归零/停机记录见 [DSS 会话边界](../../dss-debug.md)。

## 适用与待办

- 操作规则：所有新 RAM 固件都先在同一 DSS 会话中加载、运行和读完所需数据；运行态读取和收尾不 `halt()`。跨器件是保守流程，不表示每块板都已证实会在断开时复位。
- 本次只验证单会话脚本的 CPU1 心跳与固定签名；没有测试 ADC、DMA、ePWM 波形、CPU2 或独立只读会话。
- 原用户工程仍有 `EPWMCLK=SYSCLK=200 MHz` 的配置，不能作为合规 ePWM 测试固件下载。TI F2837xD 数据手册规定 `EPWMCLK` 最大 100 MHz；SYSCLK 为 200 MHz 时应分频 2。此项目的 20 kHz 向上计数、其余分频为 1 时应使用 `TBPRD=4999`。参见 [TI 数据手册](https://www.ti.com/lit/ds/symlink/tms320f28379d.pdf)。
