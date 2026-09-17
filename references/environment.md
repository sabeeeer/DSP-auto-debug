# 本机实测环境（2026-09-17 记录）

## 工具链位置

| 用途 | 路径 | 状态 |
|---|---|---|
| **CCS 12.8.1.00005（主力）** | `F:\ccs`（注册表 `HKLM\SOFTWARE\Texas Instruments\Code Composer Studio 12.8.1.00005` → Location=F:\） | 已安装 |
| CCS12 GUI | `F:\ccs\eclipse\ccstudio.exe` / 命令行 `eclipsec.exe` | 存在 |
| CCS12 的 C2000 编译器 | `F:\ccs\tools\compiler\ti-cgt-c2000_22.6.1.LTS` | 存在（COFF + EABI 运行库都在） |
| CCS12 的 DSS | `F:\ccs\ccs_base\scripting\bin\dss.bat` | 存在 |
| CCS12 的 loadti | `F:\ccs\ccs_base\scripting\examples\loadti\loadti.bat` | 存在 |
| CCS12 的 make | `F:\ccs\utils\bin\gmake.exe` | 存在 |
| CCS 6（备选，老工程用） | `C:\ti\ccsv6`（另有安装包 `F:\CCS6\CCS6.1.3.00034_win32`） | 已安装 |
| CCS6 的 C2000 编译器 | `C:\ti\ccsv6\tools\compiler\ti-cgt-c2000_15.12.1.LTS` | 存在 |
| CCS6 的 DSS / loadti | `C:\ti\ccsv6\ccs_base\scripting\{bin\dss.bat, examples\loadti\loadti.bat}` | 存在 |
| 目标配置 | `<工程>\targetConfigs\TMS320F28335.ccxml` | XDS100v1 + TMS320F28335 |
| 头文件来源 | `E:\DSP8233x_ProjectExample\DSP2833x_Libraries\DSP2833x_common\include`、`...\DSP2833x_headers\include` | 工程 `.cproject` 用绝对路径引用 E 盘，**编译硬依赖** |
| 仿真器 | XDS100（Windows 枚举为 `XDS100 Class USB Serial Port (COM9)` / `XDS100 Class Debug Port` / `XDS100 Class Auxiliary Port`） | 已连接可用 |

`D:\ti` 目前为空目录，不要在那里找工具。

## 已验证（有实测证据）

- **编译**：35 个源文件（32×`.c` + 3×`.asm`）全量编译，0 warning。
  - 用 CCS6 的 `ti-cgt-c2000_15.12.1.LTS`：`RESULT: OK`
  - 用 CCS12 的 `ti-cgt-c2000_22.6.1.LTS`：`RESULT: OK`（工程 `.cproject` 是 `OUTPUT_FORMAT=COFF`，22.6.1 仍支持 COFF）
- **链接**：`28335_RAM_lnk.cmd` + `DSP2833x_Headers_nonBIOS.cmd` + `IQmath.lib` + `rts2800_fpu32.lib` → `.out` 生成成功。
- **失败可判定**：语法错误 → cl2000 非零退出 + `error #29`；未定义符号 → 链接退出码 1 且不产出 `.out`（实测 `neg.out_exists=False`）。
- **CCS12 全自动调试闭环（实测成功）**：
  `ti_c2000_debug.ps1 -Build -Run -RunMs 4000 -ReadVars "PC,EPwm1Regs.TBPRD,..."` →
  自动检测到 `F:\ccs`、用 22.6.1 构建、DSS 连接 XDS100、加载、`target.restart()`、运行、停机读回：
  `TBPRD=65535`、`CMPA.all=0xCCCC0000`(即 CMPA=0xCCCC=52428=65535×80%)、`TBCTL.CLKDIV=3`、
  `GPADIR.bit.GPIO8=1`(OLED 初始化已执行)、`GPAMUX1.bit.GPIO0=1`(EPWM1A 复用已配置)、`SCILBAUD=39`(115200bps)
  → 与 `User/main.c` 逐项吻合。
