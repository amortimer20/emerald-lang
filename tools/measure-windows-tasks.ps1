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
    $commit = 0L
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
                $commit = [Math]::Max($commit, $process.PeakPagedMemorySize64)
            }
            catch [System.InvalidOperationException] {
                if (-not $process.HasExited) { throw }
            }
        }
        $clock.Stop()
        $output = $process.StandardOutput.ReadToEnd().Replace("`r`n", "`n").Trim()
        $errors = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0 -or $output -ne $Expected -or $errors.Length -ne 0) {
            throw "$Label failed: exit $($process.ExitCode), stdout '$output', stderr '$errors'"
        }
        if ($peak -eq 0) { throw "$Label finished without a memory sample" }
        Write-Host ("{0}: {1:F3} s, {2:F2} MiB sampled peak physical memory, {3:F2} MiB peak commit" -f
            $Label, $clock.Elapsed.TotalSeconds, ($peak / 1MB), ($commit / 1MB))
        return @{ Seconds = $clock.Elapsed.TotalSeconds; Physical = $peak; Commit = $commit }
    }
    finally {
        if ($process.Id -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

$null = Measure-TaskProgram "1,000 sequential tasks" $Emerald @("run", "tools/task-benchmark.em", "--", "1000") "499500"
$null = Measure-TaskProgram "10,000 sequential tasks" $Emerald @("run", "tools/task-benchmark.em", "--", "10000") "49995000"
$live = Measure-TaskProgram "64 live tasks" $Emerald @("run", "tools/task-live-benchmark.em", "--", "64") "started: 64`n2016"
Write-Host "All 64 task threads started (confirmed before the first task ran)."
# A default main interpreter stack is also committed by std.Thread.spawn;
# this ceiling distinguishes it from 64 * 128 MiB task stacks.
if ($live.Commit -gt 1GB) { throw "64 live tasks committed more than 1 GiB" }
$null = Measure-TaskProgram "100,000 scheduler handoffs" $Scheduler @() ""
$small = Measure-TaskProgram "2,000 sequential tasks" $Emerald @("run", "tools/task-benchmark.em", "--", "2000") "1999000"
$large = Measure-TaskProgram "20,000 sequential tasks" $Emerald @("run", "tools/task-benchmark.em", "--", "20000") "199990000"
Write-Host ("Sequential scaling: {0:F2}x time, {1:F2}x peak physical memory, {2:F2}x commit" -f
    ($large.Seconds / $small.Seconds), ($large.Physical / $small.Physical), ($large.Commit / $small.Commit))
if ($large.Seconds -gt $small.Seconds * 15 -or $large.Physical -gt $small.Physical * 2 -or $large.Commit -gt $small.Commit * 2) {
    throw "Sequential task cost did not scale approximately linearly with bounded memory"
}
