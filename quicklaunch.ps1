<#
.SYNOPSIS
    Tray launcher for a folder of shortcuts, with a global hotkey, live search
    filter and usage-based ranking.

.DESCRIPTION
    Puts a black square in the notification area. Left click on it - or the global
    hotkey (default Ctrl+Alt+R) - opens a search popup listing everything found in
    the configured sources (default D:\start). Subdirectories are groups; with more
    than one source the source name is shown in front of the group.

    A source is a folder plus an include filter ("*.lnk;*.exe"), an exclude filter
    ("*protect*.*") and an optional shortcut letter. Typing that letter and a space
    at the start of the query ("s ") limits the list to that source. The Start Menu
    folders are ordinary sources too - the settings window has a button that adds
    them.

    Everything is edited in the built-in settings window (tray menu "Settings", the gear
    at the bottom right of the popup, or the "Settings" entry in the list) - including
    every colour the popup uses. It opens by itself on the very first run.

    The hotkey is put together from the Ctrl/Alt/Shift/Win checkboxes and a key list, and
    the settings window says right away whether the combination is still free - Windows
    itself is asked, so a combination another program holds is spotted before saving.

    Windows keeps a few combinations for itself (Win+R, Win+S, ...) and never hands them
    to an ordinary hotkey. With "Use a keyboard hook" ticked, QuickLaunch answers those
    first with a low-level keyboard hook: the key is swallowed before Explorer sees it, so
    Win+R opens this launcher instead of the Windows Run box. The hook is only installed
    when the chosen combination cannot be registered the normal way.

    Typing filters the list, Up/Down picks an entry, Enter runs the
    selected one (the first one when nothing was moved), Escape hides the popup.
    The popup also hides itself as soon as it loses focus.

    Shift+Enter runs the selected entry WITH PARAMETERS: the search box turns into an
    argument box (pre-filled with the arguments used last time for that entry), Enter
    starts it, Escape goes back to the list.

    ALTERNATIVE NAMES live in the file name, in a trailing bracket group:
        "pwsh [powershell, ps].lnk"
    The entry is shown as "pwsh" and is also found by "powershell" or "ps".

    "run <text>" - or "!<text>" - hands the text straight to the shell, exactly like the
    Win+R box, and remembers what was run so it can be offered again.

    "dir <text>" (or "cd <text>", or "..<text>") searches folders instead of entries and
    opens the chosen one in Explorer. The folders come from the "dirs" setting, where an
    entry is either a folder or a folder with a trailing \* meaning all its subfolders:
        "dirs": ["D:\\", "D:\\workspace", "D:\\workspace\\*"]

    "web <text>" - or "//<text>" - opens the text as a URL in the default browser
    ("//google.com" goes to https://google.com) and remembers it for the next time. A
    source whose shortcut letter is "web" wins over the word, "//" always works.

    "=<expression>" turns the box into a calculator ("=(2+3)*4"). The result is shown
    while it is typed and Enter copies it to the clipboard. Understood are + - * / % ^,
    brackets, pi, e and sqrt, abs, round, floor, ceiling, truncate, sign, min, max, pow,
    log, log10, exp, sin, cos, tan.

    The script's own commands (open source folder, settings, reload, exit) sit at
    the bottom of the list and are searchable like any other entry. They are also on
    the tray icon's right-click menu.

    Every launch is recorded in the usage file: how often an entry was started AND
    which search text was typed to reach it. Both feed the ranking, so the entry you
    usually start with "cc" ends up first the next time you type "cc".

    Config  : %LOCALAPPDATA%\QuickLaunch\quicklaunch.config.json  (created on first run)
    Usage   : %LOCALAPPDATA%\QuickLaunch\quicklaunch.usage.json
    Icons   : %LOCALAPPDATA%\QuickLaunch\cache\icons
    Log     : <parent of the script folder>\logs\quicklaunch.log

.PARAMETER Install
    Register the "QuickLaunch" logon scheduled task and exit.

.PARAMETER Uninstall
    Remove the scheduled task and exit.

.PARAMETER ShowConsole
    Keep the console window visible (for debugging).
#>
[CmdletBinding()]
param(
    [switch] $Install,
    [switch] $Uninstall,
    [switch] $ShowConsole
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = $PSCommandPath
$scriptDir  = Split-Path -Parent $scriptPath
# nothing is ever written next to the script; settings, usage and the icon cache
# live in the user profile
$dataDir    = Join-Path $env:LOCALAPPDATA 'QuickLaunch'
if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
$configPath = Join-Path $dataDir 'quicklaunch.config.json'
$usagePath  = Join-Path $dataDir 'quicklaunch.usage.json'
$script:iconCacheDir   = Join-Path $dataDir 'cache\icons'
$script:folderIconFile = Join-Path $script:iconCacheDir 'folder.png'
# shared log folder one level up, next to the tool folders
$logPath    = Join-Path (Split-Path -Parent $scriptDir) 'logs\quicklaunch.log'
$taskName   = 'QuickLaunch'

function Log($m) {
    try {
        $dir = Split-Path -Parent $logPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $m" | Out-File $logPath -Append -Encoding utf8
    } catch { }
    Write-Verbose $m
}

# --- move data of an older version out of the script folder -------------------

foreach ($m in @(
    @{ Old = Join-Path $scriptDir 'quicklaunch.config.json'; New = $configPath },
    @{ Old = Join-Path $scriptDir 'quicklaunch.usage.json';  New = $usagePath })) {
    if ((Test-Path -LiteralPath $m.Old) -and -not (Test-Path -LiteralPath $m.New)) {
        try { Move-Item -LiteralPath $m.Old -Destination $m.New; Log "moved $($m.Old) to $($m.New)" }
        catch { Log "cannot move $($m.Old): $($_.Exception.Message)" }
    }
}
$oldCache = Join-Path $scriptDir 'cache'
if (Test-Path -LiteralPath $oldCache) {
    # icons are rebuilt in the new cache on the next start
    try { Remove-Item -LiteralPath $oldCache -Recurse -Force; Log "removed old icon cache $oldCache" } catch { }
}

# --- install / uninstall ------------------------------------------------------

function Test-LogonTask {
    [bool](Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue)
}

function Uninstall-LogonTask {
    if (Test-LogonTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Log "removed scheduled task '$taskName'"
        return $true
    }
    $false
}

function Install-LogonTask {
    [void](Uninstall-LogonTask)
    # wscript + the .vbs shim start it without any console window flashing up
    $vbs = Join-Path $scriptDir 'quicklaunch.vbs'
    $action  = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" `
                -Argument "`"$vbs`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trigger.Delay = 'PT15S'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
                -Description 'QuickLaunch tray launcher' | Out-Null
    Log "registered scheduled task '$taskName' (runs at logon, 15 s delay)"
}

if ($Install -or $Uninstall) {
    if (Uninstall-LogonTask) { Write-Host "removed scheduled task '$taskName'" }
    if ($Install) {
        Install-LogonTask
        Write-Host "registered scheduled task '$taskName' (runs at logon, 15 s delay)"
    }
    exit 0
}

# --- single instance ----------------------------------------------------------

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\QuickLaunchPS', [ref]$created)
if (-not $created) {
    Write-Host 'QuickLaunch is already running.'
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class QlNative : NativeWindow, IDisposable {
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public  static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);

    private const int WM_HOTKEY = 0x0312;
    private const int HOTKEY_ID = 0xB001;
    private bool registered;

    public event EventHandler Pressed;

    public QlNative() { CreateHandle(new CreateParams()); }

    public bool Register(uint mods, uint vk) {
        if (registered) { UnregisterHotKey(this.Handle, HOTKEY_ID); registered = false; }
        // 0x4000 = MOD_NOREPEAT: one event per press, not per key repeat
        registered = RegisterHotKey(this.Handle, HOTKEY_ID, mods | 0x4000, vk);
        return registered;
    }

    // --- keyboard hook -------------------------------------------------------
    // Windows keeps a few combinations for itself (Win+R, Win+S, ...): RegisterHotKey
    // refuses them, and the only way to answer them first is a low-level hook. The hook
    // callback must stay quick, so it only swallows the key and posts a message - the
    // popup is opened later, from the message loop.

    public delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    private const int WM_QLHOTKEY = 0x0402;          // WM_USER + 2
    private const int LLKHF_INJECTED = 0x10;
    private static readonly IntPtr OwnInput = (IntPtr)0x51CF;   // marks the keys we send ourselves

    private LowLevelKeyboardProc hookProc;   // held so the delegate is not collected
    private IntPtr hook = IntPtr.Zero;
    private uint hookMods, hookVk;
    private bool swallowUp;

    public bool HookActive { get { return hook != IntPtr.Zero; } }

    public bool StartHook(uint mods, uint vk) {
        StopHook();
        hookMods = mods; hookVk = vk;
        hookProc = new LowLevelKeyboardProc(HookCallback);
        hook = SetWindowsHookEx(WH_KEYBOARD_LL, hookProc, GetModuleHandle(null), 0);
        return hook != IntPtr.Zero;
    }

    public void StopHook() {
        if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
        hookProc = null;
        swallowUp = false;
    }

    // exactly the wanted modifiers, so Ctrl+Alt+Shift+R does not fire Ctrl+Alt+R
    private bool ModifiersMatch() {
        bool ctrl  = (GetAsyncKeyState(0x11) & 0x8000) != 0;
        bool alt   = (GetAsyncKeyState(0x12) & 0x8000) != 0;
        bool shift = (GetAsyncKeyState(0x10) & 0x8000) != 0;
        bool win   = ((GetAsyncKeyState(0x5B) & 0x8000) != 0) || ((GetAsyncKeyState(0x5C) & 0x8000) != 0);
        return ctrl  == ((hookMods & 0x2) != 0)
            && alt   == ((hookMods & 0x1) != 0)
            && shift == ((hookMods & 0x4) != 0)
            && win   == ((hookMods & 0x8) != 0);
    }

    private IntPtr HookCallback(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0) {
            int msg   = (int)wParam;
            int vk    = Marshal.ReadInt32(lParam, 0);
            int flags = Marshal.ReadInt32(lParam, 8);
            IntPtr extra = Marshal.ReadIntPtr(lParam, 16);
            if (vk == (int)hookVk && extra != OwnInput) {
                if ((msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) && ModifiersMatch()) {
                    // with the Win key held, swallowing the second key would leave Explorer
                    // thinking Win was pressed alone and open the Start menu on release
                    if ((hookMods & 0x8) != 0) {
                        keybd_event(0x11, 0, 0, OwnInput);
                        keybd_event(0x11, 0, 2, OwnInput);
                    }
                    swallowUp = true;
                    PostMessage(this.Handle, WM_QLHOTKEY, IntPtr.Zero, IntPtr.Zero);
                    return (IntPtr)1;
                }
                if ((msg == WM_KEYUP || msg == WM_SYSKEYUP) && swallowUp) {
                    // the key never reached the foreground window, so its release must not either
                    swallowUp = false;
                    return (IntPtr)1;
                }
            }
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }

    protected override void WndProc(ref Message m) {
        if ((m.Msg == WM_HOTKEY && (int)m.WParam == HOTKEY_ID) || m.Msg == WM_QLHOTKEY) {
            EventHandler h = Pressed;
            if (h != null) h(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }

    public void Dispose() {
        StopHook();
        if (registered) UnregisterHotKey(this.Handle, HOTKEY_ID);
        DestroyHandle();
    }

    public static void HideConsole() {
        IntPtr h = GetConsoleWindow();
        if (h != IntPtr.Zero) ShowWindow(h, 0);   // SW_HIDE
    }

    // A ListBox scrollbar is drawn by the theme, not by the control, so the only way to
    // get a dark one is to put the process into dark mode (undocumented uxtheme exports,
    // Windows 10 1809 and newer) and give the control the dark Explorer theme.
    [DllImport("uxtheme.dll", EntryPoint = "#135", SetLastError = true)]
    private static extern int SetPreferredAppMode(int mode);
    [DllImport("uxtheme.dll", EntryPoint = "#136", SetLastError = true)]
    private static extern void FlushMenuThemes();
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    private static extern int SetWindowTheme(IntPtr hWnd, string subAppName, string subIdList);

    public static void UseDarkScrollBars(IntPtr hWnd) {
        try { SetPreferredAppMode(2); FlushMenuThemes(); } catch { }   // 2 = force dark
        try { SetWindowTheme(hWnd, "DarkMode_Explorer", null); } catch { }
    }
}

// Asking Windows whether a combination is still free is the only reliable conflict check:
// it is taken as soon as RegisterHotKey fails on a window nobody else uses.
public class QlProbe : NativeWindow, IDisposable {
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int PROBE_ID = 0xB002;

    public QlProbe() { CreateHandle(new CreateParams()); }
    public void Dispose() { DestroyHandle(); }

    public static bool IsFree(uint mods, uint vk) {
        QlProbe p = new QlProbe();
        try {
            if (!RegisterHotKey(p.Handle, PROBE_ID, mods | 0x4000, vk)) return false;
            UnregisterHotKey(p.Handle, PROBE_ID);
            return true;
        } finally {
            p.Dispose();
        }
    }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Windows.Forms.Primitives, System.Drawing

if (-not $ShowConsole) { [QlNative]::HideConsole() }

# --- config -------------------------------------------------------------------

$defaultConfig = [ordered]@{
    # a source is a folder + its own include/exclude filter + a shortcut letter that
    # limits the list to this source when typed as the first word ("s <text>")
    sources      = @(
        [ordered]@{ path = 'D:\start'; include = ''; exclude = ''; shortcut = '' }
    )
    hotkey       = 'Ctrl+Alt+R'
    # answer combinations Windows keeps for itself (Win+R, ...) with a keyboard hook
    hookReserved = $false
    runAtLogon   = $false
    width        = 700
    rows         = 14
    fontSize     = 12
    showGroup    = $true
    showIcons    = $true
    # global filters, used for every source that has no filter of its own
    includeNames = '*.lnk;*.exe;*.url'
    excludeNames = 'desktop.ini;thumbs.db'
    offerDirs    = $true
    offerRun     = $true
    offerWeb     = $true
    offerCalc    = $true
    # every colour of the popup, as #RRGGBB
    colors       = [ordered]@{
        background = '#202020'
        text       = '#F0F0F0'
        dim        = '#969696'
        selection  = '#005A9E'
        selText    = '#D2E1F0'
        searchBack = '#2D2D2D'
    }
    # folders reachable with "dir <text>" / "cd <text>"; a trailing \* or /* means
    # "every immediate subfolder of this one"
    dirs         = @('D:\', 'D:\workspace', 'D:\workspace\*', 'D:\personalspace', 'D:\personalspace\*')
}

$script:colorKeys = @(
    @{ Key = 'background'; Text = 'Background' }
    @{ Key = 'text';       Text = 'Entry text' }
    @{ Key = 'dim';        Text = 'Group and hint text' }
    @{ Key = 'selection';  Text = 'Selected row' }
    @{ Key = 'selText';    Text = 'Group on selected row' }
    @{ Key = 'searchBack'; Text = 'Search box' }
)

function ConvertTo-Color([string] $text, $fallback) {
    if ($text -match '^#?[0-9A-Fa-f]{6}$') {
        try { return [Drawing.ColorTranslator]::FromHtml('#' + $text.TrimStart('#')) } catch { }
    }
    $fallback
}

function ConvertTo-ColorText($color) {
    '#{0:X2}{1:X2}{2:X2}' -f $color.R, $color.G, $color.B
}

# the colour map arrives either as the default hashtable or as a JSON object
function Get-CfgColor([string] $key) {
    $def = [string]$defaultConfig.colors[$key]
    $val = $def
    $map = $script:cfg['colors']
    if ($map) {
        if ($map -is [System.Collections.IDictionary]) {
            if ($map.Contains($key)) { $val = [string]$map[$key] }
        } elseif ($map.PSObject.Properties.Name -contains $key) {
            $val = [string]$map.$key
        }
    }
    ConvertTo-Color $val (ConvertTo-Color $def ([Drawing.Color]::Gray))
}

# "*.lnk; *.exe" -> @('*.lnk', '*.exe')
function Split-Patterns([string] $text) {
    @(($text ?? '') -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-Pattern([string] $name, [string[]] $patterns) {
    foreach ($p in $patterns) { if ($name -like $p) { return $true } }
    $false
}

# accepts plain strings (old "roots") and objects, always returns full source records
function ConvertTo-SourceList($value) {
    $out = @()
    foreach ($s in @($value)) {
        if (-not $s) { continue }
        if ($s -is [string]) {
            $out += [ordered]@{ path = $s; include = ''; exclude = ''; shortcut = '' }
            continue
        }
        $rec = [ordered]@{ path = ''; include = ''; exclude = ''; shortcut = '' }
        foreach ($k in @('path', 'include', 'exclude', 'shortcut')) {
            $v = $null
            if ($s -is [System.Collections.IDictionary]) {
                if ($s.Contains($k)) { $v = $s[$k] }
            } elseif ($s.PSObject.Properties.Name -contains $k) {
                $v = $s.$k
            }
            if ($null -ne $v) { $rec[$k] = ([string]$v).Trim() }
        }
        if ($rec['path']) { $out += $rec }
    }
    @($out)
}

function Read-Config {
    $script:configIsNew = -not (Test-Path -LiteralPath $configPath)
    $cfg = @{}
    foreach ($k in $defaultConfig.Keys) { $cfg[$k] = $defaultConfig[$k] }
    if ($script:configIsNew) {
        Save-Config $cfg
        Log "created default config $configPath"
        return $cfg
    }
    try {
        $raw = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    } catch {
        Log "config unreadable, using defaults: $($_.Exception.Message)"
    }
    # older configs kept plain folder lists in "root"/"roots" and a name array in
    # "excludeNames" - fold both into the current shape
    $old = $false
    if ($cfg.Contains('root')  -and $cfg['root'])  { $cfg['sources'] = ConvertTo-SourceList $cfg['root'];  $old = $true }
    if ($cfg.Contains('roots') -and $cfg['roots']) { $cfg['sources'] = ConvertTo-SourceList $cfg['roots']; $old = $true }
    $cfg.Remove('root'); $cfg.Remove('roots')
    $cfg['sources'] = ConvertTo-SourceList $cfg['sources']
    foreach ($k in @('includeNames', 'excludeNames')) {
        if ($cfg[$k] -isnot [string]) { $cfg[$k] = (@($cfg[$k]) -join ';'); $old = $true }
    }
    # internet shortcuts were not part of the default include filter of older versions
    $inc = [string]$cfg['includeNames']
    if ($inc.Contains('*.lnk') -and -not $inc.Contains('*.url')) {
        $cfg['includeNames'] = $inc.TrimEnd(';') + ';*.url'
        $old = $true
    }
    $cfg['dirs'] = @($cfg['dirs'] | Where-Object { $_ })
    if ($old) {
        try { Save-Config $cfg; Log 'config rewritten in the current format' } catch { }
    }
    $cfg
}

function Save-Config($cfg) {
    $out = [ordered]@{}
    foreach ($k in $defaultConfig.Keys) { $out[$k] = $cfg[$k] }
    # a returned one-element list arrives here as a scalar and would be written as an
    # object instead of an array
    $out['sources'] = @($cfg['sources'])
    $out['dirs']    = @($cfg['dirs'])
    ($out | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $configPath -Encoding utf8
}

# every source as it is actually used: absolute path, filters resolved against the
# global ones, a label for the group column and the shortcut letter
function Get-EffectiveSources {
    $globalInc = @(Split-Patterns ([string]$script:cfg.includeNames))
    $globalExc = @(Split-Patterns ([string]$script:cfg.excludeNames))
    $out = @()
    foreach ($s in @($script:cfg.sources)) {
        $p = ([string]$s.path).Trim()
        if (-not $p) { continue }
        $trim  = $p.TrimEnd('\')
        $label = if ($trim -match '^[A-Za-z]:$') { $trim } else { Split-Path -Leaf $trim }
        $inc   = @(Split-Patterns ([string]$s.include))
        $out += [pscustomobject]@{
            Path     = $trim
            Label    = $label
            Include  = if ($inc.Count) { $inc } else { $globalInc }
            Exclude  = @($globalExc + @(Split-Patterns ([string]$s.exclude)))
            Shortcut = ([string]$s.shortcut).Trim().ToLowerInvariant()
        }
    }
    @($out)
}

# Alternative names live in the file name itself, in a trailing bracket group:
#   "pwsh [powershell, ps].lnk"  ->  shown as "pwsh", also found by "powershell" or "ps"
function Split-EntryName([string] $baseName) {
    $m = [regex]::Match($baseName, '^(?<name>.*?)\s*\[(?<alias>[^\]]+)\]\s*$')
    if (-not $m.Success) { return @{ Name = $baseName; Aliases = @() } }
    $al = @($m.Groups['alias'].Value -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    @{ Name = $m.Groups['name'].Value.Trim(); Aliases = $al }
}

$script:cfg = Read-Config

# --- usage store --------------------------------------------------------------
# key = full path (or cmd:<id>), value = @{ count; last; queries = @{ text = count } }

function Read-Usage {
    $u = @{}
    if (Test-Path -LiteralPath $usagePath) {
        try {
            $raw = Get-Content -LiteralPath $usagePath -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) {
                $q = @{}
                if ($p.Value.PSObject.Properties.Name -contains 'queries' -and $p.Value.queries) {
                    foreach ($qp in $p.Value.queries.PSObject.Properties) { $q[$qp.Name] = [int]$qp.Value }
                }
                $saved = ''
                if ($p.Value.PSObject.Properties.Name -contains 'args') { $saved = [string]$p.Value.args }
                $u[$p.Name] = @{
                    count = [int]$p.Value.count; last = [string]$p.Value.last; queries = $q; args = $saved
                }
            }
        } catch { Log "usage file unreadable: $($_.Exception.Message)" }
    }
    $u
}

function Save-Usage {
    try { ($script:usage | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $usagePath -Encoding utf8 }
    catch { Log "cannot save usage: $($_.Exception.Message)" }
}

function Add-Usage($key, $query, $arguments) {
    if (-not $script:usage.ContainsKey($key)) {
        $script:usage[$key] = @{ count = 0; last = ''; queries = @{}; args = '' }
    }
    $e = $script:usage[$key]
    $e.count = [int]$e.count + 1
    $e.last  = (Get-Date).ToString('o')
    if ($null -ne $arguments) { $e.args = [string]$arguments }
    $q = ($query ?? '').Trim().ToLowerInvariant()
    if ($q) {
        if (-not $e.queries.ContainsKey($q)) { $e.queries[$q] = 0 }
        $e.queries[$q] = [int]$e.queries[$q] + 1
    }
    Save-Usage
}

$script:usage = Read-Usage

# --- items --------------------------------------------------------------------

function Remove-Diacritics([string] $s) {
    if (-not $s) { return '' }
    $sb = New-Object Text.StringBuilder
    foreach ($c in $s.Normalize([Text.NormalizationForm]::FormD).ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne 'NonSpacingMark') { [void]$sb.Append($c) }
    }
    $sb.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function New-CommandItem($id, $name, $group, $action) {
    [pscustomobject]@{
        Key      = "cmd:$id"
        Name     = $name
        Group    = $group
        Path     = ''
        IconFile = ''
        Command  = $action
        Aliases  = @()
        Search   = (Remove-Diacritics "$name $group").ToLowerInvariant()
        NameNorm = (Remove-Diacritics $name).ToLowerInvariant()
        Shortcut = ''
    }
}

function Get-IconCacheFile($file) {
    # keyed by path + mtime, so a replaced shortcut gets a fresh icon
    $key   = "$($file.FullName)|$($file.LastWriteTimeUtc.Ticks)"
    $bytes = [Text.Encoding]::UTF8.GetBytes($key)
    $hash  = [BitConverter]::ToString([Security.Cryptography.MD5]::HashData($bytes)).Replace('-', '')
    Join-Path $script:iconCacheDir "$hash.png"
}

# "run <text>" behaves like the Win+R box: the text is handed to the shell as it is
function Start-RunCommand([string] $text) {
    $cmd = [Environment]::ExpandEnvironmentVariables(([string]$text).Trim())
    if (-not $cmd) { return }
    $exe  = $cmd
    $rest = ''
    if ($cmd.StartsWith('"')) {
        $end = $cmd.IndexOf('"', 1)
        if ($end -gt 0) { $exe = $cmd.Substring(1, $end - 1); $rest = $cmd.Substring($end + 1).Trim() }
    } else {
        $sp = $cmd.IndexOf(' ')
        if ($sp -gt 0) { $exe = $cmd.Substring(0, $sp); $rest = $cmd.Substring($sp + 1).Trim() }
    }
    Log "run '$cmd'"
    try {
        if ($rest) { Start-Process -FilePath $exe -ArgumentList $rest } else { Start-Process -FilePath $exe }
    } catch {
        try {
            # the whole text can also be one path with spaces, a document or a URL
            Start-Process -FilePath $cmd
        } catch {
            Log "run failed: $($_.Exception.Message)"
            [Windows.Forms.MessageBox]::Show("Cannot run:`n$cmd`n`n$($_.Exception.Message)",
                'QuickLaunch', 'OK', 'Warning') | Out-Null
        }
    }
}

