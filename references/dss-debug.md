# 自动进调试器：loadti 与 DSS 用法（CCS12 实测）

> 两条通道：**loadti**（下载+运行，最简单）与 **DSS**（脚本化会话，可停机读变量）。
> 都由 `scripts/ti_c2000_debug.ps1` 按 `-ReadVars` 是否存在自动选择。

## 0. 前置

```powershell
# 仿真器是否在线（没有就别试下载）
Get-WmiObject Win32_PnPEntity | Where-Object { $_.Name -match 'XDS' } | Select Name
# CCS GUI 是否占用 JTAG（占用时先关掉里面的调试会话）
Get-Process ccstudio, ccstudio64, eclipsec -ErrorAction SilentlyContinue
```

目标配置用工程自带的 `<工程>\targetConfigs\TMS320F28335.ccxml`（XDS100v1 + TMS320F28335）。

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
