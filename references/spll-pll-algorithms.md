# C2000 锁相环（PLL）算法 —— TI 官方 SolarLib SPLL 全解

本页专讲 SolarLib 的 SPLL 模块；MPPT、数字控制、坐标变换、测量等其他模块见 [SolarLib 全库入口](solarlib-catalog.md)。

> 适用：并网逆变/UPS/微网/电能质量，需要从电网电压取 `θ / sinθ / cosθ / 频率` 的场合。
> 数据来源：`F:\controlSUITE\libs\app_libs\solar\v1.2\`（float / IQ / CLA 三套源码 + `SolarLib.pdf` 4.3 章 + `spll_coeff_compute.xlsx`）。
> 本机已按此复现并数值验证（2026-10-26）。

## 0. 先分清两个 "PLL"

| 名称 | 是什么 | 相关寄存器/接口 |
|---|---|---|
| **时钟 PLL** | 片内倍频，把 30MHz 晶振变 150MHz | `SysCtrlRegs.PLLCR` / `PLLSTS`；driverlib `SysCtl_setClock()`、`SysCtl_isPLLValid()` |
| **软件 PLL（本文）** | 从采样到的电网电压算相位角 | TI SolarLib `SPLL_*` 模块 |

问"PLL 算法"通常指后者；C2000Ware **Core SDK 里没有 SPLL**（只有时钟 PLL），要装 **controlSUITE** 或 Digital Power SDK / SolarMicroInverter 例程。

## 1. TI 官方模块清单（`libs\app_libs\solar\v1.2`）

| 模块 | 用途 | 是否需前置变换 | 抗不平衡 | 备注 |
|---|---|---|---|---|
| `SPLL_1ph_F` | 单相，PD ×cos + **自适应陷波**滤 2ω | 无 | — | theta 是 **0~1 标幺**（不是弧度） |
| `SPLL_1ph_SOGI_F` | 单相，SOGI 造正交 + Park | 自带 OSG | — | **推荐**；无 2ω 纹波，动态快 |
| `SPLL_3ph_SRF_F` | 三相对称，Clarke+Park；反馈轴按输入相位约定选 | `ABC_DQ0_POS_F` | 差 | 本库结构体名 `v_q` 不决定应接 d 还是 q |
| `SPLL_3ph_DDSRF_F` | 三相不平衡（正负序解耦双同步） | `ABC_DQ0_POS_F` + `ABC_DQ0_NEG_F` | 强 | 每拍多 4 个 LPF + 2θ 三角 |

float 用 `Solar_Lib_F.lib`（或直接把 `float\source\*.c` 加进工程，28335 有 FPU32，就用 float 版）。
CLA 版只对 F2803x/F2806x/F2837x 有意义；**F28335 没有 CLA**，忽略 `CLA\`。

## 2. 环路结构（四个模块共用）

```
vin ─ PD ─→ ε ─ Loop Filter(PI) ─→ Δω ─→ VCO(1/s, 积分) ─→ θ ─→ sin/cos ─┐
        ↑                                                                  │
        └──────────────────────────────────────────────────────────────────┘
