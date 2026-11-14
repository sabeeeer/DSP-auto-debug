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

板上已有程序且只需观察时，用默认的 `ReadOnly` 附着运行态会话读取；**不得先下载**：

```powershell
# 默认 -Mode ReadOnly：会话不在就 NO_SESSION（exit 4），绝不为了读一次而偷偷下载
pwsh -NoProfile -File .\scripts\ti_c2000_run_read.ps1 -ProjectPath "<工程根目录>" -Variables "EPwm1Regs.TBPRD"

# 本次读要从新镜像开始：显式下载一次（用户同意后才有 -ConfirmLoad）
pwsh -NoProfile -File .\scripts\ti_c2000_run_read.ps1 -ProjectPath "<工程根目录>" `
  -Mode LoadRead -ConfirmLoad -Variables "EPwm1Regs.TBPRD"
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

**选读法前先对时标**：慢速读是 PC 轮询，一轮 ≈ `-IntervalMs` + 50~120 ms（默认约 0.55~0.62 s，即约 1.8 Hz）；只有被测量变化周期 ≥ 10 倍单轮周期才看得清形状，≥ 3 倍才看趋势。数据 100 ms 一更新就该用 DMA 冻结缓冲（采样在板上，µs 级对齐），否则读到的是跳号抽样、画出来是混叠假波形。算例与自测命令见 [慢速读的时限与适用条件](references/single-session-read.md#慢速读的时限与适用条件轮询不是采样示波器)。

用户明确要求"连续运行/反复编译下载直到数据对"时才用连续模式（会重复烧录，`LOAD #N` 每轮递增）：

```powershell
pwsh -NoProfile -File .\scripts\ti_c2000_iterate.ps1 -ProjectPath "<工程根目录>" `
  -Variables "gBufSeq" -Expect "gBufSeq>=3" -MaxLoads 5 -UserApproved
```

连续运行期间其它入口被锁在外面：外部 `ReadOnly` → `READONLY_IN_ITERATE`（exit 4），外部 `LoadRead` → `MUTUALLY_EXCLUSIVE`（exit 2），外部 `-Start/-Stop` 或第二个 iterate → `ITERATE_IN_PROGRESS`（exit 4）；`-Status` 仍可查。

每步以 `RESULT: OK` **且退出码 0** 为成功。旧 `read_runtime`/`read_array` 入口已从 skill 删除（不是禁用），不要重新造独立只读会话。操作规则见 [SKILL.md](SKILL.md)。
