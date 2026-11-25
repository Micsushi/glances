[CmdletBinding()]
param(
    [string]$TaskName = "Glances Agent Monitor",
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"

$monitoringRoot = $PSScriptRoot
$launcherPath = Join-Path $monitoringRoot "run-hidden.vbs"
$workerPath = Join-Path $monitoringRoot "start-agent-logging.ps1"
$wscriptPath = Join-Path $env:SystemRoot "System32\wscript.exe"
$powershellPath = Join-Path $PSHOME "powershell.exe"

foreach ($path in @($launcherPath, $workerPath, $wscriptPath, $powershellPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}

$argumentList = @(
    "//B",
    "//Nologo",
    $launcherPath,
    $powershellPath,
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-WindowStyle",
    "Hidden",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $workerPath
)
$taskArguments = ($argumentList | ForEach-Object {
    '"' + $_.Replace('"', '\"') + '"'
}) -join " "

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$workers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*-File*`"$workerPath`"*" })
if ($workers.Count -gt 0) {
    Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'GlancesAgentMonitor\stop.request') -Value 'registration restart'
    foreach ($worker in $workers) { Wait-Process -Id $worker.ProcessId -Timeout 30 -ErrorAction Stop }
}
if ($existingTask) {
    Stop-ScheduledTask -InputObject $existingTask
}

$action = New-ScheduledTaskAction -Execute $wscriptPath -Argument $taskArguments
$trigger = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5))
)
$principal = New-ScheduledTaskPrincipal `
    -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Description "Runs the Glances background resource monitor without a console window." `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

if (-not $NoStart) {
    Start-ScheduledTask -TaskName $TaskName
}

Get-ScheduledTask -TaskName $TaskName
