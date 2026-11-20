# Integration tests for listener.ps1: runs the real listener against a throwaway
# profile folder and drives it through the clipboard.
#
# The clipboard gets overwritten, so run this where that is harmless. An SSH session
# is ideal: it has its own clipboard, separate from the desktop's.
#
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\listener.tests.ps1
#
# Exits 1 if any test fails. Keep this file ASCII: Windows PowerShell 5 reads
# BOM-less scripts in the ANSI code page.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$Listener   = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\listener.ps1'
$ProfileDir = Join-Path ([IO.Path]::GetTempPath()) ('clipbridge-test-' + [guid]::NewGuid().ToString('N'))
$Root       = Join-Path $ProfileDir 'clipbridge'
$Inbox      = Join-Path $Root 'inbox'
$LogFile    = Join-Path $Root 'listener.log'
$Scratch    = Join-Path $ProfileDir 'scratch'
$WaitMs     = 8000   # how long an expected export may take
$QuietMs    = 2000   # how long to watch for an export that must not happen
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
$script:failed = @()

function Get-LogLines {
    if (Test-Path -LiteralPath $LogFile) { return @(Get-Content -LiteralPath $LogFile -Encoding UTF8) }
    return @()
}

# Every clip the listener hands to the Mac is logged as "win -> mac: <kind> (<id>)".
function Get-ExportCount { @(Get-LogLines | Where-Object { $_ -like '*win -> mac:*' }).Count }

function Wait-Until([scriptblock]$condition, [int]$timeoutMs = $WaitMs) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return [bool](& $condition)
}

function Set-ClipData([Windows.Forms.DataObject]$data) {
    [Windows.Forms.Clipboard]::SetDataObject($data, $true, 20, 100)
}

function Set-ClipFiles([string[]]$paths) {
    $list = New-Object System.Collections.Specialized.StringCollection
    foreach ($p in $paths) { [void]$list.Add($p) }
    $data = New-Object Windows.Forms.DataObject
    $data.SetFileDropList($list)
    Set-ClipData $data
}

function Set-ClipText([string]$text) {
    $data = New-Object Windows.Forms.DataObject
    $data.SetText($text)
    Set-ClipData $data
}

function Set-ClipImage([Drawing.Color]$color) {
    $bmp = New-Object Drawing.Bitmap 8, 8
    try {
        $g = [Drawing.Graphics]::FromImage($bmp)
        try { $g.Clear($color) } finally { $g.Dispose() }
        $data = New-Object Windows.Forms.DataObject
        $data.SetImage($bmp)
        Set-ClipData $data
    } finally { $bmp.Dispose() }
}

# Deliver a clip the way the Mac does: a folder in the inbox, then ready.txt naming it.
function Send-MacClip([string]$id, [string]$kind, [scriptblock]$fill) {
    $dir = Join-Path $Inbox $id
    New-Item -ItemType Directory -Path $dir | Out-Null
    & $fill $dir
    [IO.File]::WriteAllText((Join-Path $dir 'kind.txt'), $kind, $Utf8NoBom)
    $ready = Join-Path $Inbox 'ready.txt'
    [IO.File]::WriteAllText($ready + '.tmp', $id, $Utf8NoBom)
    Move-Item -LiteralPath ($ready + '.tmp') -Destination $ready -Force
    $marker = "*mac -> win: $kind ($id)*"
    if (-not (Wait-Until { @(Get-LogLines | Where-Object { $_ -like $marker }).Count -gt 0 })) {
        throw "listener never put Mac clip $id on the clipboard"
    }
}

# Run $action and require that it makes the listener export exactly one new clip.
function Assert-Exports([scriptblock]$action) {
    $before = Get-ExportCount
    & $action
    [void](Wait-Until { (Get-ExportCount) -gt $before })
    Start-Sleep -Milliseconds 500   # catch a second, unwanted export
    $new = (Get-ExportCount) - $before
    if ($new -ne 1) { throw "expected 1 new export, got $new" }
}

