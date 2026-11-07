# TI C2000 / CCS 自动化技能

处理 DSP28335、F28379D 等 C2000 工程。入口是[SKILL.md](SKILL.md)：**只读模式、执行模式**共用**器件与 CCS 工程、TI 算法库、调试经验**三类资料。新器件、库和故障按对应类别增补，现有 28335/28379D 资料保留。

| 模式 | 做什么 | 入口 |
|---|---|---|
| 只读模式 | 读取已运行程序的数据；不编译、下载、复位或主动停核 | [运行态读取规则](references/read-only-mode.md) |
| 执行模式 | 运行态读基线、分析、按需修改并构建下载运行、运行态复读验证 | [执行手册](references/field-guide.md) |

所有读数都走只读入口。目标已暂停或实时访问失败时报告失败，不靠 `halt → read → runAsynch`，也不因为一次读数异常就重新烧录。TI 官方例程、库和板级经验按需从 [第一类](references/device-platform.md)、[第二类](references/ti-algorithm-libraries.md)、[第三类](references/debugging-experience.md)进入。

## 快速使用

要求 Windows、PowerShell 7、CCS 和当前工程的正确 `.ccxml/.out`；下载运行还需要探针与目标板。安装与恢复见 [SETUP.md](SETUP.md) 和 [RECOVER.md](RECOVER.md)。

```powershell
# 已运行程序：直接读取数值
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_runtime.ps1" -ProjectPath "<工程>" -Variables "EPwm1Regs.TBPRD"

# 确需更新程序：构建下载运行，然后另起只读调用验证
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_debug.ps1" -ProjectPath "<工程>" -Build -Run
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_runtime.ps1" -ProjectPath "<工程>" -Variables "EPwm1Regs.TBPRD"

# 已冻结的数组：按下标分批运行态读取
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_array_runtime.ps1" -ProjectPath "<工程>" `
  -ArrayName gAdcAllBuf -Rows 16 -Columns 200 -WaitFor "gAdcBufFull == 1" `
  -MinValue 0 -MaxValue 4095 -OutputPath "<新文件.csv>"
```

本板 50 Hz、1 kHz 的前 200 帧是 10 个周期；缓冲须先由固件录入并冻结。JTAG 可用更长时间传出，期间目标继续运行。`-Build/-Run/-LoadOnly` 不得与 `-ReadVars` 同次调用。成功须同时有 `RESULT: OK` 和退出码 0。

## 已有资料与验证边界

- [DSP28335 官方外设例程上板范围](references/board-tests-dsp28335.md)：区分片内回环、引脚输出及未完成的 eCAP 捕获。
- [F28379D、双核与探针记录](references/other-devices-and-probes.md)：保留 CPU1/CPU2、XDS100v2 与 CCS 配置经验。
- [SolarLib 全库](references/solarlib-catalog.md)、[SPLL 专题](references/spll-pll-algorithms.md)、[DCL/DMC 与 Core SDK](references/ti-algorithm-libraries.md)：算法先查现成实现。
- [调试案例索引](references/debugging-experience.md)：每条记录标明器件、证据和回归状态。

本仓库不包含 CCS、编译器、硬件、驱动、用户工程或许可证；见 [不可恢复项](IRREPLACEABLE.md)。
