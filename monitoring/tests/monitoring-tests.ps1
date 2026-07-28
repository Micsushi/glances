$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\AgentMonitor.psm1') -Force

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

$delta = Get-ProcessRateDelta `
    -CurrentCpuSeconds 14 `
    -PreviousCpuSeconds 12 `
    -CurrentReadBytes 9000 `
    -PreviousReadBytes 1000 `
    -CurrentWriteBytes 6000 `
    -PreviousWriteBytes 1000 `
    -ElapsedSeconds 2 `
    -LogicalProcessors 8

Assert-Equal $delta.CpuPercentOneCore 100 'one-core CPU rate'
Assert-Equal $delta.CpuPercentTotalCapacity 12.5 'total-capacity CPU rate'
Assert-Equal $delta.ReadBytesPerSecond 4000 'read I/O rate'
Assert-Equal $delta.WriteBytesPerSecond 2500 'write I/O rate'

$query = Get-NvidiaSmiQueryArguments
if ($query -notcontains '--format=csv,noheader,nounits') {
    throw 'NVIDIA query must emit machine-readable values without units.'
}
if (($query -join ' ') -notmatch 'utilization\.gpu' -or ($query -join ' ') -notmatch 'pstate') {
    throw 'NVIDIA query must include utilization and performance state.'
}

$launcherPath = Join-Path $PSScriptRoot '..\run-hidden.vbs'
$registrationPath = Join-Path $PSScriptRoot '..\register-agent-monitor.ps1'
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw 'monitor task must include a windowless launcher'
}
if (-not (Test-Path -LiteralPath $registrationPath -PathType Leaf)) {
    throw 'monitor task registration must be reproducible from the repository'
}
$registration = Get-Content -LiteralPath $registrationPath -Raw
if ($registration -notmatch 'wscript\.exe') {
    throw 'monitor task must start from wscript instead of a console executable'
}
if ($registration -match 'New-ScheduledTaskAction\s+-Execute\s+["'']?powershell') {
    throw 'monitor task must not execute PowerShell directly'
}

Write-Output 'monitoring tests passed'
