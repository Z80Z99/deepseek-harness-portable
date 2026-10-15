# ============================================================
# DeepSeek Harness - single-file bootstrap
# Extracted by the bat shell section at runtime, decoded from
# the embedded base64 block (with UTF-8 BOM so Chinese text
# survives). Runs as: powershell -NoProfile -File .dsh-bootstrap.ps1
#   -Root <batDir> -AppVersion <v> -AppBuilt <ts> -DshPin <v> -UserArgs "<args>"
# ============================================================
param(
  [string]$Root = '.',
  [string]$AppVersion = '0.0.0',
  [string]$AppBuilt = '',
  [string]$DshPin = 'latest',
  [string]$UserArgs = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# 内嵌托盘图标 PNG(构建时注入 base64;缺失时回退系统图标)
# 注意: 注入占位符只能出现在字符串值里,注释中不要出现占位符字样
$script:DSH_TRAY_ICON_B64 = '__TRAY_ICON_B64__'

$Root = ([string]$Root).Trim().Trim('"')
$Root = [System.IO.Path]::GetFullPath($Root)

$AppDir       = Join-Path $Root 'dsh-app'
$HomeDir      = Join-Path $Root 'dsh-home'
$LauncherCfg  = Join-Path $Root '.dsh-launcher.json'
$BinJs        = Join-Path $AppDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
$PortableNode = Join-Path $Root 'nodejs\node.exe'
$PortableNpm  = Join-Path $Root 'nodejs\npm.cmd'

# ---------------- self clean ----------------
# The bat re-extracts this script on every run, so delete it on the
# way out (same trick as the reference project) to keep the folder clean.
$ScriptFile = $MyInvocation.MyCommand.Path
function Self-Clean {
  try { Remove-Item $ScriptFile -Force -ErrorAction SilentlyContinue } catch { }
}

# ---------------- console helpers ----------------
function Ln([string]$t = '') { Write-Host $t }
function Hint([string]$t) { Write-Host ('  ' + $t) }
function H1([string]$t) {
  Ln ''
  Ln ('  ' + $t)
  Ln ('  ' + ('-' * 48))
}

function Is-Interactive {
  $i = $true
  try { if ([Console]::IsInputRedirected) { $i = $false } } catch { }
  return $i
}

# ---------------- launcher config (remembered choices) ----------------
function Read-Cfg {
  $c = $null
  if (Test-Path $LauncherCfg) {
    try { $c = Get-Content $LauncherCfg -Raw | ConvertFrom-Json } catch { $c = $null }
  }
  return $c
}

function Save-Cfg([hashtable]$updates) {
  # 用 hashtable 重建(不能给 ConvertFrom-Json 的 PSCustomObject 动态加属性,PS 5.1 会报错)
  $new = @{}
  $existing = Read-Cfg
  if ($existing) {
    foreach ($p in $existing.PSObject.Properties) { $new[$p.Name] = $p.Value }
  }
  foreach ($k in $updates.Keys) { $new[$k] = $updates[$k] }
  try { [IO.File]::WriteAllText($LauncherCfg, ($new | ConvertTo-Json)) } catch { }
}

# ---------------- port helpers ----------------
function Test-PortBusy([string]$p) {
  try { return [bool](Get-NetTCPConnection -State Listen -LocalPort ([int]$p) -ErrorAction SilentlyContinue) } catch { return $false }
}

# HTTP 就绪探测: 端口监听 ≠ 服务可访问(dsh 监听端口后仍需加载配置档/插件),
# 收到任意 HTTP 响应(含 4xx/5xx)才算真正在服务。Proxy 置空避免系统代理劫持本机探测。
function Test-HttpReady([string]$u) {
  try {
    $req = [System.Net.HttpWebRequest]::Create($u)
    $req.Method = 'HEAD'
    $req.Timeout = 1500
    $req.AllowAutoRedirect = $false
    $req.Proxy = $null
    $resp = $req.GetResponse()
    $resp.Close()
    return $true
  } catch [System.Net.WebException] {
    return ($null -ne $_.Exception.Response)
  } catch {
    return $false
  }
}

# 打开浏览器前等待服务真正可访问(最多 30 秒),避免抢跑打开"无法连接/未连接"页。
function Open-WhenReady([string]$u) {
  if (-not $flags.ContainsKey('no-open')) {
    $waited = 0.0
    while (-not (Test-HttpReady $u) -and $waited -lt 30.0) {
      Start-Sleep -Milliseconds 500
      $waited += 0.5
    }
    try { Start-Process $u | Out-Null } catch { }
  }
}

function Get-RandomPort {
  # 与参考项目一致: 10000-60000 范围内随机找可用端口
  for ($i = 0; $i -lt 30; $i++) {
    $p = Get-Random -Minimum 10000 -Maximum 60001
    if (-not (Test-PortBusy $p)) { return $p }
  }
  return (Get-Random -Minimum 10000 -Maximum 60001)
}

# ---------------- npm mirror speed test ----------------
function Select-FastestMirror {
  $mirrors = @(
    @{ name = '官方 npm';       url = 'https://registry.npmjs.org/' },
    @{ name = 'npmmirror 阿里'; url = 'https://registry.npmmirror.com/' },
    @{ name = '华为云';         url = 'https://mirrors.huaweicloud.com/repository/npm/' },
    @{ name = '中科大 USTC';    url = 'https://mirrors.ustc.edu.cn/npm/' }
  )
  $results = New-Object System.Collections.ArrayList
  # PS 5.1 需要先加载程序集才能 New-Object HttpClient
  try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { return $null }
  $client = New-Object System.Net.Http.HttpClient
  try {
    $client.Timeout = [TimeSpan]::FromSeconds(5)
    foreach ($m in $mirrors) {
      $best = -1
      for ($try = 0; $try -lt 2; $try++) {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, ($m.url + '@deepseek-ai/dsh'))
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
          $resp = $client.SendAsync($req).Result
          $sw.Stop()
          if ($resp.IsSuccessStatusCode) {
            $ms = [int]$sw.ElapsedMilliseconds
            if ($best -lt 0 -or $ms -lt $best) { $best = $ms }
          }
          $resp.Dispose()
        } catch { $sw.Stop() }
        $req.Dispose()
      }
      if ($best -ge 0) { [void]$results.Add(@{ name = $m.name; url = $m.url; ms = $best }) }
    }
  } finally {
    $client.Dispose()
  }
  if ($results.Count -eq 0) { return $null }
  # 注意: 必须用 scriptblock 按数值排序(Sort-Object ms 字符串属性名会按字符串排,如 208<24)
  $sorted = @($results | Sort-Object { [int]$_.ms })
  Ln '  镜像测速结果:'
  $i = 1
  foreach ($r in $sorted) {
    Ln ('    {0}. {1,-16} {2,6} ms' -f $i, $r.name, $r.ms)
    $i++
  }
  return $sorted
}

