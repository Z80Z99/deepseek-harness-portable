# DeepSeek Harness Portable

把 DeepSeek Harness（npm 包 `@deepseek-ai/dsh`）打包成**单文件 bat 便携部署程序**。

## 快速开始

下载 `DeepSeek-Harness.bat`，放到任意文件夹，双击即可：

1. 自动检测/下载 Node.js（可下载便携版到同目录 `nodejs\`，环境隔离）
2. 自动测速选择 npm 镜像并安装依赖（`dsh-app\`）
3. 自动创建便携数据目录（`dsh-home\`，配置/会话/凭据全在本地）
4. 自动随机端口启动 web 界面，服务真正可访问（HTTP 就绪）后才打开浏览器；检测到已有实例时同样等待就绪再打开，不会出现"未连接"页面
5. 关闭窗口后自动转入**系统托盘**（鲸鱼图标），托盘右键退出服务

## 特性

- 单文件 bat，绿色便携，不写注册表
- 无 Node 环境也能一键部署（自动下载便携 Node.js）
- npm 镜像测速选择（官方 / npmmirror / 华为云 / 中科大）
- 全新安装默认取 npm 最新版（`--reinstall` 亦然），后续有新版启动时提示更新
- 端口自动随机分配并记住，多实例检测防重复启动；打开浏览器前等待服务 HTTP 就绪，避免"未连接"页面
- 关闭窗口自动最小化到系统托盘，托盘管理退出
- 启动时自动检查 dsh 更新
- 会话/配置随文件夹整体搬移（相对路径记忆）

## 目录布局（运行后）

```
DeepSeek-Harness.bat      ← 单文件程序
dsh-app\                  ← npm 安装的程序本体（自动生成）
dsh-home\                 ← 便携数据（配置、会话、API Key）
nodejs\                   ← （可选）便携 Node.js
.dsh-launcher.json        ← 本地配置（不提交）
```

## 常用命令

| 命令 | 作用 |
|---|---|
| `DeepSeek-Harness.bat` | 启动（检测后台实例 → 打开/启动服务） |
| `DeepSeek-Harness.bat --stop` | 停止后台服务 |
| `DeepSeek-Harness.bat --no-open` | 启动/打开服务，但不自动开浏览器 |
| `DeepSeek-Harness.bat --reinstall` | 重装 dsh 程序本体到最新版 |
| `DeepSeek-Harness.bat --update` | 升级 dsh 到最新版 |
| `DeepSeek-Harness.bat --status` | 查看状态 |
| `DeepSeek-Harness.bat --tray-test` | 调试：直接进入系统托盘 |

## 构建

```powershell
node scripts/build-single.js [dshPin] [appVersion]
```

详见 [DSH-Portable-build/README.md](DSH-Portable-build/README.md)

## pnpm（可选，首次安装后询问）

首次安装完成后，若未检测到 pnpm，会询问是否安装（默认安装 `pnpm@10`）。为什么需要 pnpm：

1. **dsh 的插件系统依赖它**：`dsh plugin` 命令把插件安装转发给 pnpm，没有 pnpm 会直接失败，第三方插件无法安装
2. **目录结构要求**：dsh 要求 `profiles\node_modules` 是 pnpm 管理的**符号链接树**，npm 装出的真实目录会被 dsh 拒绝/重建，插件加载失败
3. **为什么是 pnpm@10**：pnpm 11 在 Node 24 下有 libuv 崩溃（实践中观察到依赖安装时 `UV_HANDLE_CLOSING` 断言），pnpm@10 稳定

跳过也没关系：之后需要装插件时随时 `npm install -g pnpm`。

## 安全说明

- **`dsh-home\` 含你的 API Key 和会话记录**，已被 .gitignore 排除，绝不会上传
- 本仓库只包含构建源码和单文件产物，运行时数据均在本机生成
