#requires -Version 5.1
# Builds the client pack from the server .ini, commits the regenerated lists and publishes a GitHub
# release with the zip. The "latest" download link in the Steam collection then points to it.
# Usage: .\Publish-Release.ps1 [-Notes "what changed"]   (needs gh, logged in)
param([string]$Notes = 'Updated mod list.', [string]$ServerName = '3dpz')
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = 'C:\Program Files\GitHub CLI\gh.exe' }
& "$PSScriptRoot\Build-ClientPack.ps1" -ServerName $ServerName
$tag = 'v' + (Get-Date -Format 'yyyy.MM.dd')
if (& $gh release view $tag 2>$null) { $tag += '-' + (Get-Date -Format 'HHmm') }
git add -- client server-config
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) { git commit -q -m "Release $tag`n`n$Notes"; git push -q }
$body = "**Download PZ-3dpz-client.zip**, unpack, run Install.cmd, choose **2 - Update** (or **1** on a new PC).`n`n$Notes"
& $gh release create $tag "dist\PZ-$ServerName-client.zip" --title "Bad boys Band installer $tag" --notes $body --latest
