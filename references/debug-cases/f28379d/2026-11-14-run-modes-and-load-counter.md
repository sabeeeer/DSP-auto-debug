# F28379D：两种运行模式（单步 / 连续）+ 下载次数统计（2026-11-14）

- 状态：**已回归（脚本层）**
- 器件/目标核：LAUNCHXL-F28379D，CPU1；XDS100v2 探针（本次只做脚本层验证，未重复上板烧录）
- 模块：`ti_c2000_service.ps1`、`ti_c2000_iterate.ps1`（新）、`ti_c2000_loadcount.ps1`（新）、两个读入口的确认闸

## 触发（用户原话）

> 第一种单步运行模式，只编译下载一次，开始运行。直到我说要编译下载再运行，完完全全防止全自动的编译下载运行……不然老是会出问题，频繁编译下载伤机器，而且打乱数据。低速读和高速度就不要执行重新下载了……第二种就是连续运行模式，就是频繁编译下载，自己读数据，数据不对，再编译下载直到数据对的。另外，我希望脚本有下载的次数，这是第几次下载，要自己统计下载次数。

三个要求：**默认绝不自动下载**、**连续模式必须显式开启**、**每次下载可数**。

## 设计

| 运行模式 | 谁能下载 | 闸门 |
|---|---|---|
| 单步（默认） | 只在用户答"是"之后，一次 | `-Start` / 读入口自启 / `-Standalone` 缺 `-ConfirmLoad` → exit 4（`LOAD_NOT_CONFIRMED` / `RELOAD_BLOCKED`），不编译、不下载、不重启 |
| 连续 | 每轮都下载，直到判据满足 | `ti_c2000_iterate.ps1` 必须 `-UserApproved`，否则 exit 4（`ITERATE_NOT_APPROVED`）；`-MaxLoads` 默认 5、上限 20 |

计数：`<工程>\readout\load-count.json`，字段 `count / firstLoad / lastLoad / lastSha256 / lastMode / history(最近 20 条)`。写入点在**真正写入目标之后**：

- `ti_c2000_service.ps1 -Start` 成功（`runAsynch` 已起）
- 两个读入口的 `-Standalone` 成功
- `ti_c2000_debug.ps1 -Run/-LoadOnly` 成功

`-Stop` 只删 `.service\` 下的会话文件，**不动** `readout\load-count.json`，所以"第几次下载"跨会话累计。输出里统一显示：

```
LOAD    : #7 (this is download number 7 for this project, previous 6)
```

读输出里的 `LOAD #N` 来自 `state.json.loadIndex`，代表当前会话那一次下载；两次读之间 N 变了，说明中间又烧录过，数据不可比。

## 连续模式的判据

每轮：`-Stop` → `-Start -Build -RunMode Iterate -ConfirmLoad` → 会话内读（不额外下载）→ 取 `readout\data\data.csv` 最后一行 → `Test-LoadExpectation`。

支持 `name>=value`、`<=`、`==`、`!=`、`>`、`<`；**表达式写错或变量缺失一律算失败**（`UNPARSED` / `MISSING`），避免拼错的判据被当成"数据对了"。每轮证据留在 `readout\iterate\round-N\`。`-Expect` 为空时"读成功"即收敛。

## 证据（自动化）

`tests/test_run_modes.ps1` 七项全过（无硬件，探针/DSS 均不接触）：

1. 计数从 0 开始、连加 3 次 = 3、`history` 3 条；加满 25 次后 `count=25`、`history` 封顶 20 且末条为最新
2. `gBufSeq>=3` 满足为 OK、`=1` 为 FAIL、变量缺失为 FAIL、`gBufSeq !! 3` 报 `UNPARSED` 并判失败
3. `-Start` 无 `-ConfirmLoad` → exit 4 + `LOAD_NOT_CONFIRMED`，**不写 `state.json`**，计数不变
4. 两个读入口无会话且无 `-ConfirmLoad` → exit 4，计数不变
5. `-Standalone` 无 `-ConfirmLoad` → exit 4 + `RELOAD_BLOCKED`
6. `iterate` 无 `-UserApproved` → exit 4 + `ITERATE_NOT_APPROVED`，计数不变
7. `-Status` 报 `SERVICE : STOPPED` 与 `LOADS : #N`

全套 7 个测试脚本 `RESULT: OK`、exit 0；`check_debug_catalog.ps1` 通过。

## 边界与未验证

- **连续模式尚未上板跑满一轮**（会重复烧录，需用户点名）。脚本层行为已回归；真机首跑需确认每轮 `LOAD #N` 递增且 `readout\iterate\round-N` 留证。
- 计数是"成功下载"次数，不含失败的构建；一次失败的 `-Start` 不计入，符合"伤机器"的衡量口径（真正写目标才算）。
- 计数器文件损坏时只丢历史，不阻断加载（`Get-LoadCount` 吞异常返回 0）。若 `count` 被手工清零，输出会从 #1 重新开始，属预期。
- `-ConfirmLoad` 是**流程开关，不是权限**：脚本无法验证"用户真的同意了"。它的价值是把"顺手自动下载"变成"必须显式写出来的一次决定"，并让漏写直接失败而不是默默烧录。
- `ti_c2000_debug.ps1` 是显式执行命令（用户说"下载运行"才调），保留无闸但计数；自动路径全部有闸。
