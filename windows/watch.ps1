# Run by the Mac over SSH. Prints "HELLO" once, then "CLIP <id>" whenever the
# desktop listener publishes a new outbox clip, and "PING" every ~15 s.
$latest = Join-Path $env:USERPROFILE 'clipbridge\outbox\latest.txt'
function Read-Latest {
    try { if (Test-Path -LiteralPath $latest) { return ([IO.File]::ReadAllText($latest)).Trim() } } catch { }
    return ''
}
$out = [Console]::Out
$last = Read-Latest
$out.WriteLine('HELLO'); $out.Flush()
$ticks = 0
while ($true) {
    Start-Sleep -Milliseconds 300
    $id = Read-Latest
    if ($id -and $id -ne $last) { $last = $id; $out.WriteLine("CLIP $id"); $out.Flush() }
    $ticks++
    if ($ticks % 50 -eq 0) { $out.WriteLine('PING'); $out.Flush() }
}
