# DSP 自动调试（CodeBuddy Skill）

> [!WARNING]
> GitHub 不能恢复 CCS、编译器、探针、目标板、驱动和许可证。
> 详见 [`IRREPLACEABLE.md`](IRREPLACEABLE.md)。

> TI C2000 / DSP2833x 在 **CCS12 / CCS6** 上的全自动开发 + 调试闭环：
> 运行态读取基线 → 判断 → 按需写代码、编译链接、下载运行 → **另起只读会话在运行态复读验证** → 失败分类并给出原因。

技能先选**只读模式**或**执行模式**，再进入三类共用资料：**器件与 CCS 工程**、**TI 库与算法**、**调试经验**。执行模式中的读数也调用只读入口，不停核、不复位。先从 `SKILL.md` 选入口，再按需读对应参考文件；以后新增型号、库或故障案例也按这三类维护。

已在 **DSP28335 + XDS100v2** 和 **F28379D + XDS100v2** 上完成 CCS12.8.1 硬件实测；
DSP28335 工程另用 CCS6（ti-cgt-c2000_15.12.1.LTS）完成编译链接实测。

---

## 1. 它能做什么

| 能力 | 说明 |
|---|---|
| 编译 + 链接自检 | `ti_c2000_build.ps1`：包含路径、汇编器版本、内存模型、浮点、输出格式、运行库、链接脚本**全部从 `.cproject` 反推**，换型号不用改脚本 |
| 下载并运行 | `ti_c2000_debug.ps1 -Build -Run`：自动找 CCS 安装与仿真器 → 下载 → 启动新程序 |
| 运行态只读 | `ti_c2000_read_runtime.ps1`：连接前关闭自动停核，启用 DSS 实时模式；只装符号，不编译、下载或主动停核，按变量列表直接读值 |
| 大数组只读 | `ti_c2000_read_array_runtime.ps1`：按固定下标分批调用运行态读脚本，完整结果才交付 CSV |
| 就绪轮询 | 不再"盲等固定时间"：每 250 ms 采样一次就绪条件，命中即返回（大程序用 `-RunMs` 给上限，如 5 分钟） |
| 长调试 | `-Background` 自分离运行 + 日志轮询，避免上层命令超时打断 |
| 失败分类 | 失败必报 `FAILURE: <分类>` + `REASON: <原因>` + 非 0 退出码，绝不把失败说成成功 |

失败分类：`COMPILE_ERRORS` / `LINK_ERRORS` / `TIMEOUT` / `CONNECT_FAILED` / `LOADTI_ERROR` / `LOADTI_TIMEOUT` / `NO_PROBE` / `NO_OUT_FILE` / `NO_CCXML` / `ENV_*`（5 类已用真实失败实例验证）。

## 2. 目录结构

```
SKILL.md                          # 任务路由与核心验证规则（按需打开下面的资料）
README.md                         # 本文件
references/
  device-platform.md              # 器件、探针、外设、工程与链接入口
  ti-algorithm-libraries.md       # C2000Ware/其他 TI 库与算法入口
  debugging-experience.md         # 调试经验与故障复盘入口
  debug-cases/CASE-TEMPLATE.md     # 新故障的独立案例模板；索引在 debugging-experience.md
  field-guide.md                 # 执行模式详细命令、SOP 与报错对照
  spll-pll-algorithms.md         # SolarLib PLL/SOGI/坐标变换与移植
  solarlib-catalog.md            # SolarLib v1.2 全库模块入口（MPPT/控制/测量/变换/PLL）
  c28x-pitfalls.md               # ADC/SPI/SCI、控制算法与并发问题
  environment.md                  # 本机实测环境、已验证项、踩过的坑
  project-map.md                  # 工程结构、模块接口、引脚占用表
  dss-debug.md                    # loadti / DSS 用法与排错、长时调试
  other-devices-and-probes.md     # 其他 C2000 型号 + 其他仿真器/双核
docs/
  portability.md                  # 迁移到 Codex / Claude Code / 其他 agent 的步骤与差异
setup/
  Setup-CCS-Skills.ps1            # 一键部署（-Target codebuddy|claude|codex|custom）
scripts/
  ti_c2000_build.ps1              # 编译 + 链接自检
  ti_c2000_debug.ps1              # 构建 + 下载 + 运行；读数入口仅走只读 DSS
  ti_c2000_read_runtime.ps1       # 当前程序运行态直接读变量/寄存器
  ti_c2000_read_array_runtime.ps1 # 大数组按固定下标分批运行态读取
  dss_template.js                 # 仅运行态只读的 DSS 模板
  dss_api_probe.js                # 换 CCS 版本时反射探测真实 DSS API
```

