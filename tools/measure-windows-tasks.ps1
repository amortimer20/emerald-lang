# Run on the Windows ReleaseSafe CI job. Physical memory is a sampled peak,
# not virtual stack reservation. Linux measurements are recorded in the journal.
param(
    [string]$Emerald = "zig-out/bin/emerald.exe",
    [Parameter(Mandatory = $true)][string]$Scheduler
)

$ErrorActionPreference = "Stop"

function Measure-TaskProgram {
    param([string]$Label, [string]$Binary, [string[]]$Arguments, [string]$Expected)

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName = (Resolve-Path $Binary).Path
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $process.StartInfo.ArgumentList.Add($argument)
    }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $peak = 0L
    try {
        [void]$process.Start()
        while (-not $process.WaitForExit(1)) {
            if ($clock.Elapsed.TotalSeconds -gt 300) {
                throw "$Label did not finish within five minutes"
            }
            # Microsoft documents PeakWorkingSet64 as the OS working-set high
            # water mark. Read while alive: an exited Process loses that data.
            # https://learn.microsoft.com/dotnet/api/system.diagnostics.process.peakworkingset64
            try {
                $process.Refresh()
                $peak = [Math]::Max($peak, $process.PeakWorkingSet64)
            }
            catch [System.InvalidOperationException] {
                if (-not $process.HasExited) { throw }
            }
        }
        $clock.Stop()
        $output = $process.StandardOutput.ReadToEnd().Trim()
        $errors = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0 -or $output -ne $Expected -or $errors.Length -ne 0) {
            throw "$Label failed: exit $($process.ExitCode), stdout '$output', stderr '$errors'"
        }
        if ($peak -eq 0) { throw "$Label finished without a memory sample" }
        Write-Host ("{0}: {1:F3} s, {2:F2} MiB sampled peak physical memory" -f
            $Label, $clock.Elapsed.TotalSeconds, ($peak / 1MB))
    }
    finally {
        if ($process.Id -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

Measure-TaskProgram "1,000 sequential tasks" $Emerald @("run", "tools/task-benchmark.em", "--", "1000") "499500"
Measure-TaskProgram "10,000 sequential tasks" $Emerald @("run", "tools/task-benchmark.em", "--", "10000") "49995000"
Measure-TaskProgram "64 live tasks" $Emerald @("run", "tools/task-live-benchmark.em", "--", "64") "2016"
Measure-TaskProgram "100,000 scheduler handoffs" $Scheduler @() ""