- **无仿真器时**：`ti_c2000_debug.ps1` 会打印 `PROBE : NOT FOUND` + 中文提示并返回退出码 3。

## 已知坑（都踩过）

1. **不要用 CCS 无界面构建**：`eclipsec -application org.eclipse.cdt.managedbuilder.core.headlessbuild -import <proj> -build <proj>/Debug`
   生成的 `Debug/*/subdir_rules.mk` 里编译器路径为**空字符串** → `CreateProcess("") failed` / `make (e=87)`。
   加 `-product com.ti.ccstudio.branding.product` 只修好顶层 `makefile`，subdir 片段仍为空。自动构建请走本 skill 的脚本。
2. 工程里原有的 `Debug/makefile` 是 **CCS12（`F:/ccs/tools/compiler/ti-cgt-c2000_22.6.1.LTS`）** 生成的（不是"别的机器拷来的"）。
   这些自动生成的 `*.mk` 已被清掉，CCS 下次构建会自己重新生成；若 GUI 报找不到编译器，看 `Debug/makefile` 的 `CG_TOOL_ROOT`。
3. **RAM 程序 + 复位**：板上复位后默认跑的是**Flash 里的旧程序**（实测读到它配的 `TBPRD=7500`/`CLKDIV=0`）。
   所以"加载后能不能跑"取决于有没有把 PC 指到程序入口——DSS 里用 `target.restart()`，或显式
   `memory.writeRegister("PC", symbol.getAddress("code_start"))`（`code_start=0x0`，实测可用）。
4. **读回时序（最容易误判的一条，已用轮询解决）**：本工程带 OLED 模拟 I2C，`OLED_Init` 清屏 + 4 行字符串要**约 3.25 秒**才跑完。
   实测多采样：t=1/2/3 s 时 PC 停在 `oled.o` 的延时循环里、`TBPRD=0`；**t=4 s 起** `TBPRD=65535`、`PCLKCR1=1`、`SCILBAUD=39` 并保持稳定（程序是确定性的，不是被反复复位）。
   因此 `dss_template.js` 不再"盲等固定时间"，而是**每 250 ms 停机检查一次就绪表达式**（默认取 `-ReadVars` 第一项 `!= 0`），命中才采样；
   默认预算 8000 ms，`-WaitFor` 可自定义判据。盲等 3000/5000 ms 都出现过读到 0 的情况，不要退回固定等待。
5. **DSS API 版本差异**：CCS12 的 DSS 里 `session.registers` **不存在**，寄存器要用 `session.memory.readRegister/writeRegister`；
   `symbol.lookupSymbol()` 也不存在（用 `symbol.getAddress()`）。换 CCS 版本先跑 `scripts/dss_api_probe.js`。
   Rhino 没有 `env.sleep()`，要用 `java.lang.Thread.sleep(ms)`。
6. **本工作区有自动 git 快照（约 60 s 一次）**：曾出现临时测试文件删除后又被带回工程（因为它已进快照）。
   不要在工程目录里留测试文件，用完立刻删并确认 `git status` 干净。
7. `.launches/` 下原有 CCS 调试启动配置已被删除；走命令行的 loadti/DSS 不受影响，GUI 里需重新建调试配置。
8. 本机 PowerShell 限制 `Set-Content` 无显式编码、管道删除等写法；脚本统一用 `-LiteralPath` / 显式编码 / .NET API。
9. **`.ps1` 脚本里禁止写中文**（重要）：PowerShell 5.1 对无 BOM 的 UTF-8 文件按 ANSI(GBK) 读取，
   中文后紧跟的 `"` 会被当成双字节字符的一部分被"吃掉"，导致字符串未闭合、脚本整套语法崩掉
   （实测踩过：`Out2 "HINT2 : …跳过本检查"` 一个中文尾字即让脚本无法运行）。
   规避：两个 `.ps1` 保持纯 ASCII 输出与注释，中文只放在 `.md` 文档里（`.md` 用 read_file 读，UTF-8 正常）。
   自检命令：`$errs=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$null,[ref]$errs); $errs.Count`