# ---------------- home helpers ----------------
# dsh 要求 profiles\node_modules 里的包是符号链接/接合点(junction);
# 搬家/拷贝时被复制成普通目录会导致 dsh 启动报错。体检并删除,由 dsh 自动重建。
function Repair-ProfilesNodeModules {
  $pn = Join-Path $HomeDir 'profiles\node_modules'
  if (-not (Test-Path $pn)) { return }
  $remove = New-Object System.Collections.ArrayList
  foreach ($top in Get-ChildItem $pn -Directory -Force -ErrorAction SilentlyContinue) {
    $isLink = (($top.Attributes) -band [IO.FileAttributes]::ReparsePoint) -ne 0
    if ($isLink) { continue }
    if ($top.Name.StartsWith('@')) {
      foreach ($inner in Get-ChildItem $top.FullName -Directory -Force -ErrorAction SilentlyContinue) {
        $innerIsLink = (($inner.Attributes) -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if (-not $innerIsLink) { [void]$remove.Add($inner.FullName) }
      }
    } else {
      [void]$remove.Add($top.FullName)
    }
  }
  if ($remove.Count -gt 0) {
    Ln ''
    Ln ('  检测到 profiles\node_modules 中有 ' + $remove.Count + ' 个目录被复制成了普通文件')
    Ln '  (整文件夹搬家/拷贝常见),正在删除,由 dsh 启动时自动重建链接...'
    foreach ($p in $remove) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    Ln '  处理完成。'
    Ln ''
  }
}

# ---------------- console window helpers ----------------
# 隐藏控制台窗口: WS_EX_TOOLWINDOW(任务栏按钮消失) + SW_HIDE 组合拳。
# 单用 SW_HIDE 在部分系统上任务栏按钮会残留;TOOLWINDOW 从根上移除任务栏按钮。
# 注意: 需要 [Native.Win] 已加载(launch 段询问分支前加载)。
function Hide-ConsoleWindow {
  try {
    $h = [Native.Win]::GetConsoleWindow()
    $ex = [Native.Win]::GetWindowLong($h, -20)   # GWL_EXSTYLE
    [void][Native.Win]::SetWindowLong($h, -20, ($ex -bor 0x80))   # WS_EX_TOOLWINDOW
    [void][Native.Win]::ShowWindow($h, 0)        # SW_HIDE
  } catch { }
}
function Show-ConsoleWindow {
  try {
    $h = [Native.Win]::GetConsoleWindow()
    $ex = [Native.Win]::GetWindowLong($h, -20)
    [void][Native.Win]::SetWindowLong($h, -20, ($ex -band (-bnot 0x80)))  # 去掉 TOOLWINDOW(恢复任务栏按钮)
    [void][Native.Win]::ShowWindow($h, 9)        # SW_RESTORE
  } catch { }
}

# ---------------- tray guard bootstrap ----------------
# 隐藏守护进程 B 的完整脚本模板(由启动器 A 就绪后以 -EncodedCommand 启动,独立控制台):
# B 与窗口完全解耦,轮询检测 A 退出(用户关闭窗口) → 创建系统托盘 → 托盘管理退出。
# 这绕开 CTRL_CLOSE 拦截在真实双击场景不可靠的问题(5 秒强杀限制/cmd 宿主行为)。
# 占位符: __ROOT__/__DSHPID__/__APID__/__ERRLOG__/__URL__/__TRAYCS__ 运行时注入;
#         __TRAY_ICON_B64__ 构建时注入(与主脚本共用)。
$script:TrayGuardTemplate = @'
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$script:ROOT    = '__ROOT__'
$script:DSH_PID = __DSHPID__
$script:A_PID   = __APID__
$script:ERR_LOG = '__ERRLOG__'
$script:URL     = '__URL__'
# 托盘守护类由启动器运行时注入(避免模板嵌套 here-string,占位符不写进注释)
$script:TrayCs = __TRAYCS__

# 等待启动器 A 退出(用户关闭窗口 / Ctrl+C / A 崩溃)
while ($true) {
  $aAlive = $false
  try { $aAlive = [bool](Get-Process -Id $script:A_PID -ErrorAction SilentlyContinue) } catch { $aAlive = $false }
  if (-not $aAlive) { break }
  Start-Sleep -Milliseconds 300
}

try {
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  Add-Type -TypeDefinition $script:TrayCs -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop
} catch {
  try { [IO.File]::AppendAllText($script:ERR_LOG, '[tray-guard] 组件加载失败: ' + $_.Exception.Message + "`r`n") } catch { }
  exit 1
}

try {
  $pngPath = Join-Path $env:TEMP ('dsh-tray-' + $PID + '.png')
  try { [IO.File]::WriteAllBytes($pngPath, [Convert]::FromBase64String('__TRAY_ICON_B64__')) } catch { }
  $bmp = $null
  $hicon = [IntPtr]::Zero
  if (Test-Path $pngPath) {
    try { $bmp = [System.Drawing.Bitmap]::FromFile($pngPath); $hicon = $bmp.GetHicon() } catch { $hicon = [IntPtr]::Zero }
  }
  if ($hicon -eq [IntPtr]::Zero) {
    $sysIcon = [System.Drawing.SystemIcons]::Application
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.DrawIcon($sysIcon, 0, 0)
    $g.Dispose()
    $hicon = $bmp.GetHicon()
  }

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $mOpen = New-Object System.Windows.Forms.ToolStripMenuItem('打开网页')
  $mOpen.add_Click({ try { Start-Process $script:URL | Out-Null } catch { } })
  $mQuit = New-Object System.Windows.Forms.ToolStripMenuItem('退出服务')
  $mQuit.add_Click({
    $script:quit = $true
    try { [System.Windows.Forms.Application]::Exit() } catch { }
  })
  [void]$menu.Items.Add($mOpen)
  [void]$menu.Items.Add($mQuit)

  $tray = New-Object DshTray -ArgumentList @($hicon, 'DeepSeek Harness - 服务运行中', $menu)
  $script:quit = $false

  # 定时器: dsh 退出则结束托盘循环(图标消失)
  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 2000
  $timer.add_Tick({
    try {
      if (-not (Get-Process -Id $script:DSH_PID -ErrorAction SilentlyContinue)) {
        try { [System.Windows.Forms.Application]::Exit() } catch { }
      }
    } catch { }
  })
  $timer.Start()

  [System.Windows.Forms.Application]::Run()
  $timer.Stop()
  $timer.Dispose()
  try { $tray.Dispose() } catch { }
  if ($bmp) { $bmp.Dispose() }
  try { Remove-Item $pngPath -Force -ErrorAction SilentlyContinue } catch { }

  if ($script:quit) {
    # 托盘"退出服务" → 结束服务并清理 PID 文件
    try { Stop-Process -Id $script:DSH_PID -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item (Join-Path $script:ROOT '.dsh-server.pid') -Force -ErrorAction SilentlyContinue } catch { }
  }
} catch {
  try { [IO.File]::AppendAllText($script:ERR_LOG, '[tray-guard] 托盘失败: ' + $_.Exception.Message + "`r`n") } catch { }
}
'@

# ---------------- system tray ----------------
# 原生 Shell_NotifyIcon + 固定 GUID(NOTIFYICON_VERSION_4):
#  - 支持用户把图标拖到托盘外层并固定(系统记住 GUID 偏好;WinForms NotifyIcon 做不到)
#  - 双击恢复窗口,右键菜单: 显示/隐藏/退出服务
#  - autoHide 压制: 托盘期间窗口被任何原因弹回时自动再隐藏(直到用户主动"显示窗口")
# 阻塞直到: 用户点"退出服务" 或 dsh 进程退出;返回 $true 表示进入过托盘循环
$script:TrayCs = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class DshTray : NativeWindow {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct NOTIFYICONDATA {
    public int cbSize;
    public IntPtr hWnd;
    public int uID;
    public uint uFlags;
    public uint uCallbackMessage;
    public IntPtr hIcon;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
    public uint dwState;
    public uint dwStateMask;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
    public uint uTimeoutOrVersion;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
    public uint dwInfoFlags;
    public Guid guidItem;
    public IntPtr hBalloonIcon;
  }

  const uint NIM_ADD = 0;
  const uint NIM_DELETE = 2;
  const uint NIM_SETVERSION = 4;
  const uint NIF_MESSAGE = 1;
  const uint NIF_ICON = 2;
  const uint NIF_TIP = 4;
  const uint NIF_GUID = 0x20;
  const uint NOTIFYICON_VERSION_4 = 4;
  const int WM_USER = 0x400;
  const int WM_LBUTTONDBLCLK = 0x0203;
  const int WM_RBUTTONUP = 0x0205;

  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  static extern bool Shell_NotifyIcon(uint dwMessage, ref NOTIFYICONDATA lpData);

  [DllImport("user32.dll")]
  static extern bool SetForegroundWindow(IntPtr hWnd);

  // 固定 GUID: 同一个图标每次启动相同,用户拖到外层后系统记住"始终显示"
  public static readonly Guid TrayGuid = new Guid("7C2F4A1B-9E3D-4C5A-B6F8-2D1E0A9B3C44");
  const int UID = 0x0D5;

  public bool AutoHide = true;
  public event Action ShowRequested;

  ContextMenuStrip _menu;
  IntPtr _hicon;

  public DshTray(IntPtr iconHandle, string tip, ContextMenuStrip menu) {
    _hicon = iconHandle;
    _menu = menu;
    CreateHandle(new CreateParams());
    NOTIFYICONDATA n = new NOTIFYICONDATA();
    n.cbSize = Marshal.SizeOf(typeof(NOTIFYICONDATA));
    n.hWnd = Handle;
    n.uID = UID;
    n.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_GUID;
    n.uCallbackMessage = WM_USER + 1;
    n.hIcon = iconHandle;
    n.szTip = tip;
    n.guidItem = TrayGuid;
    Shell_NotifyIcon(NIM_ADD, ref n);
    n.uTimeoutOrVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIcon(NIM_SETVERSION, ref n);
  }

  protected override void WndProc(ref Message m) {
    if (m.Msg == WM_USER + 1) {
      int msg = (int)m.LParam & 0xFFFF;
      if (msg == WM_LBUTTONDBLCLK) {
        if (ShowRequested != null) ShowRequested();
      } else if (msg == WM_RBUTTONUP) {
        if (_menu != null) {
          // 先激活窗口再弹菜单: 否则菜单不接收焦点,点击外部/按 ESC 无法关闭
          SetForegroundWindow(Handle);
          _menu.Show(Cursor.Position);
        }
      }
    }
    base.WndProc(ref m);
  }

  public void Dispose() {
    NOTIFYICONDATA n = new NOTIFYICONDATA();
    n.cbSize = Marshal.SizeOf(typeof(NOTIFYICONDATA));
    n.hWnd = Handle;
    n.uID = UID;
    n.uFlags = NIF_GUID;
    n.guidItem = TrayGuid;
    Shell_NotifyIcon(NIM_DELETE, ref n);
    DestroyHandle();
  }
}
'@

function Start-Tray {
  $script:trayQuit = $false
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    Add-Type -TypeDefinition $script:TrayCs -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop
  } catch {
    Ln ('  系统托盘不可用: ' + $_.Exception.Message)
    Ln '  窗口保持。'
    return $false
  }
  try {
    # 解码内嵌官方图标(png → HICON)
    $pngPath = Join-Path $env:TEMP ('dsh-tray-' + $PID + '.png')
    try {
      [IO.File]::WriteAllBytes($pngPath, [Convert]::FromBase64String($script:DSH_TRAY_ICON_B64))
    } catch { }
    $bmp = $null
    $hicon = [IntPtr]::Zero
    if (Test-Path $pngPath) {
      try {
        $bmp = [System.Drawing.Bitmap]::FromFile($pngPath)
        $hicon = $bmp.GetHicon()
      } catch { $hicon = [IntPtr]::Zero }
    }
    if ($hicon -eq [IntPtr]::Zero) {
      # 回退: 系统图标转 HICON
      $sysIcon = [System.Drawing.SystemIcons]::Application
      $bmp = New-Object System.Drawing.Bitmap(16, 16)
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.DrawIcon($sysIcon, 0, 0)
      $g.Dispose()
      $hicon = $bmp.GetHicon()
    }

    # 右键菜单
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $mShow = New-Object System.Windows.Forms.ToolStripMenuItem('显示窗口')
    $mShow.add_Click({
      $script:trayAutoHide = $false
      Show-ConsoleWindow
    })
    $mHide = New-Object System.Windows.Forms.ToolStripMenuItem('隐藏窗口')
    $mHide.add_Click({
      $script:trayAutoHide = $true
      Hide-ConsoleWindow
    })
    $mQuit = New-Object System.Windows.Forms.ToolStripMenuItem('退出服务')
    $mQuit.add_Click({
      $script:trayQuit = $true
      try { [System.Windows.Forms.Application]::Exit() } catch { }
    })
    [void]$menu.Items.Add($mShow)
    [void]$menu.Items.Add($mHide)
    [void]$menu.Items.Add($mQuit)

    # 注意: Add-Type 动态类型不能用 New-Object X(args) 括号语法(解析时类型未知),必须用 -ArgumentList
    $tray = New-Object DshTray -ArgumentList @($hicon, 'DeepSeek Harness - 双击显示窗口', $menu)
    $script:tray = $tray
    $script:trayAutoHide = $true
    $tray.add_ShowRequested({
      $script:trayAutoHide = $false
      Show-ConsoleWindow
    })

    # 图标创建成功 → 此时才隐藏窗口(失败时窗口保持可见,用户能看到错误)
    Hide-ConsoleWindow

    # 定时器: 1) dsh 退出则结束循环  2) autoHide 压制(窗口被弹回时再隐藏)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.add_Tick({
      try {
        if ($script:dshProc -and $script:dshProc.HasExited) {
          try { [System.Windows.Forms.Application]::Exit() } catch { }
        }
        if ($script:trayAutoHide) {
          Hide-ConsoleWindow
        }
      } catch { }
    })
    $timer.Start()

    Ln '  已最小化到系统托盘(官方图标; 双击恢复窗口, 右键可退出服务)。'
    Ln '  提示: 可把图标拖到托盘外层固定,系统会记住。'
    Ln ''
    [System.Windows.Forms.Application]::Run()
    $timer.Stop()
    $timer.Dispose()
    try { $tray.Dispose() } catch { }
    if ($bmp) { $bmp.Dispose() }
    try { Remove-Item $pngPath -Force -ErrorAction SilentlyContinue } catch { }
    return $true
  } catch {
    $errMsg = '系统托盘启动失败: ' + $_.Exception.Message
    try { [IO.File]::AppendAllText($errLog, '[tray] ' + $errMsg + "`r`n") } catch { }
    Ln ('  ' + $errMsg)
    Ln '  窗口保持。'
    return $false
  }
}