# Run $action and require that the listener exports nothing.
function Assert-NoExport([scriptblock]$action) {
    $before = Get-ExportCount
    & $action
    Start-Sleep -Milliseconds $QuietMs
    $new = (Get-ExportCount) - $before
    if ($new -ne 0) { throw "expected no export, got $new" }
}

function Test-Case([string]$name, [scriptblock]$body) {
    try {
        & $body
        Write-Host "PASS  $name"
    } catch {
        $script:failed += $name
        Write-Host "FAIL  $name"
        Write-Host "      $($_.Exception.Message)"
    }
}

New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
$savedProfile = $env:USERPROFILE
$proc = $null
try {
    $env:USERPROFILE = $ProfileDir   # the listener keeps everything under %USERPROFILE%\clipbridge
    $proc = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow -ArgumentList @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$Listener`"")
    $env:USERPROFILE = $savedProfile
    if (-not (Wait-Until { @(Get-LogLines | Where-Object { $_ -like '*listener started*' }).Count -gt 0 } 20000)) {
        throw 'listener did not start (is another one already running in this session?)'
    }
    Start-Sleep -Milliseconds 800   # let it finish its startup bookkeeping

    $fileA = Join-Path $Scratch 'a.bin'
    [IO.File]::WriteAllBytes($fileA, (New-Object byte[] 1024))

    Test-Case 'a newly copied file is exported' {
        Assert-Exports { Set-ClipFiles $fileA }
    }
    Test-Case 'putting the same file on the clipboard again is not exported again' {
        Assert-NoExport { Set-ClipFiles $fileA }
    }
    Test-Case 'copying the same path after the file changed is exported' {
        [IO.File]::WriteAllBytes($fileA, (New-Object byte[] 2048))
        Assert-Exports { Set-ClipFiles $fileA }
    }
    Test-Case 'newly copied text is exported' {
        Assert-Exports { Set-ClipText 'first text' }
    }
    Test-Case 'putting the same text on the clipboard again is not exported again' {
        Assert-NoExport { Set-ClipText 'first text' }
    }
    Test-Case 'text from the Mac is not sent back when it is put on the clipboard again' {
        Assert-NoExport {
            Send-MacClip 'm1' 'text' { param($dir) [IO.File]::WriteAllText((Join-Path $dir 'text.txt'), 'from the mac', $Utf8NoBom) }
        }
        Assert-NoExport { Set-ClipText 'from the mac' }
    }
    Test-Case 'copying earlier content again after something else is exported (last copy wins)' {
        Assert-Exports { Set-ClipText 'first text' }
    }
    Test-Case 'files from the Mac are not sent back when they are put on the clipboard again' {
        Assert-NoExport {
            Send-MacClip 'm2' 'files' {
                param($dir)
                New-Item -ItemType Directory -Path (Join-Path $dir 'files') | Out-Null
                [IO.File]::WriteAllBytes((Join-Path $dir 'files\from-mac.bin'), (New-Object byte[] 4096))
            }
        }
        Assert-NoExport { Set-ClipFiles (Join-Path $Inbox 'm2\files\from-mac.bin') }
    }
    Test-Case 'a newly copied image is exported' {
        Assert-Exports { Set-ClipImage ([Drawing.Color]::Red) }
    }
    Test-Case 'putting the same image on the clipboard again is not exported again' {
        Assert-NoExport { Set-ClipImage ([Drawing.Color]::Red) }
    }
    Test-Case 'a different image is exported' {
        Assert-Exports { Set-ClipImage ([Drawing.Color]::Blue) }
    }
} finally {
    $env:USERPROFILE = $savedProfile
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    if ($script:failed.Count -gt 0 -and (Test-Path -LiteralPath $LogFile)) {
        Write-Host '--- listener.log ---'
        Get-LogLines | ForEach-Object { Write-Host $_ }
    }
    Remove-Item -LiteralPath $ProfileDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed.Count -gt 0) {
    Write-Host "$($script:failed.Count) test(s) failed"
    exit 1
}
Write-Host 'all tests passed'