## 3. 安装

把整个文件夹放到 CodeBuddy 的 skills 目录：

```
Windows:  C:\Users\<你的用户名>\.codebuddy\skills\ti-c2000-ccs-auto\
Linux/mac: ~/.codebuddy/skills/ti-c2000-ccs-auto/
```

重启会话后，提到 DSP/C2000/CCS/调试/写程序或读写 DSP 头文件时会自动加载。

装给别的 agent（Codex / Claude Code / 任意目录）用仓库自带的部署脚本，`-Target` 选目录：

```powershell
... \setup\Setup-CCS-Skills.ps1 -Target codex      # -> ~/.codex/skills/
... \setup\Setup-CCS-Skills.ps1 -Target claude     # -> ~/.claude/skills/
... \setup\Setup-CCS-Skills.ps1 -Target custom -SkillsRoot <目录>
```

迁移细节与差异见 [docs/portability.md](docs/portability.md)。

## 4. 依赖

- **必需**：Code Composer Studio 12.x 或 6.x（自带 `ti-cgt-c2000_*` 编译器、`ccs_base\scripting` 下的 DSS 与 loadti）
- **可选**：XDS100/110/200/510/560、SEGGER J-Link、Blackhawk、Spectrum Digital 等 JTAG 仿真器
  （**只做编译链接自检不需要硬件**；TI 模拟器 tisim 目标也不需要）
- 运行环境：Windows + **PowerShell 7.0+（pwsh，本机 7.6.6 实测）**，脚本首行 `#requires -Version 7.0`

## 5. 快速开始

```powershell
# ⓪ 只读现有程序的运行态数据（不编译、不下载、不主动停核）
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_runtime.ps1" -ProjectPath "<工程>" `
  -Variables "gBootStage,EPwm1Regs.TBPRD"

# ① 只做编译+链接自检（几秒，不需要硬件、不打开 CCS）
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ti_c2000_build.ps1" -ProjectPath "<CCS工程根目录>"

# ② 构建 + 下载运行
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ti_c2000_debug.ps1" -ProjectPath "<工程>" -Build -Run

# ③ 新程序运行后，另起只读调用等就绪并读取
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_runtime.ps1" -ProjectPath "<工程>" `
  -WaitFor "EPwm1Regs.TBPRD != 0" -RunMs 15000 `
  -Variables "EPwm1Regs.TBPRD,EPwm1Regs.CMPA.all,SciaRegs.SCILBAUD"

# ④ 大数组分批只读；固件须先把缓冲录满并冻结
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_array_runtime.ps1" -ProjectPath "<工程>" `
  -ArrayName gAdcAllBuf -Rows 16 -Columns 200 -WaitFor "gAdcBufFull == 1" `
  -MinValue 0 -MaxValue 4095 -OutputPath "<新文件.csv>"
```

`ti_c2000_debug.ps1 -Build` 单独使用只构建；下载后启动必须明确指定 `-Run`，只有 `-LoadOnly` 会下载后暂停。与 `-ReadVars` 合用会在连接前拒绝；读取需第二次调用只读入口。

本板 50 Hz、1 kHz 时，前 200 帧是 10 个完整周期。上例等待现有固件录满并冻结 400 帧，再以运行态读数方式取前 200 帧作分析；等待条件与分析窗口是两回事。JTAG 传输可以超过 200 ms，目标仍须持续运行。

成功须同时有 `RESULT: OK` 和进程退出码 0；`RESULT: FAIL` 或非 0 退出码均算失败。

安装器和仓库自检：

