# F28379D：读数改为"常驻会话 + 附着读取"（2026-11-14）

- 状态：**已上板验证**（一次加载；低速读跨次不归零）
- 器件/目标核：LAUNCHXL-F28379D，CPU1；XDS100v2 探针，无功率负载
- 模块：`ti_c2000_service.ps1`（会话服务）、`ti_c2000_live_read.ps1`（附着读）、`ti_c2000_run_read.ps1` / `ti_c2000_read_dma.ps1`（转发入口）

读数不再每次 `connect → load → run`，改为会话启动时加载一次、之后所有读都附着到同一个会话。

## 一、为什么要改

前一版的 `ti_c2000_run_read.ps1` / `ti_c2000_read_dma.ps1` 各自在一个进程里完成"加载 → 运行 → 读 → 断开"。每次调用都重新 `loadProgram`，等于**每次读数都把程序重启一遍**：

- 同一天连续两次读，`gMsTick` 都从很小重新开始，两次数据描述的其实是两次不同的运行；
- 用户的原话是"不然你搁那疯狂刷新程序，数据肯定不对"；
- 单会话只能避免"断开后再读"，但避免不了"每次读都重启"。

## 二、现在的结构

| 角色 | 文件 | 行为 |
|---|---|---|
| 执行模式（唯一） | `scripts/ti_c2000_service.ps1` | `-Start`：`connect → reset → loadProgram → runAsynch` 后**保持会话**，轮询请求；`-Status` / `-Stop` |
| 会话协议客户端 | `scripts/ti_c2000_live_read.ps1` | 写 `cmd.txt`、读 `res.txt`，落 `readout\data\*.csv` 并调用判读 |
| 低速读入口 | `scripts/ti_c2000_run_read.ps1` | 默认附着会话；会话不在则自动 `-Start` 一次 |
| 高速读入口 | `scripts/ti_c2000_read_dma.ps1` | 同上，读一个冻结窗口 |
| 排障逃生口 | 两个入口的 `-Standalone` | 单进程 load → run → read，会重载程序 |

状态与协议都在 `<project>\readout\.service\`：`state.json`（pid / out / outSha256 / started）、`ready.txt`、`cmd.txt`、`res.txt`、`server.log`。

请求格式：`VARS a|b|c`、`ARRAY name|rows|cols`、`PING`、`STOP`。响应：`HALTED 0|1`、`V <name> <value>`、`A <index> <value>`、`E <msg>`，以 `END` 结束。

## 三、判据随之改变

常驻会话可能已经跑了几小时，因此**不能**再用"心跳首值 ≤ 10000（启动窗口）"判断这是新固件。改为三条：

1. 心跳跨轮严格递增（缺失的候选心跳不算失败，至少一个可读且递增即可）；
2. 冻结窗口在拷贝期间不变（`FrozenFlag` 与 `SeqVar` 前后一致）；
3. 会话持有的 `.out` 的 SHA256 与磁盘一致，否则 `STALE_SERVICE`（换了固件却没重启会话）。

## 四、实现时踩到的坑（都已在代码里修掉）

| 现象 | 原因 | 处理 |
|---|---|---|
| `Paths.get` 报 `Can't find method` | Rhino 不支持 varargs；`Paths.get(String, String...)` 无法解析 | 全部改用 `java.io` 流 |
| `f.delete()` 语法错误 | `delete` 是 JS 关键字，Rhino 不允许当方法名 | 用 `f.toPath()` + `java.nio.file.Files.deleteIfExists(Path)` |
| `cmd /c` 报"文件名、目录名或卷标语法不正确" | `Start-Process -ArgumentList` 数组拼接后引号被重新解释 | 用 `/d /s /c "<整条命令>"` 单字符串，日志由 cmd 自己 `>` 重定向 |
| 变量 `$rounds` 赋值报 Object[]→Int32 转换错 | PowerShell 变量名大小写不敏感，`$rounds` 撞上参数 `$Rounds` | 改名 `$samples` |
| 读数全部失败但目标在跑 | 会话里 `gRunMs`/`usMainLoop` 不存在却被当心跳 | 缺失候选只记 MISSING，不判失败 |

## 五、上板验证（LAUNCHXL-F28379D / CPU1 / XDS100v2）

| 步骤 | 结果 |
|---|---|
| `service.ps1 -Start -Build` | 编译+加载一次，`SERVICE: READY`，pid 记录在 `state.json` |
| `live_read.ps1 -Variables gMsTick,EPwm1Regs.TBPRD -Rounds 3` | `26705 → 27114 → 27540`，`RESULT: OK` |
| 紧接着再读一次 | `44843 → 45256 → 45656`，**没有归零**，pid 未变 —— 证明没有重新加载 |
| `run_read.ps1`（默认路径） | 附着同一 pid，`55750 → 56142 → 56537`，`RESULT: OK` |
| `read_dma.ps1 -FrozenBufferReady` | `FAILURE: NO_FROZEN_FLAG`（本工程固件没有 `gBufFull`），单条结论 |
| `service.ps1 -Stop` → 再 `run_read` | 自动重启新会话（新 pid），读成功 |

`tests/test_single_session_generation.ps1` 增加两条断言：默认路径必须出现 `ti_c2000_live_read.ps1`、必须保留 `-Standalone`；脚本生成路径改用 `-Standalone` 覆盖。6 个测试全 PASS。

## 六、未验证

- DMA **成功**路径：本工程 `1-1DMA_Ping-Pong` 的固件没有冻结标志，只验证了 `NO_FROZEN_FLAG` 与各拒绝路径。
- `reset()` 在多次连接失败后仍报 `Error -1138`（设备拒绝调试模式），此时靠 `halt` 兜底 + `loadProgram` 覆盖 RAM，读数正常；断电重连是否彻底消除未单独验证。
