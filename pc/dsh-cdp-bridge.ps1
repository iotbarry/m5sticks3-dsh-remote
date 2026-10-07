# dsh-cdp-bridge.ps1
# ---------------------------------------------------------------------------
#  Bridges DeepSeek Harness and the M5StickC S3 USB remote.
#
#  1) approval prompts  ->  the remote shows 确认 / 拒绝
#  2) remote keys       ->  Enter confirms, Escape rejects, even though DSH's
#                           approval card gives its buttons no keyboard focus
#  3) Ctrl+Alt+R        ->  starts / stops DSH's own voice recorder, which keeps
#                           the editor state in sync (Windows dictation does not)
#
#  DSH is an Electron app whose web content is invisible to Windows UI
#  Automation, so this talks to the Chromium DevTools protocol instead.
#  Requires DSH launched with --remote-debugging-port=9222
#  (launch-dsh-a11y.cmd does that).
#
#  USAGE
#      # list the buttons the page currently exposes
#      powershell -ExecutionPolicy Bypass -File .\dsh-cdp-bridge.ps1 -Discover
#
#      # run the bridge
#      powershell -ExecutionPolicy Bypass -File .\dsh-cdp-bridge.ps1
#
#  NOTE: this file is deliberately ASCII-only. Windows PowerShell reads .ps1
#  files as ANSI unless they carry a UTF-8 BOM, which turns non-ASCII text
#  into parse errors. Chinese labels are matched with \uXXXX escapes.
# ---------------------------------------------------------------------------

param(
  [string] $Port       = "",          # "" = auto-detect the remote's COM port
  [int]    $CdpPort    = 9222,
  # \u5141\u8bb8 allow once  \u540c\u610f approve  \u6279\u51c6 approve
  # \u786e\u8ba4 confirm
  [string] $ConfirmJs  = "\u5141\u8bb8|\u540c\u610f|\u6279\u51c6|\u786e\u8ba4|allow|approve|accept|confirm|\byes\b",
  # \u62d2\u7edd deny  \u8981\u6c42\u4fee\u6539 request changes
  # \u53d6\u6d88 cancel  \u9a73\u56de reject
  [string] $RejectJs   = "\u62d2\u7edd|\u8981\u6c42\u4fee\u6539|\u53d6\u6d88|\u9a73\u56de|deny|reject|decline|cancel|\bno\b",
  # \u5f00\u59cb\u5f55\u97f3 = "start recording"
  # \u505c\u6b62\u5e76\u8bc6\u522b = "stop and transcribe"
  [string] $RecordJs   = "\u5f00\u59cb\u5f55\u97f3|\u505c\u6b62\u5e76\u8bc6\u522b",
  [int]    $PollMs     = 400,
  [switch] $Discover
)

$ErrorActionPreference = "Continue"

# Clickable things, double-quoted outside so the single quotes inside survive.
$SELECTOR = "button,[role='button'],[role='menuitem'],a"

# ------------------------------------------------------------ CDP plumbing ---
$script:ws      = $null
$script:lastErr = ""

function Get-PageTarget {
  try { $t = Invoke-RestMethod "http://127.0.0.1:$CdpPort/json" -TimeoutSec 5 }
  catch { return $null }
  return ($t | Where-Object { $_.type -eq 'page' } | Select-Object -First 1)
}

function Connect-Cdp {
  if ($script:ws -and $script:ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) { return $true }
  $page = Get-PageTarget
  if (-not $page) { $script:lastErr = "cannot reach http://127.0.0.1:$CdpPort/json"; return $false }
  try {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [System.Threading.CancellationToken]::None
    if (-not $ws.ConnectAsync([uri]$page.webSocketDebuggerUrl, $ct).Wait(6000)) { $script:lastErr = "websocket connect timeout"; return $false }
    $script:ws = $ws
    $script:lastErr = ""
    return $true
  } catch { $script:ws = $null; $script:lastErr = $_.Exception.Message; return $false }
}

