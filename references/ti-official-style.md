# TI 官方例程写法规范（DSP2833x / F2833x，V142）

> **铁律：写任何 DSP 代码都照这里的骨架 + 对应官方例程写。
> 找不到对应例程就先告诉用户，不要凭印象猜寄存器/顺序。**

---

## 0. 本机官方例程源（TI 原版，唯一判据）

| 形式 | 路径 |
|---|---|
| **2833x 完整 CCS 工程**（推荐，能直接打开/编译） | `F:\controlSUITE\device_support\f2833x\v142\DSP2833x_examples_ccsv5\<例程名>\` |
| **2833x 单文件速查**（49 个 `Example_2833x*.c`，看代码最快） | `E:\2.28335资料\官方程序示例\<例程名>\` |
| **新器件（F2837xD/2837xS = 28377D/28379D 等）** | C2000Ware Core SDK：bitfield 例程 `F:\c2000ware-core-sdk\device_support\<器件>\examples\`；driverlib 例程 `F:\c2000ware-core-sdk\driverlib\<器件>\examples\` |
| 官方库源码（2833x，TI 原版实现，只读不改） | `F:\controlSUITE\device_support\f2833x\v142\DSP2833x_common\`、`...\DSP2833x_headers\` |
| 其它版本（备查） | `F:\controlSUITE\device_support\f2833x\v140 / v141 / v132 / v133 / v2.00.00.00` |

> 新器件（2837x/28379x/2838x/2800x…）的两种官方风格骨架、cmd 链接脚本怎么选、driverlib/SysConfig 用法：
> 见 **`references/c2000ware-guide.md`**（本机 SDK `F:\c2000ware-core-sdk`，v26.00.00.00.STS）。

版本标识（文件头应能看到）：`$TI Release: F2833x/F2823x Header Files and Peripheral Examples V142 $`。
例程用 `#include "DSP28x_Project.h"`（= `DSP2833x_Device.h` + `DSP2833x_Examples.h`）；本工程直接用后两个，**等价**。

