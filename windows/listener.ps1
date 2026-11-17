# ClipBridge desktop listener (runs in the interactive session via scheduled task).
#   inbox\ready.txt  <- Mac writes a clip id; we put inbox\<id> on the Windows clipboard.
#   outbox\<id>      -> when the Windows clipboard changes we export it here and
#                       update outbox\latest.txt; the Mac fetches it over SSH.
#   outbox\notice.txt -> "<stamp> TOOLARGE <bytes>" when a copy is over the limit, or
#                       "<stamp> SENDING <count> <bytes>" before exporting a large one;
#                       watch.ps1 forwards it so the Mac can show a notification.
# Clip folder layout: kind.txt (text|image|files) + text.txt | image.png | files\*
$ErrorActionPreference = 'Stop'
$Root         = Join-Path $env:USERPROFILE 'clipbridge'
$Inbox        = Join-Path $Root 'inbox'
$Outbox       = Join-Path $Root 'outbox'
$ReadyFile    = Join-Path $Inbox 'ready.txt'
$LatestFile   = Join-Path $Outbox 'latest.txt'
$NoticeFile   = Join-Path $Outbox 'notice.txt'
$LogFile      = Join-Path $Root 'listener.log'
$PollMs       = 300
$SettleMs     = 150
# Largest clip we sync; also caps how much older clips may keep on disk. Override with
# a CLIPBRIDGE_MAX_MB user environment variable (setx), then run restart.ps1.
$MaxMB = 0
if (-not [int]::TryParse("$env:CLIPBRIDGE_MAX_MB", [ref]$MaxMB) -or $MaxMB -le 0) { $MaxMB = 2048 }
$MaxFileBytes = [int64]$MaxMB * 1MB
$KeepClips    = 5
$NotifyBytes  = 20MB   # tell the Mac when a file copy this big starts, so it can say so
$MaxLogBytes  = 5MB
$Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Get-ClipSeq { [ClipBridge.Native]::GetClipboardSequenceNumber() }

