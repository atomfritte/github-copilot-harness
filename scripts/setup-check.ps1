<#
.SYNOPSIS
    Checks whether this machine and repository are ready for the GitHub Copilot harness,
    and offers to fix what can be fixed automatically.

.DESCRIPTION
    Read-only by default until you confirm. The script checks:
      1. Tools:        VS Code, Node.js, Git
      2. Repository:   harness files, hook configuration, skills, agents, hook tests
      3. VS Code:      user settings that affect the harness
      4. Organisation: VS Code device policies and other hook sources (best effort)

    At the end it lists the fixes it can apply and asks before changing anything.
    Every settings file is backed up next to the original before it is edited.

    Works in Windows PowerShell 5.1 and PowerShell 7+ on Windows, macOS and Linux.
    This file is ASCII only on purpose: Windows PowerShell 5.1 misreads UTF-8 without a BOM.

.PARAMETER Fix
    Apply all recommended fixes without asking. Optional fixes are still skipped.

.PARAMETER CheckOnly
    Report only. Never ask and never change anything.

.PARAMETER SkipTests
    Do not run the hook test suite.

.PARAMETER Insiders
    Check VS Code Insiders (code-insiders and its settings folder) instead of stable.

.PARAMETER RepoRoot
    Repository to check. Defaults to the parent folder of this script.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup-check.ps1

.EXAMPLE
    pwsh scripts/setup-check.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$CheckOnly,
    [switch]$SkipTests,
    [switch]$Insiders,
    [string]$RepoRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$MinVsCode = [version]'1.147.0'
$MinNodeMajor = 18

# ---------------------------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------------------------

$onWindows = $true
$onMac = $false
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $onWindows = [bool]$IsWindows
    $onMac = [bool]$IsMacOS
}

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$codeCommand = 'code'
$codeFolder = 'Code'
if ($Insiders) {
    $codeCommand = 'code-insiders'
    $codeFolder = 'Code - Insiders'
}

if ($onWindows) {
    $userSettingsPath = Join-Path (Join-Path (Join-Path $env:APPDATA $codeFolder) 'User') 'settings.json'
} elseif ($onMac) {
    $userSettingsPath = Join-Path $HOME "Library/Application Support/$codeFolder/User/settings.json"
} else {
    $configHome = $env:XDG_CONFIG_HOME
    if (-not $configHome) { $configHome = Join-Path $HOME '.config' }
    $userSettingsPath = Join-Path $configHome "$codeFolder/User/settings.json"
}

$copilotHome = $env:COPILOT_HOME
if (-not $copilotHome) { $copilotHome = Join-Path $HOME '.copilot' }

# ---------------------------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------------------------

$script:Counts = @{ OK = 0; INFO = 0; WARN = 0; FAIL = 0 }
$script:Fixes = New-Object System.Collections.ArrayList
$script:BackedUp = @{}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

function Add-Result {
    param(
        [ValidateSet('OK', 'INFO', 'WARN', 'FAIL')][string]$Status,
        [string]$Message,
        [string]$Hint
    )
    $script:Counts[$Status]++
    $color = 'Gray'
    switch ($Status) {
        'OK' { $color = 'Green' }
        'WARN' { $color = 'Yellow' }
        'FAIL' { $color = 'Red' }
        'INFO' { $color = 'Gray' }
    }
    Write-Host ('  [{0,-4}] ' -f $Status) -ForegroundColor $color -NoNewline
    Write-Host $Message
    if ($Hint) { Write-Host "         $Hint" -ForegroundColor DarkGray }
}

function Add-Fix {
    param(
        [string]$Title,
        [string]$Detail,
        [ValidateSet('Setting', 'MapEntry', 'GitIgnore', 'RemoveFile')][string]$Kind,
        [hashtable]$Data,
        [switch]$Optional
    )
    # Fixes are described as data and carried out by Invoke-Fix. Script blocks with captured
    # variables would lose sight of this script's functions when invoked later.
    [void]$script:Fixes.Add((New-Object psobject -Property @{
                Title    = $Title
                Detail   = $Detail
                Kind     = $Kind
                Data     = $Data
                Optional = [bool]$Optional
            }))
}

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

function Invoke-Native {
    # Runs an external program and captures output and exit code. Native stderr must not become
    # a terminating error, which is what Windows PowerShell does under ErrorActionPreference=Stop.
    param([string]$Exe, [string[]]$Arguments, [string]$WorkDir)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @()
    $code = -1
    if ($WorkDir) { Push-Location -LiteralPath $WorkDir }
    try {
        $output = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } catch {
        $output = @("$_")
    } finally {
        if ($WorkDir) { Pop-Location }
        $ErrorActionPreference = $previous
    }
    return New-Object psobject -Property @{ ExitCode = $code; Output = $output }
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Read-Text {
    param([string]$Path)
    # .NET reads UTF-8 with or without BOM. Get-Content in Windows PowerShell 5.1 would not.
    return [System.IO.File]::ReadAllText($Path)
}

function Write-Text {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Backup-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($script:BackedUp.ContainsKey($Path)) { return }
    $backup = '{0}.harness-backup-{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $Path -Destination $backup
    $script:BackedUp[$Path] = $backup
    Write-Host "         Backup: $backup" -ForegroundColor DarkGray
}

function ConvertFrom-Jsonc {
    # VS Code settings are JSON with comments and trailing commas. Returns the parsed object and
    # the position of the root "{" in the original text, so edits can keep comments intact.
    param([string]$Text)

    $noComments = New-Object System.Text.StringBuilder
    $rootBrace = -1
    $inString = $false
    $escaped = $false
    $i = 0
    $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($inString) {
            [void]$noComments.Append($c)
            if ($escaped) { $escaped = $false }
            elseif ($c -eq [char]92) { $escaped = $true }
            elseif ($c -eq [char]34) { $inString = $false }
            $i++
            continue
        }
        if ($c -eq [char]34) {
            $inString = $true
            [void]$noComments.Append($c)
            $i++
            continue
        }
        if ($c -eq [char]47 -and ($i + 1) -lt $n) {
            $next = $Text[$i + 1]
            if ($next -eq [char]47) {
                while ($i -lt $n -and $Text[$i] -ne [char]10) { $i++ }
                continue
            }
            if ($next -eq [char]42) {
                $i += 2
                while (($i + 1) -lt $n -and -not ($Text[$i] -eq [char]42 -and $Text[$i + 1] -eq [char]47)) { $i++ }
                $i += 2
                continue
            }
        }
        if ($c -eq [char]123 -and $rootBrace -lt 0) { $rootBrace = $i }
        [void]$noComments.Append($c)
        $i++
    }

    # Drop commas that are followed only by whitespace and a closing bracket.
    $source = $noComments.ToString()
    $clean = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $n = $source.Length
    for ($i = 0; $i -lt $n; $i++) {
        $c = $source[$i]
        if ($inString) {
            [void]$clean.Append($c)
            if ($escaped) { $escaped = $false }
            elseif ($c -eq [char]92) { $escaped = $true }
            elseif ($c -eq [char]34) { $inString = $false }
            continue
        }
        if ($c -eq [char]34) { $inString = $true }
        if ($c -eq [char]44) {
            $j = $i + 1
            while ($j -lt $n -and [char]::IsWhiteSpace($source[$j])) { $j++ }
            if ($j -lt $n -and ($source[$j] -eq [char]125 -or $source[$j] -eq [char]93)) { continue }
        }
        [void]$clean.Append($c)
    }

    $json = $clean.ToString()
    if ([string]::IsNullOrWhiteSpace($json)) { $json = '{}' }
    $object = $json | ConvertFrom-Json
    return New-Object psobject -Property @{ Object = $object; RootBrace = $rootBrace }
}

