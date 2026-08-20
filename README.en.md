# DeepSeek Harness Portable

Pack [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) (npm package `@deepseek-ai/dsh`) into a **single-file portable `.bat` launcher** for Windows.

## Quick Start

Download `DeepSeek-Harness.bat`, drop it into any folder, and double-click:

1. Automatically detects / downloads **Node.js** (can install a portable copy into `nodejs\` next to the bat — fully self-contained, no system changes)
2. Speed-tests npm mirrors and installs dependencies into `dsh-app\`
3. Creates a portable data directory `dsh-home\` (config, sessions, credentials all local)
4. Picks a random free port, starts the web UI, and opens the browser once the service is **actually ready**
5. Closing the window moves it to the **system tray** (whale icon); right-click the tray icon to exit the service

## Features

- Single `.bat` file, green & portable — no registry writes, no system pollution
- Works on machines **without Node.js** (auto-downloads a portable Node)
- npm mirror speed test (official / npmmirror / Huawei Cloud / USTC)
- Random free port allocation with persistence; duplicate-instance detection
- Closing the console window automatically minimizes to the **system tray**; exit is managed from the tray menu
- Startup version check with one-key upgrade (`--update`)
- Entire folder is movable — sessions/config follow the folder (relative path memory)

## Layout After Running

```
DeepSeek-Harness.bat      ← the single-file program
dsh-app\                  ← npm-installed program (auto-generated)
dsh-home\                 ← portable data (config, sessions, API key)
nodejs\                   ← (optional) portable Node.js
.dsh-launcher.json        ← local launcher config (not committed)
```

## Common Commands

| Command | Purpose |
|---|---|
| `DeepSeek-Harness.bat` | Launch (detects background instances → opens or starts) |
| `DeepSeek-Harness.bat --stop` | Stop the background service |
| `DeepSeek-Harness.bat --update` | Upgrade dsh to the latest version |
| `DeepSeek-Harness.bat --status` | Show status |
| `DeepSeek-Harness.bat --tray-test` | Debug: enter system tray immediately |

## Building

```powershell
node scripts/build-single.js [dshPin] [appVersion]
```

See [DSH-Portable-build/README.md](DSH-Portable-build/README.md) for details.

## Security

- **`dsh-home\` contains your API key and session history** — it is excluded via `.gitignore` and is never uploaded.
- This repository only contains build sources and the single-file artifact; all runtime data is generated locally.
