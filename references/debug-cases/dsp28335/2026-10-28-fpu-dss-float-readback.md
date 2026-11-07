# FPU 例程浮点数被 DSS 表达式读回截为整数

## 身份与状态

- 器件：TMS320F28335，`2-1SOGI_PLL` 所用板；CCS 12.8.1、CGT 22.6.1.LTS、XDS100v1。
- 例程：`F:\c2000ware-core-sdk\device_support\f2833x\examples\fpu_hardware\Example_2833xFPU_hardware.c`。
- 状态：**已回归（读回方法）**。仅验证此板和这套 DSS 自动化。

## 现象与证据

- 原例程计算 `y1=.5*3.4+4.2=5.9`、`y2=.6*7.3+8.9=13.28`。`scripts/ti_c2000_debug.ps1 -ReadVars y1,y2` 经 DSS `session.expression.evaluate` 打印 `5`、`13`，以 `y1>5.8 && y2>13.2` 为 `-WaitFor` 导致超时，日志为任务 `work/board-tests/fpu_hardware/run1.log`。
- 改为读同一变量的位型 `*(unsigned long*)&y1` 和 `*(unsigned long*)&y2`，三次独立下载运行均返回 `1086115020`、`1096055521`，按 IEEE 754 float32 解码分别为 `5.90`、`13.28`，三次均 `RESULT: OK` 且退出码 0。日志：`run2.log`、`run3.log`、`run4.log`。原 TI 源码未改动，构建零警告。

## 结论与适用边界

- 此 DSS 读数链对浮点表达式有截断表现；**不能凭直接显示的整数判定 FPU 计算错误**。需要精度时读原始位型并独立解码，或换经验证的浮点读取 API。
- 这不证明其他 CCS/DSS 版本也会截断；给其他器件用之前重新验证。