# ---------------- version check ----------------
# semver 比较: 返回 $true 表示 $b 比 $a 新(支持 -rc.N 预发布标签)
function Compare-DshVersion([string]$a, [string]$b) {
  $ca = $a; $pa = ''
  $ia = $a.IndexOf('-')
  if ($ia -ge 0) { $ca = $a.Substring(0, $ia); $pa = $a.Substring($ia + 1) }
  $cb = $b; $pb = ''
  $ib = $b.IndexOf('-')
  if ($ib -ge 0) { $cb = $b.Substring(0, $ib); $pb = $b.Substring($ib + 1) }

  $na = @()
  foreach ($p in $ca.Split('.')) { $n = 0; [void][int]::TryParse($p, [ref]$n); $na += $n }
  $nb = @()
  foreach ($p in $cb.Split('.')) { $n = 0; [void][int]::TryParse($p, [ref]$n); $nb += $n }

  for ($i = 0; $i -lt 3; $i++) {
    if ($na[$i] -lt $nb[$i]) { return $true }
    if ($na[$i] -gt $nb[$i]) { return $false }
  }
  # 主版本相同: 无 pre 标签 > 有 pre 标签
  if ($pa -eq '' -and $pb -ne '') { return $false }
  if ($pa -ne '' -and $pb -eq '') { return $true }
  if ($pa -eq $pb) { return $false }
  $ap = $pa.Split('.'); $bp = $pb.Split('.')
  $len = [Math]::Min($ap.Length, $bp.Length)
  for ($i = 0; $i -lt $len; $i++) {
    $an = 0; $bn = 0
    $aIsNum = [int]::TryParse($ap[$i], [ref]$an)
    $bIsNum = [int]::TryParse($bp[$i], [ref]$bn)
    if ($aIsNum -and $bIsNum) {
      if ($an -lt $bn) { return $true }
      if ($an -gt $bn) { return $false }
    } else {
      $cmp = [string]::Compare($ap[$i], $bp[$i], $true)
      if ($cmp -lt 0) { return $true }
      if ($cmp -gt 0) { return $false }
    }
  }
  return ($ap.Length -lt $bp.Length)
}

# 查询 registry 上 @deepseek-ai/dsh 的 latest 版本(5 秒超时,失败返回空)
function Get-DshLatestVersion([string]$registryUrl) {
  $latest = ''
  try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { return $latest }
  $client = New-Object System.Net.Http.HttpClient
  try {
    $client.Timeout = [TimeSpan]::FromSeconds(5)
    $probe = $registryUrl.TrimEnd('/') + '/@deepseek-ai%2fdsh/latest'
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $probe)
    # 注意: /latest 端点不接受 abbreviated Accept(vnd.npm.install-v1+json),会 406
    try {
      $resp = $client.SendAsync($req).Result
      if ($resp.IsSuccessStatusCode) {
        $json = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
        if ($json.version) { $latest = [string]$json.version }
      }
      $resp.Dispose()
    } catch { }
    $req.Dispose()
  } finally {
    $client.Dispose()
  }
  return $latest
}