> ⚠ `E:\DSP8233x_ProjectExample\DSP2833x_Example\`（Example01..50 中文注释版）与
> `E:\3.PZ-DSP28335-L开发板资料` 是**开发板配套例程**，风格接近但不是 TI 原版。
> 可以拿来快速找主题，但**寄存器判据一律以 controlSUITE v142 为准**。

---

## 1. main() 官方骨架（照抄）

```c
void main(void)
{
   // Step 1. 系统：PLL / 看门狗 / 外设时钟
   InitSysCtrl();

   // Step 2. GPIO（官方例子：InitGpio(); 本工程用板级初始化函数）
   InitGpio();

   // Step 3. 清中断 + 装 PIE 向量表
   DINT;                    // 先关总中断再动 PIE/向量表
   InitPieCtrl();
   IER = 0x0000;
   IFR = 0x0000;
   InitPieVectTable();

   // 用到的中断重映射到本文件的 ISR（受保护寄存器必须 EALLOW/EDIS）
   EALLOW;
   PieVectTable.EPWM1_INT = &epwm1_timer_isr;
   EDIS;

   // Step 4. 外设初始化
   InitEPwmTimer();

   // Step 5. 使能中断（四层 + EINT/ERTM）
   IER |= M_INT3;                          // ③ CPU 级
   PieCtrlRegs.PIEIER3.bit.INTx1 = 1;      // ② PIE 级
   EINT;   // ④ 全局：Enable Global interrupt INTM
   ERTM;   // ④ 全局：Enable Global realtime interrupt DBGM

   // Step 6. 主循环
   for(;;) { }
}
```

要点：
- `DINT` 在 Step 3 开头（比只写 `IER = 0` 严谨）；
- `IER = 0x0000; IFR = 0x0000;` 在 `InitPieCtrl()` **之后**；
- 向量表重映射必须在 `EALLOW ... EDIS` 里；
- **`EINT; ERTM;` 永远成对**（ERTM 清 DBGM：调试器暂停时实时中断照常响应）。
- 中断使能四层缺一不可：外设级 `ETSEL.INTEN` → PIE 级 `PIEIERx.INTxn` → CPU 级 `IER |= M_INTx` → 全局 `EINT`。

---

## 2. 外设初始化顺序（以官方 ePWM 例程为准）

1. **开外设时钟**：`SysCtrlRegs.PCLKCR1.bit.EPWMxENCLK = 1`（EALLOW 里）；先 `PCLKCR0.bit.TBCLKSYNC = 0` 停时基；
2. **引脚复用**：官方用 TI 写的 `InitEPwm1Gpio()` / `InitSciaGpio()` 等（`DSP2833x_*.c` 里）；
3. **时基**：`TBCTL / TBPHS / TBCTR / TBPRD`，值用 TI 宏（`TB_COUNT_UP`、`TB_DIV1`、`TB_SYNC_IN`）；
4. **比较**：`CMPCTL`（`CC_SHADOW` / `CC_CTR_ZERO`）→ `CMPA/CMPB`；
5. **动作限定**：`AQCTLA/AQCTLB`（`AQ_SET` / `AQ_CLEAR` / `AQ_TOGGLE`）；
6. **死区**：`DBCTL`（`DB_FULL_ENABLE` / `DB_ACTV_HIC` / `DBA_ALL` 等）+ `DBRED/DBFED`；
7. **中断源**：`ETSEL.INTSEL` + `ETSEL.INTEN` + `ETPS.INTPRD`（`ET_CTR_ZERO`、`ET_1ST`）；
8. 最后 `PCLKCR0.bit.TBCLKSYNC = 1` 放行。

SCI 例程同理：`SciaRegs.SCICCR/SCICTL1/SCIHBAUD/SCILBAUD/SCICTL2` → `SCICTL1.bit.SWRESET = 1` 放行 → FIFO（`SCIFFTX 0xE000`）→ `SCIFFRX`。

---

## 3. ISR 官方写法

```c
__interrupt void epwm1_timer_isr(void)      // 官方 V142 写 __interrupt
{
   ...干活...

   // Clear INT flag for this timer
   EPwm1Regs.ETCLR.bit.INT = 1;             // ① 清外设中断标志

   // Acknowledge this interrupt to receive more interrupts from group 3
   PieCtrlRegs.PIEACK.all = PIEACK_GROUP3;  // ② PIE 应答（官方写法）
}
```

- 本工程统一写 `interrupt void xxx(void)`（与 `DSP2833x_DefaultIsr.c` 一致，`interrupt` 与 `__interrupt` 等价）；
- **应答用 `.all = PIEACK_GROUPx`**，不要用 `.bit.ACKx = 1`（等价但非官方写法，容易漏）；
- ISR 里**别做浮点/除法/长耗时**（F28335 的 FPU 上下文不在中断里自动保存）；
- 中断里要发给主循环的数据，用标志位交接，别在 ISR 里阻塞等串口。

---

## 4. 严禁清单（"乱写" vs 官方写法）

| 乱写 | 官方写法 |
|---|---|
| `PieCtrlRegs.PIEACK.bit.ACK3 = 1;` | `PieCtrlRegs.PIEACK.all = PIEACK_GROUP3;` |
| 只写 `EINT;`，没有 `ERTM;` | `EINT; ERTM;` 成对 |
| 写 `PieVectTable.xxx` / `GpioCtrlRegs` 不包 `EALLOW/EDIS` | 必须 `EALLOW; ...; EDIS;` |
| 只开 `PIEIERx` 不开 `IER` / 只开 `IER` 不开 `EINT` | 四层全开（INTEN→PIEIER→IER→EINT） |
| ISR 里不清 `PIEACK` | 必清，否则该组后续中断全被挡住 |
| 配 GPIO 输出时不改 MUX | 先 `GPxMUX = 0`（或调 `InitXxxGpio()`）再 `GPxDIR = 1` |
| 自己 `for(i=0;i<1000;i++);` 延时 | `DELAY_US(x)`（`CPU_RATE` 由 `DSP2833x_Examples.h` 提供） |
| 用 STM32 术语写（推挽/开漏/上下拉输入模式） | DSP 只有：通用IO/复用（`GPxMUX`）+ 方向（`GPxDIR`）+ 上拉使能（`GPxPUD`） |
| 臆造寄存器位名（拼一个"看起来像"的） | 必须能在 `DSP2833x_*.h` 或官方例程里找到，否则先查再说 |
| 改 `DSP2833x_Libraries/`（TI 库源码） | 不许动；要改行为就在 APP 层包一层 |
| 在中断里调 `DELAY_US` 长延时/发串口 | 中断只置标志，主循环干活 |
| `while(1)` 里不做任何看门狗处理还跑长任务 | 保持 `InitSysCtrl()` 的 `DisableDog()`，别自己乱配 WDCR |
| 中断里更新、主循环里"分多次读"的全局量（不加快照） | 先在 `DINT…EINT`（≈20ns）里抄成本地快照，再慢慢发/用；见 §4.5 |

---

## 4.5 中断与主循环共享的数据：读必须原子（并发基本功）

**规则一句话**：❌ 不许"一边慢慢发、一边反复去读被中断更新的全局变量"；
✅ **先在极短临界区里把需要的值抄成本地快照，之后只用快照。**

### 为什么（实测踩坑全过程见 `c28x-pitfalls.md` §七）

10kHz 控制中断每 100us 更新一次 `XxxCtrl.usCmpA/B/C`；主循环按 1kHz 把它发串口
（8 字节 @460800 = **174us**）。若逐字节直接读全局变量：

```c
UARTa_SendByte(XxxCtrl.usCmpA & 0x00FF);        /* 读低字节，然后花 21.7us 发出去 */
UARTa_SendByte((XxxCtrl.usCmpA >> 8) & 0x00FF); /* 再读高字节 —— 已是 21.7us 之后 */
```

**"读这个变量的过程"被串口拖成 174us，中断必然插进来 1~2 次** →
低字节来自第 N 拍、高字节来自第 N+1 拍 → **拼出一个不存在的数**（如 `0x0088` = 136）→
波形上一个**垂直尖刺**，下一帧又弹回来。

### 正确写法（模板，直接抄）

```c
void vXxx_WaveSend(void)
{
    Uint16 usSnapA, usSnapB, usSnapC;      /* ① 局部快照变量 */

    if (usXxxWaveFlag == 0) { return; }
    usXxxWaveFlag = 0;

    DINT;                                  /* ② 极短临界区：3 条读指令 ≈ 20ns */
    usSnapA = XxxCtrl.usCmpA;
    usSnapB = XxxCtrl.usCmpB;
    usSnapC = XxxCtrl.usCmpC;              /* 相关的一组值必须"同一拍"取齐 */
    EINT;

    UARTa_SendByte(0xAA);                  /* ③ 之后 174us 慢发，全部用快照 */
    UARTa_SendByte(usSnapA & 0x00FF);
    UARTa_SendByte((usSnapA >> 8) & 0x00FF);
    /* ... 8 个字节都发快照，不再碰全局变量 */
}
```

### 三条硬性约束

| # | 约束 | 说明 |
|---|---|---|
| 1 | **临界区只包"读"，绝不包"发"** | 关中断窗口必须 ≪ 更新周期（20ns vs 100us，差 5000 倍才安全）。把 `DELAY_US` / `UARTa_SendByte` 包进 `DINT…EINT` 是重大错误 |
| 2 | **一组相关的量必须一次取齐** | 只保证"单个值不撕裂"不够：三相 CMP、设定+反馈 这类数据要"同一拍"，否则通道间关系（如三段之和 ≈ 1000）会出现瞬时假偏差 |
| 3 | **在中断上下文里调用时不许用裸 `EINT`** | `DINT…EINT` 会把中断**强行打开**（若调用前本来是关的 → 破坏上层临界区语义）。那种场合要保存/恢复 `INTM`：<br>`Uint16 usWas = __disable_interrupts(); …读… if (usWas == 0) { __enable_interrupts(); }` |

### 常见误解（每一条都实测证伪过）

| 误解 | 为什么错 |
|---|---|
| "提高读取频率（读周期 < 更新周期）就行" | ① **带宽不允许**：8 字节 @460800 = 174us → 帧率上限 5.75kHz < 更新率 10kHz，永远追不上；② **就算读得再快，只要"一次读的过程"跨过更新点，照样撕裂** |
| "降低帧率就不撞了" | 错。10Hz 发一帧，那 174us 里照样被打断 |
| "加 `volatile` 就好了" | `volatile` 只禁止编译器把读写优化掉，**完全不防撕裂** |
| "用 float 就安全了" | 32 位一次读完确实不撕裂，但**多值之间仍可能不同拍**（见约束 2） |

### 一眼定性（判断标准）

**凡是"慢过程"（串口发送 / DAC / OLED / EEPROM 写）去读"被高频中断更新的量"，就必须先快照。**
把**快**的（20ns 的读）放进临界区，把**慢**的（174us 的发）留在外面。

---

## 5. 允许的偏离（工程约定，不算乱写）

| 项 | 官方例程 | 本工程约定（允许） |
|---|---|---|
| 头文件 | `DSP28x_Project.h` | `DSP2833x_Device.h` + `DSP2833x_Examples.h`（等价） |
| ISR 关键字 | `__interrupt` | `interrupt`（与 `DSP2833x_DefaultIsr.c` 一致，等价） |
| 模块位置 | 例程自带 `APP/<模块>/` | `APP/<模块>/<模块>.c|.h`，或工程顶层目录（如 `OpenLoop/`、`Emit_Wave/1-1SPWM/`） |
| `EINT/ERTM` 位置 | 例程里（模块/主文件末尾） | 可由 `main` 统一开（本工程偏好）；但**不许漏**，且 `IER/PIEIER/INTEN` 仍随模块走 |
| 命名 | `EPwm1Regs`、`epwm1_isr` | 模块前缀统一（`EPWM3Ph_`、`UARTa_`、`TIM0_`、`SPWM_`…），ISR 名与向量表项对应 |

---

## 6. 例程索引（写什么 → 先看哪个例程）

| 要写的功能 | 官方例程目录（`...\官方程序示例\` 或 `...\DSP2833x_examples_ccsv5\`） |
|---|---|
| GPIO 配置 / 点灯 / 翻转 | `gpio_setup`、`gpio_toggle`、`timed_led_blink` |
| CPU 定时器 | `cpu_timer` |
| 外部中断 | `external_interrupt` |
| 中断优先级 | `sw_prioritized_interrupts` |
| ePWM 基本 / 增减计数 | `epwm_up_aq`、`epwm_updown_aq` |
| ePWM 死区（互补输出） | `epwm_deadband` |
| ePWM 周期中断 | `epwm_timer_interrupts` |
| ePWM 保护封波（TZ） | `epwm_trip_zone` |
| ePWM + DMA | `epwm_dma`；高精度 PWM：`hrpwm*` |
| ADC 启动/序列/中断 | `adc_soc`、`adc_seqmode_test`、`adc_seq_ovd_test`、`adc_dma` |
| SCI 串口（查询/中断/回显/自适应） | `scia_loopback`、`scia_loopback_interrupts`、`sci_echoback`、`sci_autobaud` |
| SPI | `spi_loopback`、`spi_loopback_interrupts` |
| I2C | `i2c_eeprom` |
| DMA | `dma_ram_to_ram`、`dma_xintf_to_ram` |
| eCAP / eQEP | `ecap_capture_pwm`、`ecap_apwm` / `eqep_freqcal`、`eqep_pos_speed` |
| eCAN | `ecan_back2back`、`ecan_a_to_b_xmit` |
| 看门狗 / 低功耗 | `watchdog` / `lpm_idlewake`、`lpm_standbywake`、`lpm_haltwake` |
| Flash 烧写与从 Flash 运行 | `flash_f28335`、`f28335_flash_kernel`、`xintf_run_from` |
| 浮点（FPU） | `fpu_hardware`、`fpu_software` |

---

## 7. 交付前自查（写代码的人自己过一遍）

1. 用了哪个官方例程做参照？（回答里要能说出来）
2. 中断：四层都开了吗？`EINT; ERTM;` 配对了吗？ISR 里 `ETCLR` + `PIEACK` 都有吗？
3. 受保护寄存器都包在 `EALLOW/EDIS` 里了吗？
4. 寄存器/位名都能在 `DSP2833x_*.h` 或例程里找到出处吗？
5. 有没有用 STM32 的概念/术语？
6. 延时用 `DELAY_US`、不在 ISR 里做重活？
7. 跑过 `scripts\ti_c2000_build.ps1` 且 `RESULT: OK`？
8. **有"中断里更新、主循环里读"的变量吗？读取是否原子（快照）？**（见 §4.5）
   尤其"慢过程读快变量"（串口 / DAC / OLED 读 CMP、设定值、ADC 结果）必须先快照。

---

## 8. 新器件（F2837xD/F2837xS = 28377D/28379D 等）：C2000Ware 的两种官方风格

C2000Ware Core SDK（本机 `F:\c2000ware-core-sdk`，v26.00.00.00.STS）里每个新器件都有**两套**官方例程，
**先判断该用哪套**（详见 `references/c2000ware-guide.md` §2）：老工程/要寄存器级控制 → bitfield；
新工程/要可移植 + SysConfig → driverlib。

### 8.1 bitfield 骨架（`device_support\f2837xd\examples\cpu1\epwm_up_aq\cpu01\epwm_up_aq_cpu01.c` 实测）

```c
#include "F28x_Project.h"                       // = <器件>_Device.h + <器件>_Examples.h
void main(void)
{
    InitSysCtrl();  InitEPwm1Gpio();            // 时钟 → GPIO 复用
    InitPieCtrl();  IER = 0x0000;  IFR = 0x0000;  InitPieVectTable();
    EALLOW;  PieVectTable.EPWM1_INT = &epwm1_isr;  EDIS;
    EALLOW;  CpuSysRegs.PCLKCR0.bit.TBCLKSYNC = 0;  EDIS;   // ★2837x 用 CpuSysRegs（2833x 是 SysCtrlRegs）
    InitEPwm1Example();
    EALLOW;  CpuSysRegs.PCLKCR0.bit.TBCLKSYNC = 1;  EDIS;
    IER |= M_INT3;  PieCtrlRegs.PIEIER3.bit.INTx1 = 1;
    EINT;  ERTM;                                 // 与 2833x 一模一样
    for(;;) { asm("  NOP"); }
}
__interrupt void epwm1_isr(void)
{
    EPwm1Regs.ETCLR.bit.INT = 1;
    PieCtrlRegs.PIEACK.all = PIEACK_GROUP3;
}
```

### 8.2 driverlib 骨架（`driverlib\f2837xd\examples\cpu1\epwm\epwm_ex1_trip_zone.c` 实测）

```c
#include "driverlib.h"  #include "device.h"  #include "board.h"
void main(void)
{
    Device_init();  Device_initGPIO();                 // 时钟 + 引脚解锁/上拉
    Interrupt_initModule();  Interrupt_initVectorTable();
    Interrupt_register(INT_EPWM1_TZ, &epwm1TZISR);     // 注册向量（不用手写 EALLOW）
    Board_init();                                      // SysConfig 生成的板级/GPIO 配置
    SysCtl_disablePeripheral(SYSCTL_PERIPH_CLK_TBCLKSYNC);
    initEPWM1();                                       // 内部全是 EPWM_xxx API
    SysCtl_enablePeripheral(SYSCTL_PERIPH_CLK_TBCLKSYNC);
    Interrupt_enable(INT_EPWM1_TZ);
    EINT;  ERTM;
    for(;;) { NOP; }
}
__interrupt void epwm1TZISR(void)
{
    Interrupt_clearACKGroup(INTERRUPT_ACK_GROUP2);     // 应答用 API，不写 PIEACK 寄存器
}
```

driverlib API 命名：`<外设>_<动作>`（`EPWM_setTimeBasePeriod`、`GPIO_setPinConfig(GPIO_0_EPWM1A)`…）；
库在 `driverlib\<器件>\driverlib\ccs\{Debug|Release}\driverlib{_coff|_eabi}.lib`；
`.projectspec` 里 `--define=DEBUG --define=CPU1`（Flash 加 `--define=_FLASH`）、`--entry_point code_start`。
cmd/双核/CLA/SysConfig 细节 → `references/c2000ware-guide.md` §3、§4。
