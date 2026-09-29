# 自动进调试器：loadti 与 DSS 用法（CCS12 实测）

> 两条通道：**loadti**（下载+运行，最简单）与 **DSS**（脚本化会话，可停机读变量）。
> 都由 `scripts/ti_c2000_debug.ps1` 按 `-ReadVars` 是否存在自动选择。

## 0. 前置

```powershell
# 仿真器是否在线（没有就别试下载）
Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match 'XDS' } | Select-Object Name
# CCS GUI 是否占用 JTAG（占用时先关掉里面的调试会话）
Get-Process ccstudio, ccstudio64, eclipsec -ErrorAction SilentlyContinue
```

目标配置用工程自带的 `<工程>\targetConfigs\TMS320F28335.ccxml`（**XDS100v2** + TMS320F28335）。
探针版本与 ccxml 连接类型不一致会出现"能连上但时好时坏"的 `-151`/`-1135`，改法见 other-devices-and-probes.md §3.1。

## 1. loadti（下载 / 复位运行）

```powershell
& '<CCS_ROOT>\ccs_base\scripting\examples\loadti\loadti.bat' `
    '-c=<工程>\targetConfigs\TMS320F28335.ccxml' -r -a '-t=180000' '<工程>\Debug\<工程名>.out'
```

| 选项 | 含义 |
|---|---|
| `-c=<ccxml>` | 目标配置（必需） |
| `-l` | 只加载，不运行 |
| `-r` | 运行前复位目标 |
| `-a` | 异步运行：启动后立即返回（固件是 `while(1)` 时必须用） |
| `-t=<ms>` | 脚本超时，避免永久挂住 |
| `-x=<file>` | 生成 XML 日志（排错用） |

**成功判据（脚本已内置）**：输出里出现 `Loading ... Done` 才算成功；出现 `error/failed` 或没有 `Done` 一律判失败。

## 2. DSS（脚本化调试会话）

```powershell
& '<CCS_ROOT>\ccs_base\scripting\bin\dss.bat' '<脚本>.js'
```

`scripts/dss_template.js` 是模板，占位符 `{{CCXML}} {{OUT}} {{RUN_MS}} {{VARS}} {{MODE}}` 由
`ti_c2000_debug.ps1` 填好后写到临时文件再执行：

- `MODE=full`：`loadProgram` → `target.restart()` → **轮询就绪** → `halt` → 读表达式 → 继续运行 → 断开
- `MODE=readonly`：只 `symbol.load()`（不写内存、不复位）→ `halt` → 读 → 继续运行（用于程序已由 loadti 跑起来、只想读值）

### 就绪轮询（重要）

跑完立刻读会拿到 0（本工程 OLED 模拟 I2C 初始化要 ~3.25 s）。模板因此**每 250 ms 停机采样一次就绪表达式**，
表达式为 `{{WAIT_EXPR}}`，由 PS1 生成：默认取 `-ReadVars` 的第一项 `!= 0`，也可用 `-WaitFor "<expr>"` 指定（如 `GpioCtrlRegs.GPADIR.bit.GPIO8 != 0`）。
命中即打印 `DSS: ready ('...') after N ms` 再正式读值；到预算（默认 8000 ms，`-RunMs` 可改）仍未命中会打印 WARNING 并照常读回。
轮询用 `isHalted()` 做保护、静默捕获异常，不会污染失败判定。

#### 判据怎么选（实测踩坑，2026-09 于 4-1Two_Level）

| 判据 | 结果 |
|---|---|
| `.bss` 全局变量（如 `OpenLoopCtrl.usCmpA != 0`、`xxx.usEnable == 1`） | **不可靠**：`loadProgram()` 不清 `.bss`，上次运行留下的 RAM 值会让它在 250 ms 就"就绪"，而此时 `EPwm1Regs.TBPRD` / `SCIA.SCILBAUD` 还是 0 —— 程序根本还没跑到初始化 |
| 外设寄存器（如 `EPwm1Regs.TBPRD == 14999`、`SciaRegs.SCILBAUD != 0`） | 可靠，实测 3500 ms 命中，且与源码里的赋值一一对应 |

判据最好选"**只有执行到某段代码才会被写成那个值**"的量（初始化里写死的 TBPRD/分频/波特率）。
模板现在对"≤500 ms 就就绪"会额外打印 NOTE 提醒可能是残留值；看到这个 NOTE 就换寄存器判据重读一次。

**★补充（2026-09-29，同一工程）：`.bss` 变量也能用，关键在判据要写"具体值"**

上面那条更准确的说法是：**`!= 0` 这类宽松判据不可靠，`== 具体目标值` 是可靠的。**

- **踩坑实例**：某次用 `-WaitFor "gBootStage != 0"`（该变量在 `main()` 第一行置 1）。
  结果**一进 main 就满足**，而程序当时还在 `vOpenLoopInit()` 里做上电闪灯标记 ——
  `vBoard_RollbackMark()` 是**阻塞式**的（`for` 里 `DELAY_US(700000)` + `DELAY_US(300000)`，
  本项目闪 3 次加收尾 0.5s ≈ **3.5 秒**）。
  于是读回一堆"未配置"状态：`EPwm1Regs.TBPRD = 0`、`ETSEL.all = 0`、`PIEIER3.all = 0`、`IER = 0`，
  看着像"EPWM 完全没配"，其实只是**还没跑到那一步**；串口抓包也只抓了 31ms（程序在闪灯），
  于是"数据恒定不变"，又像"调制器没工作"。前后白排查好几轮，甚至一度怀疑
  "EPWM 配置被覆盖"和"看门狗复位"。
- **正确做法**：判据写**目标值** —— `-WaitFor "gBootStage == 5"`（5 = 已进主循环），
  或继续用外设寄存器（`EPwm1Regs.TBPRD == 7500`）。
- **通用口诀**：当"读到的值既是残留、也可能是真实状态"时，**先确认程序跑到哪一步**，再解读寄存器。

**★推荐习惯：在 `main()` 里埋"启动阶段追踪变量"**

```c
volatile Uint16 gBootStage = 0;   /* 0=未进main 1=进main 2=初始化完 … 5=进主循环 */
/* 每个关键步骤后赋值；初始化函数内部再细分（如 11~19 = 某 init 的各步）*/
```
- 启动卡住时，**读这一个变量就能定位到具体哪一行**（本例正是靠它发现"卡"在闪灯阻塞里）
- 配合 `-WaitFor "gBootStage == N"` 顺带充当可靠的就绪判据
- 代价只有一个 `Uint16`，建议每个工程都留一份

**★"读太早"的典型误判清单**（看到这些先别下结论）

| 读到的现象 | 先怀疑 | 而不是 |
|---|---|---|
| `TBPRD / ETSEL / ETPS / PIEIERx / IER` 全为 0 | 程序还没跑到 PWM 初始化 | "EPWM 配置被覆盖了" |
| 串口抓包"数据恒定不变" | 程序仍在启动阶段（本项目 3.5 s 闪灯） | "调制器没工作 / 没发波" |
| 变量是"上次运行的合理值"（如 `fFreq = 50`，而本次传 5） | RAM 残留（`loadProgram()` 不清 `.bss`） | "我的改动没生效 / 没编进去" |
| `TBCTR` 不变、`theta` 不动 | 同上，先确认阶段 | "中断没跑 / 时钟没开" |

**跑 RAM 程序的关键**：`memory.loadProgram()` 本身**不会**把 PC 指到程序入口，复位后又默认跑 Flash 里的旧程序。
所以模板用 `target.restart()`（等价 CCS 的 Restart：复位并跳到加载程序的入口）；若该版本没有 `restart()`，
退回 `target.reset()` + `memory.writeRegister("PC", symbol.getAddress("code_start"))` + `runAsynch()`（实测 `code_start=0x0` 可用）。

### CCS12.8 实测 API 备忘

| 需求 | 写法 |
|---|---|
| 取会话 | `env.getServer("DebugServer.1")` → `setConfig(ccxml)` → `openSession(".*")` |
| 连接/运行控制 | `session.target.connect() / reset() / restart() / run() / runAsynch() / halt() / isHalted() / disconnect()` |
| 加载程序 | `session.memory.loadProgram(path)`（同时装载符号） |
| 只加载符号 | `session.symbol.load(path)` |
| **寄存器读写** | `session.memory.readRegister("PC")` / `session.memory.writeRegister("PC", val)` ← 没有 `session.registers` |
| 符号地址 | `session.symbol.getAddress("code_start")`（`lookupSymbol()` 在此版本不存在） |
| 表达式/变量 | `session.expression.evaluate("EPwm1Regs.TBPRD")`（返回可直接打印的值） |
| 延时 | `java.lang.Thread.sleep(ms)`（Rhino 没有 `env.sleep`） |
| 路径转义 | JS 字符串里的 Windows 路径要双反斜杠（模板由 PS1 自动处理） |

换成别的 CCS 版本时，先跑 `scripts/dss_api_probe.js` 反射出真实成员名，再改模板。

## 3. 排错对照

| 现象 | 原因 / 处置 |
|---|---|
| `JS: TypeError: Cannot find function sleep` | 用了 `env.sleep`；改 `java.lang.Thread.sleep(ms)` |
| `Cannot call method "writeRegister" of undefined` | `session.registers` 不存在；改 `session.memory.writeRegister` |
| `identifier not found: EPwm1Regs` | 会话没装载符号：full 模式用 `loadProgram`，readonly 模式要先 `symbol.load` |
| 读回全是 0 | ① 程序没跑到（换/加大 `-WaitFor` 与 `-RunMs`，别用固定等待）② 外设时钟未开（对应模块的 `PCLKCRx` 位没使能）③ 实际跑的是 Flash 旧程序（没做 `restart()`/写 PC） |
| 想确认"到底跑到哪了" | 读 `PC`，再拿 map 文件（`%TEMP%\ti_c2000_build\<工程>\<工程>.map`）查该地址落在哪个函数；配合 `GpioCtrlRegs.GPADIR`、`SysCtrlRegs.PCLKCR1` 判断初始化进度 |
| `Error reading memory: Address: 0x7012 ... 0x20000` | 用 `memory.readWord` 直接读外设帧会失败，改走 `expression.evaluate`（如 `SysCtrlRegs.PCLKCR1.all`） |
| `no probe / cannot connect` | 仿真器未插/板未上电，或 CCS GUI 占用了 JTAG |
| loadti 输出无 `Done` | 连接失败或目标被占用；加 `-x=<log>` 看详细日志 |
| 读回值与代码不符 | 先核对"哪个程序在跑"：读 `PC` 并用 map 文件查它落在哪个函数 |

## 4. 长时调试（几分钟级）

- 就绪轮询命中即返回，`-RunMs` 只是上限：大程序直接给 `-RunMs 300000`（5 分钟）不会白等。
- 下载慢（大 `.out`）时同时给 `loadti` 加超时：`-TimeoutSec 600`。
- **DSS 默认 `scriptTimeout = -1`（不超时）**，模板会显式设成 `预算 + 300 s`；真正会打断长等待的是上层命令/IDE 超时。
  规避方式：`-Background` 让脚本自分离运行（`Start-Process` + 日志重定向），立即返回日志路径，之后轮询：
  `Select-String -Path <log> -Pattern 'RESULT|^VAR |ready'`。实测 20 s 预算的后台任务在 3.0 s 命中就绪并写入 `RESULT: OK`。

## 5. 会话卫生

- 每次运行都新建/关闭 DSS 会话，脚本结束前 `disconnect()` + `server.stop()`，避免占用 JTAG 影响 CCS GUI。
- `-ReadOnly` 模式不动目标内存，适合"程序正在跑，只想采样变量"。
- 读回采样点：先 `halt()` 再 `evaluate`，读完 `runAsynch()` 恢复运行；要观察变化可连续多次采样。
