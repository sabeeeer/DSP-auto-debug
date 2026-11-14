# F28379D：断开调试会话后另起只读是错误设计（2026-11-14）

## 结论

**调试器连接断开后不能读数据。** 所谓“断开后另起只读”不是继续观察，而是重新连接一个已经复位、跑 Flash 的目标；读到的不是本次 RAM 固件。已从 skill 中禁用该路径。

## 实测

### 1. 只 `disconnect()` 也会复位

同一 DSS server 内：

```
BEFORE=520  HALTED=false
DISCONNECTED
（重连时 GEL 又打印 Memory Map Initialization Complete）
RECONNECTED
HALTED_AFTER=true
AFTER=0  DELTA=-520
```

即 `gMsTick` 归零、目标停机，不需要 `terminate()` 或 `server.stop()`。

### 2. DSS 没有“断开不复位”的选项

```
HaltOnDisconnect       -> Option not found
ResetOnDisconnect      -> Option not found
AutoResetOnDisconnect  -> Option not found
PoliteRealtimeMode     -> Option is disabled or readonly
```

CCS GUI 有对应设置，DSS 脚本层拿不到。

### 3. 另起只读必然失败

```
-1138 Device refused to allow debug mode. Power-cycle the board.
-1142 Device blocked debug access ... executing non-debuggable code
READONLY_STATE_ERROR: target halted at connect
```

## DSP28335 对照

28335 另起只读能连上，但案例记录：`gRunMs=11460` 两次不增长、`PC=0x32F06D` 在 Flash 地址，而本次 `.out` 的入口/主程序在 RAM。**读到的不是本次 RAM 固件**。

## 正确做法

唯一允许的路径是**同一 DSS 会话**：

```
connect → reset/halt（只为下载）→ loadProgram → runAsynch
→ 读 N 轮（连接保持）→ disconnect
```

入口：

- 低速：`ti_c2000_run_read.ps1`（不需要 DMA）
- 高速：`ti_c2000_read_dma.ps1 -FrozenBufferReady`（DMA + ping-pong）

禁用入口：`ti_c2000_read_runtime.ps1`、`ti_c2000_read_array_runtime.ps1`、`ti_c2000_debug.ps1 -ReadOnly`，均返回 `FAILURE: READONLY_UNRELIABLE`（exit 2）。

## 判定 RAM 的证据

1. `.cmd` 是 RAM 链接；
2. `loadProgram` 下载 `.out` 到 RAM；
3. 心跳首值 ≤ 10000 且跨轮严格递增；
4. 判据脚本 `ti_c2000_check_read.ps1` 通过。
