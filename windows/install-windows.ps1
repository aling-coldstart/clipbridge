# Registers the ClipBridge listener as a per-user logon task and starts it.
# Run from the folder that contains listener.ps1 (install.sh does this over SSH).
$ErrorActionPreference = 'Stop'
$TaskName = 'ClipBridge'
$listener = Join-Path $PSScriptRoot 'listener.ps1'
if (-not (Test-Path -LiteralPath $listener)) { throw "listener.ps1 not found next to $PSCommandPath" }

$user      = "$env:USERDOMAIN\$env:USERNAME"
$action    = New-ScheduledTaskAction -Execute 'conhost.exe' `
               -Argument "--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$listener`""
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
# No execution time limit: the default (72 h) would silently kill the listener.
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
               -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'ClipBridge clipboard listener' -Force | Out-Null

& (Join-Path $PSScriptRoot 'restart.ps1')
