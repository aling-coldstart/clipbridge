# Removes the ClipBridge task, stops the listener and deletes %USERPROFILE%\clipbridge.
$TaskName = 'ClipBridge'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*clipbridge\listener.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Remove-Item -LiteralPath (Join-Path $env:USERPROFILE 'clipbridge') -Recurse -Force -ErrorAction SilentlyContinue
'ClipBridge removed from Windows'