function Get-DirSize([string]$dir) {
    $sum = (Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($sum) { return [int64]$sum } else { return [int64]0 }
}

# Keep the newest clip (the clipboard may still point at its files), plus older ones
# while there are at most $KeepClips and they total no more than $MaxFileBytes.
function Remove-OldClips([string]$dir) {
    $total = [int64]0
    $index = 0
    foreach ($clip in (Get-ChildItem -LiteralPath $dir -Directory | Where-Object { $_.Name -notlike '*.part' } | Sort-Object LastWriteTime -Descending)) {
        $total += Get-DirSize $clip.FullName
        if ($index -gt 0 -and ($index -ge $KeepClips -or $total -gt $MaxFileBytes)) {
            Remove-Item -LiteralPath $clip.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        $index++
    }
}

function Write-Notice([string]$text) {
    $tmp = $NoticeFile + '.tmp'
    [IO.File]::WriteAllText($tmp, ('{0:yyyyMMddHHmmssfff} {1}' -f (Get-Date), $text), $Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $NoticeFile -Force
}

function Import-RemoteClip([string]$id) {
    if ($id -notmatch '^m\d+$') { throw "rejected clip id '$id'" }
    $clipDir = Join-Path $Inbox $id
    $kind = ([IO.File]::ReadAllText((Join-Path $clipDir 'kind.txt'))).Trim()
    switch ($kind) {
        'text' {
            $text = [IO.File]::ReadAllText((Join-Path $clipDir 'text.txt'), $Utf8NoBom)
            [Windows.Forms.Clipboard]::SetText($text)
        }
        'image' {
            $img = [Drawing.Image]::FromFile((Join-Path $clipDir 'image.png'))
            try { [Windows.Forms.Clipboard]::SetImage($img) } finally { $img.Dispose() }
        }
        'files' {
            $list = New-Object System.Collections.Specialized.StringCollection
            Get-ChildItem -LiteralPath (Join-Path $clipDir 'files') | ForEach-Object { [void]$list.Add($_.FullName) }
            if ($list.Count -eq 0) { throw 'files clip is empty' }
            [Windows.Forms.Clipboard]::SetFileDropList($list)
        }
        default { throw "unknown kind '$kind'" }
    }
    Write-Log "mac -> win: $kind ($id)"
}

function Get-PathsSize([string[]]$paths) {
    $total = 0
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            $total += (Get-ChildItem -LiteralPath $p -Recurse -File | Measure-Object Length -Sum).Sum
        } else {
            $total += (Get-Item -LiteralPath $p).Length
        }
    }
    return $total
}

# Returns the clip kind written into $tmp, or $null when nothing exportable.
function Save-ClipboardTo([string]$tmp) {
    if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $paths = @([Windows.Forms.Clipboard]::GetFileDropList())
        $size = Get-PathsSize $paths
        if ($size -gt $MaxFileBytes) {
            Write-Log "skip: files total $size bytes > limit $MaxFileBytes"
            Write-Notice "TOOLARGE $size"
            return $null
        }
        if ($size -ge $NotifyBytes) { Write-Notice "SENDING $($paths.Count) $size" }
        $filesDir = Join-Path $tmp 'files'
        New-Item -ItemType Directory -Path $filesDir | Out-Null
        foreach ($p in $paths) { Copy-Item -LiteralPath $p -Destination $filesDir -Recurse -Force }
        return 'files'
    }
    if ([Windows.Forms.Clipboard]::ContainsText()) {
        [IO.File]::WriteAllText((Join-Path $tmp 'text.txt'), [Windows.Forms.Clipboard]::GetText(), $Utf8NoBom)
        return 'text'
    }
    if ([Windows.Forms.Clipboard]::ContainsImage()) {
        $img = [Windows.Forms.Clipboard]::GetImage()
        try { $img.Save((Join-Path $tmp 'image.png'), [Drawing.Imaging.ImageFormat]::Png) } finally { $img.Dispose() }
        return 'image'
    }
    # e.g. files copied out of a zip, a phone, or an app attachment (virtual files, no paths)
    $data = [Windows.Forms.Clipboard]::GetDataObject()
    $formats = if ($data) { ($data.GetFormats() | Select-Object -First 12) -join ', ' } else { 'none' }
    Write-Log "skip: no text, image or file paths on clipboard (formats: $formats)"
    return $null
}

function Export-WinClip {
    $id  = 'w' + (Get-Date -Format 'yyyyMMddHHmmssfff')
    $tmp = Join-Path $Outbox ($id + '.part')
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $kind = Save-ClipboardTo $tmp
        if (-not $kind) { Remove-Item -LiteralPath $tmp -Recurse -Force; return }
        [IO.File]::WriteAllText((Join-Path $tmp 'kind.txt'), $kind, $Utf8NoBom)
        Rename-Item -LiteralPath $tmp -NewName $id
        $latestTmp = $LatestFile + '.tmp'
        [IO.File]::WriteAllText($latestTmp, $id, $Utf8NoBom)
        Move-Item -LiteralPath $latestTmp -Destination $LatestFile -Force
        Write-Log "win -> mac: $kind ($id)"
    } catch {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

# --- startup ---
foreach ($d in $Inbox, $Outbox) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClipBridgeListener', [ref]$created)
if (-not $created) { exit 0 }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace ClipBridge -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();'
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $MaxLogBytes) {
    Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.old') -Force
}
Write-Log "listener started (limit $MaxMB MB)"
$lastSeq = Get-ClipSeq

while ($true) {
    try {
        if (Test-Path -LiteralPath $ReadyFile) {
            $id = ([IO.File]::ReadAllText($ReadyFile)).Trim()
            Remove-Item -LiteralPath $ReadyFile -Force
            Import-RemoteClip $id
            $lastSeq = Get-ClipSeq          # our own change: don't echo back to the Mac
            Remove-OldClips $Inbox
        }
        if ((Get-ClipSeq) -ne $lastSeq) {
            Start-Sleep -Milliseconds $SettleMs   # let the source app finish writing all formats
            $lastSeq = Get-ClipSeq
            Export-WinClip
            Remove-OldClips $Outbox
        }
    } catch {
        Write-Log ('error: ' + $_.Exception.Message)
    }
    Start-Sleep -Milliseconds $PollMs
}
