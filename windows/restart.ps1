# Stops any running ClipBridge listener and starts it again via the scheduled task.
$TaskName = 'ClipBridge'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*clipbridge\listener.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
$log = Join-Path $env:USERPROFILE 'clipbridge\listener.log'
if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 1 }
