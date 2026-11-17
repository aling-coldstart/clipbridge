# Run by the Mac over SSH. Prints "HELLO" once, then "CLIP <id>" whenever the
# desktop listener publishes a new outbox clip, "NOTE <text>" when it reports a
# problem (outbox\notice.txt), and "PING" every ~15 s.
$outbox = Join-Path $env:USERPROFILE 'clipbridge\outbox'
$latest = Join-Path $outbox 'latest.txt'
$notice = Join-Path $outbox 'notice.txt'
function Read-Small([string]$path) {
    try { if (Test-Path -LiteralPath $path) { return ([IO.File]::ReadAllText($path)).Trim() } } catch { }
    return ''
}
$out = [Console]::Out
$last = Read-Small $latest
$lastNotice = Read-Small $notice
$out.WriteLine('HELLO'); $out.Flush()
$ticks = 0
while ($true) {
    Start-Sleep -Milliseconds 300
    # Notices first: the listener writes "SENDING" before publishing that clip, and
    # the Mac treats a SENDING as "a newer copy is coming", so the order must hold.
    $note = Read-Small $notice
    if ($note -and $note -ne $lastNotice) {
        $lastNotice = $note
        $out.WriteLine('NOTE ' + ($note -replace '^\S+ ', '')); $out.Flush()   # drop the stamp
    }
    $id = Read-Small $latest
    if ($id -and $id -ne $last) { $last = $id; $out.WriteLine("CLIP $id"); $out.Flush() }
    $ticks++
    if ($ticks % 50 -eq 0) { $out.WriteLine('PING'); $out.Flush() }
}