function New-RunItem([string] $cmd) {
    $c = $cmd
    [pscustomobject]@{
        Key      = "run:$c"
        Name     = $c
        Group    = 'Run'
        Path     = ''
        IconFile = ''
        Command  = { Start-RunCommand $c }.GetNewClosure()
        Aliases  = @()
        Search   = $c.ToLowerInvariant()
        NameNorm = $c.ToLowerInvariant()
        Shortcut = ''
    }
}

# "web <text>" / "//<text>" opens the text in the default browser
function Resolve-WebUrl([string] $text) {
    $t = ([string]$text).Trim()
    if (-not $t) { return '' }
    # anything without a scheme is a bare host or host/path, so https is added
    if ($t -match '^[A-Za-z][A-Za-z0-9+.\-]*:') { return $t }
    "https://$t"
}

function Start-WebUrl([string] $text) {
    $url = Resolve-WebUrl $text
    if (-not $url) { return }
    Log "open url $url"
    try { Start-Process $url } catch {
        Log "cannot open url: $($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show("Cannot open:`n$url`n`n$($_.Exception.Message)",
            'QuickLaunch', 'OK', 'Warning') | Out-Null
    }
}

function New-WebItem([string] $text) {
    $t = $text
    [pscustomobject]@{
        Key      = "web:$t"
        Name     = (Resolve-WebUrl $t)
        Group    = 'Web'
        Path     = ''
        IconFile = ''
        Command  = { Start-WebUrl $t }.GetNewClosure()
        Aliases  = @()
        Search   = $t.ToLowerInvariant()
        NameNorm = $t.ToLowerInvariant()
        Shortcut = ''
    }
}

# --- calculator ---------------------------------------------------------------
# "=<expression>" is evaluated by the parser below; the text never reaches
# Invoke-Expression, so a mistyped query can never turn into a command

function Split-CalcTokens([string] $text) {
    # a comma is the decimal separator on the numeric keypad, but it also separates the
    # arguments of min/max/pow - so it is only a decimal point without a function call
    $decimalComma = $text -notmatch '[A-Za-z]\s*\('
    $tokens = @()
    $i = 0
    while ($i -lt $text.Length) {
        $c = $text[$i]
        if ([char]::IsWhiteSpace($c)) { $i++; continue }
        if ([char]::IsDigit($c) -or $c -eq '.' -or ($c -eq ',' -and $decimalComma)) {
            $start = $i
            while ($i -lt $text.Length -and ([char]::IsDigit($text[$i]) -or $text[$i] -eq '.' -or
                   ($text[$i] -eq ',' -and $decimalComma))) { $i++ }
            $raw = $text.Substring($start, $i - $start).Replace(',', '.')
            $num = 0.0
            if (-not [double]::TryParse($raw, [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$num)) { throw "'$raw' is not a number" }
            $tokens += @{ Kind = 'num'; Text = $raw; Value = $num }
            continue
        }
        if ([char]::IsLetter($c)) {
            $start = $i
            while ($i -lt $text.Length -and [char]::IsLetterOrDigit($text[$i])) { $i++ }
            $tokens += @{ Kind = 'name'; Text = $text.Substring($start, $i - $start).ToLowerInvariant(); Value = 0.0 }
            continue
        }
        if ('+-*/%^(),'.Contains($c)) {
            $tokens += @{ Kind = [string]$c; Text = [string]$c; Value = 0.0 }
            $i++
            continue
        }
        throw "'$c' cannot be used here"
    }
    @($tokens)
}

function Get-CalcToken($st) {
    if ($st.Pos -lt $st.Tokens.Count) { return $st.Tokens[$st.Pos] }
    $null
}

function Invoke-CalcFunction([string] $name, [double[]] $a) {
    $need = switch ($name) {
        'pow'   { 2 } 'min' { 2 } 'max' { 2 }
        'round' { -1 } 'log' { -1 }                  # second argument optional
        default { 1 }
    }
    if ($need -ge 0 -and $a.Count -ne $need) { throw "$name takes $need argument(s)" }
    if ($need -lt 0 -and ($a.Count -lt 1 -or $a.Count -gt 2)) { throw "$name takes 1 or 2 arguments" }
    switch ($name) {
        'sqrt'     { return [math]::Sqrt($a[0]) }
        'abs'      { return [math]::Abs($a[0]) }
        'floor'    { return [math]::Floor($a[0]) }
        'ceiling'  { return [math]::Ceiling($a[0]) }
        'truncate' { return [math]::Truncate($a[0]) }
        'sign'     { return [math]::Sign($a[0]) }
        'exp'      { return [math]::Exp($a[0]) }
        'sin'      { return [math]::Sin($a[0]) }
        'cos'      { return [math]::Cos($a[0]) }
        'tan'      { return [math]::Tan($a[0]) }
        'log10'    { return [math]::Log10($a[0]) }
        'pow'      { return [math]::Pow($a[0], $a[1]) }
        'min'      { return [math]::Min($a[0], $a[1]) }
        'max'      { return [math]::Max($a[0], $a[1]) }
        'round'    { if ($a.Count -eq 2) { return [math]::Round($a[0], [int]$a[1]) } return [math]::Round($a[0]) }
        'log'      { if ($a.Count -eq 2) { return [math]::Log($a[0], $a[1]) } return [math]::Log($a[0]) }
    }
    throw "'$name' is not known"
}

function Read-CalcAtom($st) {
    $t = Get-CalcToken $st
    if (-not $t) { throw 'the expression ends too early' }
    if ($t.Kind -eq 'num') { $st.Pos++; return [double]$t.Value }
    if ($t.Kind -eq '(') {
        $st.Pos++
        $v = Read-CalcExpression $st
        $n = Get-CalcToken $st
        if (-not $n -or $n.Kind -ne ')') { throw 'a closing bracket is missing' }
        $st.Pos++
        return $v
    }
    if ($t.Kind -eq 'name') {
        $st.Pos++
        $next = Get-CalcToken $st
        if (-not $next -or $next.Kind -ne '(') {
            switch ($t.Text) {
                'pi' { return [math]::PI }
                'e'  { return [math]::E }
            }
            throw "'$($t.Text)' is not known"
        }
        $st.Pos++
        $argv = @()
        if ((Get-CalcToken $st) -and (Get-CalcToken $st).Kind -ne ')') {
            $argv += Read-CalcExpression $st
            while ((Get-CalcToken $st) -and (Get-CalcToken $st).Kind -eq ',') {
                $st.Pos++
                $argv += Read-CalcExpression $st
            }
        }
        $close = Get-CalcToken $st
        if (-not $close -or $close.Kind -ne ')') { throw 'a closing bracket is missing' }
        $st.Pos++
        return (Invoke-CalcFunction $t.Text ([double[]]$argv))
    }
    throw "'$($t.Text)' cannot be used here"
}

# power binds tighter than the unary minus on its left, but its own exponent may be signed
function Read-CalcPower($st) {
    $base = Read-CalcAtom $st
    $t    = Get-CalcToken $st
    if ($t -and $t.Kind -eq '^') {
        $st.Pos++
        return [math]::Pow($base, (Read-CalcUnary $st))
    }
    $base
}

function Read-CalcUnary($st) {
    $t = Get-CalcToken $st
    if ($t -and ($t.Kind -eq '-' -or $t.Kind -eq '+')) {
        $st.Pos++
        $v = Read-CalcUnary $st
        return $(if ($t.Kind -eq '-') { -$v } else { $v })
    }
    Read-CalcPower $st
}

function Read-CalcTerm($st) {
    $v = Read-CalcUnary $st
    while ($true) {
        $t = Get-CalcToken $st
        if (-not $t -or $t.Kind -notin @('*', '/', '%')) { return $v }
        $st.Pos++
        $r = Read-CalcUnary $st
        if (($t.Kind -eq '/' -or $t.Kind -eq '%') -and $r -eq 0) { throw 'division by zero' }
        $v = switch ($t.Kind) {
            '*' { $v * $r }
            '/' { $v / $r }
            '%' { $v % $r }
        }
    }
}

function Read-CalcExpression($st) {
    $v = Read-CalcTerm $st
    while ($true) {
        $t = Get-CalcToken $st
        if (-not $t -or $t.Kind -notin @('+', '-')) { return $v }
        $st.Pos++
        $r = Read-CalcTerm $st
        $v = $(if ($t.Kind -eq '+') { $v + $r } else { $v - $r })
    }
}

function Invoke-Calc([string] $expression) {
    $st = @{ Tokens = @(Split-CalcTokens $expression); Pos = 0 }
    if ($st.Tokens.Count -eq 0) { throw 'nothing to calculate' }
    $v = Read-CalcExpression $st
    if ($st.Pos -lt $st.Tokens.Count) { throw "'$($st.Tokens[$st.Pos].Text)' is unexpected" }
    if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { throw 'the result is not a number' }
    [double]$v
}

function Format-CalcValue([double] $value) {
    # binary floating point turns 0.1+0.2 into 0.30000000000000004, so the tail is cut off
    $r = [math]::Round($value, 10)
    $c = [Globalization.CultureInfo]::InvariantCulture
    if ([math]::Abs($r) -ge 1e15) { return $r.ToString('R', $c) }
    $r.ToString('0.##########', $c)
}

function Copy-CalcResult([string] $value) {
    if (-not $value) { return }
    try { [Windows.Forms.Clipboard]::SetText($value); Log "calc result '$value' copied" }
    catch { Log "cannot copy the result: $($_.Exception.Message)" }
}

function New-CalcItem([string] $expression) {
    $expr   = ([string]$expression).Trim()
    $result = ''
    $group  = 'Calculator'
    if (-not $expr) {
        $name = 'Type an expression, for example  =(2+3)*4'
    } else {
        try {
            $result = Format-CalcValue (Invoke-Calc $expr)
            $name   = "$expr = $result"
            $group  = 'Enter copies the result'
        } catch {
            $name  = $expr
            $group = $_.Exception.Message
        }
    }
    $r = $result
    [pscustomobject]@{
        Key      = "calc:$expr"
        Name     = $name
        Group    = $group
        Path     = ''
        IconFile = ''
        Command  = { Copy-CalcResult $r }.GetNewClosure()
        Aliases  = @()
        Search   = ''
        NameNorm = ''
        Shortcut = ''
    }
}

function New-DirItem([string] $path) {
    $trim = $path.TrimEnd('\')
    if ($trim -match '^[A-Za-z]:$') {        # a drive root has neither leaf nor parent
        $leaf   = "$trim\"
        $parent = ''
    } else {
        $leaf   = Split-Path -Leaf $trim
        $parent = Split-Path -Parent $trim
    }
    [pscustomobject]@{
        Key      = $path
        Name     = $leaf
        Group    = $parent
        Path     = $path
        IconFile = $script:folderIconFile
        Command  = $null
        Aliases  = @()
        Search   = (Remove-Diacritics $path).ToLowerInvariant()
        NameNorm = (Remove-Diacritics $leaf).ToLowerInvariant()
        Shortcut = ''
    }
}

function Get-DirItems {
    $paths = foreach ($spec in @($script:cfg.dirs)) {
        $s = ([string]$spec).Replace('/', '\')
        if ($s.EndsWith('\*')) {
            $parent = $s.Substring(0, $s.Length - 2)
            if (Test-Path -LiteralPath $parent) {
                (Get-ChildItem -LiteralPath $parent -Directory -EA SilentlyContinue).FullName
            }
        } else {
            $p = $s.TrimEnd('\')
            if ($p -match '^[A-Za-z]:$') { $p = "$p\" }
            if (Test-Path -LiteralPath $p) { $p }
        }
    }
    @($paths | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object { New-DirItem $_ })
}

# the folder list is only needed once a "dir" query is typed
function Get-DirPool {
    if ($null -eq $script:dirPool) {
        $script:dirPool = Get-DirItems
        Log "folder list built: $($script:dirPool.Count) folders"
    }
    $script:dirPool
}

function Get-Items {
    $sources = @(Get-EffectiveSources)
    $items   = @()
    $multi   = $sources.Count -gt 1

    foreach ($src in $sources) {
        if (-not (Test-Path -LiteralPath $src.Path)) { Log "source folder not found: $($src.Path)"; continue }
        foreach ($f in Get-ChildItem -LiteralPath $src.Path -Recurse -File -EA SilentlyContinue) {
            if (@($src.Include).Count -and -not (Test-Pattern $f.Name $src.Include)) { continue }
            if (Test-Pattern $f.Name $src.Exclude) { continue }
            if ($f.Attributes -band [IO.FileAttributes]::Hidden) { continue }
            $rel    = $f.DirectoryName.Substring($src.Path.Length).Trim('\')
            $parsed = Split-EntryName $f.BaseName
            $name   = $parsed.Name
            $alias  = @($parsed.Aliases)
            # several sources can hold the same group name, so keep the source visible
            $group = if ($multi) { (@($src.Label, $rel) | Where-Object { $_ }) -join '\' } else { $rel }
            $items += [pscustomobject]@{
                Key       = $f.FullName
                Name      = $name
                Group     = $group
                Path      = $f.FullName
                IconFile  = (Get-IconCacheFile $f)
                Command   = $null
                Aliases   = @($alias | ForEach-Object { (Remove-Diacritics $_).ToLowerInvariant() })
                Search    = (Remove-Diacritics "$name $group $($f.Extension) $($alias -join ' ')").ToLowerInvariant()
                NameNorm  = (Remove-Diacritics $name).ToLowerInvariant()
                Shortcut  = $src.Shortcut
            }
        }
    }

    foreach ($src in $sources) {
        $r = $src.Path
        $items += New-CommandItem "openroot:$r" "Open folder $r" 'QuickLaunch' { Start-Process explorer.exe $r }.GetNewClosure()
    }
    $items += New-CommandItem 'settings'  'Settings'                 'QuickLaunch' { Show-Settings }
    $items += New-CommandItem 'reload'    'Reload settings and list' 'QuickLaunch' { Reset-Config }
    $items += New-CommandItem 'exit'      'Exit QuickLaunch'         'QuickLaunch' { Stop-QuickLaunch }
    $items
}

# --- ranking ------------------------------------------------------------------

function Get-Score($item, [string] $query) {
    $u     = if ($script:usage.ContainsKey($item.Key)) { $script:usage[$item.Key] } else { $null }
    $score = 0

    if ($u) {
        $score += [math]::Min([int]$u.count, 99) * 20
        if ($query -and $u.queries.Count -gt 0) {
            if ($u.queries.ContainsKey($query)) {
                # exactly the text this entry is usually started with - strongest signal
                $score += 1000 + [math]::Min([int]$u.queries[$query], 20) * 50
            } else {
                foreach ($k in $u.queries.Keys) {
                    if ($k.StartsWith($query)) { $score += 400; break }
                }
            }
        }
    }

    if ($query) {
        if     ($item.NameNorm.StartsWith($query))  { $score += 300 }
        elseif ($item.NameNorm -like "* $query*")   { $score += 200 }   # word start
        elseif ($item.NameNorm.Contains($query))    { $score += 150 }
        foreach ($a in $item.Aliases) {
            if ($a -eq $query)            { $score += 350; break }
            if ($a.StartsWith($query))    { $score += 250; break }
        }
    }
    if ($item.Command) { $score -= 60 }   # keep own commands below real entries
    $score
}

function Test-Match($item, [string[]] $tokens) {
    if (-not $tokens -or $tokens.Count -eq 0) { return $true }
    foreach ($t in $tokens) { if (-not $item.Search.Contains($t)) { return $false } }
    $true
}

function Test-LearnedMatch($item, [string] $query) {
    if (-not $query) { return $false }
    if (-not $script:usage.ContainsKey($item.Key)) { return $false }
    foreach ($k in $script:usage[$item.Key].queries.Keys) {
        if ($k.StartsWith($query)) { return $true }
    }
    $false
}

function Test-SourceShortcut([string] $name) {
    $known = @(Get-EffectiveSources | ForEach-Object { $_.Shortcut } | Where-Object { $_ })
    $known -contains $name
}

function New-QuerySplit([string] $mode, [string] $text = '', [string] $shortcut = '', [string] $query = '') {
    @{ Mode = $mode; Text = $text; Shortcut = $shortcut; Query = $query }
}

# Modes recognised at the start of the query:
#   "=<expr>"                        calculator
#   "run <cmd>" / "!<cmd>"           shell command
#   "web <url>" / "//<url>"          browser
#   "dir <text>" / "cd <text>" / "..<text>"   folder list instead of the entries
#   "<shortcut> <text>"              only the entries of the source owning that shortcut
function Split-Query([string] $raw) {
    $text = ($raw ?? '').Trim()
    # a command keeps its capitals and its diacritics, so it is taken from the raw text
    if ($script:cfg.offerCalc) {
        $m = [regex]::Match($text, '^=\s*(?<rest>.*)$')
        if ($m.Success) { return (New-QuerySplit 'calc' $m.Groups['rest'].Value.Trim()) }
    }
    if ($script:cfg.offerRun) {
        $m = [regex]::Match($text, '^(?i)(run\b|!)\s*(?<rest>.*)$')
        if ($m.Success) { return (New-QuerySplit 'run' $m.Groups['rest'].Value.Trim()) }
    }
    if ($script:cfg.offerWeb) {
        $m = [regex]::Match($text, '^(?i)(?<kw>web\b|//)\s*(?<rest>.*)$')
        # a source shortcut named "web" wins over the word; "//" is always the browser
        if ($m.Success -and ($m.Groups['kw'].Value -eq '//' -or -not (Test-SourceShortcut 'web'))) {
            return (New-QuerySplit 'web' $m.Groups['rest'].Value.Trim())
        }
    }
    $q = (Remove-Diacritics $text).ToLowerInvariant()
    if ($script:cfg.offerDirs) {
        $m = [regex]::Match($q, '^((dir|cd)\b|\.\.)[\s\\/]*(?<rest>.*)$')
        if ($m.Success) { return (New-QuerySplit 'dirs' '' '' $m.Groups['rest'].Value.Trim()) }
    }
    # the space is what makes it a shortcut - "s" alone is still an ordinary search
    $m = [regex]::Match($q, '^(?<sc>\S+)\s+(?<rest>.*)$')
    if ($m.Success -and (Test-SourceShortcut $m.Groups['sc'].Value)) {
        return (New-QuerySplit 'items' '' $m.Groups['sc'].Value $m.Groups['rest'].Value.Trim())
    }
    New-QuerySplit 'items' '' '' $q
}

# the typed text first, then what was used before through the same mode and contains it
function Get-HistoryItems([string] $prefix, [string] $text, [scriptblock] $make) {
    $items = @()
    if ($text) { $items += & $make $text }
    $past = foreach ($k in $script:usage.Keys) {
        if (-not $k.StartsWith($prefix)) { continue }
        $cmd = $k.Substring($prefix.Length)
        if (-not $cmd -or $cmd -eq $text) { continue }
        if ($text -and -not $cmd.ToLowerInvariant().Contains($text.ToLowerInvariant())) { continue }
        [pscustomobject]@{ Cmd = $cmd; Count = [int]$script:usage[$k].count }
    }
    $items + @($past | Sort-Object -Property Count -Descending | ForEach-Object { & $make $_.Cmd })
}

function Get-Filtered([string] $rawQuery) {
    $split  = Split-Query $rawQuery
    switch ($split.Mode) {
        'run'  { return @(Get-HistoryItems 'run:' $split.Text { param($c) New-RunItem $c }) }
        'web'  { return @(Get-HistoryItems 'web:' $split.Text { param($c) New-WebItem $c }) }
        'calc' { return @(New-CalcItem $split.Text) }
    }
    $query  = $split.Query
    $pool   = if ($split.Mode -eq 'dirs') { Get-DirPool } else { $script:items }
    if ($split.Shortcut) { $pool = @($pool | Where-Object { $_.Shortcut -eq $split.Shortcut }) }
    $tokens = @($query -split '\s+' | Where-Object { $_ })
    $hits = foreach ($i in $pool) {
        if ((Test-Match $i $tokens) -or (Test-LearnedMatch $i $query)) {
            [pscustomobject]@{ Item = $i; Score = (Get-Score $i $query) }
        }
    }
    @($hits | Sort-Object -Property @{E = 'Score'; Descending = $true}, @{E = { $_.Item.Name }} |
        ForEach-Object { $_.Item })
}

# --- icons --------------------------------------------------------------------

# Extracting an icon from a .lnk pointing at a network share takes up to ~2 s, so it must
# never happen on the UI thread. Icons are produced by a background runspace into a PNG
# cache on disk; the paint handler only ever reads the cache and falls back to a marker.

$script:iconMem     = @{}      # cache file -> Image, UI thread only
$script:iconWorker  = $null
$script:iconHandle  = $null

function Get-ItemIcon($item) {
    if (-not $script:cfg.showIcons -or -not $item.IconFile) { return $null }
    if ($script:iconMem.ContainsKey($item.IconFile)) { return $script:iconMem[$item.IconFile] }
    if (-not (Test-Path -LiteralPath $item.IconFile)) { return $null }
    $img = $null
    try {
        # read through memory so the cache file stays unlocked
        $ms  = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($item.IconFile))
        $img = [Drawing.Image]::FromStream($ms)
    } catch { }
    $script:iconMem[$item.IconFile] = $img
    $img
}

function Start-IconWorker {
    if (-not $script:cfg.showIcons) { return }
    if ($script:iconHandle -and -not $script:iconHandle.IsCompleted) { return }
    if (-not (Test-Path -LiteralPath $script:iconCacheDir)) {
        New-Item -ItemType Directory -Path $script:iconCacheDir -Force | Out-Null
    }
    $jobs = @($script:items | Where-Object { $_.IconFile -and -not (Test-Path -LiteralPath $_.IconFile) } |
                ForEach-Object { @{ Path = $_.Path; File = $_.IconFile } })
    if (-not (Test-Path -LiteralPath $script:folderIconFile)) {
        # one shared icon for every folder entry of the "dir" command
        $jobs = @(@{ Path = "$env:WINDIR\explorer.exe"; File = $script:folderIconFile }) + $jobs
    }
    if ($jobs.Count -eq 0) { return }

    Complete-IconWorker
    $script:iconWorker = [powershell]::Create()
    [void]$script:iconWorker.AddScript({
        param($jobs)
        Add-Type -AssemblyName System.Drawing
        foreach ($j in $jobs) {
            try {
                $ico = [Drawing.Icon]::ExtractAssociatedIcon($j.Path)
                if ($ico) {
                    $bmp = $ico.ToBitmap()
                    $tmp = "$($j.File).tmp"
                    $bmp.Save($tmp, [Drawing.Imaging.ImageFormat]::Png)
                    $bmp.Dispose(); $ico.Dispose()
                    Move-Item -LiteralPath $tmp -Destination $j.File -Force
                }
            } catch { }
        }
    }).AddArgument($jobs)
    $script:iconHandle = $script:iconWorker.BeginInvoke()
    Log "icon worker started for $($jobs.Count) entries"
    $iconTimer.Start()
}

function Complete-IconWorker {
    if ($script:iconWorker) {
        try { if ($script:iconHandle) { [void]$script:iconWorker.EndInvoke($script:iconHandle) } } catch { }
        $script:iconWorker.Dispose()
        $script:iconWorker = $null
        $script:iconHandle = $null
    }
}

# --- launching ----------------------------------------------------------------

function Invoke-Entry($item, [string] $query, [string] $arguments) {
    Hide-Launcher
    # a calculation is never repeated, so it stays out of the usage file
    if (-not $item.Key.StartsWith('calc:')) { Add-Usage $item.Key $query $arguments }
    if ($item.Command) {
        try { & $item.Command } catch { Log "command $($item.Key) failed: $($_.Exception.Message)" }
        return
    }
    if (Test-Path -LiteralPath $item.Path -PathType Container) {
        Log "open folder $($item.Path)  (query '$query')"
        Start-Process explorer.exe "`"$($item.Path.TrimEnd('\'))`""
        return
    }
    Log "launch $($item.Path)  (query '$query', args '$arguments')"
    # ShellExecute passes arguments through to a shortcut's target as well
    $extra = @{}
    if ($arguments) { $extra['ArgumentList'] = $arguments }
    try {
        switch -Wildcard ($item.Path) {
            '*.ps1' {
                $psArgs = @('-NoProfile', '-File', $item.Path)
                if ($arguments) { $psArgs += $arguments }
                Start-Process (Get-Process -Id $PID).Path -ArgumentList $psArgs `
                    -WorkingDirectory (Split-Path -Parent $item.Path)
            }
            { $_ -like '*.lnk' -or $_ -like '*.url' } {
                # a shortcut carries its own "start in" - overriding it breaks the target app
                Start-Process -FilePath $item.Path @extra
            }
            default {
                Start-Process -FilePath $item.Path -WorkingDirectory (Split-Path -Parent $item.Path) @extra
            }
        }
    } catch {
        Log "launch failed, retrying through the shell: $($_.Exception.Message)"
        try {
            # same as double-clicking the entry in Explorer
            Start-Process explorer.exe "`"$($item.Path)`""
        } catch {
            Log "launch failed: $($_.Exception.Message)"
            [Windows.Forms.MessageBox]::Show("Cannot start:`n$($item.Path)`n`n$($_.Exception.Message)",
                'QuickLaunch', 'OK', 'Warning') | Out-Null
        }
    }
}

# --- settings window ----------------------------------------------------------

$script:settingsForm = $null

# keys offered for the hotkey: what is shown -> the [Windows.Forms.Keys] name that is saved
$script:hotkeyKeys = [ordered]@{}
foreach ($c in [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ') { $script:hotkeyKeys["$c"] = "$c" }
foreach ($d in 0..9)  { $script:hotkeyKeys["$d"]      = "D$d" }
foreach ($n in 1..12) { $script:hotkeyKeys["F$n"]     = "F$n" }
foreach ($d in 0..9)  { $script:hotkeyKeys["Num $d"]  = "NumPad$d" }
foreach ($k in @('Space', 'Insert', 'Delete', 'Home', 'End', 'PageUp', 'PageDown',
                 'Left', 'Right', 'Up', 'Down', 'Back', 'Tab', 'Enter', 'Escape')) {
    $script:hotkeyKeys[$k] = $k
}

function Get-HotKeyDisplay([string] $keyName) {
    foreach ($e in $script:hotkeyKeys.GetEnumerator()) { if ($e.Value -eq $keyName) { return $e.Key } }
    ''
}

function New-SettingsLabel([string] $text, [int] $x, [int] $y) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true
    $l.Location = New-Object Drawing.Point($x, $y)
    $l
}

function New-SettingsNumber([int] $x, [int] $y, [int] $w, [int] $min, [int] $max, $value) {
    $n = New-Object Windows.Forms.NumericUpDown
    $n.Minimum = $min; $n.Maximum = $max
    $n.Value   = [math]::Min([math]::Max([int]$value, $min), $max)
    $n.Location = New-Object Drawing.Point($x, $y)
    $n.Width = $w
    $n
}

function Add-SourceRow($grid, [string] $path) {
    if (-not $path) { return }
    foreach ($r in $grid.Rows) {
        if (([string]$r.Cells[0].Value).TrimEnd('\') -eq $path.TrimEnd('\')) { return }
    }
    [void]$grid.Rows.Add($path, '', '', '')
}

function Show-Settings {
    if ($script:settingsForm -and -not $script:settingsForm.IsDisposed) {
        $script:settingsForm.Activate()
        return
    }
    Hide-Launcher

    $f = New-Object Windows.Forms.Form
    $f.Text            = 'QuickLaunch settings'
    $f.StartPosition   = 'CenterScreen'
    $f.FormBorderStyle = 'Sizable'
    $f.MinimizeBox     = $false
    $f.ClientSize      = New-Object Drawing.Size(830, 738)
    $f.MinimumSize     = New-Object Drawing.Size(700, 668)
    $f.Font            = New-Object Drawing.Font('Segoe UI', 9)
    $script:settingsForm = $f

    $f.Controls.Add((New-SettingsLabel ('Sources - folders the entries come from ' +
        '(type the shortcut as the first word to see only entries from that source)') 12 10))

    $grid = New-Object Windows.Forms.DataGridView
    $grid.Location          = New-Object Drawing.Point(12, 30)
    $grid.Size              = New-Object Drawing.Size(806, 175)
    $grid.Anchor            = 'Top,Bottom,Left,Right'
    $grid.AllowUserToAddRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode     = 'FullRowSelect'
    $grid.AutoSizeColumnsMode = 'None'
    foreach ($c in @(
        @{ n = 'Folder';   w = 380 },
        @{ n = 'Include';  w = 150 },
        @{ n = 'Exclude';  w = 150 },
        @{ n = 'Shortcut'; w = 90  })) {
        $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $c.n
        $col.Width      = $c.w
        [void]$grid.Columns.Add($col)
    }
    foreach ($s in @($script:cfg.sources)) {
        [void]$grid.Rows.Add([string]$s.path, [string]$s.include, [string]$s.exclude, [string]$s.shortcut)
    }
    $f.Controls.Add($grid)

    $btnY = 212
    $btnAdd = New-Object Windows.Forms.Button
    $btnAdd.Text = 'Add folder...'; $btnAdd.Width = 110
    $btnAdd.Location = New-Object Drawing.Point(12, $btnY)
    $btnAdd.Add_Click({
        $d = New-Object Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq 'OK') { Add-SourceRow $grid $d.SelectedPath }
    })
    $f.Controls.Add($btnAdd)

    $btnUser = New-Object Windows.Forms.Button
    $btnUser.Text = 'Add my Start Menu'; $btnUser.Width = 140
    $btnUser.Location = New-Object Drawing.Point(128, $btnY)
    $btnUser.Add_Click({ Add-SourceRow $grid ([Environment]::GetFolderPath('Programs')) })
    $f.Controls.Add($btnUser)

    $btnAll = New-Object Windows.Forms.Button
    $btnAll.Text = 'Add common Start Menu'; $btnAll.Width = 160
    $btnAll.Location = New-Object Drawing.Point(274, $btnY)
    $btnAll.Add_Click({ Add-SourceRow $grid ([Environment]::GetFolderPath('CommonPrograms')) })
    $f.Controls.Add($btnAll)

    $btnDel = New-Object Windows.Forms.Button
    $btnDel.Text = 'Remove'; $btnDel.Width = 90
    $btnDel.Location = New-Object Drawing.Point(440, $btnY)
    $btnDel.Add_Click({
        foreach ($r in @($grid.SelectedRows)) { $grid.Rows.Remove($r) }
    })
    $f.Controls.Add($btnDel)


    # --- hotkey
    # picked from checkboxes and a list: pressing the combination here would only start
    # the launcher, and the Win key never reaches a text box at all
    $y = 252
    $f.Controls.Add((New-SettingsLabel 'Hotkey' 12 ($y + 3)))
    $parsedHot = ConvertTo-HotKey ([string]$script:cfg.hotkey)
    $curMods   = if ($parsedHot) { [int]$parsedHot.Mods } else { 0 }
    $curKey    = if ($parsedHot) { ([Windows.Forms.Keys]$parsedHot.Vk).ToString() } else { '' }

    $hotChecks = @{}
    $x = 140
    foreach ($m in @(
        @{ Name = 'Ctrl';  Bit = 0x2 },
        @{ Name = 'Alt';   Bit = 0x1 },
        @{ Name = 'Shift'; Bit = 0x4 },
        @{ Name = 'Win';   Bit = 0x8 })) {
        $chk = New-Object Windows.Forms.CheckBox
        $chk.Text     = $m.Name
        $chk.AutoSize = $true
        $chk.Location = New-Object Drawing.Point($x, ($y + 2))
        $chk.Checked  = ($curMods -band $m.Bit) -ne 0
        $f.Controls.Add($chk)
        $hotChecks[$m.Name] = $chk
        $x += 62
    }

    $cmbKey = New-Object Windows.Forms.ComboBox
    $cmbKey.DropDownStyle = 'DropDownList'
    $cmbKey.Location = New-Object Drawing.Point(($x + 10), $y)
    $cmbKey.Width    = 100
    foreach ($d in $script:hotkeyKeys.Keys) { [void]$cmbKey.Items.Add($d) }
    $shown = Get-HotKeyDisplay $curKey
    # a key the list does not offer stays selectable, so an old config is never lost
    if (-not $shown -and $curKey) {
        $script:hotkeyKeys[$curKey] = $curKey
        [void]$cmbKey.Items.Insert(0, $curKey)
        $shown = $curKey
    }
    $cmbKey.SelectedItem = if ($shown) { $shown } else { 'R' }
    $f.Controls.Add($cmbKey)

    $lblHot = New-SettingsLabel '' ($x + 122) ($y + 3)
    $f.Controls.Add($lblHot)

    $chkHook = New-Object Windows.Forms.CheckBox
    $chkHook.Text = 'Use a keyboard hook for keys Windows keeps for itself (Win+R)'
    $chkHook.AutoSize = $true
    $chkHook.Location = New-Object Drawing.Point(400, 284)
    $chkHook.Checked = [bool]$script:cfg.hookReserved
    $f.Controls.Add($chkHook)

    # what the checkboxes and the list currently say, as the saved "Ctrl+Alt+R" text
    $getHotKeyText = {
        $mods = @()
        foreach ($n in @('Ctrl', 'Alt', 'Shift', 'Win')) { if ($hotChecks[$n].Checked) { $mods += $n } }
        $key = [string]$script:hotkeyKeys[[string]$cmbKey.SelectedItem]
        if (-not $key -or $mods.Count -eq 0) { return '' }
        (($mods + $key) -join '+')
    }

    $showHotKeyState = {
        $text = & $getHotKeyText
        if (-not $text) {
            $lblHot.Text = 'pick a key and at least one of Ctrl / Alt / Shift / Win'
            $lblHot.ForeColor = [Drawing.Color]::Firebrick
            return
        }
        $p = ConvertTo-HotKey $text
        if (-not $p) {
            $lblHot.Text = "$text cannot be used"
            $lblHot.ForeColor = [Drawing.Color]::Firebrick
        } elseif ([int]$p.Mods -eq $curMods -and ([Windows.Forms.Keys]$p.Vk).ToString() -eq $curKey) {
            $lblHot.Text = "$text - the one in use now"
            $lblHot.ForeColor = [Drawing.Color]::FromArgb(0, 110, 0)
        } elseif ([QlProbe]::IsFree([uint32]$p.Mods, [uint32]$p.Vk)) {
            $lblHot.Text = "$text - free"
            $lblHot.ForeColor = [Drawing.Color]::FromArgb(0, 110, 0)
        } elseif ($chkHook.Checked) {
            $lblHot.Text = "$text - reserved, the keyboard hook takes it over"
            $lblHot.ForeColor = [Drawing.Color]::FromArgb(160, 90, 0)
        } else {
            $lblHot.Text = "$text - taken by another program"
            $lblHot.ForeColor = [Drawing.Color]::Firebrick
        }
    }

    foreach ($chk in $hotChecks.Values) { $chk.Add_CheckedChanged({ & $showHotKeyState }) }
    $cmbKey.Add_SelectedIndexChanged({ & $showHotKeyState })
    $chkHook.Add_CheckedChanged({ & $showHotKeyState })
    & $showHotKeyState

    # --- startup
    $y = 284
    $chkStart = New-Object Windows.Forms.CheckBox
    $chkStart.Text = 'Run at Windows startup'; $chkStart.AutoSize = $true
    $chkStart.Location = New-Object Drawing.Point(140, $y)
    $chkStart.Checked = (Test-LogonTask)
    $f.Controls.Add($chkStart)

    # --- sizes
    $y = 316
    $f.Controls.Add((New-SettingsLabel 'Width' 12 ($y + 3)))
    $numWidth = New-SettingsNumber 140 $y 80 200 4000 $script:cfg.width
    $f.Controls.Add($numWidth)
    $f.Controls.Add((New-SettingsLabel 'Rows' 250 ($y + 3)))
    $numRows = New-SettingsNumber 310 $y 60 1 60 $script:cfg.rows
    $f.Controls.Add($numRows)
    $f.Controls.Add((New-SettingsLabel 'Font size' 400 ($y + 3)))
    $numFont = New-SettingsNumber 470 $y 60 6 40 $script:cfg.fontSize
    $f.Controls.Add($numFont)

    # --- toggles
    $y = 350
    $chkIcons = New-Object Windows.Forms.CheckBox
    $chkIcons.Text = 'Show icons'; $chkIcons.AutoSize = $true
    $chkIcons.Location = New-Object Drawing.Point(140, $y)
    $chkIcons.Checked = [bool]$script:cfg.showIcons
    $f.Controls.Add($chkIcons)

    $chkGroup = New-Object Windows.Forms.CheckBox
    $chkGroup.Text = 'Show group behind the name'; $chkGroup.AutoSize = $true
    $chkGroup.Location = New-Object Drawing.Point(280, $y)
    $chkGroup.Checked = [bool]$script:cfg.showGroup
    $f.Controls.Add($chkGroup)

    # --- global filters
    $y = 382
    $f.Controls.Add((New-SettingsLabel 'Global include' 12 ($y + 3)))
    $txtInc = New-Object Windows.Forms.TextBox
    $txtInc.Text = [string]$script:cfg.includeNames
    $txtInc.Location = New-Object Drawing.Point(140, $y); $txtInc.Width = 320
    $f.Controls.Add($txtInc)
    $f.Controls.Add((New-SettingsLabel 'used by sources with an empty include' 470 ($y + 3)))

    $y = 412
    $f.Controls.Add((New-SettingsLabel 'Global exclude' 12 ($y + 3)))
    $txtExc = New-Object Windows.Forms.TextBox
    $txtExc.Text = [string]$script:cfg.excludeNames
    $txtExc.Location = New-Object Drawing.Point(140, $y); $txtExc.Width = 320
    $f.Controls.Add($txtExc)
    $f.Controls.Add((New-SettingsLabel 'always applied, on top of the source exclude' 470 ($y + 3)))

    # --- folders
    $y = 444
    $chkDirs = New-Object Windows.Forms.CheckBox
    $chkDirs.Text = 'Offer folders with "dir" / "cd"'; $chkDirs.AutoSize = $true
    $chkDirs.Location = New-Object Drawing.Point(140, $y)
    $chkDirs.Checked = [bool]$script:cfg.offerDirs
    $f.Controls.Add($chkDirs)

    $chkRun = New-Object Windows.Forms.CheckBox
    $chkRun.Text = 'Offer "run <command>" / "!<command>" like Win+R'; $chkRun.AutoSize = $true
    $chkRun.Location = New-Object Drawing.Point(400, $y)
    $chkRun.Checked = [bool]$script:cfg.offerRun
    $f.Controls.Add($chkRun)

    $y = 472
    $chkWeb = New-Object Windows.Forms.CheckBox
    $chkWeb.Text = 'Open URLs with "web <url>" / "//<url>"'; $chkWeb.AutoSize = $true
    $chkWeb.Location = New-Object Drawing.Point(140, $y)
    $chkWeb.Checked = [bool]$script:cfg.offerWeb
    $f.Controls.Add($chkWeb)

    $chkCalc = New-Object Windows.Forms.CheckBox
    $chkCalc.Text = 'Calculate "=<expression>", Enter copies the result'; $chkCalc.AutoSize = $true
    $chkCalc.Location = New-Object Drawing.Point(400, $y)
    $chkCalc.Checked = [bool]$script:cfg.offerCalc
    $f.Controls.Add($chkCalc)

    # --- colours
    $y = 500
    $f.Controls.Add((New-SettingsLabel 'Colours of the popup - click a box to change it' 12 ($y + 3)))
    $btnColReset = New-Object Windows.Forms.Button
    $btnColReset.Text = 'Default colours'; $btnColReset.Width = 120
    $btnColReset.Location = New-Object Drawing.Point(330, $y)
    $f.Controls.Add($btnColReset)

    $colorBoxes = @{}
    $i = 0
    foreach ($cd in $script:colorKeys) {
        $cx = 12 + ($i % 3) * 272
        $cy = 528 + [int][math]::Floor($i / 3) * 26
        $box = New-Object Windows.Forms.Panel
        $box.Size        = New-Object Drawing.Size(28, 18)
        $box.Location    = New-Object Drawing.Point($cx, $cy)
        $box.BorderStyle = 'FixedSingle'
        $box.BackColor   = Get-CfgColor $cd.Key
        $box.Cursor      = [Windows.Forms.Cursors]::Hand
        $box.Add_Click({
            param($s, $e)
            $d = New-Object Windows.Forms.ColorDialog
            $d.FullOpen = $true
            $d.Color    = $s.BackColor
            if ($d.ShowDialog() -eq 'OK') { $s.BackColor = $d.Color }
            $d.Dispose()
        })
        $f.Controls.Add($box)
        $f.Controls.Add((New-SettingsLabel $cd.Text ($cx + 36) ($cy + 2)))
        $colorBoxes[$cd.Key] = $box
        $i++
    }
    $btnColReset.Add_Click({
        foreach ($cd in $script:colorKeys) {
            $colorBoxes[$cd.Key].BackColor = ConvertTo-Color ([string]$defaultConfig.colors[$cd.Key]) ([Drawing.Color]::Gray)
        }
    })

    # --- folders
    $y = 580
    $f.Controls.Add((New-SettingsLabel 'Folders, one per line ("D:\work\*" means every subfolder)' 12 $y))
    $txtDirs = New-Object Windows.Forms.TextBox
    $txtDirs.Multiline  = $true
    $txtDirs.ScrollBars = 'Vertical'
    $txtDirs.WordWrap   = $false
    $txtDirs.Text       = (@($script:cfg.dirs) -join "`r`n")
    $txtDirs.Location   = New-Object Drawing.Point(12, ($y + 22))
    $txtDirs.Size       = New-Object Drawing.Size(806, 90)
    $f.Controls.Add($txtDirs)

    # --- ok / cancel
    $btnOk = New-Object Windows.Forms.Button
    $btnOk.Text = 'Save'; $btnOk.Width = 100
    $btnOk.Location = New-Object Drawing.Point(618, 700)
    $f.Controls.Add($btnOk)

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.Width = 100
    $btnCancel.Location = New-Object Drawing.Point(718, 700)
    $btnCancel.DialogResult = 'Cancel'
    $f.Controls.Add($btnCancel)
    $f.CancelButton = $btnCancel

    # only the source grid takes the extra height; everything under it keeps its
    # place above the bottom edge
    foreach ($c in $f.Controls) {
        if ($c -eq $grid -or $c.Top -lt $btnY) { continue }
        $c.Anchor = if ($c -eq $txtDirs)                    { 'Bottom,Left,Right' }
                    elseif ($c -eq $btnOk -or $c -eq $btnCancel) { 'Bottom,Right' }
                    else                                   { 'Bottom,Left' }
    }

    $btnOk.Add_Click({
        $hot    = & $getHotKeyText
        $parsed = if ($hot) { ConvertTo-HotKey $hot } else { $null }
        if (-not $parsed) {
            [Windows.Forms.MessageBox]::Show(
                'Pick a key for the hotkey and at least one of Ctrl / Alt / Shift / Win.',
                'QuickLaunch', 'OK', 'Warning') | Out-Null
            return
        }
        $isCurrent = ([int]$parsed.Mods -eq $curMods -and ([Windows.Forms.Keys]$parsed.Vk).ToString() -eq $curKey)
        if (-not $isCurrent -and -not $chkHook.Checked -and
            -not [QlProbe]::IsFree([uint32]$parsed.Mods, [uint32]$parsed.Vk)) {
            $answer = [Windows.Forms.MessageBox]::Show(
                "The hotkey '$hot' is taken by another program and QuickLaunch would not get it.`n`nSave anyway?",
                'QuickLaunch', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
        }
        $sources = @()
        foreach ($r in $grid.Rows) {
            $p = ([string]$r.Cells[0].Value).Trim()
            if (-not $p) { continue }
            $sources += [ordered]@{
                path     = $p
                include  = ([string]$r.Cells[1].Value).Trim()
                exclude  = ([string]$r.Cells[2].Value).Trim()
                shortcut = ([string]$r.Cells[3].Value).Trim()
            }
        }
        $new = @{}
        foreach ($k in $script:cfg.Keys) { $new[$k] = $script:cfg[$k] }
        $new['sources']      = $sources
        $new['hotkey']       = $hot
        $new['hookReserved'] = [bool]$chkHook.Checked
        $new['runAtLogon']   = [bool]$chkStart.Checked
        $new['width']        = [int]$numWidth.Value
        $new['rows']         = [int]$numRows.Value
        $new['fontSize']     = [int]$numFont.Value
        $new['showIcons']    = [bool]$chkIcons.Checked
        $new['showGroup']    = [bool]$chkGroup.Checked
        $new['includeNames'] = $txtInc.Text.Trim()
        $new['excludeNames'] = $txtExc.Text.Trim()
        $new['offerDirs']    = [bool]$chkDirs.Checked
        $new['offerRun']     = [bool]$chkRun.Checked
        $new['offerWeb']     = [bool]$chkWeb.Checked
        $new['offerCalc']    = [bool]$chkCalc.Checked
        $cols = [ordered]@{}
        foreach ($cd in $script:colorKeys) { $cols[$cd.Key] = ConvertTo-ColorText $colorBoxes[$cd.Key].BackColor }
        $new['colors']       = $cols
        $new['dirs']         = @($txtDirs.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        try { Save-Config $new }
        catch {
            [Windows.Forms.MessageBox]::Show("Settings cannot be saved:`n$($_.Exception.Message)",
                'QuickLaunch', 'OK', 'Error') | Out-Null
            return
        }

        # the logon task is state outside the config file, so only touch it on a change
        try {
            if ($chkStart.Checked -ne (Test-LogonTask)) {
                if ($chkStart.Checked) { Install-LogonTask } else { [void](Uninstall-LogonTask) }
            }
        } catch {
            [Windows.Forms.MessageBox]::Show("The startup task could not be changed:`n$($_.Exception.Message)",
                'QuickLaunch', 'OK', 'Warning') | Out-Null
        }

        $f.DialogResult = 'OK'
        $f.Close()
    })

    [void]$f.ShowDialog()
    $applied = $f.DialogResult -eq 'OK'
    $f.Dispose()
    $script:settingsForm = $null
    if ($applied) { Reset-Config }
}

# --- popup --------------------------------------------------------------------

$fontName = 'Segoe UI'

# all popup colours come from the config and are re-read whenever it is reloaded
function Update-ColorValues {
    $script:colBack   = Get-CfgColor 'background'
    $script:colFore   = Get-CfgColor 'text'
    $script:colDim    = Get-CfgColor 'dim'
    $script:colSel    = Get-CfgColor 'selection'
    $script:colSelDim = Get-CfgColor 'selText'
    $script:colSearch = Get-CfgColor 'searchBack'
}
Update-ColorValues

# everything scales with fontSize so bigger text does not clip; recomputed whenever
# the settings change, so width and font size need no restart
function Update-Metrics {
    $script:fSize   = [double]$script:cfg.fontSize
    $script:rowH    = [int][math]::Max(24, $script:fSize * 2.4)
    $script:iconTop = [int](($script:rowH - 16) / 2)
    $script:textTop = [int](($script:rowH - $script:fSize * 1.7) / 2)
    $script:searchH = [int][math]::Max(30, $script:fSize * 3)
}
Update-Metrics

$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar   = $false
$form.StartPosition   = 'Manual'
$form.BackColor       = $colBack
$form.TopMost         = $true
$script:padPx         = 7        # dark frame around the whole popup
$form.Padding         = New-Object Windows.Forms.Padding($script:padPx)
$form.Width           = [int]$script:cfg.width

$search = New-Object Windows.Forms.TextBox
$search.BorderStyle = 'None'
$search.BackColor   = $colSearch
$search.ForeColor   = $colFore
$search.Font        = New-Object Drawing.Font($fontName, ($fSize + 3))
$search.Dock        = 'Top'
$search.Multiline   = $true      # a single-line TextBox ignores Height
$search.Height      = $searchH
$form.Controls.Add($search)

$list = New-Object Windows.Forms.ListBox
$list.DrawMode      = 'OwnerDrawFixed'
$list.ItemHeight    = $rowH
$list.BorderStyle   = 'None'
$list.BackColor     = $colBack
$list.ForeColor     = $colFore
$list.Dock          = 'Fill'
$list.IntegralHeight = $false
$form.Controls.Add($list)

$hint = New-Object Windows.Forms.Label
$hint.Dock      = 'Bottom'
$hint.Height    = [int][math]::Max(18, $fSize * 1.8)
$hint.ForeColor = $colDim
$hint.Font      = New-Object Drawing.Font($fontName, ($fSize - 1.5))
$hint.TextAlign = 'MiddleLeft'
$script:hintDefault = '  Enter run   Shift+Enter parameters   ".." folders   "!" command   "//" web   "=" calc   Esc close'
$script:hintCalc    = '  Enter copies the result   + - * / % ^ ( ) pi e sqrt round min max log ...   Esc close'
$script:hintWeb     = '  Enter opens it in the browser   Esc close'
$script:dirPool  = $null
$script:darkScrollDone = $false
$script:argMode  = $false
$script:argItem  = $null
$script:argQuery = ''
$hint.Text      = $script:hintDefault
$hint.Dock      = 'Fill'

# the hint line and the gear share the bottom strip; the top padding keeps the list
# from ending right on top of it
$script:hintGapPx = 10
$hintBar = New-Object Windows.Forms.Panel
$hintBar.Dock    = 'Bottom'
$hintBar.Padding = New-Object Windows.Forms.Padding(0, $script:hintGapPx, 0, 0)
$hintBar.Height  = $hint.Height + $script:hintGapPx

# gear, drawn by hand: the popup has no icon resources and a glyph would depend on the font
$gear = New-Object Windows.Forms.Panel
$gear.Dock   = 'Right'
$gear.Width  = $hint.Height + 6
$gear.Cursor = [Windows.Forms.Cursors]::Hand
$script:gearHot = $false
$gear.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $col = if ($script:gearHot) { $colFore } else { $colDim }
    $br  = New-Object Drawing.SolidBrush $col
    $r   = [double]([math]::Min($s.Width, $s.Height) / 2 - 2)
    $st  = $e.Graphics.Save()
    $e.Graphics.TranslateTransform(($s.Width / 2), ($s.Height / 2))
    for ($i = 0; $i -lt 8; $i++) {
        $e.Graphics.FillRectangle($br, -1.4, -[single]$r, 2.8, [single]($r * 0.5))
        $e.Graphics.RotateTransform(45)
    }
    $e.Graphics.FillEllipse($br, -[single]($r * 0.62), -[single]($r * 0.62),
        [single]($r * 1.24), [single]($r * 1.24))
    $hole = [single]($r * 0.26)
    $e.Graphics.FillEllipse((New-Object Drawing.SolidBrush $colBack), -$hole, -$hole, ($hole * 2), ($hole * 2))
    $e.Graphics.Restore($st)
})
$gear.Add_MouseEnter({ $script:gearHot = $true;  $gear.Invalidate() })
$gear.Add_MouseLeave({ $script:gearHot = $false; $gear.Invalidate() })
$gear.Add_Click({ try { Show-Settings } catch { Log "settings failed: $($_.Exception.Message)" } })
$hintBar.Controls.Add($gear)
$hintBar.Controls.Add($hint)
$hint.BringToFront()
$form.Controls.Add($hintBar)
# docking is applied back-to-front, so the Fill control must be front-most
$list.BringToFront()

function Update-Layout {
    Update-Metrics
    Update-ColorValues
    $form.BackColor    = $script:colBack
    $search.BackColor  = $script:colSearch
    $search.ForeColor  = $script:colFore
    $list.BackColor    = $script:colBack
    $list.ForeColor    = $script:colFore
    $hintBar.BackColor = $script:colBack
    $gear.BackColor    = $script:colBack
    $hint.ForeColor    = $script:colDim
    $list.Invalidate()
    $form.Width     = [int]$script:cfg.width
    $search.Font    = New-Object Drawing.Font($fontName, ($script:fSize + 3))
    $search.Height  = $script:searchH
    $list.ItemHeight = $script:rowH
    $hint.Font      = New-Object Drawing.Font($fontName, ($script:fSize - 1.5))
    $hintBar.Height = [int][math]::Max(18, $script:fSize * 1.8) + $script:hintGapPx
    $gear.Width     = $hintBar.Height - $script:hintGapPx + 6
}

$list.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    try {
    $it  = $s.Items[$e.Index]
    $sel = ([int]$e.State -band [int][Windows.Forms.DrawItemState]::Selected) -ne 0
    $bg  = if ($sel) { $colSel } else { $colBack }
    $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush $bg), $e.Bounds)

    $x = $e.Bounds.Left + 6
    if ($script:cfg.showIcons) {
        $img = Get-ItemIcon $it
        if ($img) {
            $e.Graphics.DrawImage($img, $x, ($e.Bounds.Top + $iconTop), 16, 16)
        } elseif ($it.Path) {
            # icon not cached yet - the background worker fills it in
            $e.Graphics.DrawRectangle((New-Object Drawing.Pen $colDim),
                ($x + 3), ($e.Bounds.Top + $iconTop + 3), 9, 9)
        }
        $x += 24
    }

    $fName = New-Object Drawing.Font($fontName, $fSize)
    $brFore = New-Object Drawing.SolidBrush $colFore
    $ty = $e.Bounds.Top + $textTop
    $e.Graphics.DrawString($it.Name, $fName, $brFore, $x, $ty)

    if ($script:cfg.showGroup -and $it.Group) {
        $w = $e.Graphics.MeasureString($it.Name, $fName).Width
        $fDim     = New-Object Drawing.Font($fontName, ($fSize - 1))
        $dimColor = if ($sel) { $script:colSelDim } else { $colDim }
        $brDim    = New-Object Drawing.SolidBrush $dimColor
        $e.Graphics.DrawString($it.Group, $fDim, $brDim, ($x + $w + 10), ($ty + 2))
    }
    } catch {
        # a throwing handler aborts the whole paint loop and blanks the list
        Log "draw row $($e.Index) failed: $($_.Exception.Message)"
    }
})

