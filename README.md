# TI C2000 / CCS 自动化技能

处理 DSP28335、F28379D 等 C2000 工程。入口是[SKILL.md](SKILL.md)：**单会话读取、执行模式**共用**器件与 CCS 工程、TI 算法库、调试经验**三类资料。新器件、库和故障按对应类别增补，现有 28335/28379D 资料保留。

| 模式 | 做什么 | 入口 |
|---|---|---|
| 单会话读取 | 同一 DSS 会话内加载、运行、读数据；**断开后禁止再读** | [单会话读取规则](references/single-session-read.md) |
| 执行模式 | 运行态读基线、分析、按需修改并构建下载运行、运行态复读验证 | [执行手册](references/field-guide.md) |

所有读数都走单会话入口。断开调试连接后不能再读；不靠 `halt → read → runAsynch`，也不因为一次读数异常就重新烧录。TI 官方例程、库和板级经验按需从 [第一类](references/device-platform.md)、[第二类](references/ti-algorithm-libraries.md)、[第三类](references/debugging-experience.md)进入。

## 快速使用

要求 Windows、PowerShell 7、CCS 和当前工程的正确 `.ccxml/.out`；下载运行还需要探针与目标板。安装与恢复见 [SETUP.md](SETUP.md) 和 [RECOVER.md](RECOVER.md)。

```powershell
# 低速连续读（不需要 DMA）：单会话加载、运行、按 0.5 s 读 10 轮
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_run_read.ps1" -ProjectPath "<工程>" -Variables "gMsTick,usMainLoop,EPwm1Regs.TBPRD"

# 高速 DMA 读：固件已配 ADC+DMA 并冻结缓冲
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_dma.ps1" -ProjectPath "<工程>" `
  -ArrayName gAdcAllBuf -Rows 16 -Columns 200 -FrozenFlag gAdcBufFull -FrozenBufferReady
```

本板 50 Hz、1 kHz 的前 200 帧是 10 个周期；缓冲须先由固件录入并冻结。JTAG 可用更长时间传出，期间目标继续运行。旧 `-ReadVars`/`-ReadArray` 入口已删除（`ti_c2000_debug.ps1` 只做编译/下载/运行）；成功须同时有 `RESULT: OK` 和退出码 0。

## 已有资料与验证边界

- [DSP28335 官方外设例程上板范围](references/board-tests-dsp28335.md)：区分片内回环、引脚输出及未完成的 eCAP 捕获。
- [F28379D、双核与探针记录](references/other-devices-and-probes.md)：保留 CPU1/CPU2、XDS100v2 与 CCS 配置经验。
- [SolarLib 全库](references/solarlib-catalog.md)、[SPLL 专题](references/spll-pll-algorithms.md)、[DCL/DMC 与 Core SDK](references/ti-algorithm-libraries.md)：算法先查现成实现。
- [调试案例索引](references/debugging-experience.md)：每条记录标明器件、证据和回归状态。

本仓库不包含 CCS、编译器、硬件、驱动、用户工程或许可证；见 [不可恢复项](IRREPLACEABLE.md)。
