<#
.SYNOPSIS
	Runs every check CLAUDE.md §6 lists, in one command, from anywhere.

.DESCRIPTION
	    pwsh scripts/check.ps1              everything
	    pwsh scripts/check.ps1 -Only fuzz   only steps whose name contains "fuzz"
	    pwsh scripts/check.ps1 -Show        print every step's full output, not only failures

	Every step runs even after one fails, so one run reports the whole picture; the exit code is
	the number of failed steps. A step's output is shown only when it fails, otherwise one line.

	The runtime list is read from tests/*_runtime.luau rather than written here, because a hand-kept
	list drifts (CLAUDE.md §9): the one file that cannot run under lune, roblox_runtime, is the only
	exclusion, and the script says so at the end — the Studio half is the half that goes red quietly.

	PowerShell rather than bash because on this machine `bash` from pwsh is WSL's, which cannot
	see the rokit shims; Git Bash exists but is not on pwsh's PATH. From Git Bash this still runs as
	`pwsh scripts/check.ps1`.
#>
[CmdletBinding()]
param(
	[string] $Only = "",
	[switch] $Show
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

try {
	$steps = [System.Collections.Generic.List[object]]::new()

	function Add-Step([string] $name, [string[]] $command) {
		$steps.Add([pscustomobject]@{ Name = $name; Command = $command })
	}

	Add-Step "analyze" @("lune", "run", "analyze")

	Get-ChildItem "tests" -Filter "*_runtime.luau" |
		Sort-Object Name |
		Where-Object { $_.BaseName -ne "roblox_runtime" } |
		ForEach-Object { Add-Step $_.BaseName @("lune", "run", "tests/$($_.BaseName)") }

	Add-Step "tools/messages" @("lune", "run", "tools/messages")
	Add-Step "tools/exports" @("lune", "run", "tools/exports")
	Add-Step "bench/envelope" @("lune", "run", "bench/envelope")
	Add-Step "bench/check" @("lune", "run", "bench/check")
	Add-Step "stylua" @("stylua", "--check", "src", "tests", "analyze.luau", "bench", "spike")
	Add-Step "selene" @("selene", "src", "tests")

	if ($Only -ne "") {
		$steps = $steps | Where-Object { $_.Name -like "*$Only*" }
		if (-not $steps) {
			Write-Host "no step matches '$Only'" -ForegroundColor Red
			exit 1
		}
	}

	$failed = [System.Collections.Generic.List[string]]::new()
	$width = ($steps | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
	$clock = [System.Diagnostics.Stopwatch]::StartNew()

	foreach ($step in $steps) {
		$started = $clock.Elapsed
		$exe, $rest = $step.Command
		# A missing executable is a terminating error under `pwsh -File`: the first version of this
		# script died on it with exit 0 and no summary, and the version before that read it as green,
		# because $LASTEXITCODE kept the previous step's value (both measured). So: catch it, and
		# start every step from a sentinel so "did not run" cannot read as "passed".
		$global:LASTEXITCODE = -1
		try {
			$output = & $exe @rest 2>&1 | ForEach-Object { "$_" }
			$code = $LASTEXITCODE
		} catch {
			$output = @("$_")
			$code = -1
		}
		$seconds = ($clock.Elapsed - $started).TotalSeconds.ToString("0.0")
		$label = $step.Name.PadRight($width)

		if ($code -eq 0) {
			Write-Host ("OK    {0}  {1,6}s" -f $label, $seconds) -ForegroundColor Green
			if ($Show) { $output | ForEach-Object { Write-Host "      $_" } }
		} else {
			$failed.Add($step.Name)
			Write-Host ("FAIL  {0}  {1,6}s  (exit {2})" -f $label, $seconds, $code) -ForegroundColor Red
			$output | ForEach-Object { Write-Host "      $_" }
		}
	}

	Write-Host ""

	if ($failed.Count -eq 0) {
		Write-Host ("all {0} steps green in {1:0.0}s" -f $steps.Count, $clock.Elapsed.TotalSeconds) -ForegroundColor Green
	} else {
		Write-Host ("{0} of {1} steps failed: {2}" -f $failed.Count, $steps.Count, ($failed -join ", ")) -ForegroundColor Red
	}

	Write-Host "not run: tests/roblox_runtime.luau needs Studio (CLAUDE.md section 9)" -ForegroundColor DarkGray

	exit $failed.Count
} finally {
	Pop-Location
}
