param(
    [int]$StopAfterSamples = 0
)

$ErrorActionPreference = 'Stop'

$repoRoot = 'C:\Users\sushi\Documents\Github\glances'
$pythonExe = Join-Path $repoRoot '.venv\Scripts\python.exe'
$configFile = Join-Path $repoRoot 'monitoring\glances-agent.conf'
$logDirectory = Join-Path $env:LOCALAPPDATA 'GlancesAgentMonitor\logs'
$stopPath = Join-Path $env:LOCALAPPDATA 'GlancesAgentMonitor\stop.request'
$sampleSeconds = 10
$topProcessCount = 10
$retentionDays = 14
$logicalProcessors = [Environment]::ProcessorCount
$moduleFile = Join-Path $repoRoot 'monitoring\AgentMonitor.psm1'

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Import-Module $moduleFile -Force
Remove-ExpiredMonitoringLogs -LogDirectory $logDirectory -RetentionDays $retentionDays | Out-Null

# The scheduled task also rejects overlapping runs, but the mutex covers
# accidental manual launches of this script.
$mutex = [System.Threading.Mutex]::new($false, 'Local\GlancesAgentMonitor')
$hasMutex = $false
$glancesProcess = $null
$glancesStarted = $false
$runtimeOutputStream = $null
$runtimeErrorStream = $null
$outputCopyTask = $null
$errorCopyTask = $null

function ConvertTo-ProcessArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value -match '"') {
        throw 'Process arguments cannot contain double quotes.'
    }
    if ($Value.Length -eq 0 -or $Value -match '\s') {
        return '"' + $Value + '"'
    }
    return $Value
}