# ---------------- user args ----------------
$flags = @{}
$toks = New-Object System.Collections.ArrayList
if ($UserArgs -and ([string]$UserArgs).Trim() -ne '') {
  $re = [regex]'"([^"]*)"|([^\s"]+)'
  foreach ($m in $re.Matches([string]$UserArgs)) {
    $v = $m.Groups[1].Value
    if ($v -eq '') { $v = $m.Groups[2].Value }
    [void]$toks.Add($v)
  }
}
for ($i = 0; $i -lt $toks.Count; $i++) {
  $t = [string]$toks[$i]
  if ($t.StartsWith('--')) {
    $key = $t.Substring(2).ToLowerInvariant()
    if ($key -eq '') { continue }
    $val = $true
    if (($i + 1) -lt $toks.Count -and -not ([string]$toks[$i + 1]).StartsWith('--')) {
      $val = [string]$toks[$i + 1]
      $i++
    }
    $flags[$key] = $val
  }
}

function Show-Help {
  Ln ''
  Ln ('  DeepSeek Harness 单文件启动器  v' + $AppVersion)
  Ln '  --------------------------------------------------'
  Ln ''
  Ln '  用法:'
  Ln '    DeepSeek-Harness.bat                 安装(首次)并启动 web 界面;启动时自动检查更新'
  Ln '    DeepSeek-Harness.bat --port 8080     指定端口启动(不指定则随机分配并记住)'
  Ln '    DeepSeek-Harness.bat --no-open       不自动打开浏览器'
  Ln '    DeepSeek-Harness.bat --home <路径>   指定 DSH_HOME 目录'
  Ln '    DeepSeek-Harness.bat --registry <url> 指定 npm 镜像(默认首次安装自动测速)'
  Ln '    DeepSeek-Harness.bat --update        立即把 @deepseek-ai/dsh 升级到最新版'
  Ln '    DeepSeek-Harness.bat --reinstall     删除 dsh-app\ 并重装'
  Ln '    DeepSeek-Harness.bat --reset-home    备份 dsh-home\ 后重新初始化'
  Ln '    DeepSeek-Harness.bat --status        打印检测到的路径后退出'
  Ln '    DeepSeek-Harness.bat --help          显示本帮助'
  Ln ''
  Ln '  本 bat 旁边的目录:'
  Ln '    dsh-app\        npm 安装的程序本体(@deepseek-ai/dsh)'
  Ln '    dsh-home\       便携 DSH_HOME(配置、会话、凭据)'
  Ln '    nodejs\         (可选)便携 Node.js(node.exe + npm.cmd)'
  Ln '    .dsh-launcher.json  记住的 home 选择'
  Ln ''
}

if ($flags.ContainsKey('help')) { Show-Help; Self-Clean; exit 0 }

