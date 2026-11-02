<#
.SYNOPSIS
  Nova is a small, local Windows voice assistant.

.DESCRIPTION
  It recognizes ordinary speech through Windows' built-in System.Speech engine,
  routes only known command types, and launches only apps, folders, files, URIs,
  and modes defined in nova.config.json. It never evaluates a transcript as a
  PowerShell command.

.EXAMPLE
  .\Nova.ps1
  .\Nova.ps1 -Command 'Nova, search for rainy day recipes' -NoSpeech
  .\Nova.ps1 -Command 'Nova, open downloads' -DryRun -NoSpeech
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Command,
    [switch]$NoSpeech,
    [switch]$DryRun,
    [switch]$Hotkey,
    [switch]$ContinuousListening
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 evaluates parameter defaults before $PSScriptRoot is
# reliably populated when a script is launched with -File. Resolve it here so
# double-clicking Start-Nova.cmd and direct PowerShell calls behave identically.
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'nova.config.json'
}

$script:DryRun = [bool]$DryRun
$script:ShouldExit = $false
$script:PendingAction = $null
$script:QuietMode = $false
$script:Synthesizer = $null
$script:ConversationUntil = [datetime]::MinValue
$script:HotkeySettings = $null

function Write-NovaLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $stamp = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$stamp] $Message"
}

function Get-NovaProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Expand-NovaValue {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [Environment]::ExpandEnvironmentVariables($Value)
}

function Get-NovaConfigItem {
    param(
        [AllowNull()]$Collection,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Collection) { return $null }
    $property = $Collection.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Initialize-NovaConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Nova could not find its configuration file: $Path"
    }

    try {
        $loaded = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Nova could not read '$Path' as JSON. $($_.Exception.Message)"
    }

    foreach ($required in @('assistantName', 'apps', 'paths', 'modes', 'search')) {
        if ($null -eq (Get-NovaProperty -Object $loaded -Name $required)) {
            throw "Nova config is missing the '$required' section."
        }
    }

    $template = [string](Get-NovaProperty -Object $loaded.search -Name 'urlTemplate')
    if ([string]::IsNullOrWhiteSpace($template) -or -not $template.Contains('{query}')) {
        throw "Nova config search.urlTemplate must contain the placeholder {query}."
    }

    return $loaded
}

$script:Config = Initialize-NovaConfig -Path $ConfigPath

function Initialize-NovaVoice {
    if ($NoSpeech) { return }

    try {
        Add-Type -AssemblyName System.Speech
        $script:Synthesizer = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $voiceConfig = Get-NovaProperty -Object $script:Config -Name 'voice'
        $script:Synthesizer.Rate = [int](Get-NovaProperty -Object $voiceConfig -Name 'rate' -Default 0)
        $script:Synthesizer.Volume = [int](Get-NovaProperty -Object $voiceConfig -Name 'volume' -Default 90)
    }
    catch {
        Write-NovaLog "Speech output is unavailable: $($_.Exception.Message)"
        $script:Synthesizer = $null
    }
}

function Say-Nova {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-NovaLog "Nova: $Text"

    $behavior = Get-NovaProperty -Object $script:Config -Name 'behavior'
    $speechEnabled = [bool](Get-NovaProperty -Object $behavior -Name 'speak' -Default $true)
    if ($NoSpeech -or $script:QuietMode -or -not $speechEnabled -or $null -eq $script:Synthesizer) { return }

    try {
        # Synchronous speech prevents Nova from hearing its own answer on the next pass.
        $script:Synthesizer.Speak($Text)
    }
    catch {
        Write-NovaLog "Speech output failed: $($_.Exception.Message)"
    }
}

function Normalize-NovaText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $normalized = $Text.Trim().ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '[\u2018\u2019]', "'")
    $normalized = [regex]::Replace($normalized, '\s+', ' ')
    return $normalized.Trim(' ', ',', '.', '!', '?', ':', ';')
}

function Test-NovaActivationPhrase {
    param([Parameter(Mandatory = $true)][string]$Transcript)

    $normalized = Normalize-NovaText -Text $Transcript
    $assistantName = [regex]::Escape(([string](Get-NovaProperty -Object $script:Config -Name 'assistantName')).ToLowerInvariant())
    return [regex]::IsMatch($normalized, "^(?:hey\s+)?$assistantName$")
}