```powershell
pwsh -NoProfile -File .\tests\test_setup_failure.ps1
```

该测试要求安装失败时输出 `RESULT: FAIL` 并返回非 0。

## 6. 常用参数

| 参数 | 作用 |
|---|---|
| `-ProjectPath` | 工程根目录（含 `.cproject`），省略时从当前目录向上查找 |
| `-Build` | 调试前先跑一次编译自检，失败即中止（分类透传） |
| `-ReadVars "a,b,c"` | 运行态只读变量/寄存器（逗号分隔）；不能与 `-Build/-Run/-LoadOnly` 合用 |
| `-WaitFor "<表达式>"` | 只读调用的就绪判据（非 0 视为就绪）；不指定则直接取当前值 |
| `-RunMs` | 就绪轮询上限（默认 8000 ms）；命中即返回，设大不白等 |
| `-RunMs/-TimeoutSec` | 就绪上限 / loadti 超时（默认 180 s） |
| `-Background` | 自分离运行，立即返回日志路径 |
| `-AllowNotReady` | 超时也照常返回读值（会提示值可能无效） |
| `-Ccxml` / `-CorePattern` | 指定目标配置 / 双核选核（如 `.*CPU1.*`） |
| `-CcsRoot` / `-CompilerRoot` | 指定 CCS / 编译器版本 |
| `-LinkCmd` | 追加链接命令文件（如 Flash 版 `.cmd`） |
| `-NoProbeCheck` | 跳过仿真器前置检查 |
| `-ReadOnly` | 只读回，不复位不下载（程序已运行，`.out` 只用于符号解析） |

## 7. 已验证 / 未验证

**已上板实测**：DSP28335 + XDS100v2 + CCS12.8.1，读回值与源码吻合（`TBPRD=65535`、`CMPA=0xCCCC=52428`、`CLKDIV=3`、`SCILBAUD=39`）；F28379D + XDS100v2 + CCS12.8.1 完成构建、下载、复位、运行，并连续验证 12 个官方 bitfield 例程。证据与配置见 `references/environment.md` 和 `references/other-devices-and-probes.md` §3.2。

**编译链接实测**：DSP28335 工程使用 CCS6 的 15.12.1.LTS 与 CCS12 的 22.6.1.LTS 均通过。

**尚无本技能上板记录**：F2802x、F2806x、F28004x、F2838x，以及 F2837x 家族中除 F28379D 外的型号。首次使用请先跑编译自检，再核对目标配置和硬件行为。

## 8. 注意

- `scripts/*.ps1` 要求 **PowerShell 7.0+**（首行 `#requires -Version 7.0`，示例统一用 `pwsh`）；
  脚本仍保持**纯 ASCII**（历史约定 + 避免编码坑），中文说明一律放在 `.md` 里。
- 默认链接脚本多为 RAM 版（如 `28335_RAM_lnk.cmd`），**掉电即失**；要脱机运行需换 Flash 链接脚本。
- 调试器操作会打断目标板当前程序；`-ReadVars` 会复位并运行被加载的程序。
- 本仓库不含任何密钥；`references/environment.md` 里的路径是本机实测记录，可按需替换。

## 9. 迁移到其他 agent（Codex / Claude Code / …）

`SKILL.md` 用的是通用 skill 格式（`name` + `description`），`scripts/*.ps1` 是纯 PowerShell 调 CCS 命令行，
**不含 CodeBuddy 专有 API**，所以整套可以直接搬到别的 agent 用：

```powershell
... \setup\Setup-CCS-Skills.ps1 -Target codex      # ~/.codex/skills/
... \setup\Setup-CCS-Skills.ps1 -Target claude     # ~/.claude/skills/
... \setup\Setup-CCS-Skills.ps1 -Target custom -SkillsRoot <目录>
```

只有 git 快照 hooks 是 CodeBuddy 专有（写在 `~/.codebuddy/settings.json`，且匹配 CodeBuddy 的工具名），
给别的 agent 安装时会自动跳过（也可 `-NoHooks`）。各 agent 的目录、触发方式差异、以及用 `AGENTS.md`
兜底的做法：**[docs/portability.md](docs/portability.md)**。