# ---------------- portable node download ----------------
# 自动下载便携 Node.js 到本目录 nodejs\(与参考项目的 Ensure-NodeJs 同思路):
# 镜像测速选择 → 版本回退链(22→20→18) → 下载 zip → 解压 → 校验
function Download-PortableNode {
  $sources = @(
    @{ name = '官方';   node = 'https://nodejs.org/dist' },
    @{ name = '华为云'; node = 'https://repo.huaweicloud.com/nodejs' },
    @{ name = '腾讯云'; node = 'https://mirrors.cloud.tencent.com/nodejs' },
    @{ name = '中科大'; node = 'https://mirrors.ustc.edu.cn/nodejs-release' }
  )
  try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { Ln '  网络组件加载失败。'; return $false }

  # 1. 测速
  $results = New-Object System.Collections.ArrayList
  $client = New-Object System.Net.Http.HttpClient
  try {
    $client.Timeout = [TimeSpan]::FromSeconds(5)
    foreach ($src in $sources) {
      $best = -1
      for ($try = 0; $try -lt 2; $try++) {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, ($src.node + '/index.json'))
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
          $resp = $client.SendAsync($req).Result
          $sw.Stop()
          if ($resp.IsSuccessStatusCode) {
            $ms = [int]$sw.ElapsedMilliseconds
            if ($best -lt 0 -or $ms -lt $best) { $best = $ms }
          }
          $resp.Dispose()
        } catch { $sw.Stop() }
        $req.Dispose()
      }
      if ($best -ge 0) { [void]$results.Add(@{ name = $src.name; node = $src.node; ms = $best }) }
    }
  } finally { $client.Dispose() }
  if ($results.Count -eq 0) { Ln '  所有 Node.js 镜像均不可达(请检查网络)。'; return $false }
  $sorted = @($results | Sort-Object { [int]$_.ms })
  Ln '  Node.js 下载源测速:'
  $i = 1
  foreach ($r in $sorted) { Ln ('    {0}. {1,-6} {2,6} ms' -f $i, $r.name, $r.ms); $i++ }
  $sel = $sorted[0]
  if (Is-Interactive) {
    $ans = ''
    try { $ans = Read-Host ('  回车用默认(1. ' + $sel.name + ') 或输入编号') } catch { $ans = '' }
    $idx = 1
    if ($ans -match '^\d+$') { $n = [int]$ans; if ($n -ge 1 -and $n -le $sorted.Count) { $idx = $n } }
    $sel = $sorted[$idx - 1]
  }
  Ln ('  已选择: ' + $sel.name + '  (' + $sel.node + ')')
  Ln ''

  # 2. 版本: index.json 取 v22 最新,回退 20/18
  $ver = ''
  foreach ($major in @('22', '20', '18')) {
    try {
      $c2 = New-Object System.Net.Http.HttpClient
      $c2.Timeout = [TimeSpan]::FromSeconds(15)
      $idxJson = $c2.GetStringAsync($sel.node + '/index.json').Result | ConvertFrom-Json
      $c2.Dispose()
      $m = $idxJson | Where-Object { $_.version -match ('^v' + $major + '\.') } | Select-Object -First 1
      if ($m) { $ver = $m.version.Substring(1); break }
    } catch { }
  }
  if (-not $ver) { Ln '  获取 Node.js 版本列表失败。'; return $false }
  $arch = 'win-x64'
  if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'win-arm64' }
  $file = 'node-v' + $ver + '-' + $arch + '.zip'
  $zipUrl = $sel.node + '/v' + $ver + '/' + $file
  Ln ('  下载 ' + $file + ' (约 30MB, 视网络情况需要几分钟)...')
  Ln ''
  $zipPath = Join-Path $Root 'node.zip'
  try {
    $c3 = New-Object System.Net.Http.HttpClient
    $c3.Timeout = [TimeSpan]::FromMinutes(15)
    $resp3 = $c3.GetAsync($zipUrl).Result
    if (-not $resp3.IsSuccessStatusCode) { throw ('HTTP ' + [int]$resp3.StatusCode) }
    $bytes = $resp3.Content.ReadAsByteArrayAsync().Result
    $c3.Dispose()
    [IO.File]::WriteAllBytes($zipPath, $bytes)
    Ln ('  下载完成 (' + [math]::Round($bytes.Length / 1MB, 1) + ' MB)。解压中...')
  } catch {
    Ln ('  下载失败: ' + $_.Exception.Message)
    try { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue } catch { }
    return $false
  }

  # 3. 解压到 nodejs\
  $extractDir = Join-Path $Root ('nodejs-tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $inner = Get-ChildItem $extractDir -Directory | Select-Object -First 1
    if (-not $inner) { throw '压缩包内容为空' }
    New-Item -ItemType Directory -Path (Join-Path $Root 'nodejs') -Force | Out-Null
    Get-ChildItem $inner.FullName -Force | ForEach-Object {
      Move-Item $_.FullName (Join-Path $Root 'nodejs') -Force
    }
  } catch {
    Ln ('  解压失败: ' + $_.Exception.Message)
    try { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    return $false
  } finally {
    try { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }

  # 4. 校验
  if (Test-Path $PortableNode) {
    try { $nv = (& $PortableNode -v 2>$null | Out-String).Trim() } catch { $nv = '' }
    if ($nv -match '^v\d+\.') {
      Ln ('  Node.js 便携版安装成功: ' + $nv + '  (nodejs\)')
      Ln ''
      return $true
    }
  }
  Ln '  便携版安装失败(校验未通过)。'
  return $false
}

function Show-ManualNodeTutorial {
  Ln ''
  Ln '  手动安装 Node.js 到本目录:'
  Ln '    1. 打开 https://nodejs.org/zh-cn/download'
  Ln '       (国内可用: https://mirrors.huaweicloud.com/nodejs/)'
  Ln '    2. 下载 Windows 64 位 .zip 版(不是 .msi)'
  Ln '    3. 解压后把 node-vXX-win-x64 文件夹重命名为 nodejs'
  Ln '    4. 放入本 bat 所在目录(确保 nodejs\node.exe 和'
  Ln '       nodejs\npm.cmd 存在)'
  Ln '    5. 重新运行本 bat'
  Ln ''
}

# ---------------- node / npm detection ----------------
$NodeExe = $null
$NpmCmd  = $null
$nodeOrigin = ''
if (Test-Path $PortableNode) {
  $NodeExe = $PortableNode
  if (Test-Path $PortableNpm) { $NpmCmd = $PortableNpm }
  $nodeOrigin = 'portable (nodejs\ next to this bat)'
}
if (-not $NodeExe) {
  $c = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($c) { $NodeExe = $c.Source; $nodeOrigin = 'system node on PATH' }
}
if (-not $NpmCmd) {
  $c = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if ($c) { $NpmCmd = $c.Source }
}

$nodeVersion = ''
if ($NodeExe) {
  try { $nodeVersion = (& $NodeExe -v 2>$null | Out-String).Trim() } catch { $nodeVersion = '' }
  if ($nodeVersion -match '^v(\d+)\.') {
    if ([int]$Matches[1] -lt 18) { $nodeVersion = '' }
  } else {
    $nodeVersion = ''
  }
}

# ---- --stop: 停止后台运行的服务(读取 .dsh-server.pid) ----
if ($flags.ContainsKey('stop')) {
  $pidFile = Join-Path $Root '.dsh-server.pid'
  if (Test-Path $pidFile) {
    $svcInfo = $null
    try { $svcInfo = Get-Content $pidFile -Raw | ConvertFrom-Json } catch { $svcInfo = $null }
    $svcPid = 0
    if ($svcInfo -and $svcInfo.pid) { try { $svcPid = [int]$svcInfo.pid } catch { $svcPid = 0 } }
    if ($svcPid -gt 0) {
      try {
        Stop-Process -Id $svcPid -Force -ErrorAction Stop
        Ln ('  已停止服务(进程 ' + $svcPid + ')。')
      } catch {
        Ln ('  进程 ' + $svcPid + ' 不存在或已退出。')
      }
    }
    try { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue } catch { }
  } else {
    Ln '  未找到运行中的服务(无 PID 记录,或服务不在本目录启动)。'
  }
  Ln ''
  Self-Clean
  exit 0
}

if ($flags.ContainsKey('status')) {
  Ln ''
  Ln '  DeepSeek Harness 启动器状态'
  Ln '  --------------------------------------------------'
  Ln ('  bat 文件   : ' + (Join-Path $Root 'DeepSeek-Harness.bat'))
  Ln ('  版本       : ' + $AppVersion + '  (构建于 ' + $AppBuilt + ')')
  Ln ('  dsh 安装版 : ' + $(if ($DshPin -eq 'latest') { 'latest(安装时取 npm 最新版)' } else { $DshPin }))
  Ln ('  程序目录   : ' + $AppDir)
  if (Test-Path $BinJs) { Ln '               已安装(正常)' } else { Ln '               未安装' }
  Ln ('  数据目录   : ' + $HomeDir)
  Ln ('  node       : ' + $(if ($nodeVersion) { $nodeVersion + '  (' + $nodeOrigin + ')' } else { '未找到' }))
  Ln ('  npm        : ' + $(if ($NpmCmd) { $NpmCmd } else { '未找到' }))
  $scfg = Read-Cfg
  if ($scfg -and $scfg.port) { Ln ('  记忆端口   : ' + $scfg.port) } else { Ln '  记忆端口   : (未设置,将随机分配)' }
  if ($scfg -and $scfg.registry) { Ln ('  记忆镜像   : ' + $scfg.registry) } else { Ln '  记忆镜像   : (未设置,首次安装将测速)' }
  Ln ''
  Self-Clean
  exit 0
}

if (-not $nodeVersion) {
  # 便携与系统都不可用 → 交互询问自动下载/手动/退出
  if (Is-Interactive) {
    Ln ''
    H1 '未找到可用的 Node.js 环境'
    Ln '  DeepSeek Harness 需要 Node.js 18+。可自动下载便携版到本目录。'
    Ln ''
    Ln '  [1] 自动下载 Node.js 到本目录 nodejs\ (推荐, 约 30MB)'
    Ln '  [2] 手动下载教程(下载后放入 nodejs\)'
    Ln '  [3] 退出'
    Ln ''
    $ans = ''
    try { $ans = Read-Host '  请选择 (1/2/3)' } catch { $ans = '' }
    if ($ans -eq '2') {
      Show-ManualNodeTutorial
      if (Is-Interactive) { try { Read-Host '  按回车关闭' | Out-Null } catch { } }
      Self-Clean
      exit 0
    }
    if ($ans -ne '1') {
      Self-Clean
      exit 0
    }
    if (-not (Download-PortableNode)) {
      Ln '  便携版安装失败,请检查网络后重试。'
      Ln ''
      if (Is-Interactive) { try { Read-Host '  按回车关闭' | Out-Null } catch { } }
      Self-Clean
      exit 2
    }
    $NodeExe = $PortableNode
    $NpmCmd = $PortableNpm
    $nodeOrigin = 'portable (nodejs\ next to this bat)'
    try { $nodeVersion = (& $NodeExe -v 2>$null | Out-String).Trim() } catch { $nodeVersion = '' }
    if (-not ($nodeVersion -match '^v\d+\.')) {
      H1 'Node.js 校验失败'
      Ln '  便携版安装后校验未通过,请手动检查 nodejs\ 目录。'
      Ln ''
      if (Is-Interactive) { try { Read-Host '  按回车关闭' | Out-Null } catch { } }
      Self-Clean
      exit 2
    }
  } else {
    H1 '未找到 Node.js 18+'
    Ln '  DeepSeek Harness 需要 Node.js 18 或更高版本(dsh 是 Node CLI 程序)。'
    Ln '  二选一:'
    Ln '    1. 从 https://nodejs.org 安装 Node.js LTS 后重新运行本 bat;或'
    Ln '    2. 下载 node-vXX-win-x64.zip 便携版,解压成 nodejs\ 文件夹'
    Ln '       (内含 nodejs\node.exe 和 nodejs\npm.cmd)放到本 bat 旁边。'
    Ln ''
    if (Is-Interactive) { try { Read-Host '  按回车关闭' | Out-Null } catch { } }
    Self-Clean
    exit 2
  }
} elseif ($NodeExe -ne $PortableNode -and (Is-Interactive) -and -not $flags.ContainsKey('system-node')) {
  # 有系统 node 但无便携: 首次询问是否下载便携版隔离(记住选择)
  $earlyCfg = Read-Cfg
  $nodeMode = ''
  if ($earlyCfg -and $earlyCfg.nodeMode) { $nodeMode = [string]$earlyCfg.nodeMode }
  if ($nodeMode -eq '') {
    Ln ''
    Ln ('  检测到系统 Node.js: ' + $nodeVersion)
    Ln ''
    Ln '  [1] 使用系统 Node.js (默认)'
    Ln '  [2] 下载便携版到本目录 nodejs\ (环境隔离, 约 30MB)'
    Ln ''
    $ans = ''
    try { $ans = Read-Host '  请选择 (1/2, 默认 1)' } catch { $ans = '' }
    if ($ans -eq '2') {
      if (Download-PortableNode) {
        $NodeExe = $PortableNode
        $NpmCmd = $PortableNpm
        $nodeOrigin = 'portable (nodejs\ next to this bat)'
        try { $nodeVersion = (& $NodeExe -v 2>$null | Out-String).Trim() } catch { }
        Save-Cfg @{ nodeMode = 'portable' }
      } else {
        Ln '  便携版安装失败,继续使用系统 Node.js。'
      }
    } else {
      Save-Cfg @{ nodeMode = 'system' }
    }
    Ln ''
  }
}

# ---------------- install phase ----------------
$needInstall = $false
$updateMode  = $false
if ($flags.ContainsKey('reinstall')) {
  if (Test-Path $AppDir) { Remove-Item $AppDir -Recurse -Force }
  $needInstall = $true
}
if (-not (Test-Path $BinJs)) { $needInstall = $true }
if ($flags.ContainsKey('update')) { $needInstall = $true; $updateMode = $true }

# ---- 启动时版本检查: 已安装且非强制重装/升级时才查 ----
if (-not $needInstall) {
  $instPkg = Join-Path $AppDir 'node_modules\@deepseek-ai\dsh\package.json'
  $curVer = ''
  if (Test-Path $instPkg) {
    try { $curVer = [string]((Get-Content $instPkg -Raw | ConvertFrom-Json).version) } catch { }
  }
  if ($curVer) {
    $cReg = Read-Cfg
    $regUrl = 'https://registry.npmjs.org/'
    if ($cReg -and $cReg.registry) { $regUrl = [string]$cReg.registry }
    $latestVer = Get-DshLatestVersion $regUrl
    if ($latestVer -and (Compare-DshVersion $curVer $latestVer)) {
      Ln ''
      Ln ('  发现新版本: ' + $latestVer + '  (当前 ' + $curVer + ')')
      if (Is-Interactive) {
        try {
          $ans = Read-Host '  按 Y 立即升级 / 回车跳过'
        } catch { $ans = '' }
        if ($ans -eq 'y' -or $ans -eq 'Y') {
          $updateMode = $true
          $needInstall = $true
          Ln ''
        }
      } else {
        Ln '  非交互环境自动跳过。需要时请运行: DeepSeek-Harness.bat --update'
        Ln ''
      }
    }
  }
}

if ($needInstall) {
  if (-not $NpmCmd) {
    H1 '未找到 npm'
    Ln '  找到了 node.exe 但没找到 npm.cmd。请重新安装 Node.js'
    Ln '  (官方安装包/zip 自带 npm),然后重新运行本 bat。'
    Ln ''
    if (Is-Interactive) { try { Read-Host '  按回车关闭' | Out-Null } catch { } }
    Self-Clean
    exit 2
  }
  [void](New-Item -ItemType Directory -Path $AppDir -Force)
  $pkgJson = Join-Path $AppDir 'package.json'

  # ---- npm 镜像: --registry 参数 > 记忆的镜像 > 测速选择 ----
  $registry = ''
  if ($flags.ContainsKey('registry')) {
    $registry = [string]$flags['registry']
  } else {
    $c0 = Read-Cfg
    if ($c0 -and $c0.registry) { $registry = [string]$c0.registry }
  }
  if ($registry) {
    Ln ''
    Ln ('  使用 npm 镜像: ' + $registry)
    Ln ''
  } else {
    Ln ''
    Ln '  正在测速 npm 镜像(选择最快的安装源)...'
    Ln ''
    $mirrors = Select-FastestMirror
    if ($mirrors -and $mirrors.Count -gt 0) {
      if (Is-Interactive) {
        Ln ''
        Ln ('  回车使用默认(1. ' + $mirrors[0].name + ') 或输入编号选择:')
        $ans = ''
        try { $ans = Read-Host '  选择安装源 (默认 1)' } catch { $ans = '' }
        $idx = 1
        if ($ans -match '^\d+$') {
          $n = [int]$ans
          if ($n -ge 1 -and $n -le $mirrors.Count) { $idx = $n }
        }
        $sel = $mirrors[$idx - 1]
      } else {
        $sel = $mirrors[0]
      }
      $registry = $sel.url
      Ln ('  已选择: ' + $sel.name + '  (' + $sel.url + ')')
      Save-Cfg @{ registry = $registry }
    } else {
      Ln '  所有镜像均不可达,回退到官方 npm(请检查网络)。'
      $registry = 'https://registry.npmjs.org/'
    }
    Ln ''
  }

  if ($updateMode -and (Test-Path $pkgJson)) {
    H1 ('正在把 @deepseek-ai/dsh 升级到最新版(当前锁定 ' + $DshPin + ')')
  } else {
    # 全新安装一律取 registry 上的最新版: DshPin='latest' 时现场解析成
  # 具体版本号(如 0.1.5-rc.1)写进 package.json,把最新版锁成基线 —— 之后
  # 上游再发新版,启动时的版本检查才会提示更新。解析失败(离线/镜像不通)
  # 回退到 DshPin 字面量,由 npm 自己解析。
  $depVersion = $DshPin
  if ($depVersion -eq 'latest') {
    $regForLatest = 'https://registry.npmjs.org/'
    if ($registry) { $regForLatest = [string]$registry }
    Ln '  正在查询最新版本...'
    $resolvedVer = Get-DshLatestVersion $regForLatest
    if ($resolvedVer) {
      $depVersion = $resolvedVer
    } else {
      Ln '  查询最新版失败(网络/镜像不可达),交由 npm 解析 latest。'
    }
    Ln ''
  }
    if ($updateMode) { $depVersion = 'latest' }
    $content = "{`r`n  `"name`": `"dsh-app`",`r`n  `"private`": true,`r`n  `"dependencies`": { `"@deepseek-ai/dsh`": `"^$depVersion`" }`r`n}`r`n"
    # WriteAllText = UTF-8 WITHOUT BOM (PS 5.1 Set-Content -Encoding UTF8 writes
    # a BOM, which breaks Node's JSON.parse in the dsh profile loader)
    [IO.File]::WriteAllText($pkgJson, $content)
    H1 ('正在安装 DeepSeek Harness ' + $DshPin)
  }
  Ln '  首次运行会下载约 200 MB 依赖包到 dsh-app\。'
  Ln '  需要几分钟;之后的运行会跳过安装直接启动。'
  Ln ''
  Push-Location $AppDir
  try {
    if ($updateMode) {
      & $NpmCmd install '@deepseek-ai/dsh@latest' --omit=dev --no-audit --no-fund --registry=$registry
    } else {
      & $NpmCmd install --omit=dev --no-audit --no-fund --registry=$registry
    }
    $code = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  if ($code -ne 0 -or -not (Test-Path $BinJs)) {
    H1 '安装失败'
    Ln '  npm install 出错(见上方报错信息)。'
    Ln '  不完整的 dsh-app\ 会保留,重新运行本 bat 即可续装。'
    Ln '  无网络时可从其他电脑直接拷贝完整的 dsh-app\ 文件夹过来。'
    Ln ''
    if (Is-Interactive) { try { Read-Host '  按回车关闭' | Out-Null } catch { } }
    Self-Clean
    exit 3
  }

  # ---- [可选] pnpm: DSH 插件管理依赖 ----
  # 为什么需要 pnpm:
  #   1. DSH 的插件系统(dsh plugin 命令)把插件安装转发给 pnpm,没有 pnpm
  #      时直接报错("'pnpm' is not recognized")。
  #   2. DSH 要求 profiles\node_modules 是 pnpm 管理的符号链接结构,
  #      npm 安装的真实目录会被 DSH 拒绝/重建,插件无法加载。
  #   3. 第三方插件全家桶(如 dsh-web-ui: 任务看板/皮肤中心/梁神模式等)
  #      都通过该机制挂载。
  # 版本说明: 安装 pnpm@10——pnpm 11 在 Node 24 下存在 libuv 崩溃
  # (UV_HANDLE_CLOSING, 实测下载依赖时进程崩溃)。
  $pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
  if (-not $pnpmCmd) {
    if (Is-Interactive) {
      Ln ''
      Ln '  [可选] DSH 插件管理需要 pnpm(dsh plugin 依赖它安装第三方插件,'
      Ln '  如 dsh-web-ui 全家桶: 任务看板 / 皮肤中心 / Git 图谱等)。'
      Ln '  当前未检测到 pnpm。'
      Ln ''
      Ln '  [1] 安装 pnpm(推荐, 约几秒)'
      Ln '  [2] 跳过(以后需要时手动运行: npm install -g pnpm)'
      Ln ''
      $ans = ''
      try { $ans = Read-Host '  请选择 (1/2, 默认 1)' } catch { $ans = '1' }
      if ($ans -ne '2') {
        Ln ''
        Ln '  正在安装 pnpm@10(避开 pnpm 11 在 Node 24 下的崩溃问题)...'
        & $NpmCmd install -g pnpm@10 --no-audit --no-fund
        if ($LASTEXITCODE -eq 0) {
          Ln '  pnpm 安装完成。'
        } else {
          Ln '  pnpm 安装失败,可稍后手动安装。'
        }
        Ln ''
      }
    } else {
      Ln ''
      Ln '  提示: DSH 插件管理需要 pnpm(dsh plugin 依赖它)。'
      Ln '  需要时手动运行: npm install -g pnpm'
      Ln ''
    }
  }
}

# ---------------- home phase ----------------
$cfg = Read-Cfg

$useHome = $null
if ($flags.ContainsKey('home')) {
  $useHome = [System.IO.Path]::GetFullPath([string]$flags['home'])
} elseif ($cfg -and $cfg.home) {
  $cfgHome = [string]$cfg.home
  if ($cfgHome -eq 'dsh-home' -or $cfgHome -eq '.' -or $cfgHome -eq '') {
    # 相对标识: bat 旁边的 dsh-home\(整个文件夹搬走仍有效)
    $useHome = $HomeDir
  } else {
    $cfgHomeFull = [System.IO.Path]::GetFullPath($cfgHome)
    if (Test-Path (Join-Path $cfgHomeFull 'profiles')) {
      $useHome = $cfgHomeFull
    } else {
      # 记忆的 home 已不存在(文件夹被移动/删除) → 自动回退 bat 旁
      Ln ''
      Ln ('  记忆的数据目录已不存在: ' + $cfgHomeFull)
      if (Test-Path (Join-Path $HomeDir 'profiles')) {
        $useHome = $HomeDir
        Ln '  已自动改用本 bat 旁边的 dsh-home\。'
      } else {
        $useHome = $HomeDir
        Ln '  将使用本 bat 旁边的 dsh-home\。'
      }
      Save-Cfg @{ home = 'dsh-home' }
      Ln ''
    }
  }
} else {
  $userDsh = Join-Path $env:USERPROFILE '.dsh'
  $haveUser = Test-Path (Join-Path $userDsh 'profiles')
  $havePortable = Test-Path (Join-Path $HomeDir 'profiles')
  if ($haveUser -and -not $havePortable -and (Is-Interactive)) {
    Ln ''
    Ln '  检测到系统里已有 DeepSeek Harness 数据目录:'
    Ln ('    ' + $userDsh)
    Ln ''
    Ln '    [1] 使用本 bat 旁边的便携数据目录  (dsh-home\, 默认)'
    Ln '    [2] 复用上面这个已有目录(能看到原有会话)'
    Ln ''
    $ans = '1'
    try { $ans = Read-Host '  请选择 1/2 (默认 1)' } catch { $ans = '1' }
    if ($ans -eq '2') { $useHome = $userDsh }
  }
  if (-not $useHome) { $useHome = $HomeDir }
  # 存储相对标识: 若就是 bat 旁的 dsh-home 存 "dsh-home",整个文件夹搬走仍有效
  $homeToStore = $useHome
  if ($useHome -eq $HomeDir) { $homeToStore = 'dsh-home' }
  Save-Cfg @{ home = $homeToStore }
}

$useHome = [System.IO.Path]::GetFullPath($useHome)

if ($useHome -eq $HomeDir) {
  # 便携 home 体检(搬家/拷贝导致的链接破坏,仅针对 bat 旁的 dsh-home)
  Repair-ProfilesNodeModules

  if ($flags.ContainsKey('reset-home') -and (Test-Path $HomeDir)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Move-Item $HomeDir (Join-Path $Root ('dsh-home.backup-' + $stamp))
    Ln ('  原 dsh-home\ 已改名为 dsh-home.backup-' + $stamp)
  }
  $profileDir = Join-Path $HomeDir 'profiles\web'
  [void](New-Item -ItemType Directory -Path $profileDir -Force)

  $skeleton = @{}
  $skeleton['package.json'] = @"
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app"
      ]
    }
  }
}
"@
  $skeleton['pnpm-workspace.yaml'] = @"
