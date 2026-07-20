# Regression: `send-keys -f C-c` must interrupt a raw-mode ConPTY target.
#
# Ordinary C-c remains a raw 0x03 key for TUI compatibility.  The explicit
# force form uses a genuine CTRL_BREAK_EVENT and must not queue 0x03 behind the
# exiting application, where it could leak into the pane shell.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "psmux_test_helpers.ps1")

$ctx = $null
$failed = $false
$savedNoWarm = (Get-Item Env:\PSMUX_NO_WARM -ErrorAction SilentlyContinue).Value

function Wait-ForLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern,
        [int]$TimeoutMs = 8000
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Test-Path $Path) -and ((Get-Content $Path -Raw) -match $Pattern)) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Wait-ForProcessExit {
    param([Parameter(Mandatory)][int]$Id, [int]$TimeoutMs = 8000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (-not (Get-Process -Id $Id -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

try {
    $testExe = if ($env:PSMUX_EXE) {
        (Resolve-Path $env:PSMUX_EXE -ErrorAction Stop).Path
    } else {
        (Resolve-Path (Join-Path $PSScriptRoot "..\target\debug\psmux.exe") -ErrorAction Stop).Path
    }
    $ctx = New-PsmuxTestEnv -Tag "force_ctrl_c_raw" -Exe $testExe
    $PSMUX = $ctx.PsmuxExe
    $ns = Register-PsmuxNamespace -Ctx $ctx -Namespace ("force_ctrl_c_raw_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $env:PSMUX_NO_WARM = "1"
    Write-Host "Testing: $PSMUX"
    Write-Host "SHA256: $((Get-FileHash -Algorithm SHA256 $PSMUX).Hash)"

    $python = (Get-Command python.exe -ErrorAction Stop).Source
    $reader = Join-Path $PSScriptRoot "esc_reader.py"

    # Keep the isolated server alive after a direct-child test session exits,
    # and verify its pane can still receive input after the forced interrupt.
    $keeperLog = Join-Path $ctx.Home "keeper.log"
    & $PSMUX -L $ns new-session -d -s "force_keeper" -- $python $reader $keeperLog
    if ($LASTEXITCODE -ne 0) { throw "failed to create keeper session" }
    if (-not (Wait-ForLog -Path $keeperLog -Pattern "mode_ok=True")) {
        throw "keeper reader did not enter verified raw mode"
    }

    # Control: ordinary C-c is delivered as raw ETX and does not terminate a
    # raw-mode application.
    $ordinaryLog = Join-Path $ctx.Home "ordinary.log"
    & $PSMUX -L $ns new-session -d -s "force_ordinary" -- $python $reader $ordinaryLog
    if ($LASTEXITCODE -ne 0) { throw "failed to create ordinary C-c session" }
    if (-not (Wait-ForLog -Path $ordinaryLog -Pattern "new_mode=0x0200 actual_mode=0x0200 mode_ok=True")) {
        throw "ordinary C-c reader did not enter verified raw mode"
    }
    $ordinaryPid = [int](& $PSMUX -L $ns display-message -t "force_ordinary" -p '#{pane_pid}')
    & $PSMUX -L $ns send-keys -t "force_ordinary" C-c
    if ($LASTEXITCODE -ne 0) { throw "ordinary C-c command failed" }
    if (-not (Wait-ForLog -Path $ordinaryLog -Pattern "(?m)^RX 03\r?$")) {
        $observed = if (Test-Path $ordinaryLog) { (Get-Content $ordinaryLog -Raw).Trim() } else { "<missing log>" }
        throw "ordinary C-c did not reach the raw target as 0x03; observed: $observed"
    }
    if (-not (Get-Process -Id $ordinaryPid -ErrorAction SilentlyContinue)) {
        throw "ordinary C-c unexpectedly terminated the raw target"
    }
    Start-Sleep -Milliseconds 500
    & $PSMUX -L $ns send-keys -t "force_ordinary" x
    if (-not (Wait-ForLog -Path $ordinaryLog -Pattern "(?m)^RX 78\r?$")) {
        throw "ordinary C-c target did not remain responsive after the stability delay"
    }
    Write-Host "[PASS] ordinary C-c remains raw 0x03 and target survives"
    & $PSMUX -L $ns kill-session -t "force_ordinary" 2>&1 | Out-Null

    # Regression: forced C-c must use the proven Ctrl+Break route, terminate the
    # target, and avoid writing a raw ETX first.
    $forcedLog = Join-Path $ctx.Home "forced.log"
    & $PSMUX -L $ns new-session -d -s "force_forced" -- $python $reader $forcedLog
    if ($LASTEXITCODE -ne 0) { throw "failed to create forced C-c session" }
    if (-not (Wait-ForLog -Path $forcedLog -Pattern "new_mode=0x0200 actual_mode=0x0200 mode_ok=True")) {
        throw "forced C-c reader did not enter verified raw mode"
    }
    $forcedPid = [int](& $PSMUX -L $ns display-message -t "force_forced" -p '#{pane_pid}')
    & $PSMUX -L $ns send-keys -f -t "force_forced" C-c
    if ($LASTEXITCODE -ne 0) { throw "forced C-c command failed" }
    if (-not (Wait-ForProcessExit -Id $forcedPid)) {
        $observed = if (Test-Path $forcedLog) { (Get-Content $forcedLog -Raw).Trim() } else { "<missing reader log>" }
        throw "forced C-c did not terminate raw target PID $forcedPid; reader: $observed"
    }
    $forcedContents = Get-Content $forcedLog -Raw
    if ($forcedContents -match "(?m)^RX .*03") {
        throw "forced C-c leaked raw 0x03 before Ctrl+Break"
    }
    & $PSMUX -L $ns has-session -t "force_keeper" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "isolated server/keeper died with forced target" }
    & $PSMUX -L $ns send-keys -t "force_keeper" x
    if (-not (Wait-ForLog -Path $keeperLog -Pattern "(?m)^RX 78\r?$")) {
        throw "keeper pane stopped accepting input after forced Ctrl+C"
    }
    Write-Host "[PASS] forced C-c terminates raw target without raw 0x03 leakage"

    # Ctrl+Break is console-wide. Verify a foreground raw application exits but
    # the interactive shell hosting it returns and can execute another command.
    $shellLog = Join-Path $ctx.Home "shell_reader.log"
    $shellSentinel = Join-Path $ctx.Home "shell_survived.txt"
    & $PSMUX -L $ns new-session -d -s "force_shell" -- pwsh.exe -NoLogo -NoProfile
    if ($LASTEXITCODE -ne 0) { throw "failed to create shell-hosted force session" }
    $launchReader = "& '$python' '$reader' '$shellLog'"
    & $PSMUX -L $ns send-keys -l -t "force_shell" $launchReader
    & $PSMUX -L $ns send-keys -t "force_shell" Enter
    if (-not (Wait-ForLog -Path $shellLog -Pattern "new_mode=0x0200 actual_mode=0x0200 mode_ok=True")) {
        throw "shell-hosted reader did not enter verified raw mode"
    }
    & $PSMUX -L $ns send-keys -f -t "force_shell" C-c
    if ($LASTEXITCODE -ne 0) { throw "shell-hosted forced C-c command failed" }
    Start-Sleep -Milliseconds 500
    & $PSMUX -L $ns send-keys -l -t "force_shell" "Set-Content -LiteralPath '$shellSentinel' -Value survived"
    & $PSMUX -L $ns send-keys -t "force_shell" Enter
    $shellSurvived = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 8000) {
        if (Test-Path $shellSentinel) { $shellSurvived = $true; break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $shellSurvived) { throw "Ctrl+Break terminated or stranded the pane shell" }
    Write-Host "[PASS] forced C-c returns the same pane shell to a usable prompt"
}
catch {
    $failed = $true
    Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($null -eq $savedNoWarm) { Remove-Item Env:\PSMUX_NO_WARM -ErrorAction SilentlyContinue }
    else { $env:PSMUX_NO_WARM = $savedNoWarm }
    if ($null -ne $ctx) { Remove-PsmuxTestEnv -Ctx $ctx }
}

if ($failed) { exit 1 }
exit 0