function Update-List {
    if ($script:argMode) { return }   # the box holds arguments, not a search
    $hint.Text = switch ((Split-Query $search.Text).Mode) {
        'calc'  { $script:hintCalc }
        'web'   { $script:hintWeb }
        default { $script:hintDefault }
    }
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($i in (Get-Filtered $search.Text)) { [void]$list.Items.Add($i) }
    $list.EndUpdate()
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    $rows = [math]::Max(1, [math]::Min([int]$script:cfg.rows, $list.Items.Count))
    $form.Height = $search.Height + ($rows * $rowH) + $hintBar.Height + ($script:padPx * 2)
}

function Move-Selection([int] $delta) {
    if ($script:argMode -or $list.Items.Count -eq 0) { return }
    $i = $list.SelectedIndex + $delta
    if ($i -lt 0) { $i = $list.Items.Count - 1 }
    if ($i -ge $list.Items.Count) { $i = 0 }
    $list.SelectedIndex = $i
}

function Invoke-Selected {
    # a key arriving after the popup was hidden must not start anything
    if (-not $form.Visible) { return }
    if ($script:argMode) {
        $item    = $script:argItem
        $argText = $search.Text          # leaving arg mode restores the search text
        $query   = $script:argQuery
        Set-ArgMode $null
        Invoke-Entry $item $query $argText
        return
    }
    if ($list.Items.Count -eq 0) { return }
    $idx = [math]::Max($list.SelectedIndex, 0)
    # learn the text without the "dir"/"cd" prefix, so it matches on the next search
    Invoke-Entry $list.Items[$idx] (Split-Query $search.Text).Query ''
}