packages:
  - .

nodeLinker: hoisted
autoInstallPeers: false
"@
  $skeleton['cordis.yml'] = @"
# dsh profile root - an empty entry list. The tree is composed as patches:
# each bundle in package.json's dsh.profile.bundles, then cordis.patch.yml,
# then any --patch overlays. Edit cordis.patch.yml, not this file.
[]
"@
  $skeleton['cordis.patch.yml'] = @"
# Your patch layer for this dsh profile, applied after every bundle layer:
# a top-level YAML array of loader patch entries (id-targeted config
# overrides, disables, and insert lists; !!js expressions allowed).
[]
"@

  foreach ($name in $skeleton.Keys) {
    $dest = Join-Path $profileDir $name
    if (-not (Test-Path $dest)) {
      # UTF-8 without BOM (see install phase note)
      [IO.File]::WriteAllText($dest, $skeleton[$name])
    }
  }
} elseif ($flags.ContainsKey('reset-home')) {
  Ln '  --reset-home 已忽略:当前生效的数据目录不是便携的 dsh-home\。'
}

# ---------------- launch ----------------
$env:DSH_HOME = $useHome
$pidFile = Join-Path $Root '.dsh-server.pid'
$explicitPort = $flags.ContainsKey('port')

# ---- 后台实例检测: 扫描所有运行中的 dsh web 实例 ----
# 返回实例数组: @{ pid; port; url; isLocal }
function Find-RunningInstances {
  $found = New-Object System.Collections.ArrayList
  $rootEsc = [regex]::Escape($Root)
  $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue
  foreach ($pr in $procs) {
    if ($pr.CommandLine -match 'dsh\\lib\\bin\.js"?\s+web') {
      $pPort = ''
      if ($pr.CommandLine -match '--port\s+(\d+)') { $pPort = $Matches[1] }
      if ($pPort -eq '') { continue }
      $isLocal = $pr.CommandLine -match $rootEsc
      [void]$found.Add(@{ pid = $pr.ProcessId; port = $pPort; url = ('http://127.0.0.1:' + $pPort); isLocal = $isLocal })
    }
  }
  # 清理失效 PID 文件(本目录实例已不在)
  if (Test-Path $pidFile) {
    $svcAlive = $false
    try {
      $svcInfo = Get-Content $pidFile -Raw | ConvertFrom-Json
      if ($svcInfo.pid) { $svcAlive = [bool](Get-Process -Id ([int]$svcInfo.pid) -ErrorAction SilentlyContinue) }
    } catch { }
    if (-not $svcAlive) { try { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue } catch { } }
  }
  return $found
}