function Find-JsoncValueStart {
    # Returns the position where the value of a top-level key starts in JSONC text, or -1.
    # Comments, strings and nested objects are skipped properly, so a key that only appears
    # in a comment or deeper in the tree is not mistaken for the real one.
    param([string]$Text, [string]$Key)
    $depth = 0
    $i = 0
    $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($c -eq [char]47 -and ($i + 1) -lt $n) {
            $next = $Text[$i + 1]
            if ($next -eq [char]47) {
                while ($i -lt $n -and $Text[$i] -ne [char]10) { $i++ }
                continue
            }
            if ($next -eq [char]42) {
                $i += 2
                while (($i + 1) -lt $n -and -not ($Text[$i] -eq [char]42 -and $Text[$i + 1] -eq [char]47)) { $i++ }
                $i += 2
                continue
            }
        }
        if ($c -eq [char]34) {
            $start = $i + 1
            $i++
            while ($i -lt $n -and $Text[$i] -ne [char]34) {
                if ($Text[$i] -eq [char]92) { $i++ }
                $i++
            }
            $name = ''
            if ($i -gt $start -and $i -le $n) { $name = $Text.Substring($start, $i - $start) }
            $i++
            if ($depth -eq 1 -and $name -ceq $Key) {
                $j = $i
                while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
                if ($j -lt $n -and $Text[$j] -eq [char]58) {
                    $j++
                    while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
                    return $j
                }
            }
            continue
        }
        if ($c -eq [char]123 -or $c -eq [char]91) { $depth++ }
        elseif ($c -eq [char]125 -or $c -eq [char]93) { $depth-- }
        $i++
    }
    return -1
}

function Get-Prop {
    # Property lookup that is safe under StrictMode and works for names containing dots.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-PropCount {
    param($Object)
    if ($null -eq $Object) { return 0 }
    return @($Object.PSObject.Properties).Count
}

function Get-FileStyle {
    param([string]$Text)
    $newline = "`n"
    if ($Text.Contains("`r`n")) { $newline = "`r`n" }
    $indent = '    '
    $match = [regex]::Match($Text, '(?m)^([ \t]+)"')
    if ($match.Success) { $indent = $match.Groups[1].Value }
    return New-Object psobject -Property @{ Newline = $newline; Indent = $indent }
}

function Read-SettingsText {
    param([string]$Path)
    $text = ''
    if (Test-Path -LiteralPath $Path) { $text = Read-Text $Path }
    if ([string]::IsNullOrWhiteSpace($text)) { $text = "{`n}`n" }
    return $text
}

function Save-SettingsText {
    # Writes only if the new text still parses and holds the intended value: either
    # $Key equals $ExpectedJson, or the object at $Key contains $EntryName.
    param([string]$Path, [string]$NewText, [string]$Key, [string]$ExpectedJson, [string]$EntryName)
    $object = (ConvertFrom-Jsonc $NewText).Object
    if ($EntryName) {
        $ok = Test-Prop (Get-Prop $object $Key) $EntryName
    } else {
        $ok = ((ConvertTo-Json (Get-Prop $object $Key) -Compress) -eq $ExpectedJson)
    }
    if (-not $ok) { throw "The edit did not produce the expected value. Nothing was written to $Path." }
    Backup-File $Path
    Write-Text $Path $NewText
}

