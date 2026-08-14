<#
.SYNOPSIS
    Edition guard: starts quicklaunch.ps1 under PowerShell 7 (pwsh).

.DESCRIPTION
    quicklaunch.ps1 needs PowerShell 7 (it uses "??", MD5::HashData and Core-only
    assemblies), but Explorer's "Run with PowerShell" always uses Windows PowerShell
    5.1, which cannot even parse the file - the window just blinks and nothing starts.

    This launcher is written so 5.1 can parse it. It locates pwsh and restarts the
    real script there, hidden.

    For a completely flash-free start use quicklaunch.vbs instead; it runs this file
    with no console window at all.

    Any parameters are passed on to quicklaunch.ps1. With parameters (-Install,
    -Uninstall) the console stays visible so their output can be read.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Forward
)

$ErrorActionPreference = 'Stop'

$target = Join-Path (Split-Path -Parent $PSCommandPath) 'quicklaunch.ps1'
$quiet  = (-not $Forward) -or ($Forward.Count -eq 0)

function Show-Problem([string] $text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($text, 'QuickLaunch', 'OK', 'Error') | Out-Null
    } catch {
        Write-Host $text -ForegroundColor Red
    }
}

if (-not (Test-Path -LiteralPath $target)) {
    Show-Problem "quicklaunch.ps1 not found next to this launcher:`n$target"
    exit 1
}

# already on 7 and nothing to hide - run it in place
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $quiet) {
    & $target @Forward
    exit $LASTEXITCODE
}

$pwsh = $null
$found = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
if ($found) { $pwsh = $found.Source }
if (-not $pwsh) {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { $pwsh = $c; break }
    }
}
if (-not $pwsh) {
    Show-Problem "PowerShell 7 (pwsh.exe) was not found.`n`nInstall it with:`n  winget install Microsoft.PowerShell"
    exit 1
}

$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target)
if ($Forward) { $argList += $Forward }

if ($quiet) {
    # hide this console too, so "Run with PowerShell" blinks as little as possible
    try {
        Add-Type -Namespace QlRun -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
'@
        $h = [QlRun.Win]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) { [void][QlRun.Win]::ShowWindow($h, 0) }
    } catch { }
    Start-Process -FilePath $pwsh -ArgumentList $argList -WindowStyle Hidden
    exit 0
}

& $pwsh @argList
exit $LASTEXITCODE
