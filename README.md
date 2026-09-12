# DeepSeek Harness Portable

把 DeepSeek Harness（npm 包 `@deepseek-ai/dsh`）打包成**单文件 bat 便携部署程序**。

## 快速开始

下载 `DeepSeek-Harness.bat`，放到任意文件夹，双击即可：

1. 自动检测/下载 Node.js（可下载便携版到同目录 `nodejs\`，环境隔离）
2. 自动测速选择 npm 镜像并安装依赖（`dsh-app\`）
3. 自动创建便携数据目录（`dsh-home\`，配置/会话/凭据全在本地）
4. 自动随机端口启动 web 界面，服务就绪后打开浏览器
5. 关闭窗口后自动转入**系统托盘**（鲸鱼图标），托盘右键退出服务

## 特性

- 单文件 bat，绿色便携，不写注册表
- 无 Node 环境也能一键部署（自动下载便携 Node.js）
- npm 镜像测速选择（官方 / npmmirror / 华为云 / 中科大）
- 全新安装默认取 npm 最新版（`--reinstall` 亦然），后续有新版启动时提示更新
- 端口自动随机分配并记住，多实例检测防重复启动
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
| `DeepSeek-Harness.bat --update` | 升级 dsh 到最新版 |
| `DeepSeek-Harness.bat --status` | 查看状态 |
| `DeepSeek-Harness.bat --tray-test` | 调试：直接进入系统托盘 |

## 构建

```powershell
node scripts/build-single.js [dshPin] [appVersion]
```

详见 [DSH-Portable-build/README.md](DSH-Portable-build/README.md)

## 安全说明

- **`dsh-home\` 含你的 API Key 和会话记录**，已被 .gitignore 排除，绝不会上传
- 本仓库只包含构建源码和单文件产物，运行时数据均在本机生成
