# DSP28335：只读模板停核与默认下载后不运行

- 状态：**已定位**
- 适用范围：DSP28335 + XDS100v2、CCS 12.8.1、`4-1Two_Level_CloseLoop` 的 2026-11-07 现场；脚本默认分支的缺陷不限于该器件，其他目标尚未上板复核。
- 模块：DSS 实时访问、`loadti`、运行状态判读。
- 现象：用户要求“不下载、不停机、直接看”；旧 `-ReadOnly` 模板会 `halt()` 后读值。旧 `ti_c2000_debug.ps1 -Build` 会在构建成功后继续走默认 `loadti -l`，把程序下载后留在暂停态。

## 证据

1. 修改前的 `scripts/dss_template.js` 在只读分支中调用 `session.target.halt()`，读完再 `runAsynch()`。当日独立查询本机 CCS12.8 DSS 选项，`HaltOnConnect=true`、`AllowInterruptsWhenHalted=false`、`UseLegacyStopMode=false`、`RestartOnSymbolLoad=false`；因此即使临时 `read_runtime.js` 没写 `halt()`，连接阶段仍可能先停核。
2. 修改前的 `scripts/ti_c2000_debug.ps1` 在无 `-Run/-LoadOnly` 时默认加 `-l`；`-Build` 结束后没有退出。TI 的 `loadti` 定义 `-l` 为只加载，`-a` 为异步运行。
3. 新运行态脚本在本机板上读回：`DSS: target at connect was running`、`gBootStage=5`、`EPwm1Regs.TBPRD=7500`、`DSS: target still running after read`、`RESULT: OK`、退出码 0；没有编译、下载或脚本显式停核。第二次带 `-WaitFor "gBootStage == 5"` 仍在运行态返回 `RESULT: OK`。
4. 两次读回 `gRunMs` 均为 `11460`，不能据此声称**当前 RAM 版程序**在前进。追加运行态读取 `PC=3338349=0x32F06D`，而当前 `Debug/4-1Close_Loop.map` 入口 `_c_int00=0xB3EE`、`_main=0xB497`，位于 RAM。**推断**：目标虽显示 running，但正在执行 Flash 地址代码，而非这份 RAM `.out`。
5. **后续判定（2026-11-14）**：本次 RAM `.out` 的入口 `_c_int00=0xB3EE`、`_main=0xB497`；现场另起只读的 PC 为 `0x32F06D`，位于 Flash 区。可以判定这次读取**没有证明 RAM 镜像正在执行**；Flash 中程序的具体版本/身份仍未核实，也未在这块板上证明是哪一步造成执行路径改变。F28379D 的另一次现场实测了 `disconnect()` 后计数归零和停机；该观测不能代替 DSP28335 上的因果实验。以后验证新 RAM 固件用同一 DSS 会话加载、运行、读数，不为补读反复加载。当前未再次下载或启动 PWM 工程。

## 修复与边界

- `scripts/ti_c2000_read_runtime.ps1` 作为正式入口，转到同一版控 DSS 模板。连接前关闭自动停核、自动复位、符号加载重启和 legacy stop，打开实时模式及 polite mode；只装载符号，在运行态读值。目标已停或读取中停机时报错，不自动启动。
- `ti_c2000_debug.ps1 -Build` 单独使用只构建；下载并运行必须显式 `-Run`，下载后暂停必须显式 `-LoadOnly`；无动作参数被拒绝。`tests/test_mode_dispatch.ps1` 在隔离假工程中验证这三条，`RESULT: OK`、退出码 0。
- 运行态多个变量逐项读取并非原子快照；`isHalted=false` 只证明调试会话状态，不能证明 PC 在目标 `.out`，也不能证明主循环计数在增长。板上“新 RAM 固件下载后持续运行”的回归尚未做，不能标记为上板运行已回归。
- 后续静态复核发现原 `-ReadOnly` 仅用禁用符号的正则黑名单过滤 DSS 表达式；现在改成只接受变量/字段/固定下标与简单只读比较，连接前拒绝赋值、调用及任意 C 表达式。隔离测试覆盖危险表达式和合法等待条件，未因此重新连接目标板。即使表达式安全，读清除寄存器仍须按芯片手册判断，且 `.out` 与运行固件的身份问题仍未自动解决。

TI 依据：[CCS 12.8 实时访问与自动停核选项](https://software-dl.ti.com/ccs/esd/documents/users_guide_12.8.0/ccs_debug-main.html)、[DSS 实时选项 API](https://software-dl.ti.com/ccs/esd/documents/users_guide_12.0.0/sdto_dss_handbook.html)、[loadti 参数定义](https://software-dl.ti.com/ccs/esd/documents/sdto_dss_loadti.html)。