# Shift+Enter switches the search box into an argument box for the selected entry.
function Set-ArgMode($item) {
    if ($item) {
        $script:argMode  = $true
        $script:argItem  = $item
        $script:argQuery = $search.Text
        $u = if ($script:usage.ContainsKey($item.Key)) { $script:usage[$item.Key] } else { $null }
        $search.Text = if ($u) { [string]$u.args } else { '' }
        $search.SelectionStart = $search.Text.Length
        $hint.Text = "  Parameters for: $($item.Name)     Enter run   Esc back"
        # show only the entry being parameterised
        $list.BeginUpdate()
        $list.Items.Clear()
        [void]$list.Items.Add($item)
        $list.EndUpdate()
        $list.SelectedIndex = 0
        $form.Height = $searchH + $rowH + $hintBar.Height + ($script:padPx * 2)
    } else {
        $script:argMode = $false
        $script:argItem = $null
        $hint.Text = $script:hintDefault
        $search.Text = $script:argQuery
        $search.SelectionStart = $search.Text.Length
        Update-List
    }
}

$search.Add_KeyDown({
    param($s, $e)
    switch ($e.KeyCode) {
        'Down'     { Move-Selection 1;  $e.Handled = $true; $e.SuppressKeyPress = $true }
        'Up'       { Move-Selection -1; $e.Handled = $true; $e.SuppressKeyPress = $true }
        'PageDown' { Move-Selection 5;  $e.Handled = $true; $e.SuppressKeyPress = $true }
        'PageUp'   { Move-Selection -5; $e.Handled = $true; $e.SuppressKeyPress = $true }
        'Enter'    {
            $e.Handled = $true; $e.SuppressKeyPress = $true
            if ($e.Shift -and -not $script:argMode) {
                if ($list.Items.Count -gt 0) {
                    Set-ArgMode $list.Items[[math]::Max($list.SelectedIndex, 0)]
                }
            } else {
                Invoke-Selected
            }
        }
        'Escape'   {
            $e.Handled = $true; $e.SuppressKeyPress = $true
            if ($script:argMode) { Set-ArgMode $null } else { Hide-Launcher }
        }
    }
})
$search.Add_TextChanged({ Update-List })
$list.Add_MouseDoubleClick({ Invoke-Selected })
$list.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Enter')  { $e.Handled = $true; Invoke-Selected }
    if ($e.KeyCode -eq 'Escape') { $e.Handled = $true; Hide-Launcher }
})
$form.Add_Deactivate({ Hide-Launcher })

