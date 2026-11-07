# DSP28335：下载后用裸 DSS 读数组导致停核

- 状态：**待复核**（用户复盘与现有源码已对照；本次没有重新连接、下载或上板读数）。
- 适用范围：DSP28335、CCS 12.8、`4-1Two_Level_CloseLoop`，2026-11-07；其他器件/CCS 版本需各自验证。
- 模块：CCS DSS、运行态读取、ADC 16 路缓冲。
- 原始记录：`C:/Users/Jordon/Desktop/DSP28335_读取操作复盘_2026-11-07.md`。

## 现场经过与证据边界

用户记录：修改 ADC 校准计时和 `gAdcAllBuf[16][400]` 后，第一次构建因旧缓冲重复定义失败，第二次构建成功，随后显式 `-Run` 下载并启动。运行态读到 `usZeroTick=15256`、`usZeroTimeMs=1525`、`gAdcBufFull=1`。这些数值来自复盘，缺少本次独立原始日志和固件构建标识。

之后三次临时 `dss.bat` 脚本用了 `connect → halt → readData/evaluate → runAsynch → disconnect`。用户报告 `runAsynch()` 发出后曾出现 `gRunMs` 增量为 0，目标最终处于 halt、继电器释放。**不能把“调用了 `runAsynch`”或“`isHalted()==false`”当成应用已经持续执行的证据。**复盘提议“连接后记录 `wasRunning` 再恢复”，但连接时可能已经自动停核，连接后的状态不能还原连接前状态；这不是运行态只读方案。

同批裸 `memory.readData` 结果里出现 62516/65012（超过右对齐 12 位 ADC 的 4095 上限），16 路统计又完全一样；尝试将地址 `0xC000` 乘 2 后直接越界。**只可判定这批数据和寻址/类型解释不可信**，不能据此断言 DSS `readData` 在所有 C28x/CCS 组合上不可用。需先用符号地址、C28x 字寻址、元素宽度、维度步长及少量 `expression.evaluate` 值交叉核对。

当前工程源码静态核对：`cl_adc.c` 定义 `gAdcAllBuf[16][CL_ADC_BUF_FRAMES]`，ISR 取 `usResult[k] & 0x0FFF`，录满后 `gAdcBufFull=1` 停止写；`cl_adc.h` 的数组维度为 16×400。`main.c`、`cl_adc.h` 中仍有“用 `memory.readData` 一次批量读出”的旧注释，不能当作当前技能的读取指令。

## 技能修正

1. 新程序先 `ti_c2000_debug.ps1 -Build -Run`，确认构建、下载、运行各自成功；变量读取再调用 `ti_c2000_read_runtime.ps1` 或显式 `-ReadOnly -ReadVars`。`-Build/-Run/-LoadOnly` 与 `-ReadVars` 同时出现会在碰硬件前拒绝。
2. `dss_template.js` 只保留运行态读取：在 `connect()` 前设置非停核实时选项，仅 `symbol.load()`，逐项读取时检查目标仍显示运行；没有主动 `halt`、`runAsynch`、复位或下载路径。已停机则报错，不试图由只读脚本重启。
3. 大数组用 `scripts/ti_c2000_read_array_runtime.ps1` 分批调用正式只读入口：先在运行态等 `gAdcBufFull==1`，按固定下标读取，逐项检查 0～4095 和通道差异，保存 CSV；批次之间若固件会继续改写缓冲，应在固件内准备冻结/序号机制。额外核对板上固件与 `.out` 身份。
4. 已将 `%TEMP%/read_16ch.js`、`%TEMP%/test_read.js` 改为连接前关闭自动停核、运行态读数，检查目标状态及 `gRunMs` 是否持续递增。前者试用运行态 `readData`，仅在 12 位范围与表达式锚点一致时采用，失败则在运行态逐点读取；导出前 200 帧作为 10 周期数据。后者只测试字地址/行步长与表达式是否相符。两脚本均不主动停核、复位、重新下载或用 `runAsynch` 恢复；正式长期入口是版本化的分批 PowerShell 脚本，临时脚本不作为移植时的依赖。

## 回归边界

隔离测试能证明命令分流和模板中没有停核/下载调用；本次尚未在当前板上重新运行 6400 点读取，也未验证继电器状态、`gRunMs` 增量或 `memory.readData` 的确切寻址错误。上板回归须记录每次命令、`RESULT`、退出码、目标状态与计数器前后值。
