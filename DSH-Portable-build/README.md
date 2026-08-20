# DeepSeek-Harness.bat 构建项目

把 DeepSeek Harness（npm 包 `@deepseek-ai/dsh`）打包成**单文件 bat 部署程序**，
架构参考 `Z80Z-chat.bat`（shell 头 + 内嵌 base64 PowerShell 引导）。

## 产物

| 文件 | 说明 |
|---|---|
| `DeepSeek-Harness.bat`（工作区根目录） | 单文件交付物，约 18 KB，拷到哪里都能用 |

## 工作原理

```
DeepSeek-Harness.bat
├── ① cmd shell 头（纯 ASCII）        chcp 65001，定位并解码内嵌的 PS 引导
├── ② 内嵌 base64 PowerShell 引导     安装向导 / 启动器（运行时解码到 .dsh-bootstrap.ps1，用后自删）
└── ③ 无 zip 载荷                     程序本体直接从 npm 拉取，引导只负责编排
```

首次运行：
1. 检测 Node.js ≥ 18（优先用 bat 旁的 `nodejs\` 便携版，否则用系统 PATH 上的 node）
2. 在 `dsh-app\` 写入 package.json 并执行 `npm install --omit=dev`（下载约 200 MB）
3. 在 `dsh-home\` 创建便携 DSH_HOME（`profiles/web` 骨架：package.json / pnpm-workspace.yaml / cordis.yml / cordis.patch.yml）
4. 设置 `DSH_HOME` 后启动 `dsh web`，3 秒后自动打开浏览器

之后的运行：跳过安装，直接启动。

## 目录布局（运行后）

```
DeepSeek-Harness.bat        ← 单文件程序
dsh-app\                    ← npm 安装的程序本体（@deepseek-ai/dsh 及依赖）
dsh-home\                   ← 便携 DSH_HOME（配置、会话、凭据，全部随身）
nodejs\                     ← （可选）便携 Node.js：node.exe + npm.cmd
.dsh-launcher.json          ← 记住的 home 选择
```

## 命令行参数

| 参数 | 作用 |
|---|---|
| （无参数） | 检测后台实例 → 无则安装（如需要）并启动 web UI，**端口自动随机分配并记住** |
| `--port 8080` | 指定端口启动（覆盖随机端口；显式指定时跳过实例检测，可多开） |
| `--no-open` | 不自动打开浏览器 |
| `--home <path>` | 指定 DSH_HOME 目录 |
| `--registry <url>` | 指定 npm 镜像（默认首次安装自动测速选最快） |
| `--update` | 把 @deepseek-ai/dsh 升级到 npm 最新版 |
| `--reinstall` | 删除 dsh-app\ 重新安装 |
| `--reset-home` | 备份 dsh-home\ 为 dsh-home.backup-时间戳 后重建 |
| `--stop` | 停止后台服务（读取 .dsh-server.pid） |
| `--status` | 打印检测到的路径、记忆端口/镜像后退出 |
| `--tray-test` | 调试：就绪后直接进入系统托盘（验证托盘可用性） |
| `--help` | 显示帮助 |

## 便携 Node.js（同目录安装）

与参考项目 Z80Z-chat.bat 的 Ensure-NodeJs 同思路：

- **优先使用** bat 旁的 `nodejs\` 便携版（node.exe + npm.cmd）
- **无 Node 环境时**（交互）：菜单选择
  - `1` 自动下载 Node.js 到本目录 `nodejs\`（约 30MB；镜像测速选择，默认最快；
    版本回退链 v22→20→18，自动解压校验）
  - `2` 手动下载教程（下载 zip 解压后放入 nodejs\）
  - `3` 退出
- **有系统 Node 时**（交互，仅首次询问并记住到 `.dsh-launcher.json` 的
  `nodeMode`）：`1` 使用系统 Node.js（默认）/ `2` 下载便携版环境隔离
- **非交互**：有系统 Node 直接用；无则报错提示
- 下载源：官方 / 华为云 / 腾讯云 / 中科大（与 Z80Z 相同的四源）

## 后台实例检测

启动时扫描所有运行中的 dsh 实例（不重复启动）：

- **交互模式**：显示检测到的实例列表（含"本目录"标记），提供菜单：
  - `1` 打开浏览器使用已有实例（默认）
  - `2` 关闭后台服务（输入编号关闭指定实例；回车关闭全部）
  - `3` 取消
- **非交互模式**：自动打开已有实例（本目录优先），不重复启动。
- 显式 `--port` 时跳过检测（允许多开）。

## 端口与镜像记忆（.dsh-launcher.json）

首次运行自动完成两件事并记住到 `.dsh-launcher.json`：

- **端口**：在 10000-60000 内随机选一个未被占用的端口（参考 Z80Z-chat 的
  行为）。之后的运行沿用该端口；若端口被占用则自动换新并更新记忆。
  用 `--port N` 可临时或永久指定。
- **npm 镜像**：安装依赖前对官方 npm / npmmirror / 华为云 / 中科大四个源
  各做 2 次 HEAD 测速（5 秒超时），**交互环境可输入编号选择安装源**
  （回车用默认最快的）；非交互环境自动选最快。`--registry <url>` 可手动
  指定或覆盖。

## 启动体验

- **等就绪再开浏览器**：dsh 后台启动后，主脚本轮询端口监听（最长 60 秒），
  **服务真正就绪后**才打开浏览器，不再出现"无法连接"页。
- **就绪后可选隐藏窗口**：显示"服务已就绪"后按：
  - `T` —— **最小化到系统托盘**（窗口隐藏，托盘出现 DSH 图标：双击恢复
    窗口，右键菜单可"显示窗口 / 隐藏窗口 / 退出服务"）
  - `H` —— 完全隐藏窗口（任务栏按钮也消失，服务继续运行；停止服务需在
    任务管理器结束 node.exe）
  - 回车 —— 保持窗口
  非交互环境自动保持窗口。窗口可见时 Ctrl+C 会连同 dsh 一起退出。

## 更新与重新构建

构建脚本注入两个版本号：

```powershell
node scripts/build-single.js [dshPin] [appVersion]
# 例：node scripts/build-single.js 0.1.0-rc.8
```

- `dshPin`：首次安装时写入 package.json 的依赖版本（默认 `0.1.0-rc.7`）
- `appVersion`：显示在横幅/帮助里的 launcher 版本（默认同 dshPin）

运行中的实例升级程序本体用 `--update`，不必重新构建 bat。

## 整文件夹搬家

**bat + dsh-app\ + dsh-home\ 可以整体移动/拷贝到任意位置**：

- `.dsh-launcher.json` 中 home 以相对标识 `"dsh-home"` 存储（仅当选择复用
  系统 `~/.dsh` 时才存绝对路径），因此搬走后数据目录依然有效。
- 若记忆的绝对路径已失效（旧版配置或手动改动），启动时自动回退到 bat 旁的
  `dsh-home\` 并更新配置。
- 搬家后若 `dsh-app\` 缺失（没一起搬），首次运行会自动重新 `npm install`。

## 更新机制

- **启动时自动检查**：每次运行（已安装状态下）查询 npm 上的最新版本（5 秒
  超时，失败静默跳过）。发现新版本会提示"发现新版本 X（当前 Y）"，交互
  环境按 Y 立即升级、回车跳过；非交互环境自动跳过。
- **手动升级**：`DeepSeek-Harness.bat --update` 直接升到 npm 最新版。
- **首次安装/--reinstall**：安装 `^<锁定版本>`（如 `^0.1.0-rc.7`），只会装
  同主版本号内最新；跨大版本需 `--update`。
- 版本比较支持 `-rc.N` 预发布标签（`0.1.0-rc.9` < `0.1.0-rc.10` < `0.1.0`）。

## 已知注意点

- **首次运行需要联网 + Node.js ≥ 18**。无网络环境可先从别的机器拷 `dsh-app\`
  文件夹过来（断网机也能跳过安装直接启动）。
- PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会写 BOM，导致 dsh 的
  profile 加载器 `JSON.parse` 报 `Unexpected token '\uFEFF'`。引导脚本所有
  文件写入一律用 `[IO.File]::WriteAllText`（UTF-8 无 BOM），勿改回。
- npm 11 会提示 `allow-scripts` 警告（5 个包有安装脚本未登记）；经验证
  脚本产物与官方 npx 安装完全一致，属良性警告，无需处理。
- 首次运行会自动询问：若系统里已有 `%USERPROFILE%\.dsh`，选 1 用便携新
  home（默认），选 2 复用现有 home。
- 引导脚本每次运行都重新解码到 `.dsh-bootstrap.ps1` 并在退出时自删。
