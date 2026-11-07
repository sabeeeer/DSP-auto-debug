# DSP28335 官方外设例程：当前板的实测入口

适用范围：`E:\1.My_CCS_DSP28335\0-0ai_test_project\2-1SOGI_PLL` 所用 TMS320F28335 板、XDS100v1（序列号 `TI1P9CM8`）、CCS 12.8.1、CGT 22.6.1.LTS、本机 `F:\c2000ware-core-sdk\device_support\f2833x\examples`。2026-10-28 已通过的例程用 `28335_RAM_lnk.cmd` 和 `DSP2833x_Headers_nonBIOS.cmd` 构建，均有 `.map`、`RESULT: OK` 和退出码 0；目标板每类独立下载运行 3 次，共 **14 个 TI 例程原型对应的功能、42 次有效通过**。前 9 个中多数用按板级接线改造的副本，新增 5 个使用 TI 原版源码；逐项区别见下表。原始日志保存在 `C:\Users\Jordon\Documents\Codex\2026-10-27\ti-c2000-ccs-auto\work\board-tests`；用户交付报告与证据包在同一任务的 `outputs`。FPU 首次因浮点读回判据错误而超时，未计作通过；eCAP 捕获尝试未通过，均单独记录。

下表中 TI 源码路径均相对于上述 `examples/`。带 `safe_` 的工程是工作区副本：为避免接线冲突，保持外设收发与中断的 TI 原始顺序，仅隔离物理引脚、将 ADC 通道换到板上的 B0/B1，或增设观测计数。**片内回环通过不能证明外部引脚、收发器或板级设备已通。**

| 模块与 TI 原型 | 本板副本的必要改动 | 三次运行的直接证据 | 已验证范围 |
|---|---|---|---|
| CPU Timer：`cpu_timer/Example_2833xCpuTimer.c` | 原样；无 GPIO 输出 | Timer0/1/2 每次均计数 `2/2/2`；PRD `149999999` | 三路 CPU Timer 与中断 |
| SCI-A：`scia_loopback/Example_2833xScia_FFDLB.c` | 不调用会同时复用 SCI-B/C 引脚的 `InitSciGpio()`；SCIA 候选引脚置输入；保持片内回环 | `LoopCount=6249–6440`，`ErrorCount=0`，`LOOPBKENA=1`，GPIO28/35 mux=0 | SCI-A 片内收发；未验证物理串口帧 |
| SPI-A：`spi_loopback/Example_2833xSpi_FFDLB.c` | GPIO16–19 保持输入，隔离所接 TLV5620；增加成功/错误计数 | 成功 `4146–4266`，错误 `0`，`SPILBK=1`，GPIO16/18 mux=0 | SPI-A 片内收发；未验证 DAC 更新 |
| ePWM：`epwm_timer_interrupts/Example_2833xEPwmTimerInt.c` | GPIO0–11 保持输入 | ePWM1/4/5/6 每次相等（`2293–2409`），ePWM2 约 1/2、ePWM3 约 1/3；TBPRD `8191`，GPIO0 mux=0 | 6 路时基与中断分频；未验证引脚波形 |
| ADC：`adc_soc/Example_2833xAdcSoc.c` | 通道从 A3/A2 改到板上 DAC→ADCINB0/B1；GPIO0/1 隔离；增加总转换计数 | 总转换 `286–295`，CONV00/01=`8/9`，TBPRD `65535`；两路码值有读数 | ePWM1→ADC SEQ1→ISR；未验证电压精度 |
| eCAP：`ecap_apwm/Example_2833xECap_apwm.c` | eCAP 输出候选引脚保持输入 | `CAP_APWM=1`、`TSCTRSTOP=1`、`CAP1=19500000`、`CAP2=10000000`、`TSCTR` 非零、GPIO24 mux=0 | APWM 内部计时；未验证引脚波形或捕获模式 |
| DMA：`dma_ram_to_ram/Example_2833xDMA_ram_to_ram.c` | 原样；无 GPIO 输出 | `DMABuf1[1]=1`、`[512]=512`、`[1023]=1023`，与源缓冲一致 | Timer0 触发的 RAM→RAM DMA |
| eCAN：`ecan_back2back/Example_2833xECanBack2Back.c` | CAN-A/B 候选引脚保持输入，保留 TI 自测试位 | `PassCount=1904–1984`，`ErrorCount=0`，`STM=1`，GPIO31 mux=0 | eCAN 片内邮箱自测试；未验证收发器/总线 |
| McBSP：`mcbsp_loopback/Example_2833xMcBSP_DLB.c` | GPIO5/7/20–23 保持输入；增加成功/错误计数 | 8 位成功 `237869–250134`，错误 `0`，`DLB=1`，GPIO20 mux=0 | McBSP-A 8 位片内收发；未验证物理引脚 |
| FPU：`fpu_hardware/Example_2833xFPU_hardware.c` | 原版，无 GPIO 输出 | 三次原始位型均解码为 `y1=5.90`、`y2=13.28` | FPU32 浮点计算；DSS 整数显示陷阱见[案例](debug-cases/dsp28335/2026-10-28-fpu-dss-float-readback.md) |
| Watchdog：`watchdog/Example_2833xWatchdog.c` | 原版，无 GPIO 输出 | `WakeCount=57/60/57`，`LoopCount` 均增长 | 看门狗 WAKEINT 中断模式，未测复位模式 |
| ADC 连续序列：`adc_seqmode_test/Example_2833xAdcSeqModeTest.c` | 原版，无 GPIO 输出 | A0 的 `SampleTable[900]=2911/2923/2924`；`CONT_RUN=1` | ADC 连续采样及缓冲写入，未校验 A0 电压精度 |
| ADC→DMA：`adc_dma/Example_2833xAdcToDMA.c` | 原版，无 GPIO 输出 | 三次 `DMABuf1[0]=2924/2923/2920`、`[39]=1261/1264/1265`，DMA 通道停止位为 0 | 4 通道×10 次采样的 DMA 存储；未校验模拟精度 |
| 软件中断优先级：`sw_prioritized_interrupts/Example_2833xSWPrioritizedInterrupts.c` | 原版，无 GPIO 输出 | 三次 `ISRTraceIndex=7`、序列 `14,17,16,15,18,12,11`（十六进制），PIEIFR1 清零 | 官方默认 TEST 1 的 PIE Group 1 软优先级；其他 TEST 未运行 |

