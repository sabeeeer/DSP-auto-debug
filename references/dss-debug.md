# CCS 下载与 DSS 运行态读取

执行模式确需更新程序时，`ti_c2000_debug.ps1 -Build -Run` 用 `loadti -r -a` 下载并启动；之后单独调用 `ti_c2000_read_runtime.ps1`。只读任务直接调用读取脚本。`-Build/-Run/-LoadOnly` 与 `-ReadVars` 同次使用会在连接前拒绝。

## 下载/运行边界

| 参数 | 效果 |
|---|---|
| `-Build` | 构建而不下载。 |
| `-Run` | 下载现有 `.out`，复位并异步运行。 |
| `-Build -Run` | 构建成功后下载运行。 |
| `-LoadOnly` | 显式下载后保持暂停；不得用来读取数据。 |

成功看 `RESULT: OK` 与退出码 0，下载还应有 `Done`，运行还应有 `Target running...`。失败先看原始错误、探针/串号、`.ccxml`、供电、目标核和 CCS GUI 是否占用 JTAG；双核与 F28379D 见[器件/探针记录](other-devices-and-probes.md)。

## DSS 只读入口

```powershell
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_runtime.ps1" `
  -ProjectPath "<工程>" -Ccxml "<当前目标配置.ccxml>" `
  -OutFile "<与运行固件匹配的.out>" -Variables "<变量,寄存器>"
```

`dss_template.js` 在 `connect()` **之前**设置 `HaltOnConnect=false`、`AutoResetOnConnect=false`、`RestartOnSymbolLoad=false`、`UseLegacyStopMode=false`、`AllowInterruptsWhenHalted=true`、`PoliteRealtimeMode=true`；之后仅 `symbol.load()` 并读取。固件中的 `ERTM` 与这些调试器选项配合。脚本发现目标已停或实时读取失败就报错，不调用 `halt()`、`runAsynch()`、复位或下载。详细边界见[只读规则](read-only-mode.md)。

用 `-WaitFor "gBootStage == 5" -RunMs 15000` 可在运行态轮询就绪条件；不指定时直接取当前值。条件要能证明**本次**初始化已到目标阶段，宽松的 `.bss != 0` 可能只是 RAM 残值。超时返回失败，超时后打印的变量值不能当作已就绪证据。目标显示 running 也不是应用心跳证明，若有单调计数器，应跨时间核对递增。

大数组用 `ti_c2000_read_array_runtime.ps1` 的固定下标分批读取；每批都在运行态，固件应先冻结缓冲或提供版本号。裸 `connect → halt → readData → runAsynch` 已造成程序中断和继电器释放；[读取事故案例](debug-cases/dsp28335/2026-11-07-read-halt-bulk-array.md)保留原因与证据边界。`readData` 的页、字地址、宽度和数值范围须与表达式读数交叉验证，不因速度快就默认可信。

## 必要的 DSS API 备忘

| 用途 | CCS 12.8 记录 |
|---|---|
| 只装载符号 | `session.symbol.load(out)`；不等于下载程序。 |
| 读表达式 | `session.expression.evaluate(name)`；高频变量逐项读取不是原子快照。 |
| 符号地址 | `session.symbol.getAddress(name)`；本机该版本没有 `lookupSymbol()`。 |
| 读块 | `session.memory.readData(page, address, typeSize, count)`；C28x 的地址与数据解释先验证。 |
| 延时 | `java.lang.Thread.sleep(ms)`；Rhino 没有 `env.sleep()`。 |

换 CCS 版本时可先运行不连接目标板的 `scripts/dss_api_probe.js` 查看 API，再按当前版本验证实时选项。历史只读停核、构建后隐式 `loadti -l` 与浮点读回问题分别见[模式修复案例](debug-cases/dsp28335/2026-11-07-realtime-read-implicit-loadonly.md)和[浮点读回案例](debug-cases/dsp28335/2026-10-28-fpu-dss-float-readback.md)。
