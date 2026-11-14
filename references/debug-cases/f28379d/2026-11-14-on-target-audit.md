# 2026-11-14 全功能上机审计：4 个真缺陷

板卡：LAUNCHXL-F28379D（CPU1，RAM 调试）+ XDS100v2，工程 `F28379D_CPU1_Template`。
方法：不碰硬件的 25 项 + 上机 18 项 + 位域/判据/并发 12 项，共触发 10 次下载（LOAD #2…#11）。

## 缺陷 1（严重）连续运行结束后，工程再也读不了

**症状**：跑过一次 `ti_c2000_iterate.ps1 -MaxLoads 2`（成功收敛）之后，任何 `-Mode ReadOnly` 都返回：

```text
FAILURE: READONLY_IN_ITERATE
REASON: continuous run in progress (pid 7848, round 5/0, live session)
```

`round 5/0` 的 `maxLoads=0` 是破绽：这个"循环"根本没有 maxLoads，它不是循环。

**成因**：`Get-RunModeInfo` 有两处判据——`readout\iterate\active.json`（marker）和**存活会话的 `state.runMode`**。
iterate 循环结束时会保留最后一轮的常驻会话，它的 `state.runMode` 仍是 `Iterate`，于是被判成"循环仍在进行"。
marker 在 `finally` 里已清掉，但会话没改，这个残留会**永久**挡住只读。

**修复**：
1. `Get-RunModeInfo`：`active` 只认 marker；遗留会话的 `runMode=Iterate` 只作为 `mode` 报告，不再当占用。
2. `ti_c2000_iterate.ps1` 的 `finally`：把遗留会话的 `runMode` 改回 `SingleStep`。
3. `service -Status`：区分「正在跑」与「上一次连续运行留下的镜像」：
   `SingleStep (image left by a finished continuous run; reads attach)`。

**回归**：`tests/test_state_chaos.ps1` 新增「leftover Iterate session must not block reads」与「live marker does block reads」两条。

## 缺陷 2（严重）心跳读不到 → 好数据被判成坏数据

**症状**：读一组不含心跳量的变量（完全合法的用法）：

```text
pwsh -File ti_c2000_run_read.ps1 -Variables EPwm1Regs.TBPRD -Mode ReadOnly
...
CHECK heartbeat gMsTick: MISSING (not defined in this build)
CHECK heartbeat gRunMs: MISSING (not defined in this build)
CHECK heartbeat usMainLoop: MISSING (not defined in this build)
HEARTBEAT: FAIL
FAILURE: HEARTBEAT_FAIL
```

但同一个会话里 `gMsTick` 明明能读到（写进 `-Variables` 就正常）。

**成因**：心跳值取自 `$samples[].vars[$hn]`，而 `vars` 来自请求 `VARS <names>`——
心跳表达式**从未进入请求**。所以只有恰好出现在 `-Variables` 里的候选才有值。
于是"读寄存器"这类请求必然把三个候选全判 MISSING，进而 `HEARTBEAT_FAIL`：
把活着的目标判成"数据不可信"。

**中途试过的错方案**：把心跳并入同一个 `VARS` 请求。结果更糟——本板未定义的 `gRunMs`
让整批返回 `E`，合法的寄存器读直接变成 `VALUE_READ_FAILED`。
**未定义的候选是正常情况**（文档自己写了），不能让它拖垮整批。

**修复**：心跳用**独立、容错**的请求（`Request-Soft`，`identifier not found` 不算错），
第 1 轮探测哪些候选可读，之后只读这些；值合并进 sample 但不写进 CSV 列。

## 缺陷 3（中）`-NoHeartbeat` 反而必然失败

**成因**：`$hbOk` 初始 `$false`，`-NoHeartbeat` 让候选为空 → 循环不执行 → 末尾
`if (-not $hbOk) { FAILURE: HEARTBEAT_FAIL }` 照样触发。"跳过判活性"变成了"判活性失败"。

**修复**：`if ($heartbeats.Count -gt 0 -and -not $hbOk)`，并在 REASON 后加 HINT。

## 缺陷 4（中）CSV 判据要求心跳列，与实时判定重复

**症状**：实时心跳已 `HEARTBEAT: OK`，随后判据仍报 `FAILURE: NO_HEARTBEAT`。

**成因**：`live_read` 把可读心跳列表传给 `ti_c2000_check_read.ps1 -HeartbeatVars`，
但 CSV 只写用户 `-Variables` 的列；心跳不在其中时列不存在 → 判据失败。

**修复**：CSV 判据统一 `-AllowNoHeartbeat`——活性的权威判据是 live 采样（跨轮、实时），
比"CSV 里有没有一列"更强。

## 顺带：`.bit.` 提示

`AdcaRegs.ADCCTL1.ADCPWDNZ` → `member 'ADCPWDNZ' not found`（2837x 的位在 `ADCCTL1.bit` 里）。
现在错误消息直接给写法：

```text
HINT    : on C2837x a control bit sits in a bitfield - write Reg.BITFIELD.bit.NAME, e.g. AdcaRegs.ADCCTL1.bit.ADCPWDNZ
```

## 本次确认正常的部分

- 四道证明：探针枚举 / 会话存活 / `sha256` 一致 / `main = 0x00008A8D < 0x080000`。
- 门禁 10 种组合全部按文档拒绝（互斥、无确认、无批准、非法模式、注入变量名、重复变量、脏工程）。
- 并发互锁在真实 iterate 运行中全部正确：`READONLY_IN_ITERATE` / `MUTUALLY_EXCLUSIVE` /
  `ITERATE_IN_PROGRESS`，且 `-Status` 仍可读。
- `TARGET_BUSY`（exit 5）用真实活 pid 持锁验证通过。
- 下载计数与 `lastMode` 全程准确：`#2=SingleStep #3/#4=LoadRead #5…#11=Iterate/SingleStep`。
- 只读 11 次，`load-count.json` 未变。
- 两个工程（`F28379D_CPU1_Template`、`F28379D_CPU1_BareMetal`）都能编译。
