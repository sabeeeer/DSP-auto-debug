# F28379D：两种运行模式 × 两种读模式 + 互锁 + 下载次数统计（2026-11-14）

- 状态：**已回归（脚本层）**
- 器件/目标核：LAUNCHXL-F28379D，CPU1；XDS100v2 探针（本次只做脚本层验证，未重复上板烧录）
- 模块：`ti_c2000_service.ps1`、`ti_c2000_iterate.ps1`、`ti_c2000_readmode.ps1`（互锁库）、`ti_c2000_loadcount.ps1`（计数库）、两个读入口

## 触发（用户原话）

> 第一种单步运行模式，只编译下载一次，开始运行。直到我说要编译下载再运行，完完全全防止全自动的编译下载运行……不然老是会出问题，频繁编译下载伤机器，而且打乱数据。低速读和高速度就不要执行重新下载了……第二种就是连续运行模式，就是频繁编译下载，自己读数据，数据不对，再编译下载直到数据对的。另外，我希望脚本有下载的次数，这是第几次下载，要自己统计下载次数。

> 执行模式，等同于运行模式，我的连续运行模式呢。。。不是前面和你说了有两种模式吗。平常就是单步运行，常驻。但当我说，连续运行，你再用连续模式，频繁编译和下载。记得互锁。

要求：**两个正交维度**——运行模式（单步常驻 / 连续反复下载）与读模式（只读 / 下载后读）；**默认绝不自动下载**；**连续模式只在用户点名时开**；**互锁、有条理、不能乱调用崩溃**；**每次下载可数**。

## 设计：两个维度

|  | 单步运行（默认） | 连续运行（显式） |
|---|---|---|
| 语义 | 加载一次，常驻，读全部附着 | 每轮「停会话 → 构建下载 → 读 → 判据」，直到数据对 |
| 入口 | `ti_c2000_service.ps1 -Start -ConfirmLoad` | `ti_c2000_iterate.ps1 -UserApproved -Expect ...` |
| 闸门 | 缺 `-ConfirmLoad` → exit 4 `LOAD_NOT_CONFIRMED`，不编译不下载不重启 | 缺 `-UserApproved` → exit 4 `ITERATE_NOT_APPROVED`；`-MaxLoads` 默认 5、上限 20 |
| 记录 | `state.json.runMode=SingleStep`，计数 `lastMode=SingleStep` | 每轮 `-RunMode Iterate`，计数 `lastMode=Iterate` |

|  | `-Mode ReadOnly`（默认） | `-Mode LoadRead`（显式） |
|---|---|---|
| 下载 | **零下载** | 下载一次（`-MaxLoads N` 可循环到 `-Expect` 满足） |
| 前置证明 | 会话存活 + `sha256(out)==state.outSha256` + `&main`/`&c_int00` < 0x080000 | 需 `-ConfirmLoad`；`-Standalone` 是它的别名 |
| 失败 | `NO_SESSION`/`STALE_SERVICE`/`NOT_RAM_IMAGE`，绝不偷偷下载凑数 | `LOAD_NOT_CONFIRMED` exit 4 |

## 互锁（全部在任何 DSS 动作之前判定）

| 组合 | 结果码 |
|---|---|
| `ReadOnly` + `-ConfirmLoad`/`-Build`/`-Expect`/`-MaxLoads>1` | `MUTUALLY_EXCLUSIVE` exit 2 |
| `LoadRead`（含 `-Standalone`）缺 `-ConfirmLoad` | `LOAD_NOT_CONFIRMED` exit 4 |
| `ReadOnly` 无存活会话 | `NO_SESSION` exit 4 |
| 连续运行无 `-UserApproved` | `ITERATE_NOT_APPROVED` exit 4 |
| 连续运行期间外部 `ReadOnly` | `READONLY_IN_ITERATE` exit 4 |
| 连续运行期间外部 `LoadRead` | `MUTUALLY_EXCLUSIVE` exit 2 |
| 连续运行期间外部 `-Start/-Stop`、第二个 iterate | `ITERATE_IN_PROGRESS` exit 4 |
| 另一进程持锁 | `TARGET_BUSY` exit 5 |
| `-Status` | 任何模式都可查 |

连续运行用 `readout\iterate\active.json` 声明占用（含 pid）：轮次之间会话被停掉，没有这个标记就会有窗口让外部插进来。**标记的 pid 死了就自动忽略**，崩溃不会永久锁死项目。只有循环自己的子进程（`TI_C2000_ITERATE_CHILD=1`）能在标记下工作。

