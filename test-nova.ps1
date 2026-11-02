<#
  Smoke tests that do not launch any application or speak aloud.
  Run: powershell -ExecutionPolicy Bypass -File .\test-nova.ps1
#>

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$nova = Join-Path $root 'Nova.ps1'
$windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$cases = @(
    @{ Input = 'Nova, help'; Expected = 'Available apps:' },
    @{ Input = 'Nova, search for milk & bread'; Expected = 'DRY RUN: would open a web search for milk & bread' },
    @{ Input = 'Nova, open calculator'; Expected = 'DRY RUN: would open the calculator app' },
    @{ Input = 'Nova, focus mode'; Expected = 'DRY RUN: would open focus mode' },
    @{ Input = 'Nova, run start work'; Expected = 'I can run start work.' },
    @{ Input = 'Nova, run delete everything'; Expected = 'I only run named tasks from your config.' },
    @{ Input = 'Nova'; Expected = 'I hear you. What would you like to do?' },
    @{ Input = 'Nova, you hear me?'; Expected = 'I hear you. What would you like to do?' },
    @{ Input = 'A random sentence'; Expected = 'Heard: A random sentence' }
)

$failures = @()
foreach ($case in $cases) {
    # Nova writes its activity to the Information stream via Write-Host, so
    # capture every stream rather than only success/error output.
    # Use -File as the launcher does, which also checks Nova's config-path
    # resolution in Windows PowerShell 5.1.
    $output = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $nova -Command $case.Input -DryRun -NoSpeech *>&1 | Out-String
    if ($output -notmatch [regex]::Escape($case.Expected)) {
        $failures += "'$($case.Input)' did not produce '$($case.Expected)'. Actual output: $output"
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Nova smoke tests passed ($($cases.Count) cases)."
