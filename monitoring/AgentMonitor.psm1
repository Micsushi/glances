function Get-ProcessRateDelta {
    param(
        [double]$CurrentCpuSeconds,
        [double]$PreviousCpuSeconds,
        [double]$CurrentReadBytes,
        [double]$PreviousReadBytes,
        [double]$CurrentWriteBytes,
        [double]$PreviousWriteBytes,
        [double]$ElapsedSeconds,
        [int]$LogicalProcessors
    )

    $safeElapsed = [math]::Max($ElapsedSeconds, 0.001)
    $safeProcessors = [math]::Max($LogicalProcessors, 1)
    $cpuDelta = [math]::Max($CurrentCpuSeconds - $PreviousCpuSeconds, 0)
    $readDelta = [math]::Max($CurrentReadBytes - $PreviousReadBytes, 0)
    $writeDelta = [math]::Max($CurrentWriteBytes - $PreviousWriteBytes, 0)
    $oneCorePercent = 100 * $cpuDelta / $safeElapsed

    [pscustomobject]@{
        CpuPercentOneCore       = [math]::Round($oneCorePercent, 2)
        CpuPercentTotalCapacity = [math]::Round($oneCorePercent / $safeProcessors, 2)
        ReadBytesPerSecond      = [math]::Round($readDelta / $safeElapsed, 0)
        WriteBytesPerSecond     = [math]::Round($writeDelta / $safeElapsed, 0)
    }
}

function Get-NvidiaSmiQueryArguments {
    @(
        '--query-gpu=utilization.gpu,utilization.memory,memory.used,memory.total,clocks.current.graphics,clocks.current.memory,pstate,power.draw,temperature.gpu',
        '--format=csv,noheader,nounits'
    )
}

function Get-NvidiaTelemetry {
    $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($null -eq $nvidiaSmi) {
        return $null
    }

    try {
        $line = @(& $nvidiaSmi.Source @(Get-NvidiaSmiQueryArguments) 2>$null)[0]
        if (-not $line) {
            return $null
        }
        $values = @($line -split ',' | ForEach-Object { $_.Trim() })
        if ($values.Count -lt 9) {
            return $null
        }

        [pscustomobject]@{
            GpuUtilizationPercent       = $values[0]
            GpuMemoryUtilizationPercent = $values[1]
            GpuMemoryUsedMB             = $values[2]
            GpuMemoryTotalMB            = $values[3]
            GpuGraphicsClockMHz         = $values[4]
            GpuMemoryClockMHz           = $values[5]
            GpuPerformanceState         = $values[6]
            GpuPowerWatts               = $values[7]
            GpuTemperatureC             = $values[8]
        }
    }
    catch {
        return $null
    }
}

