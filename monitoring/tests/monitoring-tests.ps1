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

$commandLine = ConvertTo-SafeCommandLine 'tool.exe --token super-secret --password="hidden" --mode test'
if ($commandLine -match 'super-secret|hidden') {
    throw 'process command-line logging must redact sensitive option values'
}
if ($commandLine -notmatch 'tool\.exe' -or $commandLine -notmatch '--mode test') {
    throw 'safe command-line logging must retain useful non-sensitive context'
}
$longCommandLine = ConvertTo-SafeCommandLine ('tool.exe ' + ('x' * 700))
if ($longCommandLine.Length -ne 500) {
    throw 'safe command-line logging must retain the 500-character bound'
}

$retentionRoot = Join-Path ([IO.Path]::GetTempPath()) ('glances-retention-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $retentionRoot -Force | Out-Null
try {
    $now = [datetime]'2026-09-07T19:00:00Z'
    $oldCsv = Join-Path $retentionRoot 'old.csv'
    $oldLog = Join-Path $retentionRoot 'old.log'
    $freshCsv = Join-Path $retentionRoot 'fresh.csv'
    $otherFile = Join-Path $retentionRoot 'keep.txt'
    Set-Content -LiteralPath $oldCsv -Value 'old'
    Set-Content -LiteralPath $oldLog -Value 'old'
    Set-Content -LiteralPath $freshCsv -Value 'fresh'
    Set-Content -LiteralPath $otherFile -Value 'keep'
    foreach ($path in @($oldCsv, $oldLog)) {
        [IO.File]::SetLastWriteTimeUtc($path, $now.ToUniversalTime().AddDays(-15))
    }
    [IO.File]::SetLastWriteTimeUtc($freshCsv, $now.ToUniversalTime().AddDays(-1))
    $removed = Remove-ExpiredMonitoringLogs -LogDirectory $retentionRoot -RetentionDays 14 -Now $now
    Assert-Equal $removed 2 'retention must remove old CSV and diagnostic log files'
    if ((Test-Path -LiteralPath $oldCsv) -or (Test-Path -LiteralPath $oldLog)) {
        throw 'retention must remove files older than the configured bound'
    }
    if (-not (Test-Path -LiteralPath $freshCsv) -or -not (Test-Path -LiteralPath $otherFile)) {
        throw 'retention must preserve fresh and unrelated files'
    }
}
finally {
    Remove-Item -LiteralPath $retentionRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$launcherPath = Join-Path $PSScriptRoot '..\run-hidden.vbs'
$registrationPath = Join-Path $PSScriptRoot '..\register-agent-monitor.ps1'
$workerPath = Join-Path $PSScriptRoot '..\start-agent-logging.ps1'
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

$worker = Get-Content -LiteralPath $workerPath -Raw
if ($worker -match 'Start-Process[\s\S]*-FilePath\s+\$pythonExe') {
    throw 'monitor worker must not launch console Python through Start-Process'
}
if ($worker -notmatch 'CreateNoWindow\s*=\s*\$true') {
    throw 'monitor worker must create the Python runtime without a console window'
}
if ($worker -notmatch 'UseShellExecute\s*=\s*\$false') {
    throw 'monitor worker must bypass the Windows shell for the Python runtime'
}

Write-Output 'monitoring tests passed'
