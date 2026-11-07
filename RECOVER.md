# 恢复本技能

```powershell
git clone https://github.com/sabeeeer/DSP-auto-debug.git
cd DSP-auto-debug
pwsh -NoProfile -File .\setup\Setup-CCS-Skills.ps1 -Target codex -DryRun
pwsh -NoProfile -File .\setup\Setup-CCS-Skills.ps1 -Target codex
```

CodeBuddy 改用 `-Target codebuddy`；其他安装位置见 [SETUP.md](SETUP.md)。先安装 PowerShell 7 和 CCS/C2000 编译器，再恢复实际工程并核对 `.cproject`、`.ccxml`、`.cmd`。上板另需探针、驱动和目标板；仓库不能恢复这些硬件、许可证、用户工程或登录凭据，详见 [IRREPLACEABLE.md](IRREPLACEABLE.md)。

本技能的入口是 [SKILL.md](SKILL.md)：只读模式只从运行目标取数据；执行模式按运行态基线、修改、构建下载运行、运行态复读验证。恢复后先用构建脚本测试工程，不因“想读取”而重新烧写。
