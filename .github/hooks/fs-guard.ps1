$ErrorActionPreference = 'Stop'

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\agent-comms'))
$allowedPrefix = $allowedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

function IsInsideAllowed {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        return $fullPath.Equals($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Write-Decision {
    param(
        [string]$Decision,
        [string]$Reason
    )

    if ($Reason) {
        Write-Output ('{"decision":"' + $Decision + '","reason":"' + $Reason.Replace('"', '\\"') + '"}')
    } else {
        Write-Output ('{"decision":"' + $Decision + '"}')
    }
}

$rawPayload = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($rawPayload)) {
    Write-Decision -Decision 'allow'
    exit 0
}

try {
    $payload = $rawPayload | ConvertFrom-Json
} catch {
    Write-Decision -Decision 'deny' -Reason 'Invalid hook payload'
    exit 1
}

$paths = New-Object System.Collections.Generic.List[string]

if ($payload.arguments) {
    foreach ($property in $payload.arguments.PSObject.Properties) {
        $value = $property.Value
        if ($value -is [string] -and $value -match '^[A-Za-z]:\\|\.\.|/') {
            [void]$paths.Add($value)
        }
    }
}

if ($payload.toolName -in @('bash', 'powershell', 'shell')) {
    $command = $payload.arguments.command
    if ($command) {
        $windowPaths = [regex]::Matches($command, '[A-Za-z]:\\[^\s"'']+')
        foreach ($match in $windowPaths) {
            [void]$paths.Add($match.Value)
        }

        if ($command -match '\.\.') {
            Write-Decision -Decision 'deny' -Reason 'Path traversal detected'
            exit 1
        }

        if ($command -match '>|>>') {
            $redirectMatches = [regex]::Matches($command, '>|>>\s*([^\s]+)')
            foreach ($match in $redirectMatches) {
                if ($match.Groups.Count -gt 1 -and $match.Groups[1].Value) {
                    [void]$paths.Add($match.Groups[1].Value)
                }
            }
        }
    }
}

foreach ($path in $paths) {
    if (-not (IsInsideAllowed $path)) {
        Write-Decision -Decision 'deny' -Reason ('Access outside allowed directory: ' + $path)
        exit 1
    }
}

Write-Decision -Decision 'allow'