function Get-SystemTelemetry {
    param([datetime]$Timestamp = (Get-Date))

    $processors = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
    $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk `
        -Filter "Name='_Total'" -ErrorAction SilentlyContinue
    $gpu = Get-NvidiaTelemetry

    $cpuPercent = if ($processors.Count -gt 0) {
        [math]::Round(($processors | Measure-Object LoadPercentage -Average).Average, 1)
    }
    else {
        $null
    }
    $memoryTotalMB = [math]::Round($operatingSystem.TotalVisibleMemorySize / 1KB, 1)
    $memoryAvailableMB = [math]::Round($operatingSystem.FreePhysicalMemory / 1KB, 1)

    [pscustomobject]@{
        Timestamp                    = $Timestamp.ToString('o')
        CpuPercent                   = $cpuPercent
        MemoryUsedPercent            = [math]::Round(100 * ($memoryTotalMB - $memoryAvailableMB) / $memoryTotalMB, 1)
        MemoryUsedMB                 = [math]::Round($memoryTotalMB - $memoryAvailableMB, 1)
        MemoryAvailableMB            = $memoryAvailableMB
        DiskUtilizationPercent       = if ($disk) { $disk.PercentDiskTime } else { $null }
        DiskQueueLength              = if ($disk) { $disk.CurrentDiskQueueLength } else { $null }
        DiskReadBytesPerSecond       = if ($disk) { $disk.DiskReadBytesPersec } else { $null }
        DiskWriteBytesPerSecond      = if ($disk) { $disk.DiskWriteBytesPersec } else { $null }
        GpuUtilizationPercent        = if ($gpu) { $gpu.GpuUtilizationPercent } else { $null }
        GpuMemoryUtilizationPercent  = if ($gpu) { $gpu.GpuMemoryUtilizationPercent } else { $null }
        GpuMemoryUsedMB              = if ($gpu) { $gpu.GpuMemoryUsedMB } else { $null }
        GpuMemoryTotalMB             = if ($gpu) { $gpu.GpuMemoryTotalMB } else { $null }
        GpuGraphicsClockMHz          = if ($gpu) { $gpu.GpuGraphicsClockMHz } else { $null }
        GpuMemoryClockMHz            = if ($gpu) { $gpu.GpuMemoryClockMHz } else { $null }
        GpuPerformanceState          = if ($gpu) { $gpu.GpuPerformanceState } else { $null }
        GpuPowerWatts                = if ($gpu) { $gpu.GpuPowerWatts } else { $null }
        GpuTemperatureC              = if ($gpu) { $gpu.GpuTemperatureC } else { $null }
    }
}

function Get-AllProcessSnapshot {
    $cimByPid = @{}
    foreach ($process in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $cimByPid[[int]$process.ProcessId] = $process
    }

    $snapshot = @{}
    foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $cim = $cimByPid[$process.Id]
            $snapshot[$process.Id] = [pscustomobject]@{
                Pid          = $process.Id
                Name         = $process.ProcessName
                CpuSeconds   = if ($null -ne $process.CPU) { [double]$process.CPU } else { 0 }
                ReadBytes    = if ($cim) { [double]$cim.ReadTransferCount } else { 0 }
                WriteBytes   = if ($cim) { [double]$cim.WriteTransferCount } else { 0 }
                WorkingSetMB = [math]::Round($process.WorkingSet64 / 1MB, 1)
                Threads      = $process.Threads.Count
                StartedAt    = $process.StartTime.ToString('o')
                Path         = $process.Path
                CommandLine  = if ($cim) { $cim.CommandLine } else { $null }
            }
        }
        catch {
            # Processes can exit or become inaccessible between enumeration and read.
        }
    }

    return ,$snapshot
}

function Get-ProcessRateRows {
    param(
        [hashtable]$Current,
        [hashtable]$Previous,
        [double]$ElapsedSeconds,
        [int]$LogicalProcessors,
        [datetime]$Timestamp = (Get-Date)
    )

    $rows = @()
    foreach ($entry in $Current.GetEnumerator()) {
        $process = $entry.Value
        if (-not $Previous.ContainsKey($process.Pid)) {
            continue
        }
        $prior = $Previous[$process.Pid]
        $delta = Get-ProcessRateDelta `
            -CurrentCpuSeconds $process.CpuSeconds `
            -PreviousCpuSeconds $prior.CpuSeconds `
            -CurrentReadBytes $process.ReadBytes `
            -PreviousReadBytes $prior.ReadBytes `
            -CurrentWriteBytes $process.WriteBytes `
            -PreviousWriteBytes $prior.WriteBytes `
            -ElapsedSeconds $ElapsedSeconds `
            -LogicalProcessors $LogicalProcessors

        $commandLine = ConvertTo-SafeCommandLine $process.CommandLine
        $rows += [pscustomobject]@{
            Timestamp               = $Timestamp.ToString('o')
            Pid                     = $process.Pid
            ProcessName             = $process.Name
            CpuPercentTotalCapacity = $delta.CpuPercentTotalCapacity
            CpuPercentOneCore       = $delta.CpuPercentOneCore
            ReadBytesPerSecond      = $delta.ReadBytesPerSecond
            WriteBytesPerSecond     = $delta.WriteBytesPerSecond
            TotalIoBytesPerSecond   = $delta.ReadBytesPerSecond + $delta.WriteBytesPerSecond
            WorkingSetMB            = $process.WorkingSetMB
            ThreadCount             = $process.Threads
            StartedAt               = $process.StartedAt
            ExecutablePath          = $process.Path
            CommandLine             = $commandLine
        }
    }
    $rows
}

function ConvertTo-SafeCommandLine {
    param(
        [AllowNull()][string]$CommandLine,
        [int]$MaxLength = 500
    )

    if ($null -eq $CommandLine) { return $null }
    $safeLength = [math]::Max($MaxLength, 1)
    $safe = $CommandLine -replace '[\x00-\x1F\x7F]', ' '
    $sensitiveOption = '(?i)(--?(?:password|token|secret|api[-_]?key|access[-_]?token|refresh[-_]?token|credential))(\s*(?:=|:)\s*|\s+)("[^"]*"|''[^'']*''|\S+)'
    $safe = [regex]::Replace($safe, $sensitiveOption, '$1$2<redacted>')
    $sensitiveAssignment = '(?i)\b(password|token|secret|api[-_]?key|access[-_]?token|refresh[-_]?token)\s*=\s*("[^"]*"|''[^'']*''|\S+)'
    $safe = [regex]::Replace($safe, $sensitiveAssignment, '$1=<redacted>')
    if ($safe.Length -gt $safeLength) {
        return $safe.Substring(0, $safeLength)
    }
    return $safe
}

function Remove-ExpiredMonitoringLogs {
    param(
        [Parameter(Mandatory = $true)][string]$LogDirectory,
        [int]$RetentionDays = 14,
        [datetime]$Now = (Get-Date)
    )

    if ($RetentionDays -lt 1 -or -not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        return 0
    }
    $cutoffUtc = $Now.ToUniversalTime().AddDays(-$RetentionDays)
    $removed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $LogDirectory -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.csv', '.log') -and $_.LastWriteTimeUtc -lt $cutoffUtc })) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $removed++
        }
        catch {
            # A concurrent writer may own a log; retain it for the next pass.
        }
    }
    return $removed
}

function Get-TopProcessRows {
    param(
        [object[]]$Rows,
        [int]$Count = 10
    )

    $reasons = @{}
    foreach ($row in @($Rows | Sort-Object CpuPercentOneCore -Descending | Select-Object -First $Count)) {
        $reasons[$row.Pid] = 'cpu'
    }
    foreach ($row in @($Rows | Sort-Object TotalIoBytesPerSecond -Descending | Select-Object -First $Count)) {
        $reasons[$row.Pid] = if ($reasons.ContainsKey($row.Pid)) { 'cpu;io' } else { 'io' }
    }

    foreach ($row in $Rows) {
        if ($reasons.ContainsKey($row.Pid)) {
            $row | Select-Object *, @{ Name = 'TopBy'; Expression = { $reasons[$_.Pid] } }
        }
    }
}

Export-ModuleMember -Function `
    Get-ProcessRateDelta, `
    Get-NvidiaSmiQueryArguments, `
    Get-NvidiaTelemetry, `
    Get-SystemTelemetry, `
    Get-AllProcessSnapshot, `
    Get-ProcessRateRows, `
    Get-TopProcessRows, `
    ConvertTo-SafeCommandLine, `
    Remove-ExpiredMonitoringLogs