## 继续选例时的边界

- `ecap_capture_pwm` 明确要求 **GPIO4→GPIO24** 跳线。用户确认有测试跳线且 GPIO4 未接驱动器/电机；但实际运行捕获计数为零，GPIO 诊断显示 GPIO4 翻转时 GPIO24 始终为高，详见[第三类故障案例](debug-cases/dsp28335/2026-10-28-ecap-gpio24-no-edge.md)。按用户要求暂缓 eCAP，不能把 APWM 结果写成捕获通过。
- `i2c_eeprom` 会操作外部 EEPROM；未确认板上芯片、地址和可写内容前不下载运行。eQEP 两例程虽用 ePWM 模拟编码器，仍要求 GPIO 跳线；`eqep_freqcal` 要 GPIO0→GPIO20，`eqep_pos_speed` 要 ePWM1A/B 与 eQEP1A/B 及 GPIO4 Index 对应接线。ePWM AQ/死区/Trip、HRPWM 与 GPIO 输出例程需要确认输出连接与负载后用示波器验证。
- 其余纯片内候选包括 SCI/SPI 中断回环、McBSP DMA/中断回环、ADC 序列覆盖和 ePWM→DMA；前几项仍须按当前板隔离有冲突的外设 GPIO。特别是原版 `epwm_dma` 会设置 `GPADIR.all=0xFFFFFFFF`，不能因“片内 DMA”而原样下载。`fpu_software` 当前 `.cproject` 仍启用 FPU32，与源码注释的纯软件浮点目标不符，见[案例](debug-cases/dsp28335/2026-10-28-fpu-software-project-options.md)。
- F28335 **没有片上 DAC**；当前板的 TLV5620 由 SPI 驱动，不能用 F28379D 的片上 DAC 例程替代。F28379D 的例程还需要对应器件与目标核的板卡，不能由这块 F28335 的结果推定。
- 回环例程只验证对应模式。以后接外设时仍需查同器件的实际通信例程、GPIO mux、极性/波特率、板级接线，并记录外部波形或抓包。任何新故障进入[第三类](debugging-experience.md)。
