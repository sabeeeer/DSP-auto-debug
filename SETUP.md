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

板上已有程序且只需观察时，附着运行态会话读取；**不得先下载**：

```powershell
# 会话不在时，自启一次也必须经用户同意（-ConfirmLoad），否则 exit 4 且不下载
pwsh -NoProfile -File .\scripts\ti_c2000_run_read.ps1 -ProjectPath "<工程根目录>" -Variables "EPwm1Regs.TBPRD"
```

要更新固件时，先确认用户同意，再启动会话（只加载这一次），之后反复读都附着它，**断开后禁止再读**：

```powershell
pwsh -NoProfile -File .\scripts\ti_c2000_service.ps1 -ProjectPath "<工程根目录>" -Start -Build -ConfirmLoad
```

高速 DMA 数组用（附着同一会话）：

```powershell
pwsh -NoProfile -File .\scripts\ti_c2000_read_dma.ps1 -ProjectPath "<工程根目录>" `
  -ArrayName gAdcAllBuf -Rows 16 -Columns 200 -FrozenBufferReady
```

用户明确要求"反复编译下载直到数据对"时才用连续模式（会重复烧录，`LOAD #N` 每轮递增）：

```powershell
pwsh -NoProfile -File .\scripts\ti_c2000_iterate.ps1 -ProjectPath "<工程根目录>" `
  -Variables "gBufSeq" -Expect "gBufSeq>=3" -MaxLoads 5 -UserApproved
```

每步以 `RESULT: OK` **且退出码 0** 为成功。旧 `read_runtime`/`read_array` 入口已从 skill 删除（不是禁用），不要重新造独立只读会话。操作规则见 [SKILL.md](SKILL.md)。
