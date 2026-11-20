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
$MaxClipAge   = [TimeSpan]::FromHours(24)   # clips older than this go, the newest included
$ExpiryTicks  = 12000                       # check for expired clips about once an hour
$RetryTicks   = 10                          # retry a pending Mac clip about every 3 s
$CopyChunk    = 4MB
$Superseded   = 'clipboard changed during export'
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
# Anything older than $MaxClipAge goes, the newest and abandoned partial folders included.
# Only called between exports, so no .part folder here is still being written.
function Remove-OldClips([string]$dir) {
    $total = [int64]0
    $index = 0
    $cutoff = (Get-Date) - $MaxClipAge
    foreach ($part in (Get-ChildItem -LiteralPath $dir -Directory | Where-Object { $_.Name -like '*.part' -and $_.LastWriteTime -lt $cutoff })) {
        Remove-Item -LiteralPath $part.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($clip in (Get-ChildItem -LiteralPath $dir -Directory | Where-Object { $_.Name -notlike '*.part' } | Sort-Object LastWriteTime -Descending)) {
        $total += Get-DirSize $clip.FullName
        $expired = $clip.LastWriteTime -lt $cutoff
        if ($expired -or ($index -gt 0 -and ($index -ge $KeepClips -or $total -gt $MaxFileBytes))) {
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

# Retries for about 2 s; while the screen is locked the clipboard can't be written
# at all, so the main loop keeps the clip pending and tries again later.
function Set-ClipboardData([Windows.Forms.DataObject]$data) {
    [Windows.Forms.Clipboard]::SetDataObject($data, $true, 20, 100)
}

function Import-RemoteClip([string]$id) {
    if ($id -notmatch '^m\d+$') { throw "rejected clip id '$id'" }
    $clipDir = Join-Path $Inbox $id
    $kind = ([IO.File]::ReadAllText((Join-Path $clipDir 'kind.txt'))).Trim()
    $data = New-Object Windows.Forms.DataObject
    switch ($kind) {
        'text' {
            $data.SetText([IO.File]::ReadAllText((Join-Path $clipDir 'text.txt'), $Utf8NoBom))
            Set-ClipboardData $data
        }
        'image' {
            $img = [Drawing.Image]::FromFile((Join-Path $clipDir 'image.png'))
            try { $data.SetImage($img); Set-ClipboardData $data } finally { $img.Dispose() }
        }
        'files' {
            $list = New-Object System.Collections.Specialized.StringCollection
            Get-ChildItem -LiteralPath (Join-Path $clipDir 'files') | ForEach-Object { [void]$list.Add($_.FullName) }
            if ($list.Count -eq 0) { throw 'files clip is empty' }
            $data.SetFileDropList($list)
            Set-ClipboardData $data
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

# Copy one file in chunks, giving up as soon as the clipboard changes again: a newer
# copy makes this one pointless, and large files take a while.
function Copy-FileChecked([string]$src, [string]$dst) {
    $in = [IO.File]::OpenRead($src)
    try {
        $out = [IO.File]::Create($dst)
        try {
            $buf = New-Object byte[] $CopyChunk
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                if ((Get-ClipSeq) -ne $script:lastSeq) { throw $Superseded }
                $out.Write($buf, 0, $n)
            }
        } finally { $out.Dispose() }
    } finally { $in.Dispose() }
    [IO.File]::SetLastWriteTimeUtc($dst, [IO.File]::GetLastWriteTimeUtc($src))
}

# Copy a file or a whole folder (keeping its name) into $destDir.
function Copy-ClipPath([string]$path, [string]$destDir) {
    $name = Split-Path -Leaf $path
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Copy-FileChecked $path (Join-Path $destDir $name)
        return
    }
    $root = Join-Path $destDir $name
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    # .NET returns entries with exactly the prefix we pass in (Get-ChildItem may expand
    # 8.3 short names, which would throw off the relative paths).
    $base = $path.TrimEnd('\')
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($base, '*', [IO.SearchOption]::AllDirectories)) {
        $target = Join-Path $root $entry.Substring($base.Length + 1)
        if ([IO.Directory]::Exists($entry)) {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-FileChecked $entry $target
        }
    }
}

function Get-Sha256([byte[]]$bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
}

# One file-drop entry as "path|size|newest write time"; folders are summed over their files.
function Get-PathFingerprint([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        $item = Get-Item -LiteralPath $path -Force
        return "$path|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
    }
    $count = 0; $size = [int64]0; $newest = [int64]0
    foreach ($file in (Get-ChildItem -LiteralPath $path -Recurse -File -Force)) {
        $count++
        $size += $file.Length
        if ($file.LastWriteTimeUtc.Ticks -gt $newest) { $newest = $file.LastWriteTimeUtc.Ticks }
    }
    return "$path|dir|$count|$size|$newest"
}

# The clipboard content reduced to a short string: equal strings mean equal content.
# Picks the kind in the same order as Save-ClipboardTo. $null when there is nothing we
# could export, or when the clipboard can't be read right now.
function Get-ClipboardSignature {
    try {
        if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
            $parts = foreach ($p in @([Windows.Forms.Clipboard]::GetFileDropList())) { Get-PathFingerprint $p }
            return 'files:' + ($parts -join "`n")
        }
        if ([Windows.Forms.Clipboard]::ContainsText()) {
            return 'text:' + (Get-Sha256 $Utf8NoBom.GetBytes([Windows.Forms.Clipboard]::GetText()))
        }
        if ([Windows.Forms.Clipboard]::ContainsImage()) {
            $img = [Windows.Forms.Clipboard]::GetImage()
            $png = New-Object IO.MemoryStream
            try {
                $img.Save($png, [Drawing.Imaging.ImageFormat]::Png)
                return 'image:' + (Get-Sha256 $png.ToArray())
            } finally { $png.Dispose(); $img.Dispose() }
        }
    } catch {
        Write-Log "could not fingerprint clipboard: $($_.Exception.Message)"
    }
    return $null
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
        foreach ($p in $paths) { Copy-ClipPath $p $filesDir }
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
        if ($_.Exception.Message -eq $Superseded) {
            Write-Log "cancel: $Superseded ($id)"   # the main loop exports the new one next
            return
        }
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
# Signature of the content both machines already agree on: the last clip we exported,
# imported, or deliberately skipped. Some apps rewrite the clipboard without changing
# it (e.g. select-to-translate tools that back it up and restore it); that bumps the
# sequence number, and without this check we would send the same clip all over again.
$lastSig = Get-ClipboardSignature
$ticks = 0
$pendingId = $null       # Mac clip not yet on the clipboard (e.g. screen locked); newest wins
$pendingLogged = $false
$retryIn = 0             # loop passes until the next attempt at the pending clip
foreach ($d in $Inbox, $Outbox) { Remove-OldClips $d }

while ($true) {
    try {
        if (Test-Path -LiteralPath $ReadyFile) {
            $pendingId = ([IO.File]::ReadAllText($ReadyFile)).Trim()
            Remove-Item -LiteralPath $ReadyFile -Force
            $pendingLogged = $false
            $retryIn = 0                     # try right away
        }
        if ($pendingId -and $retryIn -gt 0) {
            $retryIn--
        } elseif ($pendingId) {
            try {
                Import-RemoteClip $pendingId
                $pendingId = $null
                $lastSeq = Get-ClipSeq          # our own change: don't echo back to the Mac
                $lastSig = Get-ClipboardSignature
                Remove-OldClips $Inbox
            } catch {
                if ($pendingId -notmatch '^m\d+$') { $pendingId = $null; throw }
                $retryIn = $RetryTicks
                if (-not $pendingLogged) {
                    Write-Log "waiting: clipboard unavailable (screen locked?), will retry $pendingId - $($_.Exception.Message)"
                    $pendingLogged = $true
                }
            }
        }
        if ((Get-ClipSeq) -ne $lastSeq) {
            if ($pendingId) {                    # a newer copy on Windows wins
                Write-Log "drop pending $pendingId`: newer Windows copy"
                $pendingId = $null
            }
            Start-Sleep -Milliseconds $SettleMs   # let the source app finish writing all formats
            $lastSeq = Get-ClipSeq
            $sig = Get-ClipboardSignature
            if ($sig -and $sig -eq $lastSig) {
                Write-Log 'skip: clipboard was rewritten with the same content'
            } else {
                Export-WinClip
                # Remember it only if the clipboard still holds what we fingerprinted;
                # a cancelled export leaves the sequence number ahead of $lastSeq.
                if ((Get-ClipSeq) -eq $lastSeq) { $lastSig = $sig }
                Remove-OldClips $Outbox
            }
        }
        $ticks++
        if ($ticks % $ExpiryTicks -eq 0) {
            foreach ($d in $Inbox, $Outbox) { Remove-OldClips $d }
        }
    } catch {
        Write-Log ('error: ' + $_.Exception.Message)
    }
    Start-Sleep -Milliseconds $PollMs
}
