# 迁移到其他 agent（Codex / Claude Code / Cursor / …）

**结论：能迁，本质上是"换个目录"。**

这个仓库真正值钱的是 `scripts/*.ps1`（纯 PowerShell 调 CCS 的 `cl2000` / `loadti` / DSS）和 `references/*.md`，
它们**不含任何 CodeBuddy 专有 API**；`SKILL.md` 用的 `name` + `description` frontmatter 是同代
agent 的通用 skill 格式（CodeBuddy、Claude Code、Codex 都读 `SKILL.md`，Cursor / Gemini CLI 等也兼容）。

## 1. 各 agent 的安装位置

| agent | skill 目录 | 备注 |
|---|---|---|
| CodeBuddy | `~/.codebuddy/skills/ti-c2000-ccs-auto/` | 本仓库默认；按 `description` 自动匹配加载 |
| Claude Code | `~/.claude/skills/ti-c2000-ccs-auto/` | 个人级；项目级可放 `<工程>/.claude/skills/` |
| Codex | `~/.codex/skills/ti-c2000-ccs-auto/` | 新版 Codex 支持 `SKILL.md` 形式的 skill（`skills/.system/` 是系统技能，不要动）；也可以用它的 `$skill-installer` 安装 |
| 其他（Cursor / Windsurf / Gemini CLI / Copilot CLI …） | 各自的 skills 目录，或直接把 `SKILL.md` 内容并入它的规则文件 | 也可以用 `skills` CLI（vercel-labs/skills）批量安装 |

## 2. 一键部署（推荐）

`setup/Setup-CCS-Skills.ps1` 已参数化，`-Target` 决定安装目录：

```powershell
# 先干跑，看它打算做什么（不改任何东西）
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\Setup-CCS-Skills.ps1 -Target codex -DryRun

# 装给 Codex      -> ~/.codex/skills/ti-c2000-ccs-auto
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\Setup-CCS-Skills.ps1 -Target codex

# 装给 Claude Code -> ~/.claude/skills/ti-c2000-ccs-auto
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\Setup-CCS-Skills.ps1 -Target claude

# 装到任意目录（自研 agent / 便携版）
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\Setup-CCS-Skills.ps1 -Target custom -SkillsRoot D:\agent\skills

# 不想让它碰 CodeBuddy 的配置文件
... -NoHooks
```

**hooks 只有 CodeBuddy 用得上**：git 快照的 3 个 hook 写在 `~/.codebuddy/settings.json`，而且 PostToolUse
匹配的是 CodeBuddy 的工具名（`write_to_file|replace_in_file`）。给别的 agent 安装时脚本自动跳过，
也可以用 `-NoHooks` 显式跳过。

## 3. 迁移后会"少"什么

| 能力 | CodeBuddy | 其他 agent |
|---|---|---|
| skill 自动加载 | 按 `description` 匹配，自动加载 | Codex 需要显式调用（如 `$skill` 或提到技能名）；Claude Code 按 `description` 自动加载 |
| git 快照 hooks | 有（由 `git-management` 这个 skill 提供） | **没有**，要自己写对应 agent 的 hook 机制 |
| 工具名差异 | `use_skill` / `write_to_file` / `replace_in_file` | 各家不同；`SKILL.md` 里的自然语言指令不受影响 |

脚本本身（`ti_c2000_build.ps1` / `ti_c2000_debug.ps1`）在任何 agent 下行为一致：只要 agent 能执行
PowerShell、能读到 `SKILL.md`，就可用。

## 4. 没有 skill 机制的 agent：用 AGENTS.md 兜底

把下面这段贴进 `AGENTS.md`（Codex 全局 `~/.codex/AGENTS.md`，或工程根目录 `AGENTS.md`）：

```markdown
## TI C2000 / CCS 工程（DSP2833x、F2837x 等）

改任何 `.c/.h/.cproject` 后，必须跑一次编译链接自检，看到 `RESULT: OK` 才算通过：
  powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ti_c2000_build.ps1" -ProjectPath "<工程根目录>"

要上板验证：
  ... ti_c2000_debug.ps1 -ProjectPath "<工程>" -Build -Run -ReadVars "<寄存器/变量,逗号分隔>"

脚本失败会打印 `FAILURE: <分类>` + `REASON: <原因>`（COMPILE_ERRORS / LINK_ERRORS / TIMEOUT /
CONNECT_FAILED / LOADTI_ERROR / LOADTI_TIMEOUT / NO_PROBE / NO_OUT_FILE / ENV_*），必须原样转述，
禁止把失败说成成功。完整规则见 <skill>\SKILL.md。
```

## 5. 与 agent 无关的硬前提

1. **必须装 CCS**（12.x 或 6.x）：脚本调用它的 `cl2000`、`loadti`、DSS；只做编译链接自检不需要硬件。
2. **`.cproject` 里的 TI 头文件是绝对路径**：换机器/换目录后要在 CCS 里改
   （Project → Properties → Build → C2000 Compiler → Include Options），否则报
   `cannot open source file "DSP2833x_Device.h"`；脚本会先打 `WARNING : include path missing on disk`。
3. **Windows + PowerShell 5.1**（脚本保持纯 ASCII，规避 GBK 读取无 BOM UTF-8 的问题）。
4. 上板还需要仿真器驱动（XDS100/110/200/510/560、J-Link 等）；目前硬件实测只覆盖 DSP28335 + XDS100。

## 6. 迁移后自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\ti_c2000_build.ps1 -ProjectPath <工程>
# 期望输出：CONFIG / DEFINES / EXCLUDED 三行正常 + compile: OK + link: OK + RESULT: OK
```
