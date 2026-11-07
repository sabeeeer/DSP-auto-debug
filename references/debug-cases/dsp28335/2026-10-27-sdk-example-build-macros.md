# 官方 eCAP 例程直接交给通用构建脚本时缺少 CCS 产品变量

## 身份与状态

- 器件/模块：TMS320F28335，eCAP 官方例程 `F:\c2000ware-core-sdk\device_support\f2833x\examples\ecap_capture_pwm`，SDK v26；CCS 12.8.1、C2000 CGT 22.6.1.LTS。
- 状态：**已回归（构建适配）**。2026-10-28 已修复脚本解析并在同一 eCAP 官方工程重构通过；另有多类 F2833x 官方例程在当前板各运行 3 次。`ecap_capture_pwm` 的捕获功能尚未通过，不属于本构建结论；上板故障另见 [eCAP 案例](2026-10-28-ecap-gpio24-no-edge.md)。
- 2026-10-27 构建日志：`C:\Users\Jordon\Documents\Codex\2026-10-27\ti-c2000-ccs-auto\work\build-ecap-f2833x\build.log`。构建输出放在任务 `work/`，未修改 SDK 源码，也未把旧 `.out` 计作成功。

## 现象与证据

- 调用 `ti_c2000_build.ps1 -ProjectPath <上述例程> -OutputDir <任务 work/build-ecap-f2833x> -NoStage -KeepLaunches` 后退出码 1，`RESULT: FAIL`、`FAILURE: COMPILE_ERRORS`。日志先报告 `${INSTALLROOT_2833X}`、`${INSTALLROOT_IQMATH}`、`${INSTALLROOT_FASTRTS}` include 路径不存在，随后报 `#1046 invalid macro definition: "_DEBUG"`，链接步骤跳过。
- `.cproject` 的 `<stringMacro>` 把 `INSTALLROOT_2833X` 等定义成相对于 `${PROJECT_ROOT}` 的 SDK 路径；`.project` 的 `linkedResources` 还引入 common/headers 中的源文件与 `.cmd`。现有通用脚本只从项目文件夹收源文件并只展开少数宏，因而只找到 1 个 `.c` 且未找到链接脚本。
- 该失败是**构建脚本不适配此官方工程元数据**，不是 TI eCAP 源码的编译错误。

## 修复与回归（2026-10-28）

- 按本技能 `AGENTS.md`，修改脚本前后分别执行 `tests/test_setup_failure.ps1`，两次均 `RESULT: OK`、退出码 0。
- `scripts/ti_c2000_build.ps1` 现在解析 `.cproject` 的 `<stringMacro>`、`${PROJECT_ROOT}` 和 `INSTALLROOT_*`，把 `.project` 的 `linkedResources` 中 `.c/.asm/.cmd/.lib` 纳入构建；并去掉 CCS 宏定义外层引号，避免 `#1046 invalid macro definition: "_DEBUG"`。修改不改变 SDK 源码。
- 用原来的 `ecap_capture_pwm` 工程和 `-NoStage -KeepLaunches` 重试：解析 13 个 linked resources，编译 12 个源文件，以 `28335_RAM_lnk.cmd` 和 `DSP2833x_Headers_nonBIOS.cmd` 链接，零警告，生成 `Example_2833xECap_Capture_Pwm.out` 与 `.map`，`RESULT: OK`、退出码 0。日志仍在上述 `work\build-ecap-f2833x\build.log`。
- 相同脚本构建 CPU Timer、SCI、SPI、ePWM、ADC、eCAP APWM、DMA、eCAN、McBSP 例程，均零警告并上板三次通过；每类读回见[第一类上板记录](../../board-tests-dsp28335.md)。这些运行验证脚本生成固件可下载执行，但**不代表** eCAP 捕获功能已通过。

## 仍待验证

用户确认 GPIO4→GPIO24 测试跳线，且 GPIO4 未接驱动器/电机；但 GPIO 连通性诊断显示 GPIO24 不跟随 GPIO4。按用户要求暂缓 eCAP；恢复后先核查实际排针/电气连接，再对 `ecap_capture_pwm` 做三次捕获读回并保存捕获寄存器与引脚波形。换 SDK/器件时仍需核查其他 CCS 产品变量和链接资源格式。
