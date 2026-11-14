# 常驻会话读取规则（旧的独立只读模式已删除）

**硬性规则：仿真器必须全程在线；调试器连接一旦断开，就不能再读数据。** `disconnect()` 会结束 JTAG 会话；所谓“断开后另起只读”其实是重新连接一个已经复位、跑 Flash 的目标，读到的不是本次 RAM 固件。这条规则没有例外。

**第二硬性规则：程序只在会话启动时加载一次。** 读数时重新 `connect → loadProgram → run` 等于把程序重启一遍，前后两次读到的不是同一段运行。所以读入口不加载，加载只发生在 `ti_c2000_service.ps1 -Start`。

## 三种情况

| 情况 | 是否允许 | 说明 |
|---|---|---|
| **常驻会话内** `load → runAsynch → 反复附着读` | **唯一允许** | 加载一次，会话不断开，低速/高速读都附着到它 |
| **每次读都重连重载** | **禁止** | 每次都重启程序，两次数据描述两次不同的运行；也是"数据肯定不对"的直接原因 |
| **断开后另起只读** | **禁止** | F28379D 断开会复位跑 Flash（`-1142`）；DSP28335 可能读到 Flash 旧程序（`gRunMs` 不增长、PC 在 Flash） |
| **CCS GUI 手动实时看** | 允许 | Realtime Mode + 目标可调试 + 会话保持；Expressions/Watch 开 Continuous Refresh |

## 正式入口

| 用途 | 入口 | 前提 |
|---|---|---|
| **单步运行（默认）** | `ti_c2000_service.ps1 -Start [-Build] -ConfirmLoad` | 探针在线；`-Build` 只在启动时编译一次；**缺 `-ConfirmLoad` 直接 exit 4，不下载**；`-Status` / `-Stop` 管会话 |
| **连续运行（显式）** | `ti_c2000_iterate.ps1 -UserApproved -Expect ...` | 用户明确要求；每轮停会话 → 构建下载 → 读 → 判据；最多 `-MaxLoads` 次 |
| **低速连续读** | `ti_c2000_run_read.ps1` | 不需要 DMA；默认 0.5 s × 10 轮；附着常驻会话，不加载（会话不在时也要 `-ConfirmLoad` 才自启） |
| **高速 DMA 读** | `ti_c2000_read_dma.ps1 -FrozenBufferReady` | 固件已配 ADC + DMA（+ ping-pong）并置冻结标志/序号；附着同一会话 |
| **会话协议客户端** | `ti_c2000_live_read.ps1` | 由上面两个入口内部调用，不直接使用；只读，从不下载 |
| **判读** | `ti_c2000_check_read.ps1 -CsvPath ...` | 只读 CSV，不连硬件 |
| **下载计数** | `ti_c2000_loadcount.ps1`（库） | 每次真正下载 +1，写 `readout\load-count.json`；`-Stop` 不清零 |

**下载次数必须看得见**：任何一次输出里的 `LOAD : #N` 就是"这是第几次下载"。两次读之间 N 变了，说明中间又烧录过——两份数据不是同一段运行，不能对比。

旧的独立只读入口**已从 skill 中删除**（不是禁用、不是留壳），不要再造：

- ~~`ti_c2000_read_runtime.ps1`~~（已删）
- ~~`ti_c2000_read_array_runtime.ps1`~~（已删）
- ~~`ti_c2000_debug.ps1 -ReadOnly/-ReadVars/-ReadArray/-WaitFor`~~（参数已删；`ti_c2000_debug.ps1` 只剩编译/下载/运行，`-Build`、`-Run`、`-LoadOnly`、`-ProbeCheckOnly`）

留着它们只会让人在“断开后再读”这条路上反复踩坑：入口存在就等于暗示这条路可用。

## 读取前必须确认是 RAM

1. 工程 `.cmd` 是 RAM 链接（如 `2837xD_RAM_lnk_cpu1.cmd`）；
2. `ti_c2000_service.ps1 -Start` 里的 `loadProgram` 把 `.out` 下载到 RAM，之后**不再下载**；
3. 心跳跨轮严格递增（常驻会话不查"启动窗口"——它可能已经跑了几小时）；
4. 会话记录的 `.out` SHA256 与磁盘上的一致，否则 `STALE_SERVICE`（换了固件却没重启会话）；
5. 判据脚本 `ti_c2000_check_read.ps1` 通过（活性 / 冻结窗口 / 范围）。

## 读到 Flash 假数据的当场识别（命中任意一条立即停手）

这是本 skill 最大的一次坑：读数"成功"、`RESULT: OK`、数值也像样，但仿真器早已退出，读到的是 **Flash 里的旧固件**，不是刚下载的 RAM 镜像。不要靠"看起来合理"判断，只看这四条：

| 信号 | 含义 |
|---|---|
| 心跳量跨轮**完全相同**（`gRunMs=11460`、`gMsTick=527` 之类） | 目标没在跑这份固件，或根本没跑 |
| 变量首值等于很久以前的旧读数 / 全 0 | 读的是 Flash 残留或未初始化 RAM |
| `PC` 落在 Flash 段（DSP28335 `0x32xxxx`；F28379D 在 Flash 区），不在 `.map` 里 `.text` 的 RAM 装载地址 | 执行的是 Flash 里的程序 |
| 读值"只是没变化"但目标显示 running | `isHalted()==false` 不能证明在执行本次 `.out` |

发现上述信号就报告"未验证/读到 Flash"，**不要换一个参数再试**，也不要补一次 `-Run` 把读数凑成成功。正确做法只有一个：用 `ti_c2000_run_read.ps1` / `ti_c2000_read_dma.ps1` 重新走一次同会话（加载→运行→读）。

## 判据

见 [data-read-verdict.md](data-read-verdict.md)。缺任何一级都不算读取成功。

## 历史坑（已归档）

- **2026-11-07 DSP28335**：另起只读返回 `RESULT: OK`，但 `gRunMs=11460` 两次不增长、`PC=0x32F06D` 在 Flash，读到的不是刚下载的 RAM 程序。
- **2026-11-14 F28379D**：只 `disconnect()` 后 `gMsTick 527→0`、`isHalted=true`；`HaltOnDisconnect` / `ResetOnDisconnect` / `AutoResetOnDisconnect` 均 `Option not found`；另起只读报 `-1138` / `-1142`。
- **结论**：断开后不读；要读就单会话。详见 [DSS 说明](dss-debug.md) 和 [单会话案例](debug-cases/f28379d/2026-11-14-disconnect-then-read-is-a-bug.md)。
