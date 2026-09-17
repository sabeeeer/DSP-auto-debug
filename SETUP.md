# 新电脑部署指南（拿起来就能用）

> 目标：换新电脑后，**装好 CCS → 克隆两个仓库 → 跑一次 setup 脚本 → 可用**。
> 大约 20~30 分钟，其中 CCS 安装最耗时。

## 0. 先搞清楚的边界

| 能带走（在 GitHub 上） | 不能带走（必须在新机重做） |
|---|---|
| 两个 skill 的全部代码/文档（本仓库 + `git-autosnapshot-codebuddy`） | **CCS12（或 CCS6）+ C2000 编译器**：几百 MB，官方安装包重装 |
| hooks 配置样例、自动化逻辑、失败分类、型号/仿真器适配 | **GitHub 登录**：令牌 / `gh auth login`（令牌绝不能进仓库） |
| 用法、参数、排错经验 | **git 身份**、**代理**（新网络下端口/有无都可能不同） |
| — | **你的 DSP 工程**（不在仓库里）；`.cproject` 里写死的 TI 头文件绝对路径也要改 |
| — | **硬件**：XDS 仿真器 + 目标板 + 板载驱动 |

## 1. 克隆（两个仓库）

```powershell
$skills = "$HOME\.codebuddy\skills"
New-Item -ItemType Directory -Force -Path $skills | Out-Null

# 主 skill：DSP 自动调试
git clone https://github.com/sabeeeer/DSP-auto-debug.git "$skills\ti-c2000-ccs-auto"

# 第二个 skill：git 自动快照
git clone https://github.com/sabeeeer/git-autosnapshot-codebuddy.git "$skills\git-management"
```

## 2. 一键 bootstrap

```powershell
# 先看它会做什么（不改任何东西）
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codebuddy\skills\ti-c2000-ccs-auto\setup\Setup-CCS-Skills.ps1" -DryRun

# 正式执行（按需取舍参数）
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codebuddy\skills\ti-c2000-ccs-auto\setup\Setup-CCS-Skills.ps1" `
  -GitSource "$HOME\.codebuddy\skills\git-management" `
  -GitName  "你的GitHub登录名" `
  -GitEmail "你的noreply邮箱或验证邮箱" `
  -Proxy    "http://127.0.0.1:12450"      # 只有走本地/公司代理时才需要
```

脚本会做（**幂等**，已装过的会先备份成 `.bak-<时间戳>`，不删除）：

1. 把当前仓库安装成 `<skills>\ti-c2000-ccs-auto`
2. 可选：把 `-GitSource` 指定的仓库安装成 `<skills>\git-management`
3. 把 git-management 的三个 hooks **合并**进 `~/.codebuddy/settings.json`（保留文件里其他配置；已有同名 hook 且指向 git-management 时跳过）
4. 可选：设置全局 git 身份（`-GitName` + `-GitEmail` 同时给才生效）
5. 可选：设置/清除代理环境变量（`-Proxy` / `-ClearProxy`）
6. 可选：对指定工程跑一次编译链接自检（`-ProjectPath`）
7. 打印**必须手动完成**的清单

## 3. 手动步骤（脚本不能代做）

1. **装 CCS**：CCS12.x（或 CCS6）+ C2000 编译器（`ti-cgt-c2000_*`）；用仿真器就一起装仿真器驱动。
   脚本会自动探测安装位置（注册表 / `C:\ti` / `%USERPROFILE%\ti`），也可用 `-CcsRoot` / `-CompilerRoot` 指定。
2. **GitHub 登录**：`gh auth login`（或设 `GH_TOKEN`）；令牌建议勾 `repo, read:org`。
   走代理的机器**先配代理**，否则 git/gh 会连不上（表现为 `Failed to connect to github.com port 443`）。
3. **git 身份**：`git config --global user.name/user.email`（没配会导致提交失败）。
4. **复制 DSP 工程**（不在仓库里），并在 CCS 里改 `.cproject` 的**绝对 include 路径**：
   `Project > Properties > Build > C2000 Compiler > Include Options`，把 `DSP2833x_*` / `F28xx_*` 头文件目录指向新机上的实际位置
   （或把 TI 的 `DSP2833x_Libraries`/example 包一并复制到同样的路径）。**这是换机最容易踩的坑**：路径不对 → `cannot open source file "DSP2833x_Device.h"`。
5. **验证**：
   ```powershell
   # 只要编译链接（不需要硬件）
   powershell -NoProfile -ExecutionPolicy Bypass -File "<skills>\ti-c2000-ccs-auto\scripts\ti_c2000_build.ps1" -ProjectPath "<工程>"
   # 下载运行 + 读回（需要探针+板子上电）
   powershell -NoProfile -ExecutionPolicy Bypass -File "<skills>\ti-c2000-ccs-auto\scripts\ti_c2000_debug.ps1" -ProjectPath "<工程>" -Build -Run -ReadVars "EPwm1Regs.TBPRD"
   ```
6. **重启 CodeBuddy 会话**，让新 skill 与 hooks 生效。

## 4. 老机 → 新机的日常同步

skill 本身就是 git 仓库，改完推送、新机拉取即可：

```powershell
# 老机（改完 skill 后）
cd "$HOME\.codebuddy\skills\ti-c2000-ccs-auto"; git add -A; git commit -m "更新：xxx"; git push

# 新机
cd "$HOME\.codebuddy\skills\ti-c2000-ccs-auto"; git pull
```

## 5. 换机常见坑一览（都踩过）

| 现象 | 原因 / 处置 |
|---|---|
| `Failed to connect to github.com port 443` | 本机走代理，但 git/gh 不读系统代理 → `-Proxy` 或 `git config --global http.https://github.com.proxy http://host:port` |
| gh 报 `401 Bad credentials` | ① 用管道把令牌喂给 gh 会带编码噪声 → 用文件重定向；② gh 要求令牌含 `read:org` |
| `cannot open source file "DSP2833x_Device.h"` | `.cproject` 的绝对 include 路径在新机不存在 |
| 下载成功但寄存器全是 0 | 程序没跑到（加大 `-RunMs`）/ 没做 `restart` 跳入口 / 外设时钟未开 |
| CCS 里 Build 报 `make (e=87)` 或编译器路径为空 | 别用 CCS 无界面构建；删掉 `Debug` 下自动生成的 `*.mk` 让 CCS 重新生成 |
| 提交失败 `Please tell me who you are` | 未配 git 身份（见步骤 3） |
| 中文仓库名建出来变成 `-` | GitHub 不允许非 ASCII 仓库名，中文放 description/README |