function Get-NovaRequiredConfidence {
    param([Parameter(Mandatory = $true)][string]$Transcript)

    $behavior = Get-NovaProperty -Object $script:Config -Name 'behavior'
    $minimumConfidence = [double](Get-NovaProperty -Object $behavior -Name 'minimumConfidence' -Default 0.45)
    if (-not (Test-NovaActivationPhrase -Transcript $Transcript)) { return $minimumConfidence }

    # The activation phrase cannot invoke a PC action by itself; it merely
    # opens a short conversation window after the user has held the hotkey.
    $hotkeyConfig = Get-NovaProperty -Object $script:Config -Name 'hotkey'
    return [double](Get-NovaProperty -Object $hotkeyConfig -Name 'activationMinimumConfidence' -Default 0.22)
}

function Resolve-NovaVirtualKey {
    param([Parameter(Mandatory = $true)][string]$Key)

    $keyName = ($Key.Trim().ToUpperInvariant() -replace '\s+', '')
    $functionKey = [regex]::Match($keyName, '^F(?<number>(?:[1-9]|1[0-2]))$')
    if ($functionKey.Success) {
        # Windows virtual keys: F1 is 112 through F12 at 123.
        return (111 + [int]$functionKey.Groups['number'].Value)
    }

    $namedKeys = @{
        'RIGHTCTRL' = 0xA3
        'RIGHTCONTROL' = 0xA3
        'LEFTCTRL' = 0xA2
        'LEFTCONTROL' = 0xA2
        'SCROLLLOCK' = 0x91
    }
    if ($namedKeys.ContainsKey($keyName)) { return [int]$namedKeys[$keyName] }

    if ($keyName -match '^\d{1,3}$') {
        $virtualKey = [int]$keyName
        if ($virtualKey -ge 1 -and $virtualKey -le 254) { return $virtualKey }
    }

    throw "Unsupported hotkey '$Key'. Use F1 through F12, Right Ctrl, Left Ctrl, Scroll Lock, or a Windows virtual-key number."
}

function Get-NovaHotkeySettings {
    if ($null -ne $script:HotkeySettings) { return $script:HotkeySettings }

    $hotkeyConfig = Get-NovaProperty -Object $script:Config -Name 'hotkey'
    $key = [string](Get-NovaProperty -Object $hotkeyConfig -Name 'key' -Default 'F8')
    $holdMilliseconds = [int](Get-NovaProperty -Object $hotkeyConfig -Name 'holdMilliseconds' -Default 500)
    $listenSeconds = [int](Get-NovaProperty -Object $hotkeyConfig -Name 'listenSeconds' -Default 8)
    $sessionSeconds = [int](Get-NovaProperty -Object $hotkeyConfig -Name 'sessionSeconds' -Default 60)

    if ($holdMilliseconds -lt 150 -or $holdMilliseconds -gt 3000) {
        throw 'hotkey.holdMilliseconds must be between 150 and 3000.'
    }
    if ($listenSeconds -lt 2 -or $listenSeconds -gt 30) {
        throw 'hotkey.listenSeconds must be between 2 and 30.'
    }
    if ($sessionSeconds -lt 15 -or $sessionSeconds -gt 600) {
        throw 'hotkey.sessionSeconds must be between 15 and 600.'
    }

    $script:HotkeySettings = [pscustomobject]@{
        Key = $key
        VirtualKey = Resolve-NovaVirtualKey -Key $key
        HoldMilliseconds = $holdMilliseconds
        ListenSeconds = $listenSeconds
        SessionSeconds = $sessionSeconds
    }
    return $script:HotkeySettings
}

function Test-NovaConversationActive {
    if ($script:ConversationUntil -gt (Get-Date)) { return $true }
    $script:ConversationUntil = [datetime]::MinValue
    return $false
}

function Start-NovaConversation {
    $settings = Get-NovaHotkeySettings
    $script:ConversationUntil = (Get-Date).AddSeconds($settings.SessionSeconds)
}

function Refresh-NovaConversation {
    if (-not (Test-NovaConversationActive)) { return }
    $settings = Get-NovaHotkeySettings
    $script:ConversationUntil = (Get-Date).AddSeconds($settings.SessionSeconds)
}

function Stop-NovaConversation {
    $script:ConversationUntil = [datetime]::MinValue
}