function Stop-ProcessTree {
    param([int]$ProcessId)

    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Stop-ProcessTree -ProcessId $child.ProcessId
    }

    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        exit 0
    }
    Remove-Item -LiteralPath $stopPath -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $pythonExe)) {
        throw "Glances Python environment not found: $pythonExe"
    }

    $startedAt = Get-Date -Format 'yyyyMMdd-HHmmss'
    "$(Get-Date -Format o) START pid=$PID" | Add-Content -LiteralPath (Join-Path $logDirectory 'lifecycle.log')
    $runtimeOutput = Join-Path $logDirectory "glances-$startedAt.out.log"
    $runtimeError = Join-Path $logDirectory "glances-$startedAt.err.log"

    # Keep the Glances runtime active as a lightweight independent health
    # signal. The native sampler below owns durable CSV output because the
    # Glances CSV exporter can remain buffered at zero bytes on Windows.
    $glancesArguments = @(
        '-m', 'glances',
        '--config', $configFile,
        '--time', $sampleSeconds,
        '--disable-check-update',
        '--disable-plugin', 'all',
        '--enable-plugin', 'cpu,mem',
        '--stdout', 'cpu.total,mem.percent'
    )

    $processInfo = New-Object Diagnostics.ProcessStartInfo
    $processInfo.FileName = $pythonExe
    $processInfo.Arguments = ($glancesArguments | ForEach-Object {
        ConvertTo-ProcessArgument ([string]$_)
    }) -join ' '
    $processInfo.WorkingDirectory = $repoRoot
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true

    $runtimeOutputStream = [IO.File]::Open(
        $runtimeOutput,
        [IO.FileMode]::Create,
        [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite
    )
    $runtimeErrorStream = [IO.File]::Open(
        $runtimeError,
        [IO.FileMode]::Create,
        [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite
    )
    $glancesProcess = New-Object Diagnostics.Process
    $glancesProcess.StartInfo = $processInfo
    if (-not $glancesProcess.Start()) {
        throw 'Glances failed to start.'
    }
    $glancesStarted = $true
    $outputCopyTask = $glancesProcess.StandardOutput.BaseStream.CopyToAsync($runtimeOutputStream)
    $errorCopyTask = $glancesProcess.StandardError.BaseStream.CopyToAsync($runtimeErrorStream)

    $previous = Get-AllProcessSnapshot
    $previousAt = Get-Date
    $completedSamples = 0

    while ($true) {
        Start-Sleep -Seconds $sampleSeconds
        if (Test-Path -LiteralPath $stopPath) { break }

        if ($glancesProcess.HasExited) {
            throw "Glances exited unexpectedly with code $($glancesProcess.ExitCode). See $runtimeError"
        }

        $sampledAt = Get-Date
        $elapsedSeconds = ($sampledAt - $previousAt).TotalSeconds
        $current = Get-AllProcessSnapshot
        $rows = @(Get-ProcessRateRows `
            -Current $current `
            -Previous $previous `
            -ElapsedSeconds $elapsedSeconds `
            -LogicalProcessors $logicalProcessors `
            -Timestamp $sampledAt)
        $topRows = @(Get-TopProcessRows -Rows $rows -Count $topProcessCount)

        $day = $sampledAt.ToString('yyyyMMdd')
        [pscustomobject]@{
            Timestamp = $sampledAt.ToString('o')
            MonitorPid = $PID
            LogDriveFreeMB = [math]::Round(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($logDirectory))).AvailableFreeSpace / 1MB, 1)
        } | Export-Csv -LiteralPath (Join-Path $logDirectory "health-$day.csv") -NoTypeInformation -Append
        $systemCsv = Join-Path $logDirectory "system-$day.csv"
        $topCsv = Join-Path $logDirectory "top-processes-v2-$day.csv"
        $summaryCsv = Join-Path $logDirectory "runtime-summary-v2-$day.csv"

        Get-SystemTelemetry -Timestamp $sampledAt |
            Export-Csv -LiteralPath $systemCsv -NoTypeInformation -Append

        if ($topRows.Count -gt 0) {
            $topRows | Export-Csv -LiteralPath $topCsv -NoTypeInformation -Append
        }

        $summaryRows = @(
            $rows |
                Group-Object ProcessName |
                ForEach-Object {
                    [pscustomobject]@{
                        Timestamp               = $sampledAt.ToString('o')
                        ProcessName             = $_.Name
                        ProcessCount            = $_.Count
                        CpuPercentTotalCapacity = [math]::Round(($_.Group | Measure-Object CpuPercentTotalCapacity -Sum).Sum, 2)
                        CpuPercentOneCore       = [math]::Round(($_.Group | Measure-Object CpuPercentOneCore -Sum).Sum, 2)
                        ReadBytesPerSecond      = [math]::Round(($_.Group | Measure-Object ReadBytesPerSecond -Sum).Sum, 0)
                        WriteBytesPerSecond     = [math]::Round(($_.Group | Measure-Object WriteBytesPerSecond -Sum).Sum, 0)
                        WorkingSetMB            = [math]::Round(($_.Group | Measure-Object WorkingSetMB -Sum).Sum, 1)
                        ThreadCount             = ($_.Group | Measure-Object ThreadCount -Sum).Sum
                    }
                }
        )
        if ($summaryRows.Count -gt 0) {
            $summaryRows | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Append
        }

        $previous = $current
        $previousAt = $sampledAt
        $completedSamples++

        if ($StopAfterSamples -gt 0 -and $completedSamples -ge $StopAfterSamples) {
            break
        }
    }

    exit 0
}
catch {
    $failure = ($_ | Out-String) + $_.ScriptStackTrace
    $failureLog = Join-Path $logDirectory 'startup-errors.log'
    try { "$(Get-Date -Format o) pid=$PID $failure" | Add-Content -LiteralPath $failureLog } catch {}
    try { (New-Object -ComObject WScript.Shell).LogEvent(1, "Glances monitor failed: $failure") | Out-Null } catch {}
    exit 1
}
finally {
    if ($hasMutex) {
        try { "$(Get-Date -Format o) EXIT pid=$PID" | Add-Content -LiteralPath (Join-Path $logDirectory 'lifecycle.log') } catch {}
    }
    if ($glancesStarted -and -not $glancesProcess.HasExited) {
        Stop-ProcessTree -ProcessId $glancesProcess.Id
    }
    if ($glancesStarted) {
        [void]$glancesProcess.WaitForExit(5000)
    }
    foreach ($copyTask in @($outputCopyTask, $errorCopyTask)) {
        if ($null -ne $copyTask) {
            try {
                [void]$copyTask.Wait(5000)
            } catch {
                # The process exit path is authoritative; log copying is best effort.
            }
        }
    }
    foreach ($stream in @($runtimeOutputStream, $runtimeErrorStream)) {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    if ($null -ne $glancesProcess) {
        $glancesProcess.Dispose()
    }
    if ($hasMutex) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
