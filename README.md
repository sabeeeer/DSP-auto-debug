# TI C2000 / CCS 自动化技能

处理 DSP28335、F28379D 等 C2000 工程。入口是[SKILL.md](SKILL.md)：**两种运行模式（默认单步、可选连续）+ 常驻会话附着读取**共用**器件与 CCS 工程、TI 算法库、调试经验**三类资料。新器件、库和故障按对应类别增补，现有 28335/28379D 资料保留。

| 模式 | 做什么 | 入口 |
|---|---|---|
| **单步运行（默认）** | **加载一次**，目标一直跑，会话不退出；下载前必须先问用户，同意后才加 `-ConfirmLoad` | `scripts/ti_c2000_service.ps1` |
| **连续运行（显式）** | 反复「构建下载 → 读 → 判据」直到数据对，最多 `-MaxLoads` 次；必须 `-UserApproved` | `scripts/ti_c2000_iterate.ps1` |
| 低速 / 高速读 | 附着常驻会话读变量或 DMA 冻结窗口，**不重载、不复位** | [常驻会话读取规则](references/single-session-read.md) |
| 执行手册 | 运行态读基线、分析、按需修改并构建下载运行、运行态复读验证 | [执行手册](references/field-guide.md) |

读数一律附着常驻会话。断开调试连接后不能再读；每次读数都重连重载会让两次数据描述两次不同运行。每次真正下载都会写入 `readout\load-count.json`，输出显示 `LOAD : #N`，`-Stop` 不清零。TI 官方例程、库和板级经验按需从 [第一类](references/device-platform.md)、[第二类](references/ti-algorithm-libraries.md)、[第三类](references/debugging-experience.md)进入。

## 快速使用

要求 Windows、PowerShell 7、CCS 和当前工程的正确 `.ccxml/.out`；下载运行还需要探针与目标板。安装与恢复见 [SETUP.md](SETUP.md) 和 [RECOVER.md](RECOVER.md)。

```powershell
# 1) 单步模式：确认下载后加载一次（-ConfirmLoad 表示用户已同意），然后一直跑
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_service.ps1" -ProjectPath "<工程>" -Start -Build -ConfirmLoad

# 2) 低速连续读（不需要 DMA）：附着上面的会话，按 0.5 s 读 10 轮
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_run_read.ps1" -ProjectPath "<工程>" -Variables "gMsTick,usMainLoop,EPwm1Regs.TBPRD"

# 3) 高速 DMA 读：固件已配 ADC+DMA 并冻结缓冲，附着同一个会话
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_dma.ps1" -ProjectPath "<工程>" `
  -ArrayName gAdcAllBuf -Rows 16 -Columns 200 -FrozenFlag gAdcBufFull -FrozenBufferReady

# 4) 连续运行模式：反复构建下载直到数据满足判据（仅在用户明确要求时）
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_iterate.ps1" -ProjectPath "<工程>" `
  -Variables "gBufSeq,gErr" -Expect "gBufSeq>=3","gErr==0" -MaxLoads 5 -UserApproved

# 5) 查看（含累计下载次数）/ 结束会话
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_service.ps1" -ProjectPath "<工程>" -Status
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_service.ps1" -ProjectPath "<工程>" -Stop
```

第 2、3 步如果发现会话不在，**必须带 `-ConfirmLoad` 才会自启一次**，否则 `FAILURE: LOAD_NOT_CONFIRMED`（exit 4，什么都不做）；`-Build` 只在启动时生效。`-Standalone` 是排障逃生口，会在单进程里重载程序，同样要求 `-ConfirmLoad`，不作为常规用法。本板 50 Hz、1 kHz 的前 200 帧是 10 个周期；缓冲须先由固件录入并冻结。JTAG 可用更长时间传出，期间目标继续运行。旧 `-ReadVars`/`-ReadArray` 入口已删除（`ti_c2000_debug.ps1` 只做编译/下载/运行）；成功须同时有 `RESULT: OK` 和退出码 0。

## 已有资料与验证边界

- [DSP28335 官方外设例程上板范围](references/board-tests-dsp28335.md)：区分片内回环、引脚输出及未完成的 eCAP 捕获。
- [F28379D、双核与探针记录](references/other-devices-and-probes.md)：保留 CPU1/CPU2、XDS100v2 与 CCS 配置经验。
- [SolarLib 全库](references/solarlib-catalog.md)、[SPLL 专题](references/spll-pll-algorithms.md)、[DCL/DMC 与 Core SDK](references/ti-algorithm-libraries.md)：算法先查现成实现。
- [调试案例索引](references/debugging-experience.md)：每条记录标明器件、证据和回归状态。

本仓库不包含 CCS、编译器、硬件、驱动、用户工程或许可证；见 [不可恢复项](IRREPLACEABLE.md)。
