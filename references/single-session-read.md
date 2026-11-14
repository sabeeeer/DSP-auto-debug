# 单会话读取规则（旧的独立只读模式已删除）

**硬性规则：仿真器必须全程在线；调试器连接一旦断开，就不能再读数据。** `disconnect()` 会结束 JTAG 会话；所谓“断开后另起只读”其实是重新连接一个已经复位、跑 Flash 的目标，读到的不是本次 RAM 固件。这条规则没有例外。**仿真器在线 + 单会话**是读取 RAM 运行态数据的唯一前提。

## 三种情况

| 情况 | 是否允许 | 说明 |
|---|---|---|
| **同一 DSS 会话内** `load → runAsynch → 读` | **唯一允许** | 连接全程不断开；读发生在 `runAsynch` 之后 |
| **断开后另起只读** | **禁止** | F28379D 断开会复位跑 Flash（`-1142`）；DSP28335 可能读到 Flash 旧程序（`gRunMs` 不增长、PC 在 Flash） |
| **CCS GUI 手动实时看** | 允许 | Realtime Mode + 目标可调试 + 会话保持；Expressions/Watch 开 Continuous Refresh |

## 两个正式入口

| 用途 | 入口 | 前提 |
|---|---|---|
| **低速连续读** | `ti_c2000_run_read.ps1` | 不需要 DMA；默认 0.5 s × 10 轮（名义 5 s，实际含读取开销约 6 s）；时长 = `-Rounds` × `-IntervalMs`，100 s 用 `-Rounds 200 -IntervalMs 500` |
| **高速 DMA 读** | `ti_c2000_read_dma.ps1 -FrozenBufferReady` | 固件已配 ADC + DMA（+ ping-pong）并置冻结标志/序号 |

旧的独立只读入口**已从 skill 中删除**（不是禁用、不是留壳），不要再造：

- ~~`ti_c2000_read_runtime.ps1`~~（已删）
- ~~`ti_c2000_read_array_runtime.ps1`~~（已删）
- ~~`ti_c2000_debug.ps1 -ReadOnly/-ReadVars/-ReadArray/-WaitFor`~~（参数已删；`ti_c2000_debug.ps1` 只剩编译/下载/运行，`-Build`、`-Run`、`-LoadOnly`、`-ProbeCheckOnly`）

留着它们只会让人在“断开后再读”这条路上反复踩坑：入口存在就等于暗示这条路可用。

## 读取前必须确认是 RAM

1. 工程 `.cmd` 是 RAM 链接（如 `2837xD_RAM_lnk_cpu1.cmd`）；
2. `loadProgram` 把 `.out` 下载到 RAM；
3. 心跳首值在启动窗口内（`gMsTick`/`gRunMs` ≤ 10000）且跨轮严格递增；
4. 判据脚本 `ti_c2000_check_read.ps1` 通过（身份 / 活性 / 冻结窗口 / 范围）。

## 判据

见 [data-read-verdict.md](data-read-verdict.md)。缺任何一级都不算读取成功。

## 历史坑（已归档）

- **2026-11-07 DSP28335**：另起只读返回 `RESULT: OK`，但 `gRunMs=11460` 两次不增长、`PC=0x32F06D` 在 Flash，读到的不是刚下载的 RAM 程序。
- **2026-11-14 F28379D**：只 `disconnect()` 后 `gMsTick 527→0`、`isHalted=true`；`HaltOnDisconnect` / `ResetOnDisconnect` / `AutoResetOnDisconnect` 均 `Option not found`；另起只读报 `-1138` / `-1142`。
- **结论**：断开后不读；要读就单会话。详见 [DSS 说明](dss-debug.md) 和 [单会话案例](debug-cases/f28379d/2026-11-14-disconnect-then-read-is-a-bug.md)。