function Eval-Js([string]$expr) {
  if (-not (Connect-Cdp)) { return "__ERR__" }
  $id = Get-Random -Minimum 100000 -Maximum 999999
  $payload = @{
    id     = $id
    method = "Runtime.evaluate"
    params = @{ expression = $expr; returnByValue = $true; awaitPromise = $false }
  } | ConvertTo-Json -Compress -Depth 8

  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$bytes)
    $ct = [System.Threading.CancellationToken]::None
    if (-not $script:ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(6000)) {
      $script:lastErr = "send timeout"; return "__ERR__"
    }

    $buf = New-Object byte[] 262144
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline) {
      $sb = New-Object System.Text.StringBuilder
      $end = $false
      while (-not $end) {
        $rseg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$buf)
        $task = $script:ws.ReceiveAsync($rseg, $ct)
        if (-not $task.Wait(4000)) { $script:lastErr = "receive timeout"; return "__ERR__" }
        $res = $task.Result
        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
          $script:ws = $null; $script:lastErr = "socket closed"; return "__ERR__"
        }
        [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
        $end = $res.EndOfMessage
      }
      try { $obj = $sb.ToString() | ConvertFrom-Json } catch { continue }
      if ($obj.id -eq $id) {
        if ($obj.result -and $obj.result.exceptionDetails) {
          $script:lastErr = "javascript error: " + $obj.result.exceptionDetails.text
          return "__ERR__"
        }
        if ($obj.result -and $obj.result.result) { return $obj.result.result.value }
        return $null
      }
    }
    $script:lastErr = "no response for id $id"
  } catch { $script:ws = $null; $script:lastErr = $_.Exception.Message }
  return "__ERR__"
}

