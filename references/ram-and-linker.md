# RAM 布局与链接脚本（C2000 / DSP2833x 实战）

> 触发场景：链接报
> `error #10099-D: program will not fit into available memory, or the section contains a call site that requires a trampoline that can't be generated`
> 或者"新加的模块明明不大，一链接就爆"。
> 本文是 **DSP28335 实测总结**；其他 C2000 型号思路相同、段名与地址不同（见 `c2000ware-guide.md`）。

## 0. 一句话结论

**别让 `.text` 挤在小段里，更别让它跨不连续内存。**
把 SARAM 合并成"连续大块"：**L0~L3 给程序、L4~L7 给数据（各 16K 字）**。
工程再做大就换 **Flash 链接脚本**（F28335 有 256K 字 Flash，是 RAM 的 8 倍）。

---

## 1. F28335 的 RAM 规格（先记住这张表）

| 块 | 地址范围 | 大小 | 说明 |
|---|---|---|---|
| M0 | 0x000000 ~ 0x000400 | 1K 字 | 常被 boot ROM / 早期栈占用 |
| M1 | 0x000400 ~ 0x000800 | 1K 字 | 常给 `.stack`；也可做小变量区 |
| L0 | 0x008000 | 4K 字 | ⚠️ L0~L3 在 0x3F8000 有**镜像**（同一物理内存，只能定义一次）|
| L1 | 0x009000 | 4K 字 | |
| L2 | 0x00A000 | 4K 字 | |
| L3 | 0x00B000 | 4K 字 | |
| L4 | 0x00C000 | 4K 字 | |
| L5 | 0x00D000 | 4K 字 | |
| L6 | 0x00E000 | 4K 字 | |
| L7 | 0x00F000 | 4K 字 | |

- **L0~L7 地址完全连续**：`0x008000 ~ 0x010000`，共 **32K 字（64 KB）**，是 F28335 唯一的片上零等待 RAM。
- **片上没有更大的 RAM 了**。要更大只能：Flash（256K 字，读有等待周期）、或外扩 XINTF ZONE7（很慢）。
- 注意"字"：C28x 一个地址存 16 位。32K 字 = 64 KB，不是 32 KB。

---

## 2. 症状 → 先分清是哪一种

报错位置通常指向 `.cmd` 里 `.text` 那一行。**同一句报错包含两种完全不同的毛病**：

| 症状细节 | 真实原因 | 处置 |
|---|---|---|
| 分配空间真的不够 | 段太小 | 扩段（合并大块 / 上 Flash）|
| 报错文本含 **`trampoline`** | `.text` 被放在**多个不连续** memory range（如 `> RAML1 | RAML6 | RAML7`）。跨片调用需要跳转代理（trampoline），生成不出来就报这条 | **必须合并成连续块**，扩再多也没用 |

⚠️ 第二种最坑：总空间明明够（12K + 8K = 20K），照样报"装不下"。

---

## 3. 标准解法：合并成连续大块（本工程已采用）

### 改前（TI 例程默认，很容易撞顶）

```
PAGE 0:
   RAML0 : origin = 0x008000, length = 0x001000
   RAML1 : origin = 0x009000, length = 0x001000
   RAML2 : origin = 0x00A000, length = 0x001000
   RAML3 : origin = 0x00B000, length = 0x001000
PAGE 1:
   RAML4 .. RAML7 : 各 0x1000

SECTIONS:
   ramfuncs : > RAML0
   .text    : > RAML1      ← 只有 4K 字！工程稍大就爆
   .ebss    : > RAML4
   .econst  : > RAML5
```

### 改后（推荐：连续 16K + 16K）

