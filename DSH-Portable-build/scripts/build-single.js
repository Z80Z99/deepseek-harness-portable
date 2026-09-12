// ============================================================
// DeepSeek Harness - single-file build script
// Merges deploy/install.template.bat + deploy/bootstrap.ps1
// into one DeepSeek-Harness.bat (shell header + base64 PS block).
// Usage: node scripts/build-single.js [dshPin] [appVersion]
// ============================================================
import fs from 'fs'
import path from 'path'
import crypto from 'crypto'
import { fileURLToPath } from 'url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const projectRoot = path.join(__dirname, '..')

const TEMPLATE = path.join(projectRoot, 'deploy', 'install.template.bat')
const BOOTSTRAP = path.join(projectRoot, 'deploy', 'bootstrap.ps1')
const TRAY_ICON = path.join(projectRoot, 'assets', 'dsh-tray.png')
const OUTPUT = path.join(projectRoot, '..', 'DeepSeek-Harness.bat')

// 默认 'latest': 全新安装时由 bootstrap 现场解析 registry 的最新版
// 并锁成基线,这样无需每次发版都重新构建 bat。
const DSH_PIN = process.argv[2] || 'latest'
const APP_VERSION = process.argv[3] || DSH_PIN

function main() {
  let bat = fs.readFileSync(TEMPLATE, 'utf8')
  const placeholders = ['__APP_VERSION__', '__APP_BUILT__', '__DSH_PIN__', '__DSH_PS_B64_PLACEHOLDER__']
  for (const ph of placeholders) {
    if (!bat.includes(ph)) {
      console.error(`  template missing placeholder: ${ph}`)
      process.exit(1)
    }
  }

  // bootstrap ps1 -> base64 (prepend UTF-8 BOM so PowerShell reads Chinese as UTF-8)
  let ps = fs.readFileSync(BOOTSTRAP, 'utf8')
  if (fs.existsSync(TRAY_ICON)) {
    const iconB64 = fs.readFileSync(TRAY_ICON).toString('base64')
    if (!ps.includes('__TRAY_ICON_B64__')) {
      console.error('  bootstrap missing __TRAY_ICON_B64__ placeholder')
      process.exit(1)
    }
    // 全量替换(占位符必须只出现在字符串值里)
    ps = ps.split('__TRAY_ICON_B64__').join(iconB64)
    console.log(`  tray icon embedded (${(iconB64.length / 1024).toFixed(1)} KB base64)`)
  } else {
    console.warn('  !! assets/dsh-tray.png missing; tray falls back to system icon')
  }
  const psBuf = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(ps, 'utf8')])
  const b64 = psBuf.toString('base64')
  const b64Lines = []
  for (let i = 0; i < b64.length; i += 76) b64Lines.push(b64.slice(i, i + 76))
  console.log(`  bootstrap embedded (${b64Lines.length} base64 lines)`)

  const now = new Date()
  const pad = (v) => String(v).padStart(2, '0')
  const builtAt = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}T${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`

  bat = bat.replace('__APP_VERSION__', APP_VERSION)
    .replace('__APP_BUILT__', builtAt)
    .replace('__DSH_PIN__', DSH_PIN)
    .replace('__DSH_PS_B64_PLACEHOLDER__', b64Lines.join('\r\n'))

  // cmd batch files must be CRLF (LF breaks goto labels)
  bat = bat.replace(/^\uFEFF/, '').replace(/\r?\n/g, '\r\n')

  fs.mkdirSync(path.dirname(OUTPUT), { recursive: true })
  fs.writeFileSync(OUTPUT, bat, 'utf8')

  const sha = crypto.createHash('sha256').update(fs.readFileSync(OUTPUT)).digest('hex')
  const sizeKB = (fs.statSync(OUTPUT).size / 1024).toFixed(1)
  console.log('')
  console.log(`  generated: ${OUTPUT}`)
  console.log(`  size: ${sizeKB} KB   sha256: ${sha}`)
  console.log('')
}

main()
