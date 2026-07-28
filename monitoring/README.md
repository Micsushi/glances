# Glances agent monitor

This setup runs Glances in the background every 10 seconds and writes logs to:

`%LOCALAPPDATA%\GlancesAgentMonitor\logs`

The files are:

- `system-YYYYMMDD.csv`: CPU, memory, disk utilization/queue/read-write rates,
  and NVIDIA utilization, clocks, performance state, power, VRAM, and temperature.
- `top-processes-v2-YYYYMMDD.csv`: the busiest processes across the whole device by
  both CPU and disk I/O, including PID, memory, executable, and command line.
- `runtime-summary-v2-YYYYMMDD.csv`: CPU, disk I/O, memory, and process counts
  grouped by executable.
- `glances-*.err.log` and `startup-errors.log`: diagnostic errors.

Glances remains active as an independent CPU/memory health signal. A compact
native Windows sampler owns the durable CSV files because Glances' CSV exporter
can stay buffered at zero bytes on Windows and its full process export is too
large when hundreds of processes are present.

Command lines often reveal a project path or test command. Neither Glances nor
Windows can reliably map a process back to a specific Codex task if the process
was launched without a task identifier.

Windows starts `start-agent-logging.ps1` through the per-user scheduled task
named `Glances Agent Monitor`.

Register or repair that task with:

```powershell
.\monitoring\register-agent-monitor.ps1
```

The task starts through `wscript.exe` and `run-hidden.vbs`, so the long-running
PowerShell monitor does not create a terminal window at sign-in or restart.