```
MEMORY
{
PAGE 0 :
   BEGIN      : origin = 0x000000, length = 0x000002
   RAMM0      : origin = 0x000050, length = 0x0003B0
   RAMCODE    : origin = 0x008000, length = 0x004000	//L0~L3 合并：连续 16K 字 → 程序段
   ZONE7A     : origin = 0x200000, length = 0x00FC00
   CSM_RSVD   : origin = 0x33FF80, length = 0x000076
   CSM_PWL    : origin = 0x33FFF8, length = 0x000008
   ADC_CAL    : origin = 0x380080, length = 0x000009
   RESET      : origin = 0x3FFFC0, length = 0x000002
   IQTABLES   : origin = 0x3FE000, length = 0x000b50
   ...
PAGE 1 :
   BOOT_RSVD  : origin = 0x000002, length = 0x00004E
   RAMM1      : origin = 0x000400, length = 0x000400
   RAMDATA    : origin = 0x00C000, length = 0x004000	//L4~L7 合并：连续 16K 字 → 数据段
   ZONE7B     : origin = 0x20FC00, length = 0x000400
}

SECTIONS
{
   codestart        : > BEGIN,     PAGE = 0
   ramfuncs         : > RAMCODE,   PAGE = 0
   .text            : > RAMCODE,   PAGE = 0     ← 16K 字，连续
   .cinit           : > RAMCODE,   PAGE = 0
   .pinit           : > RAMCODE,   PAGE = 0
   .switch          : > RAMCODE,   PAGE = 0

   .stack           : > RAMM1,     PAGE = 1
   .ebss            : > RAMDATA,   PAGE = 1     ← 数据也从 4K 扩到 16K
   .econst          : > RAMDATA,   PAGE = 1
   .esysmem         : > RAMM1,     PAGE = 1

   IQmath           : > RAMCODE,   PAGE = 0
   IQmathTables     : > IQTABLES,  PAGE = 0, TYPE = NOLOAD
   FPUmathTables    : > FPUTABLES, PAGE = 0, TYPE = NOLOAD
   ...
}
```

**收益**：代码 4K→16K、数据 4K+4K→16K，且都**连续**（彻底避开 trampoline）。

### 三条硬约束（违反会出玄学问题）

1. **同一物理内存在 PAGE 0 / PAGE 1 只能定义一次**。
   F28335 的 PAGE 0/PAGE 1 指向同一片物理 RAM；同地址写两遍 → 链接器警告 + 运行时程序与数据互相踩。
   合并 L0~L3 给 PAGE 0 之后，PAGE 1 里就**不能再出现 L3 范围**（这正是要检查的点）。
2. **不要用 `|` 把不连续的段拼给同一个 section**（`.text : > A | C` 之间隔着 B）。
   要么给连续块，要么确认全程在 ±16 位偏移可达范围内（做不到就老实合并）。
3. **改前先搜 DMA 段**：
   ```powershell
   Get-ChildItem -Recurse -Include *.c,*.h,*.cmd | Select-String 'DMARAML|RAML6|RAML7'
   ```
   若有 `#pragma DATA_SECTION(buf,"DMARAML6")` 之类，说明那个块被 DMA 借用，不能挪（或要同步改宏）。

---

## 4. 隐蔽陷阱：编译器默认不按函数分段

`--gen_func_subsections` **默认关闭**。含义：
**一个 `.c` 里只要有"一个"函数被引用，整份 `.c` 的代码都会被链进程序段。**

实测代价：在 RAM 已经贴着上限的工程里挂一个几十行的"自测函数"，
`.text` 直接涨 2~3K 字（因为同文件里的 sin/cos 大函数也一起进来了），立刻爆链接。

| 解法 | 做法 | 代价 |
|---|---|---|
| ① **可选功能单独成文件**（首选）| 把"临时/自测/调试专用"的功能放在自己的 `.c`。没人引用时整份不占空间；要用时只带进它和它的直接依赖 | 文件多一点，最省事 |
| ② 打开函数分段 | 编译选项加 `--gen_func_subsections=on` | 全工程 map 变化，需回归验证 |
| ③ 精simple代码 | 去 `double`、去库调用、合并函数 | 见 `ti-official-style.md` |

---

## 5. 编码陷阱：改 `.cmd` 必看

TI 例程的 `.cmd` 常是 **GBK（codepage 936）**，里面可能有中文注释。
PowerShell 的 `Get-Content` / `Set-Content` / `[IO.File]::ReadAllText` **默认按 UTF-8 处理** →
GBK 中文会被替换成 U+FFFD，**不可逆**（写回后原文就没了）。

