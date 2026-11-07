# eCAP 捕获无边沿：GPIO4 翻转而 GPIO24 保持高电平

## 身份与状态

- 器件/板卡：`2-1SOGI_PLL` 所用 TMS320F28335，单核；XDS100v1 `TI1P9CM8`，CCS 12.8.1，CGT 22.6.1.LTS。
- 模块：ePWM3A GPIO4 → eCAP1 GPIO24；TI 原例程 `F:\c2000ware-core-sdk\device_support\f2833x\examples\ecap_capture_pwm\Example_2833xECap_Capture_Pwm.c`。
- 状态：**排查中**。用户要求暂缓 eCAP。只在这块板和这条声称接好的 GPIO4→GPIO24 跳线上观察到；不能推广到 F28335 其他板或 F28379D。

## 现象与原始证据

- 用户确认两脚已有测试跳线，GPIO4 未接功率级、驱动器或电机。
- TI 原版已编译链接通过。下载运行后 `ECap1IntCount=0`、`ECap1PassCount=0`、`CAP1..4=0`；GPIO4/GPIO24 已设为 ePWM3/eCAP1 复用，ePWM3 时基和 eCAP 计数器运行。原始日志：任务 `work/board-tests/ecap_capture_pwm/run1.log`、`diagnostic2.log`。
- 把 TI 例程副本 `PWM3_TIMER_MIN` 从 10 增到 1000，编译零警告、下载运行，捕获仍为零。日志：任务 `work/board-tests/build_slower_ecap_capture_pwm/run1.log`。因此不能只归咎于初始 PWM 频率过高。
- 单独的 GPIO 连通性诊断副本将 GPIO4 作为输出高/低交替采样，将 GPIO24 作为输入。目标板读回 GPIO4 高/低分别为 `1/0`，GPIO24 对应为 `1/1`；关闭 GPIO24 内部上拉后仍是 `1/1`。日志：任务 `work/board-tests/build_gpio4_gpio24_link_check/run2.log`、`run3.log`。诊断程序不是 TI eCAP 功能例程，其 `RESULT: OK` 只表示诊断程序运行成功，**连通性判据失败**。

## 排查与未完成项

- 已排除：只有内部上拉造成的高电平；仅因 ePWM3 初始 TBPRD=10 太快。
- 尚未区分：测试跳线是否真正连到芯片 GPIO4/GPIO24、板级丝印/排针映射、焊点或板上其他电路，以及 GPIO24 管脚电气故障。没有万用表或示波器实测，不写成已定位。
- 恢复工作时先用表或示波器在 **DSP 实际 GPIO4、GPIO24 管脚/排针** 测同相高低；接通后再按 TI 原例程三次独立下载运行，核对 CAP2/3/4 和 PassCount。不要用 APWM 内部计时结果代替捕获模式验证。
