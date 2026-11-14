---
name: ti-c2000-ccs-auto
description: 处理 TI C2000/DSP 的 CCS 工程：两种运行模式（默认单步——只加载一次、常驻、下载前必问用户；用户点名"连续运行"才用连续模式——反复编译下载直到数据对）× 两种读模式（默认只读、零下载、按判据确认跑的是 RAM 镜像；或本次下载一次再读），模式间有互锁，并统计下载次数；共用器件与 CCS、TI 算法库、调试经验三类入口。适用于读取当前板参数/ADC/寄存器，或编写、构建和上板验证 DSP28335、F28379D 等工程。
---

# TI C2000 / CCS 工程

**先选运行模式与读法，再从三类资料入口取证。它们共用同一套资料。**确认实际工程、器件、目标核、探针、当前运行固件和任务范围。

**所有 C2000 板的 DSS 操作前提**：本用户的调试阶段用 RAM 链接与 RAM 变量/缓冲；先核对 `.cmd`/`.map`，不能把 Flash 中的旧程序当作新 RAM 固件。验证新下载程序时，按“一次连接、按需构建与加载一次、运行、在同一会话边运行边读完计划数据”执行。不要把断开会话后的目标运行状态或另起会话读到的数值，自动算作这份新 RAM 固件的证据；断开前必须完成心跳、身份及所需数据检查。**单会话读取不额外编译/下载，但不等于 DSS 建连/断连绝对无扰动；断开后禁止再读。**读数阶段和读数结束不调用 `halt()`；执行模式仅可在加载前按需停核。不同器件/探针的断开行为须实测，不能宣称 DSS 对每颗 DSP 都必然复位；见[DSS 会话边界](references/dss-debug.md#所有器件的操作前提会话边界)。

## 这个 skill 怎么被调用（与 AI 工具无关）

**本 skill 不是 CodeBuddy 专属插件**：它是「一份 Markdown + 一组 PowerShell 脚本」，不需要任何专有运行时。任何 AI 只要能读文件、能执行 `pwsh`，就能完整使用它——互锁、四道证明、下载计数全在脚本内部，**不依赖 AI 是否守规矩**。

| 工具 | 它自动读的入口 | 拿不到这个文件时的后果 |
|---|---|---|
| CodeBuddy | 项目根 `CODEBUDDY.md`（或本 skill 的 `SKILL.md`） | 会按习惯自创流程，绕过互锁 |
| **Codex** | **`AGENTS.md`**（仓库/工作目录根） | **完全不知道这个 skill 存在** |
| Claude Code | `CLAUDE.md` | 同上 |
| Cursor / Copilot | `.cursor/rules/*.mdc` / `.github/copilot-instructions.md` | 同上 |

**所以换工具前必须先确认工程根有 `AGENTS.md`**（Codex 只认这一个文件名），并且它显式写出 skill 的绝对路径与"先读 `SKILL.md` 再动手"。`AGENTS.md` / `CODEBUDDY.md` / `CLAUDE.md` 三份内容必须完全一致，改一处要同步另外两处。

自检（只读文件，不碰目标）：

```powershell
pwsh -NoProfile -File scripts/check_project_entry.ps1 -ProjectPath <CCS 工程目录>
```

它查四件事，任一不满足即 `RESULT: FAIL`（exit 1）并逐条给 `VIOLATION:`：① 工程内没有 skill 脚本副本；② 工程目录或其上层（≤3 层）有入口文档；③ 每份入口文档都提到 `ti-c2000-ccs-auto`；④ 没有哪一行仍在让人去跑已删除的副本。**`RESULT: OK` 才是"这个工程会按 skill 运行"**。

### 三个校验点（"在用这个 skill"必须可证，不能靠声明）

| # | 时机 | 手段 | 失败表现 |
|---|---|---|---|
| ① **事前** | 开始操作前 | `check_project_entry.ps1 -ProjectPath <工程>` | `VIOLATION:` 逐条列出：有副本 / 缺入口文档 / 文档没提 skill / 仍指向已删脚本 |
| ② **事中** | 每次运行 | 每个入口都打印 `SKILL   : ti-c2000-ccs-auto@<ver>`（`<ver>` = `sha256(SKILL.md)` 前 8 位），并追加一行到 `<工程>\readout\skill-runs.jsonl` | 输出里**没有** `SKILL   :` 行 = 这次操作不是本 skill 跑的 |
| ③ **事后** | 收尾 / 怀疑走偏 | `check_project_entry.ps1 -MaxRunAgeMinutes N` | 最近一次运行过旧，或来自另一个 skill 目录 → `RESULT: FAIL` |

②还兼一个硬门禁：**工程内若存在 skill 脚本副本**，写目标的入口（`service -Start`、`iterate`）直接 `PROJECT_NOT_CLEAN`(2) 拒绝——副本才是实际执行者，不能让它决定一次下载；只读入口只给 `WARN` 并继续（读不会损坏目标）。

### 多平台副本必须同步（这是"换了工具就不按 skill 跑"的常见真因）

有的工具把 skill 放在自己的目录里（如 Codex 的 `%USERPROFILE%\.codex\skills\<name>`），读的是**它自己那份副本**，不会跟着本目录更新。实测 2026-11-14：Codex 那份是几天前的旧版（70 文件 / `SKILL.md` 7479 B，还留着已删除的 `ti_c2000_read_runtime.ps1`），于是"按 skill 跑"实际上跑的是旧规则——**看起来完全正确，比报错更危险**。

```powershell
pwsh -NoProfile -File tools/sync_platform_copies.ps1 -DryRun   # 先看计划：ADD / UPDATE / KEEP / PRUNE
pwsh -NoProfile -File tools/sync_platform_copies.ps1            # 执行，并自证同步后完全一致
```

源永远是 `~/.codebuddy/skills/ti-c2000-ccs-auto`；目标自动发现已存在的平台副本，`PRUNE` 会删掉目标里多出来的旧文件（`-NoPrune` 可保留）。**改完 skill 就要同步一次**，否则别的工具继续跑旧版。

**"审核通过"≠"内容正确"，也不是"内容最新"**。Codex 自带 `skill-creator` 的 `quick_validate.py` 可以复核格式（本 skill 实测 `Skill is valid!`）：

```powershell
# 只查 frontmatter / 命名（≤64 字符）/ 未完成的脚手架占位符
$env:PYTHONUTF8 = '1'
& python "$env:USERPROFILE\.codex\skills\.system\skill-creator\scripts\quick_validate.py" "$env:USERPROFILE\.codex\skills\ti-c2000-ccs-auto"
```

那条脚本自己的注释写明：**"it does not prove that the skill makes good decisions"**。它过了只说明"Codex 能识别、能触发"，不说明规则正确、更不说明是最新版。所以它是**第四条旁证**，不能替代上面的三点校验，也不能替代同步。

## 两种运行模式 × 两种读模式（互锁）

**下载是唯一会重启程序、也是唯一在磨损目标的操作，因此被单独管起来。**默认永远是单步；连续模式必须用户点名。

| 运行模式 | 何时使用 | 行为与入口 |
|---|---|---|
| **单步运行（默认）** | 日常调试、读数据，以及任何"只想看当前程序"的场合。 | `scripts/ti_c2000_service.ps1 -Start [-Build]` 只加载**一次**并常驻运行，之后所有读都附着。**任何下载都必须先得到用户同意**：调用方只有在用户回答"要编译下载"之后才可加 `-ConfirmLoad`；没加就返回 `FAILURE: LOAD_NOT_CONFIRMED`（exit 4），**不编译、不下载、不重启程序**。 |
| **连续运行（显式开启）** | 只在用户明确说"反复编译下载直到数据对/实验现象成功"时使用。 | `scripts/ti_c2000_iterate.ps1 -UserApproved -Expect 'gBufSeq>=3','gErr==0'`：每轮「停会话 → 构建下载 → 会话内读 → 判据」，不满足再来一轮，最多 `-MaxLoads`（默认 5，上限 20）。没有 `-UserApproved` 直接 `FAILURE: ITERATE_NOT_APPROVED`（exit 4）。 |

**运行模式和读模式是两个独立维度**：运行模式决定"程序多久上一次板"，读模式决定"这次读要不要重新下载"。两者交叉时由互锁表裁决，见下。

| 读模式 | 何时使用 | 入口 |
|---|---|---|
| **`-Mode ReadOnly`（默认）** | 日常读。会话已在跑，只想看当前程序。 | `scripts/ti_c2000_run_read.ps1 -Variables gMsTick,gState`（慢变量）/ `scripts/ti_c2000_read_dma.ps1 -FrozenBufferReady -ArrayName gBuf -Rows 256 -Columns 1`（DMA 冻结窗口）。**绝不下载**：读之前要过四道证明「① 仿真器被 Windows 枚举在线 ② 会话活着 ③ `sha256(out)` 与本次构建一致 ④ 入口符号 `main`/`_c_int00` 地址 < 0x080000 即 RAM（裸符号名，`&main` 在 C28x 上无法求值）」，任一条不成立就拒绝——`NO_PROBE`(3) / `NO_SESSION` / `STALE_SERVICE` / `NOT_RAM_IMAGE` / `RAM_UNVERIFIED`，不会偷偷烧一次把数据凑出来。**"证明不了在 RAM"= 拒绝，不是放行**；确实要读未验证目标时才用 `-AllowUnverified`（日志里会写明）；`-NoProbeCheck` 可跳过 1 秒的探针枚举。 |
| **`-Mode LoadRead`（显式）** | 本次读必须从新固件开始（改了代码、要确认新镜像），只下载一次。 | 同一命令加 `-Mode LoadRead -ConfirmLoad`：停常驻会话 → **下载一次** → 读 → 退出。`-MaxLoads N -Expect 'gBufSeq>=3'` 可反复下载到判据满足（等价于连续运行的单次版）。 |

**慢速读只有"轮询"精度，选它之前先对时标**：单轮周期 S ≈ `-IntervalMs` + 50~120 ms（默认 0.5 s → S≈0.55~0.62 s，采样上限约 8~20 Hz）。判据三条：① 被测量变化周期 ≥ 10×S（看趋势 ≥ 3×S）；② 不需要等间隔/精确时刻（测不了频率、相位、占空比）；③ 两次采样之间没有有意义的瞬变。**例：数据 100 ms 一更新（10 Hz），慢速读 1.8 Hz 欠采样 5.5 倍——数值本身是真的，但漏掉 5~6 次更新，画出来是混叠假波形，要看每一点必须用 DMA 冻结缓冲。** 算例、实测方法与自测命令见 [慢速读的时限与适用条件](references/single-session-read.md#慢速读的时限与适用条件轮询不是采样示波器)。

**互锁（调用前就判，一条 `FAILURE:` + 一个退出码，不会崩、不会乱跑）**：

| 组合 | 结果 |
|---|---|
| `ReadOnly` + `-ConfirmLoad` / `-Build` / `-Expect` / `-MaxLoads>1` | `MUTUALLY_EXCLUSIVE` exit 2 |
| `LoadRead` + `-AllowUnverified` / `-NoProbeCheck`（只属于 ReadOnly） | `MUTUALLY_EXCLUSIVE` exit 2 |
| `ReadOnly` 但探针没被枚举（拔线/驱动没起来） | `NO_PROBE` exit 3 |
| `ReadOnly` 但入口符号 `main`/`_c_int00` 读不到（无法证明 RAM） | `RAM_UNVERIFIED` exit 4 |
| `LoadRead` 无 `-ConfirmLoad`（含 `-Standalone`） | `LOAD_NOT_CONFIRMED` exit 4 |
| 连续运行无 `-UserApproved` | `ITERATE_NOT_APPROVED` exit 4 |
| 连续运行期间外部 `ReadOnly` | `READONLY_IN_ITERATE` exit 4（每轮都重下载，附着读到的运行已经不存在） |
| 连续运行期间外部 `LoadRead` | `MUTUALLY_EXCLUSIVE` exit 2（同一时刻只允许一个下载者） |
| 连续运行期间外部 `service -Start/-Stop`、第二个 `iterate` | `ITERATE_IN_PROGRESS` exit 4 |
| 另一进程正持有目标 | `TARGET_BUSY` exit 5 |
| `service -Status` | 任何模式下都可查（纯报告） |

**为什么必须常驻**：每次读数都 `connect → load → run` 等于每次都重启程序，两次读到的就不是同一段运行。常驻会话把加载放在启动时，之后所有读都是"附着读取"；反复刷新程序才是"数据肯定不对"的根因。

**只读不是"下载后读"的替代，而是它的后半段**："下载后读"在实现上就是 `service -Start`（下载一次）+ 反复 `ReadOnly`（零下载）。只读真正不可替代的场合：① 连续运行每轮读必须零下载，否则测的不是同一段运行；② 保留现场——跑飞/进 fault 时一读就重下载等于抹掉证据；③ 程序固化在 Flash 运行时不消耗擦写寿命；④ 同一镜像反复对照时每次约 1 s（含探针枚举），而重下载要约 10~30 s 并重启程序（累积计数器被清零）。它唯一的短板是"板上不一定是我刚编的这版"，这正好由第 ③ 道证明（sha256）兜住：对不上就 `STALE_SERVICE` 拒绝，而不是拿旧数据冒充新数据。**只改代码、验收一次就走的场景用 `-Mode LoadRead` 最短**，不需要常驻会话。

**下载计数（必须汇报）**：每次真正写入目标——`service -Start`（`SingleStep`）、`ti_c2000_iterate.ps1` 的每轮（`Iterate`）、`-Mode LoadRead`、`-Standalone`、`ti_c2000_debug.ps1 -Run/-LoadOnly`——都会把 `<工程>\readout\load-count.json` 的 `count` +1，输出显示 `LOAD    : #7 (this is download number 7 for this project)`；`lastMode` 记录这次是单步、连续还是按需读。`-Stop` 不清零，计数跨会话累计。**读输出里的 `LOAD #N` 就是当前会话那一次下载**：两次读之间 N 若变了，中间又烧录过，数据不可比，必须说明。

**入口职责**：`ti_c2000_service.ps1` 管会话（启动时加载一次 / 停 / 查，并维护下载计数）；`ti_c2000_iterate.ps1` 是连续运行的唯一入口（每轮都是"停会话 + 构建下载 + ReadOnly 读 + 判据"）；`ti_c2000_run_read.ps1`（慢速，标量/状态机）和 `ti_c2000_read_dma.ps1`（DMA 冻结缓冲，数组/波形）默认 **ReadOnly 附着**；`ti_c2000_live_read.ps1` 是会话协议客户端（只读、从不下载）；`ti_c2000_readmode.ps1` 是运行模式 × 读模式的互锁库（标记、RAM 判据、目标锁）；`ti_c2000_loadcount.ps1` 是计数与判据库；`ti_c2000_check_read.ps1` 只拿 CSV 做判读，不连硬件。除这些之外，没有任何别的读数入口。

**脚本只有一个来源**：工程目录里**不得**放本 skill 脚本的副本。副本会抢执行权（实际运行时走副本、不按 skill 的互锁与判据），而且 skill 一更新副本就过期。工程自带的 `Tools/scripts/` 只放**本工程特有**的工具（如串口帧解析、正弦表生成）。发现旧副本（`ti_c2000_*.ps1`、`verify_on_target.ps1`、`dss_load_run_read.js` 之类）直接删除，并把工程入口文档里的调用改成上面的 skill 命令。

**`-Standalone` 逃生口**：两个读入口都保留 `-Standalone`，它只是 `-Mode LoadRead` 的别名（单进程 load → run → read），同样要求 `-ConfirmLoad`，否则 `FAILURE: LOAD_NOT_CONFIRMED`（exit 4）；只用于没有常驻会话的排障，不是常规用法。

旧的独立只读会话入口（`ti_c2000_read_runtime.ps1` / `ti_c2000_read_array_runtime.ps1`）以及 `ti_c2000_debug.ps1` 里的 `-ReadOnly/-ReadVars/-ReadArray/-WaitFor` **已从 skill 中删除**，不保留“禁用但还在”的空壳：**仿真器断开后再读，一定不是本次 RAM 固件**（F28379D 复位跑 Flash；DSP28335 可能读到 Flash 旧程序）。**仿真器在线 + 单会话**是读取 RAM 运行态数据的前提。低速连续读适用于所有板；高速 DMA 读需要固件配置 ADC+DMA 并冻结缓冲——28335 与 28379D 都有 DMA，按工程配置决定，不是器件差异。CCS GUI 手动实时看仍可行：Realtime Mode + 目标可调试 + 会话保持，Expressions/Watch 开 Continuous Refresh。

**最大的一次坑（别再犯）**：读数"成功"、`RESULT: OK`、数值也像样，但仿真器早已退出或程序被重新加载，读到的是 Flash 里的旧固件、或者是另一次运行的残值。当场识别信号：心跳量跨轮完全相同、首值是旧读数或全 0、`PC` 落在 Flash 段、只有"目标显示 running"这一条证据。命中任意一条就报告"未验证/读到 Flash"，不要换个参数再试，也不要补一次 `-Run` 把读数凑成成功。判据见[常驻会话读取规则](references/single-session-read.md)。

常驻会话的判据与一次性读取不同：**不查"启动窗口 ≤ 10 s"**（会话可能已经跑了几小时），改为查 ①心跳跨轮递增 ②冻结窗口在拷贝期间不变 ③会话持有的 `.out` 与实际磁盘上的 SHA256 一致（`STALE_SERVICE` 会明确拦住换了固件却没重启的会话）。

**表述纠正**：不能写「CCS 完全不支持边运行边读」。CCS 支持运行态读；限制是「会话断开后另起只读」不可靠，以及 µs 级高速数据必须由固件 DMA + 冻结缓冲提供。慢变量、状态机、计数器走低速连续读即可，不需要 DMA。

`ti_c2000_debug.ps1` 现在只做编译/下载/运行（`-Build` / `-Run` / `-LoadOnly` / `-ProbeCheckOnly`），不读任何值；传旧参数会被 `UNKNOWN_ARGUMENT` 明确拒绝（exit 2），不会被静默忽略。单会话内读数时目标必须持续运行；已停机就报告失败，不用 `halt → read → runAsynch`，也不借读数之名重复烧录。

冻结 RAM 缓冲仍是数组读取；它可由 ISR 或 DMA 填充，DMA 不是第三种模式。高速读沿用脚本名 `scripts/ti_c2000_read_dma.ps1`，用 `-FrozenBufferReady` 声明已核对固件会冻结缓冲；标量走 `ti_c2000_run_read.ps1`。两者读的是**同一个常驻会话**，不需要为了读标量再加载一次。

**DSP28335 RAM 工程的实测边界**：另起只读曾得到运行态数值，但 PC 位于 Flash，而本次 `.out` 的入口和主程序位于 RAM；不能把这份读数算作新 RAM 固件的验证。F28379D 的另一现场在 `disconnect()` 后观察到计数归零和目标停机。两者都采用单会话完成本次新固件的加载、运行和全部读取；不要为了补读反复调用会重新加载程序的脚本。具体成因与适用范围见[读取案例](references/debug-cases/dsp28335/2026-11-07-realtime-read-implicit-loadonly.md)和[DSS 说明](references/dss-debug.md)。

用户要求上板运行或下载时，**先问一次「是否编译下载并运行」**（单步模式默认不问不下载），同意后再用 `ti_c2000_debug.ps1 -ProbeCheckOnly` 检查当前探针，然后才执行构建或 CCS 调试调用，并把同意转成 `-ConfirmLoad`。若返回 `NO_PROBE`，停止并询问用户是否已接好探针和目标板；收到回复前不编译、不自动重试，也不跳过检查。纯代码构建任务不需要探针。构建默认使用工程声明的 C2000 编译器版本；找不到时报告，只有用户明确同意才传 `-AllowCompilerFallback`。

## 三类入口：共用同一种执行模式

| 类别 | 什么时候进入 | 先读 |
|---|---|---|
| **一、器件与 CCS 工程** | 读取当前芯片 ADC/外设寄存器，或换 DSP28335/F28379D 等器件/板卡；处理探针、CPU1/CPU2、架构、外设配置、`.cproject`、`.ccxml`、编译器、链接和 `.cmd`。 | [器件与工程入口](references/device-platform.md)；写任何外设配置时再读[官方例程模板规则](references/peripheral-examples.md)，从**同器件、同核、同写法**的 TI 源码迁移。 |
| **二、TI 库与算法** | 读取当前算法参数，或实现控制、DSP、数学、AI、校准、通信功能并准备调用 TI 现成库；DCL、DMC、SolarLib 的 MPPT/控制/测量/PLL 等都在这里。 | [TI 库与算法入口](references/ti-algorithm-libraries.md)：先查本机 Core SDK、controlSUITE 和工程已有实现，读候选库的文档、示例、头文件及链接要求，再决定复用或自研。**做 dq/abc（Clarke/Park/InvPark）变换或逆变器电压定向时另必读 [dq/abc 变换规范](references/dq-transforms.md)**：正反变换必须配套，且 **d=幅值、q=0 才能进入闭环/发波**。 |
| **三、调试经验** | ADC、串口抓包、SPI、波形异常、原子访问、寄存器读回、超时等症状；以后 eCAP 出现实测故障也归这里。 | [调试经验入口](references/debugging-experience.md)：按现象找已有复盘，保留原始日志/波形，区分实测结论与推测。 |

例如读 F28379D 的 eCAP 寄存器走单会话读取与第一类；配置 eCAP 走执行模式与第一类；调用 DCL/SolarLib 先读第二类；排查实测 eCAP 故障再读第三类。已有 DSP28335 + XDS100v1/v2 和 F28379D + XDS100v2 的记录；每块板仍须核对探针与目标核。

**调试收尾**：按[第三类归档规则](references/debugging-experience.md)检查新证据。新增或可复现的故障进对应器件案例并登记索引，不把经验只留在对话里。

## 工作规则

1. `.out` 用于下载到 RAM 并提供符号；读取的是该 `.out` 的 RAM 程序，须与板上运行固件一致。记录原始数值、单位、采样条件和目标核；`isHalted()==false` 不足以证明应用在跑，有心跳变量时检查其前后递增。纯构建不覆盖 `Debug` 下的 `.out`；运行态数组在同一 DSS 会话内分批核对心跳。若试运行态 `readData`，先与表达式锚点和数值范围交叉核对。
2. 执行模式写外设配置先选**同器件、同核、同 API 风格**的 TI 例程，算法先查现成库。确需修改时做真实编译链接；**只有用户同意后的下载**（`-ConfirmLoad` 的 `-Start`/`-Standalone`、连续模式、`ti_c2000_debug.ps1 -Run`）才加载并运行，读入口默认不加载。周期信号先在固件侧录满并冻结窗口：50 Hz、1 kHz 的 10 周期是 200 帧；JTAG 可在更长时间内传出，目标仍须运行。
3. 成功同时要求 `RESULT: OK` 与退出码 0；失败记录分类、原因和日志。交付时区分现场实测、源码推断和历史案例，不把某一板的结论推广到其他型号。
4. µs 级波形由固件采集进 RAM 并冻结，再用 JTAG 传出；不要把逐次读 ADC 寄存器当成连续采样。用[读取判据](references/data-read-verdict.md)分别核对固件身份、运行活性、缓冲冻结状态与数值范围；缺失的证据标为未验证，不把 `RESULT: OK` 理解为算法或硬件功能通过。

**后续更新仍按三类归档**：新器件/外设配置进第一类，新 TI 库或算法进第二类，新实测故障进第三类；维护细则见 `AGENTS.md`。