```powershell
# ✅ 正确：用 GBK 读写 .cmd（本技能所有脚本都这么干）
$gbk = [Text.Encoding]::GetEncoding(936)
$t = $gbk.GetString([IO.File]::ReadAllBytes($f))
$t = $t.Replace('旧文本','新文本')
[IO.File]::WriteAllBytes($f, $gbk.GetBytes($t))
```

**怎么判断文件编码**：GBK 能正确解出中文、而 UTF-8 严格解码抛异常 ⇒ 该文件是 GBK。
（`New-Object Text.UTF8Encoding($false,$true).GetString($bytes)` 抛异常即非 UTF-8。）

⚠️ **中文路径也不行**：TI 编译器打不开含中文的目录（报 `Fatal error #1965: cannot open source file "...\ģ�ⷢ��\x.c"`）。
工程内所有目录名、文件名都用 ASCII。

---

## 6. 大工程的正解：上 Flash

RAM 总共 32K 字；**F28335 的 Flash 有 256K 字**。

| 方案 | 做法 | 适用 |
|---|---|---|
| RAM 链接（默认）| `28335_RAM_lnk.cmd` | 调试期：下载快、改完即测、掉电即失 |
| Flash 链接 | 换 `F28335.cmd`（`.text > FLASH`、`.cinit > FLASH`，`ramfuncs` 仍拷到 RAM）| 脱机运行 / 代码量大 |
| 混合 | 代码放 Flash，热函数用 `ramfuncs` 段 + `MemCopy` 搬到 RAM 跑 | 性能敏感 |

⚠️ 换 Flash 需要**配套两件事**（照 TI 官方例程抄，别自己发明）：
- `DSP2833x_CodeStartBranch.asm` 里的 `codestart`（把入口跳到 `_c_int00`）
- `InitFlash()`（在 `DSP2833x_SysCtrl.c` 里有，设置 Flash 等待周期）

脚本侧可用 `-LinkCmd "<Flash脚本>.cmd"` 追加链接脚本（见 SKILL.md「换型号 / 换仿真器」表）。

---

## 7. 一键诊断

```powershell
pwsh -File scripts\check_ram_layout.ps1 -ProjectPath <工程目录>
```

输出内容：
- 找到的 `.cmd` 文件、编码判断
- MEMORY 各段：名称 / 地址 / 大小（字 & KB）/ 归属 PAGE
- SECTIONS 关键段（`.text`、`.ebss`、`.econst`、`ramfuncs`…）分到哪里、**是否跨片**
- **PAGE 冲突检查**（同一地址范围被两个 PAGE 都定义了）
- 结论与建议：连续 / 跨片、代码段可用总量、是否该改

---

## 8. 现场处置顺序（照做）

1. 跑 `scripts\check_ram_layout.ps1` —— **先判是"跨片"还是"真不够"**
2. **跨片** → 按 §3 合并成 `RAMCODE` / `RAMDATA` 连续大块
3. **真不够** → 先看 §4（是不是被整份 `.c` 拖累）；仍未解决 → §6 上 Flash
4. 改完跑 `scripts\ti_c2000_build.ps1` 自检（几秒出结果，不用开 CCS）
5. ⚠️ `.cmd` 改动会影响**整个工程的内存布局**，改完务必编译一次确认；本技能改 `.cmd` 前建议先 `git add` 一眼（能回滚）

---

## 9. 附：本次实测的完整过程（可作参照）

| 步骤 | 现象 | 处置 |
|---|---|---|
| 1 | 新增 4 个源文件后 `#10099-D`，指向 `.text : > RAML1` | `.text` 只有 8K 字 → 把 `RAML1` 扩到 12K（并入原 RAML2）|
| 2 | 又不够（新增一个自测模块）| ① 把自测功能单独成 `cl_dac.c`（§4 解法①）② 仍不够 |
| 3 | 把 `RAML6/RAML7` 挪到 PAGE 0、`.text : > RAML1 | RAML6 | RAML7` | 仍报错，且报错文本含 `trampoline` → 跨片！|
| 4 | **合并成 `RAMCODE`(L0~L3, 16K) + `RAMDATA`(L4~L7, 16K)** | ✅ 编译链接 `RESULT: OK`，代码与数据空间都翻倍 |

> 教训：**第 3 步那样"往不连续的段上加"是错的**。要么一次合并成连续大块，要么上 Flash。
