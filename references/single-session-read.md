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
| **单步运行（默认运行模式）** | `ti_c2000_service.ps1 -Start [-Build] -ConfirmLoad` | 探针在线；`-Build` 只在启动时编译一次；**缺 `-ConfirmLoad` 直接 exit 4，不下载**；`-Status` / `-Stop` 管会话；`state.json` 记 `runMode=SingleStep` |
| **连续运行（显式运行模式）** | `ti_c2000_iterate.ps1 -UserApproved -Expect ...` | 用户明确要求；每轮停会话 → 构建下载（`-RunMode Iterate`）→ ReadOnly 读 → 判据；最多 `-MaxLoads` 次；无 `-UserApproved` 即 `ITERATE_NOT_APPROVED` exit 4 |
| **低速读 · `-Mode ReadOnly`（默认）** | `ti_c2000_run_read.ps1` | 不需要 DMA；默认 0.5 s × 10 轮；**零下载**，缺会话直接 `NO_SESSION` exit 4；读之前过四道证明：探针在线（`-NoProbeCheck` 可跳）+ 会话存活 + sha256 一致 + RAM 地址 |
| **低速读 · `-Mode LoadRead`** | `ti_c2000_run_read.ps1 -Mode LoadRead -ConfirmLoad` | 停常驻会话 → 下载一次 → 读；`-MaxLoads/-Expect` 可循环；`-Standalone` 是它的别名 |
| **高速 DMA 读** | `ti_c2000_read_dma.ps1 -FrozenBufferReady` | 固件已配 ADC + DMA（+ ping-pong）并置冻结标志/序号；附着同一会话，两种 `-Mode` 与低速读一致 |
| **会话协议客户端** | `ti_c2000_live_read.ps1` | 由上面两个入口内部调用，不直接使用；只读，从不下载 |
| **判读** | `ti_c2000_check_read.ps1 -CsvPath ...` | 只读 CSV，不连硬件 |
| **下载计数** | `ti_c2000_loadcount.ps1`（库） | 每次真正下载 +1，写 `readout\load-count.json`，`lastMode` = `SingleStep`/`Iterate`/`LoadRead`/`Explicit`；`-Stop` 不清零 |
| **互锁库** | `ti_c2000_readmode.ps1`（库） | 运行模式 × 读模式的全部闸门、RAM 判据、目标锁与连续运行标记都在这里 |

### 两个维度与互锁

运行模式（程序多久上一次板）与读模式（这次读要不要下载）是**正交**的，交叉时按下表裁决；每条都只打一行 `FAILURE:` 并返回一个退出码，不会崩、不会执行到一半：

| 组合 | 结果 |
|---|---|
| `ReadOnly` + `-ConfirmLoad` / `-Build` / `-Expect` / `-MaxLoads>1` | `MUTUALLY_EXCLUSIVE` exit 2 |
| `LoadRead`（含 `-Standalone`）缺 `-ConfirmLoad` | `LOAD_NOT_CONFIRMED` exit 4 |
| `LoadRead` + `-AllowUnverified` / `-NoProbeCheck` | `MUTUALLY_EXCLUSIVE` exit 2（两者只属于 ReadOnly） |
| `ReadOnly` 但 Windows 没枚举到探针 | `NO_PROBE` exit 3 |
| `ReadOnly` 时没有存活会话 | `NO_SESSION` exit 4 |
| 会话存在但 `sha256(out)` 与 state 不符 | `STALE_SERVICE` exit 2 |
| 入口符号 `main`（裸符号名）/ `_c_int00` ≥ 0x080000（跑的是 Flash 镜像） | `NOT_RAM_IMAGE` exit 4 |
| 入口符号读不到（无法证明 RAM） | `RAM_UNVERIFIED` exit 4（`-AllowUnverified` 才放行，并写日志） |
| 连续运行无 `-UserApproved` | `ITERATE_NOT_APPROVED` exit 4 |
| 连续运行期间外部 `ReadOnly` | `READONLY_IN_ITERATE` exit 4 |
| 连续运行期间外部 `LoadRead` | `MUTUALLY_EXCLUSIVE` exit 2 |
| 连续运行期间外部 `-Start/-Stop`、第二个 iterate | `ITERATE_IN_PROGRESS` exit 4 |
| 另一进程持有目标 | `TARGET_BUSY` exit 5 |
| 连续运行跑到 `-MaxLoads` 仍未满足 `-Expect` | `ITERATE_NOT_CONVERGED` exit 1 |
| 连续运行中进程已死留下的标记 | 自动忽略（标记里带 pid），不长期锁项目 |

**下载次数必须看得见**：任何一次输出里的 `LOAD : #N` 就是"这是第几次下载"。两次读之间 N 变了，说明中间又烧录过——两份数据不是同一段运行，不能对比。

### 为什么保留只读模式（它和"下载后读"是同一件事的两半）

"下载后读"在实现上就是 `service -Start`（下载一次）+ 反复 `ReadOnly`（零下载），所以两者不是二选一。只读不可替代的四个场合：

| 场合 | 为什么必须零下载 |
|---|---|
| 连续运行（`iterate`）的每轮读 | 每轮都重下载的话，读到的永远是"刚重启的那一瞬"，判据永远不收敛 |
| 保留现场 | 跑飞 / 进 fault / 触发保护时，一读就重下载等于把当时的状态机位置、故障标志全部抹掉 |
| 程序固化在 Flash 运行时 | `loadProgram` 会擦写 Flash，有寿命成本；只读完全不写 |
| 同一镜像反复对照 | 只读约 1 s/次（含约 1 s 的探针枚举，`-NoProbeCheck` 可省），重下载要 10~30 s 且重启程序，累积计数器被清零、前后不可比 |

