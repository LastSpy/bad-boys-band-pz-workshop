#requires -Version 5.1
# Refreshes client\workshop-ids.txt from the server config and zips the client folder into dist\.
# Run after every change of the server mod list.
param(
    [string]$ServerName = '3dpz',
    [string]$ZomboidDirectory = (Join-Path $env:USERPROFILE 'Zomboid')
)
$ErrorActionPreference = 'Stop'

$ini = Join-Path $ZomboidDirectory "Server\$ServerName.ini"
$line = Get-Content -LiteralPath $ini | Where-Object { $_ -like 'WorkshopItems=*' } | Select-Object -First 1
if (-not $line) { throw "No WorkshopItems in $ini" }
$ids = @($line.Substring('WorkshopItems='.Length) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })

# Client-only items that the server does not load (e.g. ZombieBuddy Extensions jar).
$client = Join-Path $PSScriptRoot 'client'
$extra = Join-Path $client 'extra-ids.txt'
if (Test-Path -LiteralPath $extra) { $ids += @(Get-Content -LiteralPath $extra | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }) }
$ids = @($ids | Select-Object -Unique)

[IO.File]::WriteAllLines((Join-Path $client 'workshop-ids.txt'), [string[]]$ids)

# Mod ids the server loads: the installer uses them to find subscribed items that ship the same id.
$modsLine = Get-Content -LiteralPath $ini | Where-Object { $_ -like 'Mods=*' } | Select-Object -First 1
$modIds = @($modsLine.Substring('Mods='.Length) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
[IO.File]::WriteAllLines((Join-Path $client 'mod-ids.txt'), [string[]]$modIds)
Write-Host "mod-ids.txt: $($modIds.Count) mods"
Write-Host "workshop-ids.txt: $($ids.Count) items from $ini"

# For people running their own server with this set: the three lines to paste into their .ini.
$cfgDir = Join-Path $PSScriptRoot 'server-config'
New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
$cfgLines = @(Get-Content -LiteralPath $ini | Where-Object { $_ -match '^(Mods|WorkshopItems|Map)=' })
[IO.File]::WriteAllLines((Join-Path $cfgDir "$ServerName-mods.ini"), [string[]]$cfgLines)
Write-Host "server-config\$ServerName-mods.ini: $($cfgLines.Count) lines"

$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$zip = Join-Path $dist "PZ-$ServerName-client.zip"
Compress-Archive -Path (Join-Path $client '*') -DestinationPath $zip -Force
Write-Host "Pack: $zip"