function Get-NovaCommandBody {
    param([Parameter(Mandatory = $true)][string]$Transcript)

    $normalized = Normalize-NovaText -Text $Transcript
    $requiresWakeWord = [bool](Get-NovaProperty -Object $script:Config -Name 'wakeWordRequired' -Default $true)
    $assistantName = [regex]::Escape([string](Get-NovaProperty -Object $script:Config -Name 'assistantName'))
    $match = [regex]::Match($normalized, "^(?:hey\s+)?$assistantName\b[\s,.:!\-]*(?<body>.*)$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    # During a deliberately started, short conversation, follow-up questions do
    # not need the wake word. An optional wake word is still stripped for a
    # natural mix of "search..." and "Nova, search...".
    if (Test-NovaConversationActive) {
        if ($match.Success) { return (Normalize-NovaText -Text $match.Groups['body'].Value) }
        return $normalized
    }

    if (-not $requiresWakeWord) { return $normalized }
    if (-not $match.Success) { return $null }
    return (Normalize-NovaText -Text $match.Groups['body'].Value)
}

function Confirm-NovaAction {
    param([Parameter(Mandatory = $true)]$Action, [Parameter(Mandatory = $true)][string]$Prompt)
    $script:PendingAction = $Action
    Say-Nova $Prompt
}

function Start-NovaTarget {
    param([Parameter(Mandatory = $true)][string]$Target, [string]$Description = $Target)

    $expandedTarget = Expand-NovaValue -Value $Target
    if ($script:DryRun) {
        Write-NovaLog "DRY RUN: would open $Description ($expandedTarget)"
        return $true
    }

    try {
        Start-Process -FilePath $expandedTarget | Out-Null
        Write-NovaLog "Opened $Description."
        return $true
    }
    catch {
        Write-NovaLog "Could not open $Description. $($_.Exception.Message)"
        return $false
    }
}

function Start-NovaApp {
    param([Parameter(Mandatory = $true)][string]$Alias)

    $app = Get-NovaConfigItem -Collection $script:Config.apps -Name $Alias
    if ($null -eq $app) { return $false }

    $started = Start-NovaTarget -Target ([string]$app) -Description "the $Alias app"
    if ($started) { Say-Nova "Opening $Alias." }
    return $true
}

function Start-NovaPath {
    param([Parameter(Mandatory = $true)][string]$Alias)

    $path = Get-NovaConfigItem -Collection $script:Config.paths -Name $Alias
    if ($null -eq $path) { return $false }

    $expandedPath = Expand-NovaValue -Value ([string]$path)
    if (-not (Test-Path -LiteralPath $expandedPath -PathType Container)) {
        Say-Nova "I could not find the $Alias folder."
        return $true
    }

    $started = Start-NovaTarget -Target $expandedPath -Description "the $Alias folder"
    if ($started) { Say-Nova "Opening $Alias." }
    return $true
}

function Search-NovaWeb {
    param([Parameter(Mandatory = $true)][string]$Query)

    $trimmedQuery = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedQuery)) {
        Say-Nova 'Tell me what you would like to search for.'
        return
    }

    $template = [string](Get-NovaProperty -Object $script:Config.search -Name 'urlTemplate')
    $url = $template.Replace('{query}', [uri]::EscapeDataString($trimmedQuery))
    if ($url -notmatch '^https?://') {
        Say-Nova 'The configured search address is not a web address, so I did not open it.'
        return
    }

    if (Start-NovaTarget -Target $url -Description "a web search for $trimmedQuery") {
        Say-Nova "Searching for $trimmedQuery."
    }
}

