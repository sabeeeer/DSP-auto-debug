# 2026-11-14 F28379D 单会话读取：上板暴力测试与输出契约修复

板卡：LAUNCHXL-F28379D（XDS110，工程 `F28379D_CPU1_Template`，链接 `2837xD_RAM_lnk_cpu1.cmd`）。
入口：`scripts/ti_c2000_run_read.ps1`（低速连续读）、`scripts/ti_c2000_read_dma.ps1`（冻结缓冲读）。
目的：验证"仿真器全程在线、单会话运行态读 RAM"在真实板上不再出现前面的误判，同时把输出契约钉死。

## 一、测试矩阵（真实运行，全部通过）

| 用例 | 命令要点 | 期望 | 实际 |
|---|---|---|---|
| 多类型变量 10 轮 | `-Variables gMsTick,usMainLoop,gEPWM_SineUpdates,gEPWM_SineCycles,EPwm1Regs.TBPRD,EPwm1Regs.CMPA.bit.CMPA,SciaRegs.SCILBAUD.all` | 计数器递增、常量恒定、寄存器可读 | `gMsTick 583→6230`、`TBPRD` 恒 `9999`、`SCILBAUD.all` 恒 `53`、`CMPA` 按正弦变化、`HEARTBEAT: OK`、`RESULT: OK` |
| 长时长 | `-Rounds 200 -IntervalMs 200`（6 变量，1200 个值） | 单调递增、无丢点 | `RESULT: OK`、退出码 0 |
| 空变量列表 | `-Variables ''` | `NEED_VARIABLES` / 退出码 2 | 一致（新增 `[AllowEmptyString()]` 后才不再退化成参数绑定错误 exit 1） |
| 重复变量 | `-Variables gMsTick,gMsTick` | `DUPLICATE_VARIABLES` / 2 | 一致 |
| 轮数 0 / 间隔负数 | `-Rounds 1`、`-IntervalMs -5` | `INVALID_READ_REQUEST` / 2 | 一致 |
| 注入字符 | `-Variables 'gMsTick;Remove-Item'` | 拒绝 / 2 | 一致 |
| 不存在的符号 | `-Variables 'gMsTick,NoSuchVariable_xyz'` | `VALUE_READ_FAILED` / 1 | 一致（修复后 verdict 也变 FAIL，见二.2） |
| 常量心跳 | `-HeartbeatExpr EPwm1Regs.TBPRD` | `HEARTBEAT_FAIL` + `REASON` / 1 | 一致（修复后补 `REASON`，见二.4） |
| 启动窗口 | `-StartupMaxMs 1` | `STALE_PROGRAM` / 1 | 一致 |
| 关闭心跳 | `-NoHeartbeat`，只读常量 | `RESULT: OK` | 一致 |
| `-Build` 集成 | 构建 + 同会话下载读取 | 构建与读取共一次调用、只有一个 `RESULT` | 一致（修复后见二.3） |
| `-OutRoot` | 输出到临时目录 | 只有 `<OutRoot>\readout\` | 一致，无镜像、无时间戳目录 |
| DMA 缺 `-FrozenBufferReady` | — | `BUFFER_NOT_CONFIRMED` / 2 | 一致 |
| DMA 冻结标志不可读 | `-FrozenFlag NoSuchFlagXyz` | `NO_FROZEN_FLAG` / 1 + verdict FAIL | 修复后一致（原先误报 `NO_LIVENESS_EVIDENCE`） |
| DMA 标志永不满足 | `-FrozenValue 12345 -WaitMs 600` | `BUF_NOT_READY` / 1 | 一致 |
| DMA 数组不存在 | `-ArrayName gNotExistBuf`，标志已满足 | `NO_ARRAY` / 1 | 一致 |
| 非法行/列、范围倒置、超大数组 | `-Rows 0`、`-ValueMin 10 -ValueMax 1`、`-Rows 400 -Columns 400` | `BAD_DIMENSIONS` / `INVALID_RANGE` / `ARRAY_TOO_LARGE`，退出码 2 | 一致 |
| 旧只读入口 | `ti_c2000_read_runtime.ps1` / `ti_c2000_read_array_runtime.ps1`（有无参数都试） | `READONLY_UNRELIABLE` / 2 | 修复后一致（原先强制参数在守卫之前绑定失败，退化成 exit 1） |
| `debug.ps1` 旧参数 | `-ReadVars`、`-ReadOnly`、`-WaitFor` | `READONLY_UNRELIABLE` / `WAIT_REQUIRES_SINGLE_SESSION`，退出码 2 | 一致 |
| `check_read.ps1` 边界 | 正常 CSV、行数不符、范围越界、心跳递减、单行、无心跳列、启动窗口、`0x` 十六进制、文件不存在 | `OK` / `EXPECTED_ROWS_MISMATCH` / `RANGE_VIOLATION` / `HEARTBEAT_NOT_ADVANCING` / `NO_LIVENESS_INTERVAL` / `NO_HEARTBEAT` / `STARTUP_WINDOW_VIOLATION` / 接受十六进制 / `NO_CSV` | 一致 |

## 二、本轮修掉的四个缺陷（都是"看起来通过、其实结论错"一类）

1. **`RESULT:` 行重复**：成功时校验器与主脚本各打一条 `RESULT: OK`；失败时诊断回显还会带出 DSS 内部的 `RESULT: OK`，出现"第一条 RESULT 是 OK、实际 FAIL"。现在：子脚本、校验器、诊断回显一律过滤 `^RESULT:`，每次调用只有一条 `RESULT:`，以最后一条 + 退出码为准。
2. **失败保留上一次的 OK**：`verdict.txt` 在失败路径不重写，上一轮成功留下的 `result: OK` 与 `data.csv` 原样留着，失败会被看成成功。现在：定义在会话开始之前的 `Publish-Readout` / `Fail-Readout` 负责在任一失败路径改写为 `result: FAIL` + `failure:` + `reason:`，并删除上一轮的 `data.csv` / `array.csv` / `variables.csv`。
3. **`-Build` 时出现两个 `RESULT`**：构建脚本自己的 `RESULT: OK` 被原样回显。现在：构建输出过滤 `^RESULT:`，改为打印 `BUILD   : OK`。
4. **心跳失败没有 `REASON`**：只打 `FAILURE: HEARTBEAT_FAIL`。现在：`REASON` 里点名哪几路心跳不递增。

另外两处同类小坑：已禁用脚本的强制参数会在守卫之前绑定失败（改为可选参数，保证任何调用方式都返回 `READONLY_UNRELIABLE` / 2）；`-Variables ''` 同理。

## 三、回归保护

新增 `tests/test_readout_contract.ps1`（静态、无需上板）：固定 `readout\` 目录、禁止时间戳目录与镜像、脚本内成功 `RESULT` 只有一处、`^RESULT:` 过滤点 ≥2、失败发布函数必须定义在 DSS 会话开始之前。已实测可拦截上述 1/2/3 类回退。

## 四、仍然存在的限制（不许含糊）

- `ti_c2000_read_dma.ps1` 一次调用只读**一个冻结窗口**。本工程没有 ADC+DMA 固件（`User/` 下没有缓冲数组），因此 DMA 成功路径（真实搬数据、范围判据）**未在本板上验证**，只验证了全部拒绝路径。
- `-Rounds × -IntervalMs` 是主机侧名义时长，单轮开销约几十毫秒（心跳读 + 时间戳），实际间隔略大于设定值；不要把 `hostMs` 当精确采样周期。
- 连接首轮仍可能遇到 `reset failed ... fallback halt`（XDS110 在目标运行态被接管时的常见表现），脚本按"仅 halt + load"继续，属于预期路径，不是失败。