# One expression does two things: it installs the keyboard bridge inside the page
# if it is missing (also re-installs itself after a page reload), and it reports
# whether an approval prompt is on screen.
$JS_DETECT = "(() => {
  if (window.__dshBridgeVer !== 12) {
    if (window.__dshBridgeFn) document.removeEventListener('keydown', window.__dshBridgeFn, true);
    window.__dshBridgeVer = 12;
    window.__dshBridgeFn = function(e){
      // The board can deliver one press as several keydown events, arriving
      // within a few milliseconds. Debounce only AFTER a branch has matched,
      // otherwise the modifier keydowns of a chord eat the real key's slot.
      const now = Date.now();
      window.__dshLastKey = window.__dshLastKey || {};
      const fresh = function(tag){
        if (now - (window.__dshLastKey[tag] || 0) < 150) return false;
        window.__dshLastKey[tag] = now;
        return true;
      };
      if (e.ctrlKey && e.altKey && (e.code === 'KeyR' || e.key === 'r' || e.key === 'R')) {
        if (!fresh('rec')) return;
        const rb = [...document.querySelectorAll('button')].find(function(b){
          const t = (b.getAttribute('aria-label')||'') + (b.getAttribute('title')||'') + (b.innerText||'');
          return /$RecordJs/.test(t);
        });
        if (rb) { rb.click(); e.preventDefault(); e.stopPropagation(); }
        return;
      }
      if (e.key !== 'Enter' && e.key !== 'Escape') return;
      if (!fresh(e.key)) return;
      const els = [...document.querySelectorAll(`"$SELECTOR`")];
      const items = els.map(function(el){ return {el:el, t:(el.innerText||el.textContent||'').trim()}; })
                       .filter(function(o){ return o.t && o.t.length<=12 && (o.el.offsetWidth||o.el.offsetHeight||o.el.getClientRects().length); });
      const ask  = items.find(function(o){ return /$ConfirmJs/i.test(o.t); });
      const deny = items.find(function(o){ return /$RejectJs/i.test(o.t); });
      if (ask && deny) {
        (e.key === 'Enter' ? ask : deny).el.click();
        e.preventDefault(); e.stopPropagation();
        return;
      }
      // No approval on screen: DSH sometimes drops focus after voice input, so
      // an Enter would land nowhere. Put the caret back and press send.
      if (e.key === 'Enter') {
        const comp = document.querySelector('.RlGAzG_input');
        if (comp && !(document.activeElement === comp || comp.contains(document.activeElement))) {
          comp.focus();
          const sb = [...document.querySelectorAll('button')].find(function(b){
            const t = (b.innerText || '').trim();
            return /\u53d1\u9001/.test(t) && !/\u505c\u6b62/.test(t) && (b.offsetWidth || b.offsetHeight);
          });
          if (sb) { sb.click(); e.preventDefault(); e.stopPropagation(); }
        }
      }
    };
    document.addEventListener('keydown', window.__dshBridgeFn, true);
  }
  const els = [...document.querySelectorAll(`"$SELECTOR`")].filter(e=>(e.offsetWidth||e.offsetHeight||e.getClientRects().length));
  const txt = els.map(e=>(e.innerText||e.textContent||'').trim()).filter(t=>t&&t.length<=12);
  const ask  = txt.some(t=>/$ConfirmJs/i.test(t));
  const deny = txt.some(t=>/$RejectJs/i.test(t));
  return (ask && deny) ? 'ASK' : 'IDLE';
})()"

$JS_LIST = "(() => { const els=[...document.querySelectorAll(`"$SELECTOR`")]; return JSON.stringify(els.map(e=>(e.innerText||e.textContent||'').trim()).filter(t=>t&&t.length<=12)); })()"

# ------------------------------------------------------------------ discovery
if ($Discover) {
  if (-not (Connect-Cdp)) {
    Write-Host "Cannot reach the DSH debug port $CdpPort - $($script:lastErr)" -ForegroundColor Red
    Write-Host "Start DSH with launch-dsh-a11y.cmd first." -ForegroundColor Yellow
    exit 1
  }
  Write-Host "Connected to the DSH page. Trigger an approval and watch this list." -ForegroundColor Cyan
  Write-Host ""
  $seen = @{}
  while ($true) {
    $json = Eval-Js $JS_LIST
    if ($json -eq "__ERR__") { Write-Host "eval error: $($script:lastErr)" -ForegroundColor Red; Start-Sleep -Seconds 2; continue }
    if ($json) {
      foreach ($n in ($json | ConvertFrom-Json)) {
        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = $true
        $tag = ""
        if ($n -match $ConfirmJs) { $tag = "   <== confirm candidate" }
        if ($n -match $RejectJs)  { $tag = "   <== reject candidate" }
        if ($n -match $RecordJs)  { $tag = "   <== record button" }
        Write-Host ("  {0}{1}" -f $n, $tag)
      }
    }
    Start-Sleep -Milliseconds 2000
  }
}

# ----------------------------------------------------------------- serial port
if (-not $Port) {
  try {
    $cands = Get-PnpDevice -PresentOnly -ErrorAction Stop |
             Where-Object { $_.InstanceId -match 'VID_303A' -and $_.FriendlyName -match '\(COM\d+\)' }
    # Running firmware exposes the CDC as interface MI_01. The ROM download
    # loader exposes MI_00 / MI_02 instead, so never pick those.
    $dev = $cands | Where-Object { $_.InstanceId -match 'MI_01' } | Select-Object -First 1
    if (-not $dev) { $dev = $cands | Where-Object { $_.InstanceId -notmatch 'MI_0[02]' } | Select-Object -First 1 }
    if ($dev -and $dev.FriendlyName -match '\((COM\d+)\)') { $Port = $Matches[1] }
  } catch {}
}
if (-not $Port) {
  $p = [System.IO.Ports.SerialPort]::GetPortNames() | Select-Object -First 1
  if ($p) { $Port = $p }
}
if (-not $Port) {
  Write-Host "No serial port for the remote. Is the device on and plugged in?" -ForegroundColor Red
  exit 1
}

Write-Host "remote serial port : $Port"   -ForegroundColor Green
Write-Host "DSH debug port     : $CdpPort" -ForegroundColor Green
Write-Host ""

$script:sp    = $null
$script:state = ""

function Send-Line([string]$s) {
  if (-not ($script:sp -and $script:sp.IsOpen)) {
    try {
      $script:sp = New-Object System.IO.Ports.SerialPort($Port, 115200, 'None', 8, 'One')
      $script:sp.Open()
      $script:sp.DtrEnable = $false      # idle control lines: no esptool reset
      $script:sp.RtsEnable = $false
    } catch { $script:sp = $null; return }
  }
  try { $script:sp.Write("$s`n") }
  catch { try { $script:sp.Close() } catch {}; $script:sp = $null }
}

while ($true) {
  $v = Eval-Js $JS_DETECT
  if ($v -eq "__ERR__") {
    Write-Host ("{0:HH:mm:ss}  eval error: {1}" -f (Get-Date), $script:lastErr) -ForegroundColor Red
    Start-Sleep -Milliseconds 1000
    continue
  }
  $want = if ($v -eq "ASK") { "ASK" } else { "IDLE" }
  if ($want -ne $script:state) {
    Send-Line $want
    $script:state = $want
    $color = if ($want -eq "ASK") { "Yellow" } else { "DarkGray" }
    Write-Host ("{0:HH:mm:ss}  -> {1}" -f (Get-Date), $want) -ForegroundColor $color
  }
  Start-Sleep -Milliseconds $PollMs
}