function Get-NovaFileMatches {
    param([Parameter(Mandatory = $true)][string]$Needle)

    $matches = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $blockedExtensions = @('.exe', '.msi', '.bat', '.cmd', '.ps1', '.vbs', '.js', '.jse', '.wsf', '.scr', '.com')
    $roots = @(Get-NovaProperty -Object $script:Config -Name 'fileSearchRoots' -Default @())
    $maximumFilesToInspect = 20000
    $deadline = (Get-Date).AddSeconds(8)
    $inspectedFiles = 0
    $script:LastFileSearchTruncated = $false

    foreach ($rootValue in $roots) {
        $root = Expand-NovaValue -Value ([string]$rootValue)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

        # A small breadth-first walk avoids an unbounded Get-ChildItem -Recurse
        # call on a large Downloads folder. Reparse points are skipped, so a
        # trusted folder cannot silently expand into a linked location.
        $directories = New-Object 'System.Collections.Generic.Queue[string]'
        $directories.Enqueue($root)
        while ($directories.Count -gt 0) {
            if ((Get-Date) -gt $deadline -or $inspectedFiles -ge $maximumFilesToInspect) {
                $script:LastFileSearchTruncated = $true
                return $matches.ToArray()
            }

            $currentDirectory = $directories.Dequeue()
            try {
                $directoryInfo = New-Object System.IO.DirectoryInfo($currentDirectory)
                if (($directoryInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

                foreach ($file in $directoryInfo.GetFiles()) {
                    $inspectedFiles++
                    if ((Get-Date) -gt $deadline -or $inspectedFiles -ge $maximumFilesToInspect) {
                        $script:LastFileSearchTruncated = $true
                        return $matches.ToArray()
                    }
                    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    if ($file.Extension -in $blockedExtensions) { continue }
                    if ($file.Name.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                    $matches.Add($file)
                    if ($matches.Count -ge 5) { return $matches.ToArray() }
                }

                foreach ($childDirectory in $directoryInfo.GetDirectories()) {
                    if (($childDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $directories.Enqueue($childDirectory.FullName)
                    }
                }
            }
            catch [System.UnauthorizedAccessException] {
                continue
            }
            catch [System.IO.IOException] {
                continue
            }
            catch {
                Write-NovaLog "Could not fully search $currentDirectory. $($_.Exception.Message)"
                continue
            }
        }
    }

    return $matches.ToArray()
}

function Open-NovaFile {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    if (-not (Test-Path -LiteralPath $File.FullName -PathType Leaf)) {
        Say-Nova 'That file is no longer available.'
        return
    }

    if (Start-NovaTarget -Target $File.FullName -Description "the file $($File.Name)") {
        Say-Nova "Opening $($File.Name)."
    }
}

function Open-NovaExplorerSearch {
    param([Parameter(Mandatory = $true)][string]$Query)

    # search-ms uses the Windows Search index when it is available. It is a
    # useful, visible fallback when a quick trusted-folder walk has not located
    # a match yet; it never runs a user-provided command.
    $uri = 'search-ms:query={0}&displayname={1}' -f `
        [uri]::EscapeDataString($Query), `
        [uri]::EscapeDataString("Nova search: $Query")
    return (Start-NovaTarget -Target $uri -Description "a File Explorer search for $Query")
}

function Find-NovaFile {
    param([Parameter(Mandatory = $true)][string]$Query)

    $needle = $Query.Trim(' ', '"', "'")
    if ([string]::IsNullOrWhiteSpace($needle)) {
        Say-Nova 'Tell me the file name or part of its name.'
        return
    }

    Say-Nova "Looking for $needle."
    $matches = @(Get-NovaFileMatches -Needle $needle)
    if ($matches.Count -eq 0) {
        if ($script:LastFileSearchTruncated) {
            if (Open-NovaExplorerSearch -Query $needle) {
                Say-Nova "I did not find $needle quickly in your trusted folders, so I opened a File Explorer search."
            }
        }
        else {
            if (Open-NovaExplorerSearch -Query $needle) {
                Say-Nova "I could not find a safe direct match, so I opened a File Explorer search for $needle."
            }
        }
        return
    }

    if ($matches.Count -eq 1) {
        $file = $matches[0]
        $confirm = [bool](Get-NovaProperty -Object (Get-NovaProperty -Object $script:Config -Name 'behavior') -Name 'confirmFileOpens' -Default $true)
        if ($confirm) {
            Confirm-NovaAction -Action @{ Type = 'OpenFile'; File = $file } -Prompt "I found $($file.Name). Say Nova, confirm to open it, or Nova, cancel."
        }
        else {
            Open-NovaFile -File $file
        }
        return
    }

    Write-NovaLog 'File choices:'
    for ($index = 0; $index -lt $matches.Count; $index++) {
        Write-NovaLog ("  {0}. {1}" -f ($index + 1), $matches[$index].FullName)
    }
    Confirm-NovaAction -Action @{ Type = 'ChooseFile'; Files = $matches } -Prompt "I found $($matches.Count) files. Say Nova, choose 1 through $($matches.Count), or Nova, cancel."
}

function Start-NovaUri {
    param([Parameter(Mandatory = $true)][string]$Uri, [Parameter(Mandatory = $true)][string]$Description)

    # Declarative mode/task actions may open only web URLs and familiar Windows
    # protocol handlers. This prevents a config typo from turning into a shell
    # invocation via a spoken task name.
    if ($Uri -notmatch '^(?:https?|ms-settings|ms-clock|search-ms):') {
        Write-NovaLog "Skipped unsupported URI scheme in $Description."
        return $false
    }
    return (Start-NovaTarget -Target $Uri -Description $Description)
}

function Invoke-NovaActions {
    param(
        [AllowNull()]$Actions,
        [Parameter(Mandatory = $true)][string]$Context
    )

    foreach ($action in @($Actions)) {
        $type = [string](Get-NovaProperty -Object $action -Name 'type')
        $target = [string](Get-NovaProperty -Object $action -Name 'target')
        if ([string]::IsNullOrWhiteSpace($type) -or [string]::IsNullOrWhiteSpace($target)) {
            Write-NovaLog "Skipped an incomplete action in $Context."
            continue
        }
        switch ($type.ToLowerInvariant()) {
            'app' { [void](Start-NovaApp -Alias $target) }
            'path' { [void](Start-NovaPath -Alias $target) }
            'uri' { [void](Start-NovaUri -Uri $target -Description $Context) }
            default { Write-NovaLog "Skipped unsupported $Context action '$type'." }
        }
    }
}

function Invoke-NovaMode {
    param([Parameter(Mandatory = $true)][string]$ModeName)

    $mode = Get-NovaConfigItem -Collection $script:Config.modes -Name $ModeName
    if ($null -eq $mode) { return $false }

    $silence = Get-NovaProperty -Object $mode -Name 'silence'
    if ($null -ne $silence) { $script:QuietMode = [bool]$silence }

    $modeMessage = [string](Get-NovaProperty -Object $mode -Name 'say' -Default "Starting $ModeName mode.")
    # Speak the quiet-mode acknowledgement before muting later replies.
    if ($ModeName -ieq 'quiet' -and -not $NoSpeech -and $null -ne $script:Synthesizer) {
        $previousQuietMode = $script:QuietMode
        $script:QuietMode = $false
        Say-Nova $modeMessage
        $script:QuietMode = $previousQuietMode
    }
    else {
        Say-Nova $modeMessage
    }

    Invoke-NovaActions -Actions (Get-NovaProperty -Object $mode -Name 'actions' -Default @()) -Context "$ModeName mode"
    return $true
}

function Invoke-NovaTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [switch]$Confirmed
    )

    $tasks = Get-NovaProperty -Object $script:Config -Name 'tasks'
    $task = Get-NovaConfigItem -Collection $tasks -Name $TaskName
    if ($null -eq $task) { return $false }

    $behavior = Get-NovaProperty -Object $script:Config -Name 'behavior'
    $confirmTasks = [bool](Get-NovaProperty -Object $behavior -Name 'confirmTasks' -Default $true)
    if ($confirmTasks -and -not $Confirmed) {
        Confirm-NovaAction -Action @{ Type = 'RunTask'; TaskName = $TaskName } -Prompt "I can run $TaskName. Say Nova, confirm or Nova, cancel."
        return $true
    }

    $taskMessage = [string](Get-NovaProperty -Object $task -Name 'say' -Default "Running $TaskName.")
    Say-Nova $taskMessage
    Invoke-NovaActions -Actions (Get-NovaProperty -Object $task -Name 'actions' -Default @()) -Context "the $TaskName task"
    return $true
}

function Show-NovaHelp {
    $name = [string](Get-NovaProperty -Object $script:Config -Name 'assistantName')
    $apps = @($script:Config.apps.PSObject.Properties.Name) -join ', '
    $paths = @($script:Config.paths.PSObject.Properties.Name) -join ', '
    $modes = @($script:Config.modes.PSObject.Properties.Name) -join ', '
    $tasks = Get-NovaProperty -Object $script:Config -Name 'tasks'
    $taskNames = if ($null -eq $tasks) { '' } else { @($tasks.PSObject.Properties.Name) -join ', ' }
    Say-Nova "Try: $name, open Notepad; $name, search for the weather; $name, find budget; $name, focus mode; or $name, run start work."
    Write-NovaLog "Available apps: $apps"
    Write-NovaLog "Available folders: $paths"
    Write-NovaLog "Available modes: $modes"
    if (-not [string]::IsNullOrWhiteSpace($taskNames)) { Write-NovaLog "Available run tasks: $taskNames" }
}

function Invoke-NovaPendingAction {
    param([Parameter(Mandatory = $true)][string]$Input)

    $pending = $script:PendingAction
    if ($null -eq $pending) { return $false }

    if ($Input -match '^(?:cancel|no|never mind|nevermind)$') {
        $script:PendingAction = $null
        Say-Nova 'Cancelled.'
        return $true
    }

    if ($pending.Type -eq 'OpenFile' -and $Input -match '^(?:confirm|yes|open it|do it)$') {
        $script:PendingAction = $null
        Open-NovaFile -File $pending.File
        return $true
    }

    if ($pending.Type -eq 'RunTask' -and $Input -match '^(?:confirm|yes|do it)$') {
        $script:PendingAction = $null
        if (-not (Invoke-NovaTask -TaskName $pending.TaskName -Confirmed)) {
            Say-Nova "That task is no longer available."
        }
        return $true
    }

    if ($pending.Type -eq 'ChooseFile' -and $Input -match '^(?:choose |option |number )?(?<number>[1-5])$') {
        $choice = [int]$Matches['number']
        if ($choice -le $pending.Files.Count) {
            $file = $pending.Files[$choice - 1]
            $script:PendingAction = $null
            Open-NovaFile -File $file
            return $true
        }
    }

    Say-Nova 'Please say confirm, cancel, or choose a numbered file.'
    return $true
}

function Invoke-NovaCommand {
    param([Parameter(Mandatory = $true)][string]$Transcript)

    Write-NovaLog "Heard: $Transcript"
    $wasInConversation = Test-NovaConversationActive
    $isActivationPhrase = (-not $wasInConversation -and (Test-NovaActivationPhrase -Transcript $Transcript))
    if ($isActivationPhrase) {
        Start-NovaConversation
        Say-Nova 'I hear you. What would you like to do?'
        return
    }
    $body = Get-NovaCommandBody -Transcript $Transcript
    if ($null -eq $body -or [string]::IsNullOrWhiteSpace($body)) {
        return
    }

    if ($wasInConversation) { Refresh-NovaConversation }

    if (Invoke-NovaPendingAction -Input $body) { return }

    if ($body -match '^(?:can\s+)?you\s+hear\s+me$') {
        Start-NovaConversation
        Say-Nova 'I hear you. What would you like to do?'
        return
    }

    if ($body -match '^(?:help|what can you do|commands)$') {
        Show-NovaHelp
        return
    }

    if ($body -match '^(?:exit|quit|goodbye)$') {
        Say-Nova 'Goodbye.'
        $script:ShouldExit = $true
        return
    }

    if ($body -match '^(?:stop listening|end (?:the )?(?:session|conversation))$') {
        if (Test-NovaConversationActive) {
            Stop-NovaConversation
            Say-Nova 'Conversation ended. Hold the hotkey when you want to talk again.'
        }
        else {
            Say-Nova 'Goodbye.'
            $script:ShouldExit = $true
        }
        return
    }

    if ($body -match '^(?:run|launch)(?:\s+task)?\s+(?<task>.+)$') {
        $taskName = $Matches['task'].Trim()
        if (Invoke-NovaTask -TaskName $taskName) { return }
        $tasks = Get-NovaProperty -Object $script:Config -Name 'tasks'
        $taskNames = if ($null -eq $tasks) { '' } else { @($tasks.PSObject.Properties.Name) -join ', ' }
        if ([string]::IsNullOrWhiteSpace($taskNames)) {
            Say-Nova 'I do not have any safe run tasks configured yet.'
        }
        else {
            Say-Nova "I only run named tasks from your config. Available tasks are: $taskNames."
        }
        return
    }

    if ($body -match '^(?:search(?: for)?|look up|google)\s+(?<query>.+)$') {
        Search-NovaWeb -Query $Matches['query']
        return
    }

    if ($body -match "^(?:what(?:'s| is)? )?(?:the )?time(?: is it)?\??$") {
        Say-Nova ("It is {0}." -f (Get-Date -Format 'h:mm tt'))
        return
    }

    if ($body -match "^(?:what(?:'s| is)? )?(?:the )?date(?: today)?\??$") {
        Say-Nova ("Today is {0}." -f (Get-Date -Format 'dddd, MMMM d'))
        return
    }

    # Nova has no cloud language model in this local-first build. During an
    # explicitly opened conversation, route everyday question forms to a
    # normal browser search instead of trying to infer a system action.
    $behavior = Get-NovaProperty -Object $script:Config -Name 'behavior'
    $searchQuestions = [bool](Get-NovaProperty -Object $behavior -Name 'searchQuestionsInConversation' -Default $true)
    if ($wasInConversation -and $searchQuestions -and $body -match '^(?:what|who|when|where|why|how|tell me about|explain|define)\b') {
        Search-NovaWeb -Query $body
        return
    }

    if ($body -match '^(?:find|locate)\s+(?:file\s+)?(?<query>.+)$') {
        Find-NovaFile -Query $Matches['query']
        return
    }

    if ($body -match '^(?:activate|start|turn on|enable)\s+(?<mode>.+)$') {
        $modeName = ($Matches['mode'] -replace '\s+mode$', '').Trim()
        if (Invoke-NovaMode -ModeName $modeName) { return }
    }

    if ($body -match '^(?<mode>.+?)\s+mode$') {
        if (Invoke-NovaMode -ModeName $Matches['mode']) { return }
    }

    if ($body -match '^open\s+(?<target>.+)$') {
        $target = ($Matches['target'] -replace '^(?:my |the )', '').Trim()
        $target = ($target -replace '\s+folder$', '').Trim()
        if (Start-NovaApp -Alias $target) { return }
        if (Start-NovaPath -Alias $target) { return }
        Find-NovaFile -Query $target
        return
    }

    if ($body -match '^(?:cancel|never mind|nevermind)$') {
        Say-Nova 'There is nothing to cancel.'
        return
    }

    Say-Nova "I did not recognize that as a safe command. Say $((Get-NovaProperty -Object $script:Config -Name 'assistantName')), help for examples."
}

function New-NovaRecognizer {
    try {
        Add-Type -AssemblyName System.Speech
        $recognizer = New-Object System.Speech.Recognition.SpeechRecognitionEngine
        $recognizer.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
        # Give the short activation phrase its own grammar. Dictation remains
        # loaded for ordinary questions and commands, while this grammar helps
        # Windows recognize the phrase consistently.
        $activationChoices = New-Object System.Speech.Recognition.Choices
        [void]$activationChoices.Add('nova')
        $activationBuilder = New-Object System.Speech.Recognition.GrammarBuilder
        $activationBuilder.Append($activationChoices)
        $recognizer.LoadGrammar((New-Object System.Speech.Recognition.Grammar($activationBuilder)))
        $recognizer.SetInputToDefaultAudioDevice()
        $recognizer.InitialSilenceTimeout = [TimeSpan]::FromSeconds(8)
        $recognizer.BabbleTimeout = [TimeSpan]::FromSeconds(5)
        $recognizer.EndSilenceTimeout = [TimeSpan]::FromMilliseconds(700)
        return $recognizer
    }
    catch {
        throw "Nova could not start the microphone. Check that a default recording device and the Windows speech language are available. $($_.Exception.Message)"
    }
}

function Receive-NovaUtterance {
    param(
        [Parameter(Mandatory = $true)]$Recognizer,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    try {
        $result = $Recognizer.Recognize([TimeSpan]::FromSeconds($TimeoutSeconds))
    }
    catch {
        Write-NovaLog "Microphone listening stopped: $($_.Exception.Message)"
        return $false
    }

    if ($null -eq $result) { return $false }
    $minimumConfidence = Get-NovaRequiredConfidence -Transcript $result.Text
    if ($result.Confidence -lt $minimumConfidence) {
        Write-NovaLog ("Ignored low-confidence speech ({0:P0}): {1}" -f $result.Confidence, $result.Text)
        return $false
    }

    Invoke-NovaCommand -Transcript $result.Text
    return $true
}

function Initialize-NovaKeyboard {
    if ($null -ne ('Nova.NativeKeyboard' -as [type])) { return }

    $definition = 'using System; using System.Runtime.InteropServices; namespace Nova { public static class NativeKeyboard { [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int virtualKey); } }'
    Add-Type -TypeDefinition $definition
}

function Test-NovaKeyDown {
    param([Parameter(Mandatory = $true)][int]$VirtualKey)
    $state = [Nova.NativeKeyboard]::GetAsyncKeyState($VirtualKey)
    return (([int]$state -band 0x8000) -ne 0)
}

function Wait-NovaHotkeyHold {
    param(
        [Parameter(Mandatory = $true)][int]$VirtualKey,
        [Parameter(Mandatory = $true)][int]$HoldMilliseconds
    )

    $pressedAt = $null
    while (-not $script:ShouldExit) {
        if (Test-NovaKeyDown -VirtualKey $VirtualKey) {
            if ($null -eq $pressedAt) {
                $pressedAt = Get-Date
            }
            elseif (((Get-Date) - $pressedAt).TotalMilliseconds -ge $HoldMilliseconds) {
                return $true
            }
        }
        else {
            $pressedAt = $null
        }
        Start-Sleep -Milliseconds 30
    }
    return $false
}

function Wait-NovaKeyRelease {
    param([Parameter(Mandatory = $true)][int]$VirtualKey)

    while (-not $script:ShouldExit -and (Test-NovaKeyDown -VirtualKey $VirtualKey)) {
        Start-Sleep -Milliseconds 30
    }
}

function Start-NovaHotkeyListening {
    param([Parameter(Mandatory = $true)]$Recognizer)

    $settings = Get-NovaHotkeySettings
    $name = [string](Get-NovaProperty -Object $script:Config -Name 'assistantName')
    Initialize-NovaKeyboard

    Write-NovaLog "On standby. Hold $($settings.Key) for $($settings.HoldMilliseconds) ms, release it, then say '$name'."
    Say-Nova "Nova is on standby. Hold $($settings.Key), then say $name."

    while (-not $script:ShouldExit) {
        if (Test-NovaConversationActive) {
            $remaining = [math]::Ceiling(($script:ConversationUntil - (Get-Date)).TotalSeconds)
            $timeout = [math]::Max(1, [math]::Min(5, [int]$remaining))
            [void](Receive-NovaUtterance -Recognizer $Recognizer -TimeoutSeconds $timeout)
            if (-not (Test-NovaConversationActive) -and -not $script:ShouldExit) {
                Say-Nova "I'm back on standby. Hold $($settings.Key) when you want to talk again."
            }
            continue
        }

        if (-not (Wait-NovaHotkeyHold -VirtualKey $settings.VirtualKey -HoldMilliseconds $settings.HoldMilliseconds)) { break }
        Wait-NovaKeyRelease -VirtualKey $settings.VirtualKey
        if ($script:ShouldExit) { break }

        Say-Nova 'Listening.'
        [void](Receive-NovaUtterance -Recognizer $Recognizer -TimeoutSeconds $settings.ListenSeconds)
    }
}

function Start-NovaContinuousListening {
    param([Parameter(Mandatory = $true)]$Recognizer)

    $name = [string](Get-NovaProperty -Object $script:Config -Name 'assistantName')
    Write-NovaLog "Listening continuously. Say '$name, help' for examples. Press Ctrl+C to stop."
    Say-Nova "Nova is listening. Say $name, help when you need me."

    while (-not $script:ShouldExit) {
        try {
            $result = $Recognizer.Recognize()
        }
        catch {
            Write-NovaLog "Microphone listening stopped: $($_.Exception.Message)"
            break
        }
        if ($null -eq $result) { continue }
        $minimumConfidence = Get-NovaRequiredConfidence -Transcript $result.Text
        if ($result.Confidence -lt $minimumConfidence) {
            Write-NovaLog ("Ignored low-confidence speech ({0:P0}): {1}" -f $result.Confidence, $result.Text)
            continue
        }
        Invoke-NovaCommand -Transcript $result.Text
    }
}

function Start-Nova {
    if ($Hotkey -and $ContinuousListening) {
        throw 'Use either -Hotkey or -ContinuousListening, not both.'
    }

    Initialize-NovaVoice
    $recognizer = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($Command)) {
            Invoke-NovaCommand -Transcript $Command
            return
        }

        $recognizer = New-NovaRecognizer
        if ($ContinuousListening) {
            Start-NovaContinuousListening -Recognizer $recognizer
        }
        else {
            # Hotkey mode is the default. -Hotkey is accepted for clarity when
            # launching Nova from another shortcut or automation.
            Start-NovaHotkeyListening -Recognizer $recognizer
        }
    }
    finally {
        if ($null -ne $recognizer) { $recognizer.Dispose() }
        if ($null -ne $script:Synthesizer) { $script:Synthesizer.Dispose() }
    }
}

Start-Nova
