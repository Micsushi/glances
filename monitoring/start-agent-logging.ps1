param(
    [int]$StopAfterSamples = 0
)

$ErrorActionPreference = 'Stop'

$repoRoot = 'C:\Users\sushi\Documents\Github\glances'
$pythonExe = Join-Path $repoRoot '.venv\Scripts\python.exe'
$configFile = Join-Path $repoRoot 'monitoring\glances-agent.conf'
$logDirectory = Join-Path $env:LOCALAPPDATA 'GlancesAgentMonitor\logs'
$sampleSeconds = 10
$topProcessCount = 10
$logicalProcessors = [Environment]::ProcessorCount
$moduleFile = Join-Path $repoRoot 'monitoring\AgentMonitor.psm1'

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Import-Module $moduleFile -Force

# The scheduled task also rejects overlapping runs, but the mutex covers
# accidental manual launches of this script.
$mutex = [System.Threading.Mutex]::new($false, 'Local\GlancesAgentMonitor')
$hasMutex = $false
$glancesProcess = $null

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

    if (-not (Test-Path -LiteralPath $pythonExe)) {
        throw "Glances Python environment not found: $pythonExe"
    }

    $startedAt = Get-Date -Format 'yyyyMMdd-HHmmss'
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

    $glancesProcess = Start-Process `
        -FilePath $pythonExe `
        -ArgumentList $glancesArguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $runtimeOutput `
        -RedirectStandardError $runtimeError `
        -PassThru

    $previous = Get-AllProcessSnapshot
    $previousAt = Get-Date
    $completedSamples = 0

    while ($true) {
        Start-Sleep -Seconds $sampleSeconds

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
    $failureLog = Join-Path $logDirectory 'startup-errors.log'
    "$(Get-Date -Format o) $($_.Exception.Message)" | Add-Content -LiteralPath $failureLog
    exit 1
}
finally {
    if ($null -ne $glancesProcess -and -not $glancesProcess.HasExited) {
        Stop-ProcessTree -ProcessId $glancesProcess.Id
    }
    if ($hasMutex) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