它唯一的短板是"板上不一定是我刚编的这版"，而这正好由第 ③ 道证明（`sha256(out) == state.outSha256`）兜住：不一致就 `STALE_SERVICE` 拒绝，不会拿旧数据冒充新数据。**验收一次就走的场景用 `-Mode LoadRead` 最短**，不需要常驻会话。

旧的独立只读入口**已从 skill 中删除**（不是禁用、不是留壳），不要再造：

- ~~`ti_c2000_read_runtime.ps1`~~（已删）
- ~~`ti_c2000_read_array_runtime.ps1`~~（已删）
- ~~`ti_c2000_debug.ps1 -ReadOnly/-ReadVars/-ReadArray/-WaitFor`~~（参数已删；`ti_c2000_debug.ps1` 只剩编译/下载/运行，`-Build`、`-Run`、`-LoadOnly`、`-ProbeCheckOnly`）

留着它们只会让人在“断开后再读”这条路上反复踩坑：入口存在就等于暗示这条路可用。

## 慢速读的时限与适用条件（轮询，不是采样示波器）

慢速读（`ti_c2000_run_read.ps1`）是"隔一段时间向目标要一次当前值"的**轮询**，采样时刻由 PC 侧决定、精度只到几十毫秒，不是板上定时器采样。一轮的时间由三段组成：

| 段 | 本机实测/取值 | 说明 |
|---|---|---|
| 服务端 DSS 求值 | 约 10~50 ms | 每次请求在 DSS 里求一次表达式 |
| 协议往返 | `Start-Sleep -Milliseconds 40` 实测 **47 ms**（42.9~55.8），文件往返 0.6 ms | 写 `cmd.txt` → 每 40 ms 查一次 `res.txt` |
| `-IntervalMs` | 默认 500 ms | 两次采样之间的主动等待 |
| **单轮周期 S** | **S ≈ IntervalMs + 50~120 ms**；默认 **≈ 0.55~0.62 s** | 抖动可达 ±1 个轮询窗口（约 ±40 ms） |

- **点数 = `-Rounds`**（默认 10），与数据更新率无关。
- **总时长 ≈ Rounds × S**，必须小于 `-TimeoutSec`（默认 600 s）→ 默认配置最多约 1000 点／10 分钟；要更久就同时加 `-Rounds` 和 `-TimeoutSec`。
- 想更快只能压 `-IntervalMs`；压到 0 时 S 就等于工具开销（约 50~120 ms），即**慢速读的采样上限约 8~20 Hz**。

### 什么数据能用慢速读（三条全满足）

1. **被测量的变化周期 ≥ 10 × S**（能看清形状）；只判趋势/方向可放宽到 ≥ 3 × S。默认 S≈0.6 s → 变化周期 ≥ 6 s，看趋势 ≥ 2 s。
2. **不需要等间隔、不需要精确时刻**：采样点有 ±40 ms 级抖动 → 不能用来测频率、相位、占空比、抖动。
3. **两次采样之间没有有意义的瞬变**：累加计数、最终稳定状态、故障标志可以；脉冲、单次事件、"每 100 ms 变一次"的序列不行。

### 算例：100 ms 更新一次的数据（10 Hz）

默认 S≈0.55 s → 采样率约 **1.8 Hz**，对 10 Hz 的信号欠采样 **5.5 倍**：

| 问题 | 答案 |
|---|---|
| 能读多少点 | 点数 = `-Rounds`，与更新率无关；默认 10 点，跨度约 5.5 s |
| 数值本身对吗 | **对**。每次是在目标内存上做一次 DSS 求值，单个 16/32 位值不会被撕裂，也不是"分几次拼"出来的 |
| 能还原这个 100 ms 序列吗 | **不能**。1.8 Hz 对 10 Hz 欠采样 5.5 倍，相邻两点之间漏掉约 5~6 次更新，得到的是跳号抽样；画成曲线是**混叠出的假波形** |
| 还能算什么 | 单调量的平均速率 `(v2−v1)/Δt`（Δt 用 CSV 的 `hostMs` 实测差）、最终稳定值、状态趋势 |
| 要看每一点 | 慢速读做不到（工具开销已 50~120 ms）→ 用 `ti_c2000_read_dma.ps1`：固件按 100 ms（或更快）写入缓冲并置冻结标志/序号，一次 `readData` 搬整个窗口，采样时刻由定时器决定、µs 级对齐 |

一句话：**慢速读回答"现在是多少"，不回答"这一百毫秒里发生了什么"。变化周期接近或短于 S 的信号，读数会"对但没用"。**

### 先量一次自己板子的工具开销（不要照抄上表）

```powershell
pwsh -NoProfile -File <skill>\scripts\ti_c2000_run_read.ps1 -ProjectPath "<工程>" `
  -Variables gMsTick -Rounds 20 -IntervalMs 0
# 打开 <工程>\readout\data\data.csv：相邻两行 hostMs 的差 = 本机真实单轮开销 T
# 之后一律用 S = IntervalMs + T 估算，再套上面三条判据
```

`-IntervalMs 0` 就是"最快能多快"，这个数决定慢速读在本机的上限频率；换电脑、换探针、换 DSS 版本都重新测一次。

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
