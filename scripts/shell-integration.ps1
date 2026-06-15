# ADtention Terminal PowerShell integration.
# This file is intended to be dot-sourced from a PowerShell profile.

function Get-AdtentionCache {
    if ($env:ADTENTION_CACHE) {
        return $env:ADTENTION_CACHE
    }

    $claudeCache = Join-Path $HOME ".claude/adtention"
    if (Test-Path -LiteralPath $claudeCache) {
        return $claudeCache
    }

    return (Join-Path $HOME ".adtention")
}

function Test-AdtentionShouldTriggerEnter {
    param(
        [AllowNull()]
        [string] $CommandText
    )

    if ([string]::IsNullOrWhiteSpace($CommandText)) {
        return $false
    }

    $trimmed = $CommandText.Trim()
    if ($trimmed.StartsWith("#")) {
        return $false
    }

    $firstToken = ($trimmed -split '\s+', 2)[0].Trim('"', "'")
    $commandName = Split-Path -Leaf $firstToken
    $ownCommands = @(
        "adtention-open",
        "adtention-open.exe",
        "adtention-refresh",
        "adtention-refresh.exe",
        "adtention-terminal",
        "adtention-terminal.exe",
        "learn-more"
    )

    return $ownCommands -notcontains $commandName
}

function New-AdtentionEnterEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CommandText,

        [string] $Cwd = (Get-Location).ProviderPath
    )

    [ordered] @{
        source = "terminal-enter"
        shell = "powershell"
        command = $CommandText
        cwd = $Cwd
    }
}

function ConvertTo-AdtentionJson {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        $Event
    )

    process {
        $Event | ConvertTo-Json -Compress -Depth 6
    }
}

function Get-AdtentionCurrentLine {
    [string] $line = ""
    [int] $cursor = 0

    try {
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref] $line, [ref] $cursor)
        return $line
    } catch {
        return ""
    }
}

function Start-AdtentionRefreshJob {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Json,

        [Parameter(Mandatory = $true)]
        [string] $Cwd
    )

    $binary = if ($env:ADTENTION_BINARY) { $env:ADTENTION_BINARY } else { "adtention-terminal" }

    try {
        Start-Job -Name "adtention-terminal-refresh" -ArgumentList $binary, $Cwd, $Json -ScriptBlock {
            param(
                [string] $Binary,
                [string] $WorkingDirectory,
                [string] $Payload
            )

            try {
                $Payload | & $Binary refresh $WorkingDirectory *> $null
            } catch {
            }
        } | Out-Null
    } catch {
    }
}

function Start-AdtentionUpdateJob {
    if ($env:ADTENTION_AUTO_UPDATE -eq "0") {
        return
    }

    $binary = if ($env:ADTENTION_BINARY) { $env:ADTENTION_BINARY } else { "adtention-terminal" }

    try {
        Start-Job -Name "adtention-terminal-update" -ArgumentList $binary -ScriptBlock {
            param(
                [string] $Binary
            )

            try {
                & $Binary update *> $null
            } catch {
            }
        } | Out-Null
    } catch {
    }
}

function Invoke-AdtentionEnterRefresh {
    $commandText = Get-AdtentionCurrentLine
    if (-not (Test-AdtentionShouldTriggerEnter $commandText)) {
        return
    }

    $cwd = (Get-Location).ProviderPath
    if ([string]::IsNullOrWhiteSpace($cwd)) {
        $cwd = (Get-Location).Path
    }

    $event = New-AdtentionEnterEvent -CommandText $commandText -Cwd $cwd
    $json = ConvertTo-AdtentionJson $event
    Start-AdtentionRefreshJob -Json $json -Cwd $cwd
}

function Invoke-AdtentionPromptDisplay {
    $cache = Get-AdtentionCache
    $terminalFile = Join-Path $cache "terminal.txt"
    if (-not (Test-Path -LiteralPath $terminalFile)) {
        return
    }

    $rows = @(Get-Content -LiteralPath $terminalFile -TotalCount 2 -ErrorAction SilentlyContinue)
    $title = if ($rows.Count -ge 1) { [string] $rows[0] } else { "" }
    $line = if ($rows.Count -ge 2) { [string] $rows[1] } else { "" }

    if ($title) {
        try {
            $host.UI.RawUI.WindowTitle = $title
        } catch {
        }
    }

    try {
        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $cache "last_render_seen"),
            [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString(),
            [System.Text.Encoding]::ASCII
        )
    } catch {
    }

    if ($line -and $env:ADTENTION_PROMPT_LINE -ne "0") {
        Write-Host $line
    }
}

function Enable-AdtentionPowerShellIntegration {
    if ($env:ADTENTION_DISABLE_KEYBINDING -eq "1") {
        return
    }

    if (-not (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue)) {
        return
    }

    try {
        $null = [Microsoft.PowerShell.PSConsoleReadLine]
    } catch {
        return
    }

    try {
        Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
            param($key, $arg)

            try {
                Invoke-AdtentionEnterRefresh
            } catch {
            }

            [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        }
    } catch {
    }
}

function Enable-AdtentionPromptDisplay {
    if (-not $Global:AdtentionTerminalOriginalPrompt) {
        $Global:AdtentionTerminalOriginalPrompt = if (Test-Path Function:\prompt) {
            (Get-Command prompt).ScriptBlock
        } else {
            { "PS $($executionContext.SessionState.Path.CurrentLocation)> " }
        }
    }

    function global:prompt {
        Invoke-AdtentionPromptDisplay
        & $Global:AdtentionTerminalOriginalPrompt
    }
}

Start-AdtentionUpdateJob
Enable-AdtentionPromptDisplay
Enable-AdtentionPowerShellIntegration

function global:learn-more {
    & adtention-terminal learn-more @args
}
