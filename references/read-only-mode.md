# 只读模式：运行态实时读取，不构建、下载或主动停核

适用：用户要**读取现有程序**的参数、ADC 值、变量或寄存器，或先核对板上状态再决定是否改代码。先从[第一类](device-platform.md)确认器件、目标核、探针和 `.ccxml`；读取算法参数时查[第二类](ti-algorithm-libraries.md)的结构体/单位，解释异常时查[第三类](debugging-experience.md)。这三类与原模式共用。

## 操作边界

- 不编辑工程/配置，不调用构建脚本，不加 `-Build`、`-Run` 或 `-LoadOnly`，不下载 `.out`，不复位、启动或主动停核。**只读结果异常也不自动切换原模式。**
- `-OutFile` 指向**已存在、与当前运行固件匹配**的 `.out`，仅向调试器装载符号，目标程序不被下载。若固件身份/符号不确定，先核对现有构建记录、map/校验值或 CCS 会话；无法确认时停止符号变量的判读，不用“顺手重新编译/下载”解决。
- 运行态读取脚本在 `connect()` 前设置 CCS DSS 选项：`HaltOnConnect=false`、`AutoResetOnConnect=false`、`RestartOnSymbolLoad=false`、`UseLegacyStopMode=false`、`AllowInterruptsWhenHalted=true`、`PoliteRealtimeMode=true`。现场 CCS12.8 查询发现 `HaltOnConnect` 默认是 **true**；所以临时脚本即便没有显式 `halt()`，连接时也可能先停核再恢复。固件中的 `ERTM` 清除 C28x 的 DBGM，配合调试器实时选项使用；单靠 `ERTM` 不能代替调试器设置。
- 目标必须已在运行。若连接后发现已暂停、读数时变成暂停或实时访问失败，脚本报错并不擅自 `runAsynch()`；先核对固件状态和 CCS 连接配置。运行态逐项读取也不构成同一时刻的原子快照，高频变量可跨中断变化。

## 最小命令

```powershell
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_runtime.ps1" `
  -ProjectPath "<当前 CCS 工程>" -Ccxml "<当前目标配置.ccxml>" `
  -OutFile "<与板上固件匹配的已有.out>" -CorePattern ".*CPU1.*" `
  -Variables "<参数表达式>,<ADC结果表达式>,<寄存器表达式>"
```

单核器件可省略 `-CorePattern`；F28379D 等双核器件明确选 CPU1/CPU2。`-Variables` 必填，可传逗号分隔的多个变量或寄存器表达式；不要传会写寄存器、调用函数或产生副作用的表达式。直接调用旧入口 `ti_c2000_debug.ps1 -ReadOnly -ReadVars "..."` 也会走相同运行态路径。具体表达式从当前器件头文件、当前工程和已有 `.out` 确认，不照搬另一型号的寄存器名。

需要等现有程序到某个状态再取数值时，可加 `-WaitFor "<只读条件>" -RunMs <上限毫秒>`；只读模式在**运行态**反复读条件，不停核、不编译或下载。若目标在连接时已经暂停，报错退出，不自动启动目标。

例如 F28335 的 ADC 可分别读 `AdcMirror.ADCRESULT0`（右对齐 12 位）与 `AdcRegs.ADCRESULT0`（左对齐结果），先核对当前工程是否使用该结果槽；其它器件按自身寄存器定义。单个 ADC 码值不能判断正弦幅值、通道接线或电压精度。需要趋势时多次独立采样并记录时间；不能靠一次读数做修改结论。

## 判读与停止条件

1. 保存命令、目标核、固件标识、原始 `VAR` 输出、退出码和 `RESULT`。`RESULT: OK` 只表示这次读取完成，不表示 ADC/算法/外设功能正确。
2. 若读到全零、前后矛盾、浮点显示成整数或与物理现象冲突，先核对符号匹配、ADC 左/右对齐、寄存器位/整字、目标核与采样时机；用同一只读模式的另一表达式或 CCS 已有寄存器视图交叉核查。DSP28335 的已知读回陷阱见[调试经验](c28x-pitfalls.md)与[FPU 位型案例](debug-cases/dsp28335/2026-10-28-fpu-dss-float-readback.md)。
3. 若只读证据仍不足，报告“未确认”及需要的下一种证据。编译、下载、复位、运行新测试固件属于**原模式**，需用户已有相应任务授权。

TI 依据：[CCS 12.8 实时模式与自动停核选项](https://software-dl.ti.com/ccs/esd/documents/users_guide_12.8.0/ccs_debug-main.html)、[DSS `AllowInterruptsWhenHalted` 选项](https://software-dl.ti.com/ccs/esd/documents/users_guide_12.0.0/sdto_dss_handbook.html)。