$instances = @()
if (-not $explicitPort) { $instances = @(Find-RunningInstances) }

if ($instances.Count -gt 0) {
  if (Is-Interactive) {
    # 交互菜单: 打开 / 关闭后台服务 / 取消
    Ln ''
    Ln ('  检测到 ' + $instances.Count + ' 个 DeepSeek Harness 后台实例:')
    $i = 1
    foreach ($ins in $instances) {
      $tag = ''
      if ($ins.isLocal) { $tag = '  (本目录)' }
      Ln ('    {0}. {1}   (PID {2}){3}' -f $i, $ins.url, $ins.pid, $tag)
    }
    Ln ''
    Ln '  [1] 打开浏览器使用已有实例(默认)'
    Ln '  [2] 关闭后台服务(输入编号关闭指定;回车关闭全部)'
    Ln '  [3] 取消'
    Ln ''
    $ans = ''
    try { $ans = Read-Host '  请选择 (1/2/3, 默认 1)' } catch { $ans = '' }
    if ($ans -eq '3') {
      Ln '  已取消。'
      Ln ''
      Self-Clean
      exit 0
    }
    if ($ans -eq '2') {
      $which = ''
      try { $which = Read-Host '  输入要关闭的实例编号(回车=关闭全部)' } catch { $which = '' }
      $toClose = @()
      if ($which -match '^\d+$') {
        $n = [int]$which
        if ($n -ge 1 -and $n -le $instances.Count) {
          $toClose = @($instances[$n - 1])
        } else {
          Ln ('  编号 ' + $n + ' 无效,关闭全部。')
          $toClose = @($instances)
        }
      } else {
        $toClose = @($instances)
      }
      foreach ($ins in $toClose) {
        try {
          Stop-Process -Id ([int]$ins.pid) -Force -ErrorAction Stop
          Ln ('  已关闭: ' + $ins.url + '  (PID ' + $ins.pid + ')')
        } catch {
          Ln ('  关闭失败(可能已退出): ' + $ins.url)
        }
        # 若关闭的是本目录实例,清理 PID 文件
        if ($ins.isLocal -and (Test-Path $pidFile)) {
          try { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue } catch { }
        }
      }
      Ln ''
      Ln '  后台服务已关闭。再次运行本 bat 即可重新启动。'
      Ln ''
      Self-Clean
      exit 0
    }
    # 选 1 或回车 → 打开已有实例(本目录优先)
    $pick = $instances | Where-Object { $_.isLocal } | Select-Object -First 1
    if (-not $pick) { $pick = $instances[0] }
    Ln ('  打开已有实例: ' + $pick.url)
    Ln ''
    Open-WhenReady $pick.url
    if (Is-Interactive) { try { Read-Host '  按回车关闭本窗口' | Out-Null } catch { } }
    Self-Clean
    exit 0
  } else {
    # 非交互: 打开第一个实例(本目录优先),不重复启动
    $pick = $instances | Where-Object { $_.isLocal } | Select-Object -First 1
    if (-not $pick) { $pick = $instances[0] }
    Ln ''
    Ln ('  检测到已有实例在 ' + $pick.url + ' 运行,直接使用该实例,不再重复启动。')
    Ln '  如需停止服务: DeepSeek-Harness.bat --stop'
    Ln ''
    Open-WhenReady $pick.url
    Self-Clean
    exit 0
  }
}