# repaints the list while the background worker fills the icon cache
$iconTimer = New-Object Windows.Forms.Timer
$iconTimer.Interval = 900
$iconTimer.Add_Tick({
    if ($form.Visible) { $list.Invalidate() }
    if (-not $script:iconHandle -or $script:iconHandle.IsCompleted) {
        $iconTimer.Stop()
        Complete-IconWorker
        Log 'icon cache filled'
    }
})

function Hide-Launcher {
    if ($form.Visible) { $form.Hide() }
}

# Directory mtimes change whenever an entry is added, removed or renamed, so this is
# enough to know when the cached item list is stale - and it costs one stat per folder.
function Get-FolderSignature {
    $parts = foreach ($root in (Get-EffectiveSources).Path) {
        if (-not (Test-Path -LiteralPath $root)) { "missing:$root"; continue }
        $dirs = @(Get-Item -LiteralPath $root) +
                @(Get-ChildItem -LiteralPath $root -Recurse -Directory -EA SilentlyContinue)
        ($dirs | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
    }
    ($parts -join '#')
}

function Update-Items([switch] $Force) {
    $sig = Get-FolderSignature
    if (-not $Force -and $sig -eq $script:itemsSig) { return }
    $script:items    = Get-Items
    $script:itemsSig = $sig
    Log "item list rebuilt: $($script:items.Count) entries"
    Start-IconWorker
}

function Show-Launcher {
    Update-Items
    $script:dirPool = $null      # folders are re-read once per popup
    $script:argMode = $false
    $script:argItem = $null
    $hint.Text      = $script:hintDefault
    $search.Text    = ''
    Update-List
    $scr = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $form.Left = $scr.Left + [int](($scr.Width  - $form.Width) / 2)
    $form.Top  = $scr.Top  + [int](($scr.Height - $form.Height) / 3)
    $form.Show()
    if (-not $script:darkScrollDone) {
        # needs a created handle, so it can only happen once the popup exists
        [QlNative]::UseDarkScrollBars($list.Handle)
        $script:darkScrollDone = $true
    }
    $form.Activate()
    [void][QlNative]::SetForegroundWindow($form.Handle)
    $search.Focus()
}

function Switch-Launcher {
    if ($form.Visible) { Hide-Launcher } else { Show-Launcher }
}

# --- hotkey -------------------------------------------------------------------

function ConvertTo-HotKey([string] $text) {
    $mods = 0
    $key  = $null
    foreach ($part in ($text -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        switch ($part.ToLowerInvariant()) {
            'ctrl'    { $mods = $mods -bor 0x2 }
            'control' { $mods = $mods -bor 0x2 }
            'alt'     { $mods = $mods -bor 0x1 }
            'shift'   { $mods = $mods -bor 0x4 }
            'win'     { $mods = $mods -bor 0x8 }
            default   { $key = $part }
        }
    }
    if (-not $key) { return $null }
    try { $vk = [int][Enum]::Parse([Windows.Forms.Keys], $key, $true) }
    catch { return $null }
    [pscustomobject]@{ Mods = [uint32]$mods; Vk = [uint32]$vk }
}

$hk = New-Object QlNative
$hk.add_Pressed({ Switch-Launcher })

function Register-QlHotKey {
    $parsed = ConvertTo-HotKey ([string]$script:cfg.hotkey)
    if (-not $parsed) {
        Log "hotkey '$($script:cfg.hotkey)' cannot be parsed"
        return $false
    }
    $hk.StopHook()
    $ok = $hk.Register($parsed.Mods, $parsed.Vk)
    if (-not $ok -and $script:cfg.hookReserved) {
        # Windows will not hand this combination over, so it is taken with the keyboard hook
        $ok = $hk.StartHook($parsed.Mods, $parsed.Vk)
        Log "hotkey $($script:cfg.hotkey) taken over with the keyboard hook: $ok"
        return $ok
    }
    Log "hotkey $($script:cfg.hotkey) registered: $ok"
    $ok
}

# --- tray ---------------------------------------------------------------------

function New-SquareIcon {
    $bmp = New-Object Drawing.Bitmap(16, 16)
    $g   = [Drawing.Graphics]::FromImage($bmp)
    $g.Clear([Drawing.Color]::Transparent)
    $g.FillRectangle([Drawing.Brushes]::Black, 1, 1, 14, 14)
    # thin gray outline keeps the black square visible on a dark taskbar
    $g.DrawRectangle((New-Object Drawing.Pen ([Drawing.Color]::FromArgb(150, 150, 150))), 1, 1, 13, 13)
    $g.Dispose()
    $hicon = $bmp.GetHicon()
    [Drawing.Icon]::FromHandle($hicon)
}

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon    = New-SquareIcon
$tray.Text    = "QuickLaunch  ($($script:cfg.hotkey))"
$tray.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Open launcher',            $null, { Show-Launcher })
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add('Open first source folder', $null, {
    $first = @(Get-EffectiveSources)[0]
    if ($first) { Start-Process explorer.exe $first.Path }
})
[void]$menu.Items.Add('Settings',                 $null, { Show-Settings })
[void]$menu.Items.Add('Reload settings and list', $null, { Reset-Config })
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add('Exit QuickLaunch',         $null, { Stop-QuickLaunch })
$tray.ContextMenuStrip = $menu

$tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Switch-Launcher }
})

