# FPU software 例程的工程选项仍启用 FPU32

## 身份与状态

- 范围：本机 `F:\c2000ware-core-sdk\device_support\f2833x\examples\fpu_software`，TMS320F28335，CGT 22.6.1.LTS。
- 状态：**待复核**。已静态核查并成功构建现有工程，尚未用修正的纯软件浮点选项上板验证。

## 现象与证据

- `Example_2833xFPU_software.c` 注释要求移除 `--float_support=fpu32` 并链接 `rts2800.lib` 或 `rts2800_ml.lib`，以验证软件浮点。
- 同目录 `.cproject` 的 `FLOAT_SUPPORT` 值却为 `fpu32`，链接输入还含 `rts2800_fpu32.lib`。技能构建脚本按当前工程元数据成功编译链接，输出明确列出 `--float_support=fpu32`、`rts2800_fpu32.lib`。因此这份现有工程的构建成功**不能证明软件浮点路径**。原始构建输出见任务 `work/board-tests/fpu_software/build_command.log`。

## 处置

- 如需验证软件浮点，先在工作区副本中把编译和链接选项按源码注释改成无 FPU 支持及相应 RTS 库，检查汇编/映射文件，再上板比对位型。不得直接把当前构建结果登记成“FPU software 上板通过”。
- 其他 SDK 版本需重新核对 `.cproject` 和实际编译命令。
