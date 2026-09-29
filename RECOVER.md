# 恢复指南（本仓库）

本仓库是独立 skill 仓库（TI C2000 / DSP2833x 全自动开发+调试）。**完整恢复流程**见主仓库：

- 主仓库 **`sabeeeer/codebuddy-skills`**（skill + AI 记忆 + 恢复脚本一体）
- 恢复入口：主仓库根 **`RECOVER.md`**
- 一键恢复：在主仓库副本里执行 `pwsh -NoProfile -File ./restore.ps1 -Apply`

## 本仓库单独恢复

```bash
git clone git@github.com:<owner>/<repo>.git
# 复制到 skill 目录（CodeBuddy）
#   Windows:  xcopy /E /I /Y <repo> "%USERPROFILE%\.codebuddy\skills\ti-c2000-ccs-auto"
#   bash:     cp -r <repo> ~/.codebuddy/skills/ti-c2000-ccs-auto
```

## 依赖

| 依赖 | 用途 | 缺失后果 |
|---|---|---|
| **PowerShell 7** | 所有 `.ps1` 脚本 | 5.1 会因编码/`$PSStyle` 差异出错 |
| **git** | 版本管理 | — |
| **CCS 12 / CCS6** | 编译与下载 | `ti_c2000_build.ps1` / `ti_c2000_debug.ps1` 不可用 |
| **调试探针**（本机 XDS100v2）| 下载运行 | 只能编译，不能下载/读寄存器 |
| **C2000Ware / controlSUITE** | 官方例程检索 | `c2000ware_find.ps1` 退化到 GitHub 快照或不可用 |

## 关键脚本

| 脚本 | 用途 |
|---|---|
| `scripts/ti_c2000_build.ps1` | 编译+链接自检（不打开 CCS、不碰硬件；认 `RESULT: OK`） |
| `scripts/ti_c2000_debug.ps1` | 构建 + 下载运行 + 读回变量/寄存器 |
| `scripts/c2000ware_find.ps1` | 按外设检索官方例程 |
| `scripts/check_ram_layout.ps1` | RAM 段占用自检（链接报 `#10099-D` 时用） |
| `scripts/ti_c2000_set_probe.ps1` | 设置/切换仿真器连接类型 |

## 可迁移性

本仓库遵守主仓库 `PORTABILITY.md` 的十条规范（内容平台中立、路径不硬编码、凭据不入库、关键目录 ASCII）。
文档里出现的本机路径（如 CCS 安装位置、资料目录）均为**示例**，换机后按实际路径调整。

安装门禁（推送前自动检查）：

```powershell
pwsh -NoProfile -File "$env:USERPROFILE/.codebuddy/skills/git-management/scripts/install_gate.ps1" -Path <本仓库>
```

应急绕过：`git push --no-verify`（建议事后补检）。