function Reset-Config {
    $script:cfg = Read-Config
    $script:iconMem = @{}
    $script:dirPool = $null
    Update-Layout
    $tray.Text  = "QuickLaunch  ($($script:cfg.hotkey))"
    if (-not (Register-QlHotKey)) {
        $tray.ShowBalloonTip(4000, 'QuickLaunch', "Hotkey '$($script:cfg.hotkey)' could not be registered.", 'Warning')
    }
    Update-Items -Force
    Log 'config reloaded'
}

function Stop-QuickLaunch {
    Log 'exit'
    $iconTimer.Stop()
    Complete-IconWorker
    $tray.Visible = $false
    $tray.Dispose()
    $hk.Dispose()
    [Windows.Forms.Application]::Exit()
}

# --- run ----------------------------------------------------------------------

$script:items    = @()
$script:itemsSig = ''
Update-Items -Force      # also pre-warms the icon cache in the background

if (-not (Register-QlHotKey)) {
    $tray.ShowBalloonTip(5000, 'QuickLaunch',
        ("Hotkey '$($script:cfg.hotkey)' is taken by another program. Use the tray icon, change it in the " +
         'settings, or let the keyboard hook take it over there.'),
        'Warning')
}

Log "started, sources=$((Get-EffectiveSources).Path -join '; '), items=$($script:items.Count)"
[Windows.Forms.Application]::EnableVisualStyles()

# nothing is configured yet on the very first start, so go straight to the settings
if ($script:configIsNew) {
    $firstRun = New-Object Windows.Forms.Timer
    $firstRun.Interval = 200
    $firstRun.Add_Tick({ $firstRun.Stop(); Show-Settings })
    $firstRun.Start()
}

[Windows.Forms.Application]::Run()

$mutex.ReleaseMutex()
exit 0