# 端口: --port 参数 > 记忆端口 > 随机分配可用端口(10000-60000,与参考项目一致)
$port = ''
$portSource = ''
if ($flags.ContainsKey('port')) {
  $port = [string]$flags['port']
  $portSource = '参数指定'
} elseif ($cfg -and $cfg.port) {
  $port = [string]$cfg.port
  $portSource = '记忆端口'
}
$url = 'http://127.0.0.1:' + $port

if ($port -and $port -ne '0') {
  if (Test-PortBusy $port) {
    Ln ('  端口 ' + $port + ' 已被占用(' + $portSource + '),改随机分配。')
    $port = ''
  }
} else {
  $port = ''   # --port 0 = 交给随机逻辑
}
if (-not $port) {
  $port = [string](Get-RandomPort)
  $portSource = '随机分配'
  Save-Cfg @{ port = $port }
}
$url = 'http://127.0.0.1:' + $port

Ln ''
Ln '  正在启动 DeepSeek Harness 服务...'
Ln ''

# 后台启动 dsh: 独立隐藏控制台(与参考项目 detached 等价,关闭本窗口服务继续运行),
# stdout 丢弃(不再显示 "dsh web: http://..." 等), stderr 写入 dsh-error.log 便于排错
$errLog = Join-Path $Root 'dsh-error.log'
$webArgs = @('"' + $BinJs + '"', 'web', '--port', $port)
# 新版 dsh 默认自开浏览器(openBrowser 默认 true,打开的是带认证握手的 URL),
# --no-open 必须透传给 dsh,否则启动器的 --no-open 形同虚设
if ($flags.ContainsKey('no-open')) { $webArgs += '--no-open' }
try {
  $dshProc = Start-Process -FilePath $NodeExe -ArgumentList $webArgs -WorkingDirectory $Root -WindowStyle Hidden -RedirectStandardOutput 'NUL' -RedirectStandardError $errLog -PassThru
} catch {
  Ln ''
  Ln ('  启动 dsh 失败: ' + $_.Exception.Message)
  Ln ''
  if (Is-Interactive) { try { Read-Host '  按回车关闭' | Out-Null } catch { } }
  Self-Clean
  exit 4
}
# 记录 PID/端口 供 --stop 与多实例保护使用(与参考项目 PID 文件同样的思路)
try {
  $pidJson = '{"pid":' + $dshProc.Id + ',"port":"' + $port + '","url":"' + $url + '"}'
  [IO.File]::WriteAllText((Join-Path $Root '.dsh-server.pid'), $pidJson)
} catch { }

# 轮询等待服务就绪(最长 60 秒): 以 HTTP 可访问为准,端口监听只作兜底
$ready = $false
for ($i = 0; $i -lt 120; $i++) {
  if ($dshProc.HasExited) { break }
  if (Test-HttpReady $url) { $ready = $true; break }
  Start-Sleep -Milliseconds 500
}
if (-not $ready -and (Test-PortBusy $port)) { $ready = $true }

if ($ready) {
  # 服务就绪后才显示启动信息
  Ln ''
  Ln ('  DeepSeek Harness  v' + $AppVersion + '  (构建于 ' + $AppBuilt + ')')
  Ln '  --------------------------------------------------'
  Ln ('  程序目录 : ' + $AppDir)
  Ln ('  数据目录 : ' + $useHome)
  Ln ('  网页界面 : ' + $url + '  (' + $portSource + ')')
  Ln '  首次运行 : 在浏览器里完成引导配置(API Key、模型)'
  Ln '  关闭窗口或按 Ctrl+C 将最小化到系统托盘,服务继续运行。'
  Ln '  退出服务: 托盘图标右键 → "退出服务"'
  Ln ''

  # 浏览器由 dsh 就绪后自行打开(openBrowser 默认开,URL 带认证握手),
  # 启动器不再重复开页——此前"启动一次开两个页面"即启动器+dsh 各开一个。
  # HTTP 就绪轮询保留: 就绪后才打启动横幅,并保证 URL 变量对后续逻辑可用。

  # 交互模式: 启动隐藏托盘守护 B(独立控制台,与窗口解耦)。
  # 用户关闭窗口 → 启动器 A 退出 → B 检测到 A 退出 → 创建托盘,由托盘管理退出。
  if (Is-Interactive) {
    if ($flags.ContainsKey('tray-test')) {
      # 调试模式: 当前进程直接进入托盘(验证托盘本身是否可用,失败时窗口保持+错误写日志)
      Ln '  [tray-test] 直接进入托盘...'
      Ln ''
      $trayUsed = Start-Tray
      if ($trayUsed -and $script:trayQuit) {
        try { Stop-Process -Id $dshProc.Id -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item (Join-Path $Root '.dsh-server.pid') -Force -ErrorAction SilentlyContinue } catch { }
      }
    } else {
      try {
        $bScript = $script:TrayGuardTemplate
        $bScript = $bScript.Replace('__ROOT__', $Root)
        $bScript = $bScript.Replace('__DSHPID__', [string]$dshProc.Id)
        $bScript = $bScript.Replace('__APID__', [string]$PID)
        $bScript = $bScript.Replace('__ERRLOG__', $errLog)
        $bScript = $bScript.Replace('__URL__', $url)
        # __TRAYCS__ → 完整 here-string(模板避免嵌套,在此注入)
        $bScript = $bScript.Replace('__TRAYCS__', "@'`r`n" + $script:TrayCs + "`r`n'@")
        $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bScript))
        Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $b64) | Out-Null
        Ln '  已启动托盘守护:关闭本窗口或按 Ctrl+C 后,服务将转入系统托盘。'
        Ln '  退出服务: 托盘图标右键 → "退出服务"'
        Ln ''
      } catch {
        try { [IO.File]::AppendAllText($errLog, '[tray-guard] 守护进程启动失败: ' + $_.Exception.Message + "`r`n") } catch { }
        Ln '  托盘守护启动失败,服务仅后台运行。停止服务: DeepSeek-Harness.bat --stop'
        Ln ''
      }
      # 启动器 A 等待: dsh 退出则收尾(用户关窗时 A 被终止,由 B 接管)
      while ($true) {
        if ($dshProc.HasExited) { break }
        Start-Sleep -Milliseconds 500
      }
    }
  }
} else {
  Ln ''
  Ln '  等待服务就绪超时(或 dsh 已退出)。'
  if (Test-Path $errLog) {
    try {
      $errSize = (Get-Item $errLog).Length
      if ($errSize -gt 0) {
        Ln ('  dsh 错误日志(' + $errLog + '):')
        Get-Content $errLog -Tail 10 | ForEach-Object { Ln ('    ' + $_) }
      }
    } catch { }
  }
  Ln ''
}

# 服务为独立进程(关闭本窗口后继续后台运行),启动器直接收尾退出。
# 停止服务: DeepSeek-Harness.bat --stop
if (-not $ready) {
  try { Remove-Item (Join-Path $Root '.dsh-server.pid') -Force -ErrorAction SilentlyContinue } catch { }
}

Ln ''
Self-Clean
exit 0
