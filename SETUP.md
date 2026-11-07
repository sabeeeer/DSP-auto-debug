# 新电脑安装

先安装 CCS、C2000 编译器、PowerShell 7；上板还需要目标板与探针驱动。工程、硬件、许可证和 GitHub 登录不会随 skill 仓库自动恢复。恢复边界见 [RECOVER.md](RECOVER.md)。

```powershell
git clone https://github.com/sabeeeer/DSP-auto-debug.git
cd DSP-auto-debug
pwsh -NoProfile -File .\setup\Setup-CCS-Skills.ps1 -Target codex -DryRun
pwsh -NoProfile -File .\setup\Setup-CCS-Skills.ps1 -Target codex
```

给 CodeBuddy 安装时把 `-Target` 改为 `codebuddy`；其他目录用 `-Target custom -SkillsRoot <目录>`。脚本的 Git 快照 hook、代理和 Git 身份参数是可选的，与 C2000 调试无关。详情见 [迁移说明](docs/portability.md)。

复制实际 CCS 工程后，核对 `.cproject` 的 include 路径、编译器版本、`.ccxml` 的探针与目标核、RAM/Flash `.cmd`。先做不碰硬件的构建自检：

```powershell
pwsh -NoProfile -File .\scripts\ti_c2000_build.ps1 -ProjectPath "<工程根目录>"
```

板上已有程序且只需观察时，直接在运行态读取；不得先下载：

```powershell
pwsh -NoProfile -File .\scripts\ti_c2000_read_runtime.ps1 -ProjectPath "<工程根目录>" -Variables "EPwm1Regs.TBPRD"
```

确需更新程序时，构建下载运行与读取分两次调用：

```powershell
pwsh -NoProfile -File .\scripts\ti_c2000_debug.ps1 -ProjectPath "<工程根目录>" -Build -Run
pwsh -NoProfile -File .\scripts\ti_c2000_read_runtime.ps1 -ProjectPath "<工程根目录>" -Variables "EPwm1Regs.TBPRD"
```

每步以 `RESULT: OK` **且退出码 0** 为成功。只读调用不编译、下载、复位或主动停核；已停机时会报错。操作规则见 [SKILL.md](SKILL.md)。