## 计数

`<工程>\readout\load-count.json`：`count / firstLoad / lastLoad / lastSha256 / lastMode / history(最近 20)`。`lastMode` ∈ `SingleStep | Iterate | LoadRead | Explicit`，写入点在**真正写入目标之后**（`service -Start` 成功、`LoadRead` 的 `-Standalone`/`-Mode LoadRead` 成功、`ti_c2000_debug.ps1 -Run/-LoadOnly` 成功）。`-Stop` 只删 `.service\` 下的会话文件，**不动**计数，所以"第几次下载"跨会话累计。输出统一 `LOAD    : #7 (this is download number 7 for this project, previous 6)`。

读输出里的 `LOAD #N` 来自 `state.json.loadIndex`；两次读之间 N 变了，说明中间又烧录过，数据不可比。

## 连续模式一轮做了什么

1. `service -Stop`（释放上一轮会话）
2. `service -Start -Build -ConfirmLoad -RunMode Iterate -UserApproved` → `LOAD #N` 递增
3. `run_read -Mode ReadOnly`（附着刚启动的会话，**不额外下载**，仍走 RAM/sha/心跳判据）
4. 取 `readout\data\data.csv` 最后一行 → `Test-LoadExpectation`
5. 满足 → `RESULT: OK` exit 0；否则下一轮；用尽 → `ITERATE_NOT_CONVERGED` exit 1

判据支持 `name>=value`、`<=`、`==`、`!=`、`>`、`<`；**表达式写错或变量缺失一律算失败**（`UNPARSED`/`MISSING`），避免拼错的判据被当成"数据对了"。每轮证据留在 `readout\iterate\round-N\`（`round.log` + `data.csv`）。`-Expect` 为空时"读成功"即收敛。**构建/下载失败立即终止**（不会自己好），读失败才进下一轮。

## 证据（自动化）

`tests/test_run_modes.ps1` 八组全过（无硬件，stub 探针）：

1. 计数接受四种合法 mode、拒绝未知名字、`history` 封顶 20 且末条最新
2. `service -Start -RunMode Iterate` 无 `-UserApproved` → exit 4 `ITERATE_NOT_APPROVED`，不留 `state.json`
3. `iterate` 无 `-UserApproved` → exit 4 `ITERATE_NOT_APPROVED`，不留标记、计数不变
4. `-Start` 无 `-ConfirmLoad` / `LoadRead` 无 `-ConfirmLoad` / `-Standalone` 无 `-ConfirmLoad` → exit 4 `LOAD_NOT_CONFIRMED`
5. `ReadOnly` + `-ConfirmLoad`/`-Build`/`-Expect` → exit 2 `MUTUALLY_EXCLUSIVE`（`-Standalone` 是 LoadRead 别名，不在此列）
6. `ReadOnly` 无会话（低速与 DMA）→ exit 4 `NO_SESSION`，计数不变
7. 造一个存活 pid 的连续运行标记：外部 `ReadOnly` → `READONLY_IN_ITERATE`(4)、`LoadRead` → `MUTUALLY_EXCLUSIVE`(2)、`-Start`/`-Stop`/第二个 iterate → `ITERATE_IN_PROGRESS`(4)、`-Status` 仍 `RESULT: OK` 且报 `RUN MODE`
8. 标记 pid 已死 → 被忽略（`ReadOnly` 回到 `NO_SESSION`）；带确认的 `LoadRead` 走到探针检查（`PROBE_CHECK_FAILED` exit 2）且**锁已释放、计数不变**

`check_debug_catalog.ps1` 通过。

## 边界与未验证

- **连续模式尚未上板跑满一轮**（会重复烧录，需用户点名）。脚本层行为已回归；真机首跑需确认每轮 `LOAD #N` 递增且 `readout\iterate\round-N` 留证。
- 计数只算"成功下载"，失败的构建不计入——符合"真正写目标才伤机器"的口径。
- 计数器文件损坏时只丢历史，不阻断加载（`Get-LoadCount` 吞异常返回 0）；手工清零会从 #1 重新开始，属预期。
- `-ConfirmLoad` / `-UserApproved` 是**流程开关，不是权限**：脚本无法验证"用户真的同意了"。价值在于把"顺手自动下载"变成"必须显式写出来的一次决定"，漏写就直接失败而不是默默烧录。
- `ti_c2000_debug.ps1` 是显式执行命令（用户说"下载运行"才调），保留无闸但计数；自动路径全部有闸。