function Set-JsoncValue {
    # Sets a top-level key to a scalar JSON value (true, false, a number or a quoted string),
    # editing the text in place so comments and formatting survive.
    param([string]$Path, [string]$Key, [string]$JsonValue)

    $text = Read-SettingsText $Path
    $parsed = ConvertFrom-Jsonc $text
    if ($parsed.RootBrace -lt 0) { throw "$Path does not contain a JSON object." }
    $style = Get-FileStyle $text

    if (Test-Prop $parsed.Object $Key) {
        $start = Find-JsoncValueStart $text $Key
        $scalar = New-Object regex '\G(?:true|false|null|"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?)'
        $match = $null
        if ($start -ge 0) { $match = $scalar.Match($text, $start) }
        if ($null -eq $match -or -not $match.Success) { throw "Could not locate a simple value for `"$Key`" in $Path. Set it by hand to $JsonValue." }
        $newText = $text.Substring(0, $match.Index) + $JsonValue + $text.Substring($match.Index + $match.Length)
    } else {
        $comma = ''
        if ((Get-PropCount $parsed.Object) -gt 0) { $comma = ',' }
        $insert = $style.Newline + $style.Indent + '"' + $Key + '": ' + $JsonValue + $comma
        $newText = $text.Insert($parsed.RootBrace + 1, $insert)
    }

    Save-SettingsText -Path $Path -NewText $newText -Key $Key -ExpectedJson $JsonValue
}

function Add-JsoncMapEntry {
    # Adds one entry to a top-level object-valued key, creating the key if it is missing.
    # $EntryName is the plain (unescaped) property name.
    param([string]$Path, [string]$Key, [string]$EntryName, [string]$EntryJsonValue)

    $text = Read-SettingsText $Path
    $parsed = ConvertFrom-Jsonc $text
    if ($parsed.RootBrace -lt 0) { throw "$Path does not contain a JSON object." }
    $style = Get-FileStyle $text
    $entryKeyJson = '"' + $EntryName.Replace('\', '\\').Replace('"', '\"') + '"'
    $entry = $entryKeyJson + ': ' + $EntryJsonValue

    if (Test-Prop $parsed.Object $Key) {
        $existing = Get-Prop $parsed.Object $Key
        if ($existing -isnot [System.Management.Automation.PSCustomObject]) {
            throw "`"$Key`" in $Path is not an object. Add the rule by hand."
        }
        $start = Find-JsoncValueStart $text $Key
        if ($start -lt 0 -or $text[$start] -ne [char]123) { throw "Could not locate `"$Key`" in $Path to edit it. Add this entry by hand: $entry" }
        $comma = ''
        if ((Get-PropCount $existing) -gt 0) { $comma = ',' }
        $insert = $style.Newline + $style.Indent + $style.Indent + $entry + $comma
        $newText = $text.Insert($start + 1, $insert)
    } else {
        $comma = ''
        if ((Get-PropCount $parsed.Object) -gt 0) { $comma = ',' }
        $block = '{' + $style.Newline + $style.Indent + $style.Indent + $entry + $style.Newline + $style.Indent + '}'
        $insert = $style.Newline + $style.Indent + '"' + $Key + '": ' + $block + $comma
        $newText = $text.Insert($parsed.RootBrace + 1, $insert)
    }

    Save-SettingsText -Path $Path -NewText $newText -Key $Key -EntryName $EntryName
}

function ConvertTo-PolicyBool {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [int] -or $Value -is [long]) { return ($Value -ne 0) }
    $text = "$Value".Trim().ToLowerInvariant()
    if ($text -eq 'true' -or $text -eq '1') { return $true }
    if ($text -eq 'false' -or $text -eq '0') { return $false }
    return $null
}

function Get-Frontmatter {
    # Returns the YAML header of a Markdown file as text, or $null.
    param([string]$Path)
    $match = [regex]::Match((Read-Text $Path), '\A---\r?\n(.*?)\r?\n---\r?\n', 'Singleline')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Get-FrontmatterValue {
    param([string]$Frontmatter, [string]$Name)
    if (-not $Frontmatter) { return $null }
    $match = [regex]::Match($Frontmatter, '(?m)^' + [regex]::Escape($Name) + ':\s*(.*?)\s*$')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.Trim('"', "'")
}

# ---------------------------------------------------------------------------------------------
# 1. Tools
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'GitHub Copilot Harness - setup check' -ForegroundColor White
Write-Host "Repository: $RepoRoot" -ForegroundColor DarkGray

Write-Section '1. Tools'

if (Test-Command $codeCommand) {
    $result = Invoke-Native $codeCommand @('--version')
    $versionText = ''
    if ($result.Output.Count -gt 0) { $versionText = $result.Output[0].Trim() }
    $parsedVersion = $null
    if ($versionText -match '^\d+\.\d+\.\d+') { $parsedVersion = [version]$Matches[0] }
    if ($null -eq $parsedVersion) {
        Add-Result WARN "VS Code was found, but '$codeCommand --version' did not return a version." 'Check the version under Help > About.'
    } elseif ($parsedVersion -lt $MinVsCode) {
        Add-Result WARN "VS Code $parsedVersion is older than $MinVsCode, the version this harness was written against." 'Update VS Code. Skills, custom agents and hooks on the Copilot harness changed a lot during 2026.'
    } else {
        Add-Result OK "VS Code $parsedVersion"
    }

    $extensions = Invoke-Native $codeCommand @('--list-extensions')
    $copilot = @($extensions.Output | Where-Object { $_ -match '^github\.copilot' })
    if ($copilot.Count -gt 0) {
        Add-Result OK ("Copilot extension listed: " + ($copilot -join ', '))
    } else {
        Add-Result INFO 'No separate Copilot extension is listed.' 'Recent VS Code builds ship Copilot built in. Confirm in VS Code that you are signed in to GitHub with a Copilot licence.'
    }
} else {
    Add-Result WARN "The '$codeCommand' command is not on PATH, so the VS Code version could not be checked." 'In VS Code run "Shell Command: Install ''code'' command in PATH" (macOS) or re-run the installer with "Add to PATH" (Windows).'
}

$nodeReady = $false
if (Test-Command 'node') {
    $result = Invoke-Native 'node' @('--version')
    $nodeText = ''
    if ($result.Output.Count -gt 0) { $nodeText = $result.Output[0].Trim() }
    if ($nodeText -match '^v(\d+)\.') {
        if ([int]$Matches[1] -ge $MinNodeMajor) {
            $nodeReady = $true
            Add-Result OK "Node.js $nodeText"
        } else {
            Add-Result FAIL "Node.js $nodeText is too old. The hook scripts need Node.js $MinNodeMajor or later." 'Install a current LTS release from your software centre or https://nodejs.org.'
        }
    } else {
        Add-Result FAIL "Could not read the Node.js version (got '$nodeText')."
    }
} else {
    Add-Result FAIL 'Node.js is not on PATH. Without it no hook runs: /goal is not enforced and the guard is inactive.' "Install Node.js $MinNodeMajor or later. In a dev container or remote host it must exist there, not only on your laptop."
}

if (Test-Command 'git') {
    $result = Invoke-Native 'git' @('--version')
    Add-Result OK ($result.Output -join ' ')
} else {
    Add-Result WARN 'Git is not on PATH. The reviewer subagent and /deep-review rely on git diff.'
}

if ($env:REMOTE_CONTAINERS -or $env:CODESPACES -or $env:WSL_DISTRO_NAME -or $env:SSH_CONNECTION) {
    Add-Result INFO 'This looks like a container, WSL or remote shell.' 'Good: the tools above were checked where the agent will run. User settings below are those of this environment, not of your local VS Code.'
}

# ---------------------------------------------------------------------------------------------
# 2. Repository
# ---------------------------------------------------------------------------------------------

Write-Section '2. Repository'

$requiredFiles = @(
    '.github/copilot-instructions.md',
    '.github/hooks/harness.json',
    '.github/hooks/harness/config.json',
    '.github/hooks/harness/lib.mjs',
    '.github/hooks/harness/goal.mjs',
    '.github/hooks/harness/goal-stop.mjs',
    '.github/hooks/harness/goal-verdict.mjs',
    '.github/hooks/harness/on-prompt.mjs',
    '.github/hooks/harness/session-start.mjs',
    '.github/hooks/harness/guard.mjs',
    '.github/agents/explorer.agent.md',
    '.github/agents/planner.agent.md',
    '.github/agents/implementer.agent.md',
    '.github/agents/reviewer.agent.md',
    '.github/agents/verifier.agent.md',
    '.github/agents/goal-judge.agent.md',
    '.github/skills/goal/SKILL.md',
    '.github/skills/workflow/SKILL.md',
    '.github/skills/fan-out/SKILL.md',
    '.github/skills/deep-review/SKILL.md',
    'AGENTS.md'
)
$missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) })
if ($missing.Count -eq 0) {
    Add-Result OK "All $($requiredFiles.Count) harness files are present."
} else {
    foreach ($file in $missing) { Add-Result FAIL "Missing: $file" }
    Add-Result INFO 'Copy the missing files from the harness repository. See README.md, Quick start.'
}

# Hook configuration
$hooksFile = Join-Path $RepoRoot '.github/hooks/harness.json'
if (Test-Path -LiteralPath $hooksFile) {
    try {
        $hooks = (Read-Text $hooksFile) | ConvertFrom-Json
        if ((Get-Prop $hooks 'version') -ne 1) {
            Add-Result FAIL '.github/hooks/harness.json must have "version": 1, otherwise the whole file is rejected.'
        }
        if ((Get-Prop $hooks 'disableAllHooks') -eq $true) {
            Add-Result WARN '.github/hooks/harness.json has "disableAllHooks": true, so none of the harness hooks run.'
        }
        $events = Get-Prop $hooks 'hooks'
        $eventNames = @()
        $broken = 0
        if ($events) {
            foreach ($property in $events.PSObject.Properties) {
                $eventNames += $property.Name
                foreach ($entry in @($property.Value)) {
                    $command = Get-Prop $entry 'command'
                    if ($command -and $command -match '^node\s+(\S+)') {
                        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $Matches[1]))) {
                            $broken++
                            Add-Result FAIL "Hook '$($property.Name)' points to a script that does not exist: $($Matches[1])"
                        }
                    }
                }
            }
        }
        foreach ($needed in @('agentStop', 'subagentStop', 'userPromptSubmitted', 'sessionStart', 'preToolUse')) {
            if ($eventNames -notcontains $needed) {
                Add-Result WARN "No '$needed' hook is configured in harness.json."
            }
        }
        if ($broken -eq 0 -and $eventNames.Count -gt 0) {
            Add-Result OK ("Hook configuration is valid: " + ($eventNames -join ', '))
        }
    } catch {
        Add-Result FAIL ".github/hooks/harness.json is not valid JSON: $($_.Exception.Message)"
    }

    $strayJson = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot '.github/hooks') -Filter '*.json' -File | Where-Object { $_.Name -ne 'harness.json' })
    if ($strayJson.Count -gt 0) {
        Add-Result INFO ("Other hook files in .github/hooks run in addition to the harness: " + (($strayJson | ForEach-Object { $_.Name }) -join ', '))
    }
}

# Harness configuration
$configFile = Join-Path $RepoRoot '.github/hooks/harness/config.json'
if (Test-Path -LiteralPath $configFile) {
    try {
        $config = (Read-Text $configFile) | ConvertFrom-Json
        $checks = Get-Prop (Get-Prop $config 'goal') 'checks'
        $checkNames = @()
        if ($checks) { $checkNames = @($checks.PSObject.Properties | Where-Object { $_.Name -notlike '$*' } | ForEach-Object { $_.Name }) }
        if ($checkNames.Count -gt 0) {
            Add-Result OK ("Goal checks registered: " + ($checkNames -join ', '))
        } else {
            Add-Result WARN 'No goal checks are registered, so /goal --check <name> cannot be used yet.' 'Add your test and lint commands under goal.checks in .github/hooks/harness/config.json, for example "test": "npm test".'
        }
    } catch {
        Add-Result FAIL ".github/hooks/harness/config.json is not valid JSON: $($_.Exception.Message)"
    }
}

# Skills: a skill whose name differs from its folder silently fails to load.
$skillsDir = Join-Path $RepoRoot '.github/skills'
if (Test-Path -LiteralPath $skillsDir) {
    $skillProblems = 0
    $skillNames = @()
    foreach ($dir in Get-ChildItem -LiteralPath $skillsDir -Directory) {
        $skillFile = Join-Path $dir.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillFile)) {
            $skillProblems++
            Add-Result FAIL "Skill folder '$($dir.Name)' has no SKILL.md."
            continue
        }
        $frontmatter = Get-Frontmatter $skillFile
        $name = Get-FrontmatterValue $frontmatter 'name'
        $description = Get-FrontmatterValue $frontmatter 'description'
        if ($name -ne $dir.Name) {
            $skillProblems++
            Add-Result FAIL "Skill '$($dir.Name)': the name in SKILL.md is '$name'. It must equal the folder name or the skill does not load."
        } elseif ($name -notmatch '^[a-z0-9-]{1,64}$') {
            $skillProblems++
            Add-Result FAIL "Skill '$name': names may contain only lowercase letters, digits and hyphens (64 characters at most)."
        } elseif (-not $description) {
            $skillProblems++
            Add-Result FAIL "Skill '$name' has no description."
        } elseif ($description.Length -gt 1024) {
            $skillProblems++
            Add-Result FAIL "Skill '$name': the description is longer than 1024 characters."
        } else {
            $skillNames += "/$name"
        }
    }
    if ($skillProblems -eq 0 -and $skillNames.Count -gt 0) { Add-Result OK ("Skills are well formed: " + ($skillNames -join ', ')) }
}

# Agents: the Copilot schema requires a description.
$agentsDir = Join-Path $RepoRoot '.github/agents'
if (Test-Path -LiteralPath $agentsDir) {
    $agentProblems = 0
    $agentNames = @()
    foreach ($file in Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File) {
        $frontmatter = Get-Frontmatter $file.FullName
        if (-not (Get-FrontmatterValue $frontmatter 'description')) {
            $agentProblems++
            Add-Result FAIL "Agent file $($file.Name) has no description, which the Copilot harness requires."
        } else {
            $agentName = Get-FrontmatterValue $frontmatter 'name'
            if (-not $agentName) { $agentName = $file.BaseName -replace '\.agent$', '' }
            $agentNames += $agentName
        }
        foreach ($localOnly in @('handoffs', 'agents', 'argument-hint')) {
            if ($frontmatter -and $frontmatter -match ('(?m)^' + [regex]::Escape($localOnly) + ':')) {
                Add-Result WARN "Agent file $($file.Name) uses '$localOnly', which only the deprecated Local harness supports."
            }
        }
    }
    if ($agentProblems -eq 0 -and $agentNames.Count -gt 0) { Add-Result OK ("Agents are well formed: " + ($agentNames -join ', ')) }
    if ($agentNames.Count -gt 0 -and $agentNames -notcontains 'goal-judge') {
        Add-Result WARN "No agent named 'goal-judge' exists. /goal needs it to verify a goal." 'Restore .github/agents/goal-judge.agent.md, or set goal.judgeAgent in config.json to the agent you use.'
    }
}

# Deprecated prompt files
$promptsDir = Join-Path $RepoRoot '.github/prompts'
if (Test-Path -LiteralPath $promptsDir) {
    $prompts = @(Get-ChildItem -LiteralPath $promptsDir -Filter '*.prompt.md' -File)
    if ($prompts.Count -gt 0) {
        Add-Result WARN "$($prompts.Count) prompt file(s) in .github/prompts run only in the deprecated Local harness." 'Convert them to skills (.github/skills/<name>/SKILL.md) before the Local harness is removed.'
    }
}

# AGENTS.md still the template?
$agentsMd = Join-Path $RepoRoot 'AGENTS.md'
if (Test-Path -LiteralPath $agentsMd) {
    if ((Read-Text $agentsMd) -match 'Replace everything in this file with facts about YOUR project') {
        Add-Result WARN 'AGENTS.md is still the template.' 'Describe your project, its layout and the build, test and lint commands. Agents read this file at the start of every session.'
    } else {
        Add-Result OK 'AGENTS.md has been filled in.'
    }
}

# .gitignore
$gitignore = Join-Path $RepoRoot '.gitignore'
$ignoresState = $false
if (Test-Path -LiteralPath $gitignore) {
    $ignoresState = [bool]((Read-Text $gitignore) -match '(?m)^\s*/?\.harness/?\s*$')
}
if ($ignoresState) {
    Add-Result OK '.gitignore excludes the runtime state folder .harness/'
} else {
    Add-Result WARN '.gitignore does not exclude .harness/, so goal state could be committed by accident.'
    Add-Fix -Title 'Add .harness/ to .gitignore' -Detail $gitignore -Kind GitIgnore -Data @{ Path = $gitignore }
}

# Runtime state
$stateDir = Join-Path $RepoRoot '.harness'
$debugFlag = Join-Path $stateDir 'debug'
if (Test-Path -LiteralPath $debugFlag) {
    Add-Result WARN 'The hook event trace is switched on (.harness/debug exists). It logs shortened prompts and tool arguments.'
    Add-Fix -Title 'Switch off the hook event trace' -Detail 'Removes .harness/debug. The existing events.log is kept.' -Kind RemoveFile -Data @{ Path = $debugFlag }
}
$goalFile = Join-Path $stateDir 'goal.json'
if (Test-Path -LiteralPath $goalFile) {
    try {
        $goal = (Read-Text $goalFile) | ConvertFrom-Json
        Add-Result INFO "A goal exists with status '$(Get-Prop $goal 'status')': $(Get-Prop $goal 'condition')" 'Clear it with: node .github/hooks/harness/goal.mjs clear'
    } catch {
        Add-Result WARN '.harness/goal.json exists but cannot be read. Delete it to reset the goal state.'
    }
}

if (Test-Path -LiteralPath (Join-Path $RepoRoot '.git')) {
    Add-Result OK 'The folder is a Git repository.'
} else {
    Add-Result INFO 'The folder is not a Git repository. Repository hooks are discovered at the repository root.'
}

# Hook tests
$testsDir = Join-Path $RepoRoot 'tests'
if ($SkipTests) {
    Add-Result INFO 'Hook tests skipped (-SkipTests).'
} elseif (-not $nodeReady) {
    Add-Result INFO 'Hook tests not run because Node.js is not ready.'
} elseif (-not (Test-Path -LiteralPath (Join-Path $testsDir 'hooks.test.mjs'))) {
    Add-Result INFO 'tests/hooks.test.mjs is not present, so the hook scripts were not exercised.'
} else {
    $result = Invoke-Native 'node' @('--test', 'tests/') $RepoRoot
    $text = $result.Output -join "`n"
    $passed = [regex]::Match($text, '(?m)^\S*\s*pass\s+(\d+)\s*$')
    $failed = [regex]::Match($text, '(?m)^\S*\s*fail\s+(\d+)\s*$')
    $summary = ''
    if ($passed.Success) { $summary = "$($passed.Groups[1].Value) passed" }
    if ($failed.Success) { $summary += ", $($failed.Groups[1].Value) failed" }
    if ($result.ExitCode -eq 0) {
        Add-Result OK "Hook tests pass ($summary). The scripts work with Node.js on this machine."
    } else {
        Add-Result FAIL "Hook tests failed ($summary)." 'Run "node --test tests/" in the repository to see the details.'
    }
}

# ---------------------------------------------------------------------------------------------
# 3. VS Code user settings
# ---------------------------------------------------------------------------------------------

Write-Section '3. VS Code user settings'
Write-Host "  $userSettingsPath" -ForegroundColor DarkGray

$settings = $null
$settingsUsable = $true
if (Test-Path -LiteralPath $userSettingsPath) {
    try {
        $settings = (ConvertFrom-Jsonc (Read-Text $userSettingsPath)).Object
    } catch {
        $settingsUsable = $false
        Add-Result WARN "The settings file could not be parsed, so settings were not checked and will not be edited: $($_.Exception.Message)"
    }
} else {
    Add-Result INFO 'No user settings file exists yet for the default profile. Defaults apply.' 'If you use a named VS Code profile, its settings live in a profile subfolder that this script does not read.'
}

if ($settingsUsable) {
    $settingsPath = $userSettingsPath

    if ((Get-Prop $settings 'chat.agent.enabled') -eq $false) {
        Add-Result FAIL 'chat.agent.enabled is false: agents are switched off.'
        Add-Fix -Title 'Enable agents (chat.agent.enabled = true)' -Detail $settingsPath -Kind Setting -Data @{ Path = $settingsPath; Key = 'chat.agent.enabled'; Value = 'true' }
    } else {
        Add-Result OK 'Agents are not disabled in user settings.'
    }

    $localPreferred = @()
    foreach ($key in @('chat.defaultToCopilotHarness', 'chat.editor.preferCopilotHarness')) {
        if ((Get-Prop $settings $key) -eq $false) { $localPreferred += $key }
    }
    if ($localPreferred.Count -gt 0) {
        Add-Result WARN ("New sessions do not default to the Copilot harness (" + ($localPreferred -join ', ') + " = false).") 'The harness targets the Copilot runtime. The deprecated Local harness uses different hooks and tool names.'
        foreach ($key in $localPreferred) {
            Add-Fix -Title "Prefer the Copilot harness ($key = true)" -Detail $settingsPath -Kind Setting -Data @{ Path = $settingsPath; Key = $key; Value = 'true' }
        }
    } else {
        Add-Result OK 'Nothing in user settings steers sessions away from the Copilot harness.'
    }
    if ((Get-Prop $settings 'chat.editor.localAgent.enabled') -eq $true) {
        Add-Result INFO 'The Local harness is visible (chat.editor.localAgent.enabled). Select "Copilot" in the Session Target control when you use the harness.'
    }

    if ((Get-Prop $settings 'chat.tools.global.autoApprove') -eq $true) {
        Add-Result WARN 'chat.tools.global.autoApprove is true: every tool call is approved automatically in every workspace.' 'The harness does not need this. Prefer the Assisted permission level for unattended runs.'
    }
    if ((Get-Prop $settings 'chat.tools.terminal.enableAutoApprove') -eq $false) {
        Add-Result INFO 'Rule-based terminal auto-approval is off (chat.tools.terminal.enableAutoApprove). Expect a prompt for each command.'
    }
    if ((Get-Prop $settings 'chat.mcp.access') -eq 'none') {
        Add-Result INFO 'MCP servers are disabled (chat.mcp.access = none). The harness itself needs none.'
    }

    # Optional: built-in progress check for Autopilot
    if ((Get-Prop $settings 'chat.autopilot.advanced.enabled') -eq $true) {
        Add-Result OK 'Autopilot progress check is on (chat.autopilot.advanced.enabled).'
    } else {
        Add-Result INFO 'Autopilot progress check is not enabled in user settings (chat.autopilot.advanced.enabled, experimental).' 'In Autopilot mode a second model then checks progress against your request after each turn. See docs/goal.md.'
        Add-Fix -Optional -Title 'Enable the Autopilot progress check (chat.autopilot.advanced.enabled = true)' -Detail 'Experimental VS Code setting. Affects Autopilot mode in all your workspaces.' -Kind Setting -Data @{ Path = $settingsPath; Key = 'chat.autopilot.advanced.enabled'; Value = 'true' }
    }

    # Optional: let the agent read and set the goal without a prompt each time
    $ruleName = '/^node \.github\/hooks\/harness\/goal\.mjs (status|set)\b/'
    $autoApprove = Get-Prop $settings 'chat.tools.terminal.autoApprove'
    $hasGoalRule = $false
    if ($autoApprove -is [System.Management.Automation.PSCustomObject]) {
        $hasGoalRule = [bool](@($autoApprove.PSObject.Properties | Where-Object { $_.Name -like '*goal*mjs*' }).Count)
    }
    if ($hasGoalRule) {
        Add-Result OK 'A terminal auto-approve rule for the goal command exists.'
    } else {
        Add-Result INFO 'No terminal auto-approve rule for the goal command. With Manual permissions you confirm each "goal.mjs status" and "goal.mjs set".'
        Add-Fix -Optional -Title 'Auto-approve "goal.mjs status" and "goal.mjs set" in the terminal' -Detail 'Adds one rule to chat.tools.terminal.autoApprove. "clear" and "verdict" stay behind a prompt, so the agent cannot release its own goal unseen.' -Kind MapEntry -Data @{ Path = $settingsPath; Key = 'chat.tools.terminal.autoApprove'; Entry = $ruleName; Value = 'true' }
    }
}

# Workspace settings
$workspaceSettings = Join-Path $RepoRoot '.vscode/settings.json'
if (Test-Path -LiteralPath $workspaceSettings) {
    try {
        [void](ConvertFrom-Jsonc (Read-Text $workspaceSettings))
        Add-Result OK 'Workspace settings (.vscode/settings.json) parse correctly.'
    } catch {
        Add-Result WARN ".vscode/settings.json could not be parsed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------------------------
# 4. Organisation policy and other hook sources
# ---------------------------------------------------------------------------------------------

Write-Section '4. Organisation policy and other hook sources (best effort)'

$policyNames = @(
    'ChatAgentMode', 'ChatAllowManagedHooksOnly', 'ChatStrictPluginOnlyCustomization', 'ChatHooks',
    'ChatToolsAutoApprove', 'ChatToolsTerminalEnableAutoApprove', 'ChatPluginsEnabled', 'ChatMCP',
    'ChatApprovedAccountOrganizations', 'Claude3PIntegration'
)
$policies = @{}
$policySource = $null

if ($onWindows) {
    foreach ($root in @('HKLM:\Software\Policies\Microsoft\VSCode', 'HKCU:\Software\Policies\Microsoft\VSCode')) {
        if (Test-Path -Path $root) {
            $policySource = 'Windows registry (Software\Policies\Microsoft\VSCode)'
            $item = Get-ItemProperty -Path $root
            foreach ($property in $item.PSObject.Properties) {
                # Computer policy (HKLM, read first) wins over user policy.
                if ($property.Name -notlike 'PS*' -and -not $policies.ContainsKey($property.Name)) { $policies[$property.Name] = $property.Value }
            }
        }
    }
} elseif ($onMac) {
    $managed = '/Library/Managed Preferences/com.microsoft.VSCode'
    if (Test-Path -LiteralPath "$managed.plist") {
        $policySource = "$managed.plist"
        foreach ($name in $policyNames) {
            $result = Invoke-Native 'defaults' @('read', $managed, $name)
            if ($result.ExitCode -eq 0 -and $result.Output.Count -gt 0) { $policies[$name] = ($result.Output -join ' ').Trim() }
        }
    }
} else {
    $policyFile = '/etc/vscode/policy.json'
    if (Test-Path -LiteralPath $policyFile) {
        $policySource = $policyFile
        try {
            $policyObject = (ConvertFrom-Jsonc (Read-Text $policyFile)).Object
            foreach ($property in $policyObject.PSObject.Properties) { $policies[$property.Name] = $property.Value }
        } catch {
            Add-Result WARN "$policyFile exists but could not be parsed."
        }
    }
}

if ($null -eq $policySource) {
    Add-Result INFO 'No VS Code device policy was found on this machine.'
} else {
    Add-Result INFO "VS Code device policies found: $policySource ($($policies.Count) value(s))."
    $relevant = 0

    if ((ConvertTo-PolicyBool $policies['ChatAgentMode']) -eq $false) {
        $relevant++
        Add-Result FAIL 'Policy ChatAgentMode = false: agents are disabled by your organisation. The harness cannot be used.'
    }
    if ((ConvertTo-PolicyBool $policies['ChatAllowManagedHooksOnly']) -eq $true) {
        $relevant++
        Add-Result WARN 'Policy ChatAllowManagedHooksOnly is set: repository hooks do not run.' 'Skills, agents and instructions still work, but /goal is not enforced and the guard is inactive. See docs/enterprise.md, "As a managed agent plugin".'
    }
    if ($policies.ContainsKey('ChatStrictPluginOnlyCustomization')) {
        $strict = $policies['ChatStrictPluginOnlyCustomization']
        if ((ConvertTo-PolicyBool $strict) -ne $false -and "$strict" -ne '') {
            $relevant++
            Add-Result WARN "Policy ChatStrictPluginOnlyCustomization is set ($strict): standalone repository customizations may be blocked." 'The harness then has to be distributed as a managed plugin. See docs/enterprise.md.'
        }
    }
    if ((ConvertTo-PolicyBool $policies['ChatToolsAutoApprove']) -eq $false) {
        $relevant++
        Add-Result INFO 'Policy ChatToolsAutoApprove = false: no global auto-approval and saved approvals are not applied. Expect more prompts.'
    }
    if ((ConvertTo-PolicyBool $policies['ChatToolsTerminalEnableAutoApprove']) -eq $false) {
        $relevant++
        Add-Result INFO 'Policy ChatToolsTerminalEnableAutoApprove = false: terminal auto-approve rules are ignored.'
    }
    if ((ConvertTo-PolicyBool $policies['ChatPluginsEnabled']) -eq $false) {
        $relevant++
        Add-Result INFO 'Policy ChatPluginsEnabled = false: agent plugins are disabled, so plugin distribution is not an option here.'
    }
    if ($policies.ContainsKey('ChatMCP')) {
        $relevant++
        Add-Result INFO "Policy ChatMCP = $($policies['ChatMCP']): MCP access is managed."
    }
    if ($relevant -eq 0) { Add-Result OK 'None of the device policies found restricts the harness.' }
}
Add-Result INFO 'Copilot enterprise-managed settings (permissions, sandbox, hook sources, MCP allowlist) are delivered by GitHub and cannot be read from here.' 'In VS Code run "Developer: Policy Diagnostics" to see what applies to your account.'

# Policy hooks deployed by IT
$policyHookDir = '/etc/github-copilot/policy.d'
if ($onWindows) { $policyHookDir = Join-Path $env:ProgramData 'GitHub\Copilot\policy.d' }
if (Test-Path -LiteralPath $policyHookDir) {
    $policyHooks = @(Get-ChildItem -LiteralPath $policyHookDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($policyHooks.Count -gt 0) {
        Add-Result INFO "$($policyHooks.Count) Copilot policy hook file(s) are deployed in $policyHookDir. They run in addition to the harness hooks."
    }
}

# Personal hooks and settings of the Copilot runtime
$userHookDir = Join-Path $copilotHome 'hooks'
if (Test-Path -LiteralPath $userHookDir) {
    $userHooks = @(Get-ChildItem -LiteralPath $userHookDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($userHooks.Count -gt 0) {
        Add-Result INFO ("Personal hooks in $userHookDir run in addition to the harness hooks: " + (($userHooks | ForEach-Object { $_.Name }) -join ', ')) 'If you copied the harness there as well, every hook runs twice.'
    }
}
foreach ($candidate in @((Join-Path $copilotHome 'settings.json'), (Join-Path $RepoRoot '.github/copilot/settings.json'), (Join-Path $RepoRoot '.github/copilot/settings.local.json'))) {
    if (Test-Path -LiteralPath $candidate) {
        try {
            $copilotSettings = (ConvertFrom-Jsonc (Read-Text $candidate)).Object
            if ((Get-Prop $copilotSettings 'disableAllHooks') -eq $true) {
                Add-Result WARN "$candidate has disableAllHooks = true. Copilot CLI then skips every hook for this repository."
            }
        } catch {
            Add-Result INFO "$candidate could not be parsed and was not checked."
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Summary and fixes
# ---------------------------------------------------------------------------------------------

Write-Section 'Summary'
Write-Host ('  {0} ok, {1} info, {2} warning(s), {3} failure(s)' -f $script:Counts.OK, $script:Counts.INFO, $script:Counts.WARN, $script:Counts.FAIL)

function Invoke-Fix {
    param($Item)
    try {
        $data = $Item.Data
        switch ($Item.Kind) {
            'Setting' { Set-JsoncValue $data['Path'] $data['Key'] $data['Value'] }
            'MapEntry' { Add-JsoncMapEntry $data['Path'] $data['Key'] $data['Entry'] $data['Value'] }
            'RemoveFile' { Remove-Item -LiteralPath $data['Path'] -Force }
            'GitIgnore' {
                $existing = ''
                if (Test-Path -LiteralPath $data['Path']) { $existing = Read-Text $data['Path'] }
                if ($existing -and -not $existing.EndsWith("`n")) { $existing += "`n" }
                Write-Text $data['Path'] ($existing + "`n# Harness runtime state (active goal, history)`n.harness/`n")
            }
        }
        Write-Host "  [DONE] $($Item.Title)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [SKIP] $($Item.Title)" -ForegroundColor Yellow
        Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkGray
        return $false
    }
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Allowed, [string]$Default)
    while ($true) {
        $answer = $null
        try { $answer = Read-Host $Prompt } catch { return $Default }
        if ($null -eq $answer) { return $Default }
        $answer = $answer.Trim().ToLowerInvariant()
        if ($answer -eq '') { return $Default }
        $first = $answer.Substring(0, 1)
        if ($Allowed -contains $first) { return $first }
        Write-Host "  Please answer with one of: $($Allowed -join ', ')"
    }
}

$recommended = @($script:Fixes | Where-Object { -not $_.Optional })
$optional = @($script:Fixes | Where-Object { $_.Optional })
$applied = 0

if ($script:Fixes.Count -eq 0) {
    Write-Host '  Nothing to fix automatically.'
} else {
    Write-Section 'Available fixes'
    if ($recommended.Count -gt 0) {
        Write-Host '  Recommended:'
        foreach ($item in $recommended) {
            Write-Host "    - $($item.Title)"
            if ($item.Detail) { Write-Host "      $($item.Detail)" -ForegroundColor DarkGray }
        }
    }
    if ($optional.Count -gt 0) {
        Write-Host '  Optional:'
        foreach ($item in $optional) {
            Write-Host "    - $($item.Title)"
            if ($item.Detail) { Write-Host "      $($item.Detail)" -ForegroundColor DarkGray }
        }
    }
    Write-Host ''

    if ($CheckOnly) {
        Write-Host '  -CheckOnly was given, so nothing was changed.'
    } elseif ($Fix) {
        foreach ($item in $recommended) { if (Invoke-Fix $item) { $applied++ } }
        if ($optional.Count -gt 0) { Write-Host '  Optional fixes are not applied by -Fix. Run the script without switches to choose them.' }
    } else {
        if ($recommended.Count -gt 0) {
            $choice = Read-Choice "  Apply the $($recommended.Count) recommended fix(es)? [Y]es / [n]o / [s]elect one by one" @('y', 'n', 's') 'y'
            foreach ($item in $recommended) {
                $apply = ($choice -eq 'y')
                if ($choice -eq 's') { $apply = ((Read-Choice "    $($item.Title)? [Y/n]" @('y', 'n') 'y') -eq 'y') }
                if ($apply) { if (Invoke-Fix $item) { $applied++ } }
            }
        }
        foreach ($item in $optional) {
            if ((Read-Choice "  Optional: $($item.Title)? [y/N]" @('y', 'n') 'n') -eq 'y') {
                if (Invoke-Fix $item) { $applied++ }
            }
        }
    }
    if ($applied -gt 0) {
        Write-Host ''
        Write-Host "  $applied fix(es) applied. Restart VS Code or reload the window so settings take effect, then run this script again." -ForegroundColor Green
    }
}

Write-Section 'What only you can do in VS Code'
Write-Host '  1. Open the repository folder and trust the workspace.'
Write-Host '  2. Select "Copilot" in the Session Target control of the Chat view or Agents window.'
Write-Host '  3. Run "Chat: Open Customizations" and confirm that agents, skills and hooks are listed.'
Write-Host '  4. Run "Developer: Policy Diagnostics" to see organisation settings that apply to you.'
Write-Host '  5. Walk through docs/smoke-test.md once. It confirms that the hooks fire in a live session.'
Write-Host ''

if ($script:Counts.FAIL -gt 0) { exit 1 }
exit 0
