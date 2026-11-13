<#
.SYNOPSIS
    Repeatable runtime-weight baseline for XerahS (XIP0091). PowerShell 7+, Windows/Linux/macOS.

.DESCRIPTION
    Runs a published XerahS build in an isolated portable profile and records, per run:
      - startup time as logged by Program.cs ("Startup time: N ms (+ M ms async init)")
      - private memory / working set / thread count / handle count at fixed idle checkpoints
      - optional region-capture latency, parsed from the existing "[RegionCapture] Milestone:" log lines
    Results are appended to a CSV so before/after builds can be compared with Compare-UiWeight below.

    Run it on the same machine, on AC power, with nothing else heavy running. Use -Runs 5 or more and
    compare medians, not single runs.

.EXAMPLE
    # One-time: publish the build under test
    dotnet publish src/desktop/app/XerahS.App -c Release -r win-x64 -o out/before
    # Tray-only scenario (SilentRun must be on in the portable profile; the script prompts on first run)
    pwsh scripts/perf/Measure-UiWeight.ps1 -AppDir out/before -Label before -Runs 5
    # Same for the change, then:
    pwsh scripts/perf/Measure-UiWeight.ps1 -Compare -Csv perf-results.csv
#>
[CmdletBinding()]
param(
    [string]$AppDir,
    [string]$Label = 'build',
    [int]$Runs = 5,
    [int[]]$CheckpointsSec = @(5, 30, 120, 600),
    [int]$CaptureSamples = 0,
    [string]$Csv = (Join-Path (Get-Location) 'perf-results.csv'),
    [switch]$Compare,
    # CI mode: seed a tray-only portable profile instead of prompting for first-run setup.
    [switch]$SeedSilentRun,
    # After the idle checkpoints, launch a second instance (which brings the main window up), wait,
    # sample memory again and (Windows) save a screenshot, to prove the main window still works.
    [string]$ShowMainWindowScreenshotDir
)

$ErrorActionPreference = 'Stop'

function Compare-UiWeight([string]$Path) {
    $rows = Import-Csv $Path
    $metrics = 'StartupMs', 'AsyncInitMs', 'PrivateMB_5s', 'PrivateMB_30s', 'PrivateMB_120s', 'PrivateMB_600s',
               'WorkingSetMB_600s', 'Threads_600s', 'PrivateMB_AfterShow', 'OverlayMs_Median'
    foreach ($group in ($rows | Group-Object Label)) {
        $line = [ordered]@{ Label = $group.Name; Runs = $group.Count }
        foreach ($m in $metrics) {
            $vals = $group.Group | Where-Object { $_.$m -ne '' -and $null -ne $_.$m } | ForEach-Object { [double]$_.$m } | Sort-Object
            $line[$m] = if ($vals.Count) { [math]::Round($vals[[int][math]::Floor(($vals.Count - 1) / 2)], 1) } else { '' }
        }
        [pscustomobject]$line
    }
}

if ($Compare) { Compare-UiWeight $Csv | Format-Table -AutoSize; return }
if (-not $AppDir) { throw 'Pass -AppDir <published XerahS folder> or -Compare.' }

$exeName = if ($IsWindows) { 'XerahS.exe' } else { 'XerahS' }
$source = Resolve-Path $AppDir
$exe = Get-ChildItem -Path $source -Recurse -Filter $exeName | Select-Object -First 1
if (-not $exe) { throw "Could not find $exeName under $source" }

# Isolated portable copy: PathsManager.IsPortable is true when portable.txt sits next to the executable,
# so settings, history and logs stay out of the user's real profile.
$work = Join-Path ([IO.Path]::GetTempPath()) "xerahs-perf-$Label"
if (-not (Test-Path $work)) {
    Copy-Item $exe.Directory.FullName $work -Recurse
    New-Item (Join-Path $work 'portable.txt') -ItemType File | Out-Null
    Write-Host "Portable copy created at $work."
}
$seedMarker = Join-Path $work '.seeded'
if ($SeedSilentRun -and -not (Test-Path $seedMarker)) {
    # Portable layout: <exe dir>/XerahS/Settings/ApplicationConfig.json (PathsManager.SettingsFolder).
    # A non-empty, newer-than-current ApplicationVersion means "not first run, not an upgrade",
    # so no onboarding or what's-new UI appears.
    $settingsDir = Join-Path $work 'XerahS/Settings'
    New-Item $settingsDir -ItemType Directory -Force | Out-Null
    @{ ApplicationVersion = '999.0.0'; SilentRun = $true; ShowTray = $true; AutoCheckUpdate = $false } |
        ConvertTo-Json | Set-Content (Join-Path $settingsDir 'ApplicationConfig.json')
    New-Item $seedMarker -ItemType File | Out-Null
} elseif (-not $SeedSilentRun -and -not (Test-Path (Join-Path $work 'XerahS'))) {
    Write-Host 'First run: XerahS will open. Finish onboarding, enable "Start minimized to tray" (SilentRun) if you are'
    Write-Host 'measuring the tray scenario, then exit from the tray. Press Enter here when done.'
    Start-Process (Join-Path $work $exeName) | Out-Null
    Read-Host | Out-Null
}
$appExe = Join-Path $work $exeName