```

- **PD**：单相 `ε = vin·cosθ`（含 2ω）；SOGI `ε = cosθ·v' + sinθ·qv'`；三相将按输入相位约定得到的鉴相误差送入结构体 `v_q`
- **LF**：双线性离散 PI → `ylf[n] = ylf[n-1] + B0·ε[n] + B1·ε[n-1]`
- **VCO**：`fo = fn + ylf`，`θ += 2π·fo·Ts`

## 3. SOGI（二阶广义积分器）—— 单相的关键

模拟域（Ciobotaru PESC'06）：

```
D(s) = v'/v  = k·ωn·s / (s² + k·ωn·s + ωn²)      ← 同相分量，谐振点增益 1、相移 0
Q(s) = qv'/v = k·ωn² / (s² + k·ωn·s + ωn²)       ← 正交分量，谐振点增益 1、相移 -90°
```

`k` 越小选频越窄、抗谐波越好但响应越慢。**TI 把 k 硬编码成 0.5**（`SPLL_1ph_SOGI_F_coeff_update`）。

双线性离散（`float\source\SPLL_1ph_SOGI_F.c` 逐行对应）：

```c
x = 2·k·wn·Ts;              // TI: osg_x = 2*0.5*wn*delta_T
y = (wn·Ts)²;               // TI: osg_y
t = 1/(x + y + 4);          // TI: temp
b0  =  x*t;   b2 = -b0;
a1  = 2(4-y)*t;   a2 = (x-y-4)*t;
qb0 = 0.5*y*t;  qb1 = 2*qb0;  qb2 = qb0;
```

运行（**注意移位顺序，见 §7 坑 1**）：

```c
v'  = b0*(u[0]-u[2]) + a1*v'[1]  + a2*v'[2];      // 同相
qv' = qb0*u[0] + qb1*u[1] + qb2*u[2] + a1*qv'[1] + a2*qv'[2];  // 正交
```

数值校验（Ts=50us, 50Hz）：`|Hd|=1.0000 / 0.0°`，`|Hq|=1.0000 / -90.0°` —— 严格正交、单位增益。
但在 52Hz 变成 `|Hd|=0.9879 / -8.92°`、`|Hq|=0.9499 / -98.92°`（仍正交，但**整体有相移**，见坑 3）。

## 4. Park 与符号约定（**最容易搞错的地方**）

TI `SPLL_1ph_SOGI_F` 里：

```
u_Q = cosθ·v' + sinθ·qv'      → 锁定时 = 0，就是误差 ε
u_D = cosθ·qv' - sinθ·v'      → 锁定时 = -V   ← 负号！
```

推导：`vin = V sin(ωt)` → `v' = V sin ωt`，`qv' = -V cos ωt`
→ `u_Q = V sin(ωt-θ)`，`u_D = -V cos(ωt-θ)`。

**结论（实测确认）**：
1. `sinθ` 与输入 `vin` **同相**，`θ` 就是电网相位；
2. 幅值要取 `-u_D`（或 `u_D` 取绝对值/取负），直接拿 `u_D` 当 Vd 会得到负的幅值；
3. `SPLL_1ph_F`（陷波版）也是 `sin` 与输入同相（PD 用 `cos`，DC 分量 `0.5V sin(θg-θ)`）。

三相 `ABC_DQ0_POS_F`：`d = αcosθ+βsinθ`，`q = -αsinθ+βcosθ`。若 `va=V cosφ`、`vb=V cos(φ−2π/3)`、`vc=V cos(φ+2π/3)`，则 `d=V cos(φ−θ)`、`q=V sin(φ−θ)`；**q 是该约定下的鉴相误差**。若三相改用 `sin` 型，则 `d=V sin(φ−θ)`、`q=−V cos(φ−θ)`；**d 是该约定下的鉴相误差**。`SPLL_3ph_SRF_F` 的 `v_q` 只是反馈字段名，应按实际相序、相位定义和负反馈方向选择 d/q。盲目照抄另一种输入的接线，会造成 90° 偏差或锁相失败。工程里的 dq 角度约定见 `c28x-pitfalls.md`。

## 5. 环路滤波器整定（`spll_coeff_compute.xlsx` 的原公式）

给定：整定时间 `ts`、阻尼比 `ζ`（一般 0.707）、允许误差带 `δ`：

```
c  = 1/sqrt(1-ζ²)
wn = ln(c/δ) / (ζ·ts)
Ti = 2ζ/wn
Kp = wn²·Ti
Ki = wn²
B0 = (2Kp + Ki·Ts)/2          # Ts = 1/ISR频率
B1 = -(2Kp - Ki·Ts)/2
```

TI 推荐锚点：`ts=30ms, ζ=0.7, δ=5%` → `wn=119.0 rad/s`（19Hz），`Kp=166.6`，`Ki=27755.5`。
文档里 `B0=166.8776 / B1=-166.3224` 对应 **50kHz**；源码 init 里写死的 `166.9743 / -166.266` 反推 `Kp=166.62`、`Ki·Ts=0.7083` → **约 39kHz**，两者都不是 20kHz。
**所以：绝不要沿用 init 里的硬编码系数，按自己的 Ts 重算后再写进去。**

公式在 20kHz 下的常用组合（可直接抄，Ts=50us）：

| fs | Ts | Kp | Ki | B0 | B1 |
|---|---|---|---|---|---|
| 10 kHz | 100 us | 166.6 | 27755.5 | 168.0 | -165.2 |
| 20 kHz | 50 us | 166.6 | 27755.5 | 167.29 | -165.91 |
| 50 kHz | 20 us | 166.6 | 27755.5 | 166.88 | -166.32 |

需要更快的锁相（相位跳变恢复 <20ms）就减 `ts`（如 15~20ms），但 PI 带宽过大会把 2ω/谐波放进来（SOGI 版好一些，陷波版容易失锁）。

## 6. 各模块的调用开销 / 使用要点（F28335, 150MHz, FPU32）

- `SPLL_1ph_SOGI_F`：每拍 2 次 `sin/cos`（RTS 库，约 1~2 us@150MHz）+ 约 30 次浮点乘加。20kHz 下没问题。
  想省时间：θ 用查表/`IQsin`，或按 100us 调用（2 个控制周期调 1 次，相位误差 = 0.0314 rad·频率偏差，可接受）。
- `SPLL_3ph_SRF_F`：只要 1 次 sin/cos + Clark/Park，最省。
- `SPLL_3ph_DDSRF_F`：额外 4 个一阶 LPF + `sin/cos(2θ)`，且必须先算 `ABC_DQ0_POS/NEG`。
- 采样必须与 PWM 同步（EPWM 中断里调），否则电网频率 50Hz 与 ISR 不同步会产生拍频纹波。

## 7. 踩坑清单（全部经本次复现/读码确认）

1. **移位顺序不能"交换"，必须"当前值同时写 [1] 和 [0]"**
   TI 写法：
   ```c
   osg_u[0] = <新值>;
   osg_u[2] = osg_u[1];
   osg_u[1] = osg_u[0];     // ← 赋的是刚算的新值
   ```
   用别的语言/习惯写法 `[2]=[1]; [1]=[0]; [0]=新值` 会让反馈晚一拍。实测：晚一拍 → `a1·y[n-1]` 项恒为 0 → **滤波器直接发散到 1e98**（我复现时就踩了这个，收敛前先爆炸）。
2. **`SPLL_1ph_SOGI_F` 的 `θ` 超 2π 时归 0 而不是减 2π**
   `if(theta > 2π) theta = 0;` —— 每周期丢掉超出量（相位小跳变）。三相模块写的是 `theta -= 2π`（正确）。移植时统一改成减法。
3. **SOGI 的 ωn 是固定值 → 频率偏离额定就有稳态相位误差**
   实测 52Hz：SOGI 相移 -8.92° → 输出 θ 有 **≈9° 固定偏差**，`fo` 还带 ±2Hz 纹波（两支路幅值不等引起）。
   改进：用 `fo` 周期性（如每 20~50ms）重算 `osg_coeff`（自适应 SOGI），实测偏差从 8.9° 降到约 2°、纹波减半。
   固定频率场合（50Hz±0.5Hz）可不管。
4. **init 里硬编码的 `B0/B1` 与实际采样率不匹配**（见 §5）——必须按 Ts 重算。
5. **IQ 版 Q 格式各不相同**：SOGI 用 `IQ23`、SRF 用 `IQ21`、DDSRF 用 `IQ22`，而 `ABC_DQ0_*` 输出是 `IQ24`。跨模块传递要移位（`>>1` / `>>2` / `<<3`），漏了就是比例错 2^n 倍。
6. **`SPLL_1ph_F` 的 `theta` 是 0~1 标幺**（`θ += wo·Ts/(2π)`），`SPLL_1ph_SOGI_F` 的 `theta` 是 0~2π 弧度。两模块混用会差 2π。
7. **`SPLL_1ph_F` 的 sin/cos 是前向欧拉自激振荡器**（`sin += Δt·wo·cos`），幅值会漂，靠 `±0.99` 限幅兜住 —— 精度不如 SOGI 版按 θ 查表。
8. **`SPLL_1ph_F` 的陷波器要单独 init**：`SPLL_1ph_F_notch_coeff_update(Ts, 2·2π·fgrid, c2=0.00001, c1=0.1, &spll)`，漏调 → 2ω 不被滤除，`fo` 抖 ±1Hz。
9. **F28335 没有 CLA**：别把 `CLA\` 目录的东西加进工程（`Cla1Regs` 不存在）。
10. 首次调用时 `sin=cos=0` → `u_Q=0`，PLL 从第 2 拍才开始工作；`fo` 要由 `fn+ylf` 给出（init 里 `fo=0` 无害，但别拿第一拍的 `fo` 当"频率读数"）。

## 8. 移植到现有 28335 工程的最小做法

1. 从 `F:\controlSUITE\libs\app_libs\solar\v1.2\float\{include,source}` 拷 4 个文件（`Solar_F.h`、`SPLL_1ph_SOGI_F.h/.c`，如需三相再加 `ABC_DQ0_POS_F.h/.c`、`SPLL_3ph_SRF_F.h/.c`）。
2. 新增目录必须补 `.cproject` 的 include 路径（否则 `cannot open source file`）。
3. 初始化（`main` 里，`InitSysCtrl()` 之后）：
   ```c
   SPLL_1ph_SOGI_F_init(GRID_FREQ, (float32)(1.0/ISR_FREQ), &spll1);
   SPLL_1ph_SOGI_F_coeff_update((float32)(1.0/ISR_FREQ), (float32)(2*PI*GRID_FREQ), &spll1);
   spll1.lpf_coeff.B0_lf = <按 §5 算>;   spll1.lpf_coeff.B1_lf = <按 §5 算>;
   ```
4. ISR 里（与 ADC 同步）：
   ```c
   spll1.u[0] = (float32)vgrid_pu;      // 标幺 -1..1，ADC 采样后归一化
   SPLL_1ph_SOGI_F_FUNC(&spll1);        // 或 _MACRO，函数版省空间、宏版省调用开销
   // 之后 spll1.theta[0] / spll1.sin / spll1.cos / spll1.fo 可用
   ```
5. 中断里更新、主循环读取 → **必须快照**（`DINT; θ=…; EINT;`），否则串口回读会出现垂直毛刺（见 `ti-official-style.md` §4.5）。

## 9. 参考

- `F:\controlSUITE\libs\app_libs\solar\v1.2\SolarLib.pdf` 第 4.3 章（P66–P107）：SPLL_1ph / SOGI / 3ph SRF / 3ph DDSRF 的完整推导与用法
- `spll_coeff_compute.xlsx`：环路系数计算表（改 `ts/ζ/δ/Fs` 即出 B0/B1）
- 复现脚本与验证图：`%TEMP%\spll_verify.py`、工作区 `spll_ti_verify.png`

## 10. 半拍补偿：10 kHz 合成输入的 PC 数值结果（2026-10-27）

TI 的 `SPLL_3ph_SRF_F` 用**拍首** `theta[0]` 做 Park，但采样到运算之间相位已前进 `ω·Ts/2`。
10 kHz 下 `0.5 × 314 × 100µs = 0.0157 rad = 0.90°`。

PC 仿真（三相平衡正弦 50 Hz，fs = 10 kHz，稳态 5000~6000 拍；目标板未验证）：

| 实现 | 稳态相位误差 | 频率 | vq |
|---|---|---|---|
| TI 原版（无补偿；旧记录，未在本次复跑） | **约 1.802°** | 50.000 Hz | 1.1e-5 |
| TI + 半拍补偿（适配层） | **0.002°** | 50.000 Hz | 1.3e-5 |
| 自研 PLL（Park 补偿、输出不补偿） | **0.902°** | 50.000 Hz | 1.2e-5 |

做法：Park 前把角度换成 `theta + 0.5*omega*Ts`（omega 用上一拍输出）。
单相 SOGI 版同理，实测 1.796°（含 SOGI 自身相移）。

**注意**：这组数据只说明此合成场景中的相位偏差，不能作为实际 ADC 延迟、噪声或 20 kHz 控制系统的误差下限。20 kHz 下半拍相角为 0.45°，是否可接受由应用误差预算决定。

## 11. 本工程内的落地位置（2026-10-27）

| 内容 | 路径 |
|---|---|
| SolarLib 源码（已拷贝） | `2-1SOGI_PLL/Library/solarlib/{include,source}` |
| include path 已加 | `.cproject` -> `Library/solarlib/include` |
| 使用文档 | `Library/solarlib/README.md`（10k/20k 系数表、三处必改、调用顺序）|
| 适配层（与自研 PLL 同接口） | `Library/solarlib_adapter.{h,c}` |
| 切换方式 | `PLL_Update3()` -> `PLL_Update3_TI()`，并调一次 `PLL_TI_Init(10000.0f)` |
| **三相 SOGI（DSOGI）实现**（2026-10-28） | `PLL/dsogi_pll.c`：两块 TI SOGI-QSG 系数 + PNSC + TI SRF 环路 + ω 自适应 |
| **唯一对外接口** | `PLL3_Init(fs_hz)` / `PLL3_Run(va,vb,vc,&theta,&freq)`（`PLL/pll.h`，输入三相电压、输出 θ 与 f） |
| DSOGI 上板结果 | 不平衡下 vq 纹波 0.262→0.001 pu、谐波下 0.348→0.011 pu，见调试案例 §目标板回归 |

**当前 sine 型测试适配层的处理**：覆盖硬编码 B0/B1、`v_q[0] = abc.d`、`fo` 补 20 Hz 低通。换输入相位约定时重新确认反馈轴；2026-10-27 15:28 的主程序源码已接入 TI 适配层，但上板结果仍待验证，见[调试案例](debug-cases/dsp28335/2026-10-27-solarlib-spll-integration.md)。

**本机 SolarLib 副本**：`C:\Users\Jordon\Desktop\contr\v1.2`（另有 `F:\controlSUITE\libs\app_libs\solar\v1.2` 同版本）。
