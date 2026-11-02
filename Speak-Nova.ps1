param(
    [Parameter(Mandatory = $true)][string]$Text,
    [int]$Rate = 0,
    [int]$Volume = 90
)

Add-Type -AssemblyName System.Speech
$speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
    $speaker.Rate = [math]::Max(-10, [math]::Min(10, $Rate))
    $speaker.Volume = [math]::Max(0, [math]::Min(100, $Volume))
    # Text is passed as a PowerShell parameter, never evaluated as code.
    $speaker.Speak($Text)
}
finally {
    $speaker.Dispose()
}
