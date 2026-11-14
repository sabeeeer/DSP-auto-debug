# 跨 agent 安装

本技能的 PowerShell 脚本调用本机 CCS；迁移后仍须有实际工程、编译器、探针及目标板。平台和硬件边界见仓库根目录的 [RECOVER.md](../RECOVER.md)。

```powershell
pwsh -NoProfile -File .\setup\Setup-CCS-Skills.ps1 -Target codex -DryRun
pwsh -NoProfile -File .\setup\Setup-CCS-Skills.ps1 -Target codex
```

`-Target codebuddy` 安装到 `~/.codebuddy/skills/`，`-Target claude` 安装到 `~/.claude/skills/`，`-Target codex` 安装到 `~/.codex/skills/`。其他目录用 `-Target custom -SkillsRoot <目录>`。新会话中先检查 [SKILL.md](../SKILL.md) 能被所用 agent 发现；各产品的自动触发行为以当前版本为准。

迁移工程后核对 `.cproject` 的 include/编译器路径、`.ccxml` 的探针与目标核，以及 `.cmd` 和 `.out`。先执行不碰硬件的构建测试；需要读数据时用单会话入口：

```powershell
pwsh -NoProfile -File .\scripts\ti_c2000_build.ps1 -ProjectPath "<工程>"
pwsh -NoProfile -File .\scripts\ti_c2000_run_read.ps1 -ProjectPath "<工程>" -Variables "EPwm1Regs.TBPRD"
```

**断开调试连接后不能再读**；旧 `read_runtime`/`read_array` 入口已禁用（`READONLY_UNRELIABLE`）。任何目标核、外设引脚或库兼容性均按当前器件和工程重新验证；DSP28335 与 F28379D 的已验证范围见[器件入口](../references/device-platform.md)。