function Get-Sample([System.Diagnostics.Process]$p) {
    $p.Refresh()
    [pscustomobject]@{
        PrivateMB    = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
        WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
        Threads      = $p.Threads.Count
        Handles      = $p.HandleCount
    }
}

for ($run = 1; $run -le $Runs; $run++) {
    $logDir = Join-Path $work "logs-run$run-$(Get-Date -Format yyyyMMddHHmmss)"
    $env:XERAHS_LOGS_DIR = $logDir   # PathsManager.LogsFolderOverrideVariable
    $proc = Start-Process $appExe -PassThru
    $row = [ordered]@{ Label = $Label; Run = $run; Os = [Runtime.InteropServices.RuntimeInformation]::OSDescription; When = (Get-Date -Format s) }

    $elapsed = 0
    foreach ($cp in $CheckpointsSec) {
        Start-Sleep -Seconds ($cp - $elapsed); $elapsed = $cp
        if ($proc.HasExited) { throw "XerahS exited early (run $run)." }
        $s = Get-Sample $proc
        $row["PrivateMB_${cp}s"] = $s.PrivateMB
        $row["WorkingSetMB_${cp}s"] = $s.WorkingSetMB
        $row["Threads_${cp}s"] = $s.Threads
        $row["Handles_${cp}s"] = $s.Handles
    }

    if ($ShowMainWindowScreenshotDir) {
        Start-Process $appExe | Out-Null   # second instance relays to the first, which shows MainWindow
        Start-Sleep -Seconds 20
        if ($proc.HasExited) { throw "XerahS exited after the main window was opened (run $run)." }
        $s = Get-Sample $proc
        $row.PrivateMB_AfterShow = $s.PrivateMB
        $row.WorkingSetMB_AfterShow = $s.WorkingSetMB
        if ($IsWindows) {
            New-Item $ShowMainWindowScreenshotDir -ItemType Directory -Force | Out-Null
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $bmp = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
            $bmp.Save((Join-Path $ShowMainWindowScreenshotDir "$Label-run$run.png"), [System.Drawing.Imaging.ImageFormat]::Png)
            $g.Dispose(); $bmp.Dispose()
        }
    }

    if ($CaptureSamples -gt 0) {
        Write-Host "Run ${run}: press your region-capture hotkey $CaptureSamples times (Esc each time), then press Enter."
        Read-Host | Out-Null
    }

    $log = Get-ChildItem $logDir -Recurse -File -ErrorAction SilentlyContinue | Get-Content -ErrorAction SilentlyContinue
    $m = $log | Select-String 'Startup time: (\d+) ms \(\+ (\d+) ms async init\)' | Select-Object -Last 1
    $row.StartupMs = if ($m) { $m.Matches[0].Groups[1].Value } else { '' }
    $row.AsyncInitMs = if ($m) { $m.Matches[0].Groups[2].Value } else { '' }

    # Hotkey -> overlay visible, from the milestones OverlayManager already logs.
    $overlay = $log | Select-String 'Milestone: overlay displayed \(\+(\d+) ms\)' | ForEach-Object { [double]$_.Matches[0].Groups[1].Value } | Sort-Object
    $row.OverlayMs_Median = if ($overlay.Count) { $overlay[[int][math]::Floor(($overlay.Count - 1) / 2)] } else { '' }
    $row.OverlayMs_Count = $overlay.Count

    Stop-Process -Id $proc.Id -Force
    Start-Sleep -Seconds 3
    [pscustomobject]$row | Export-Csv $Csv -Append -NoTypeInformation -Force
    Write-Host "Run $run/$Runs recorded: startup $($row.StartupMs) ms, private $($row["PrivateMB_$($CheckpointsSec[-1])s"]) MB at $($CheckpointsSec[-1]) s."
}

Remove-Item Env:XERAHS_LOGS_DIR -ErrorAction SilentlyContinue
Compare-UiWeight $Csv | Format-Table -AutoSize
