#requires -Version 5.1
<#
  Установщик клиента для сервера Project Zomboid.
  1. Подписывается через Steam на все моды сервера (workshop-ids.txt).
  2. Ждёт загрузки модов, которым нужны файлы в папке игры.
  3. Кладёт эти файлы рядом с ProjectZomboid64.exe и прописывает их в ProjectZomboid64.site.json.
  4. Ставит PZ_Optimization (замена классов игры) его собственным установщиком.
  5. Включает в игре ровно те моды, что на сервере (Zomboid\mods\default.txt, mod-ids.txt).
  6. Выставляет настройки модов из mod-options.txt (Zomboid\Lua\modOptions.ini).
  7. Убирает из Zomboid\Lua\layout.ini окна, сохранённые с размером больше экрана.

  Запуск: двойной клик по Install.cmd. Steam должен быть запущен, игра закрыта.
  При запуске - меню: Первый запуск / Обновить / Настройки (последние два - если уже ставили).
  Что поставлено, хранится в Zomboid\bbb-installer.json.
  -Mode X        First, Update или Settings - без меню
  -Lang en|ru    язык сообщений (иначе спросит при первом запуске и запомнит)
  -DryRun        только показать, что будет сделано, ничего не менять
  -SkipSubscribe не подписываться на все моды (только обязательные)
  -Yes           не спрашивать перед отпиской от конфликтующих модов
  -HeapGB N      память для игры: 12, 10, 8 или 6 ГБ (иначе установщик спросит;
                 с -Yes берётся рекомендованное по объёму памяти ПК)
#>
param(
    [string]$GameDirectory,
    [switch]$DryRun,
    [switch]$SkipSubscribe,
    [switch]$Yes,
    [ValidateSet(12, 10, 8, 6)][int]$HeapGB,
    [ValidateSet('First', 'Update', 'Settings')][string]$Mode,
    [ValidateSet('en', 'ru')][string]$Lang,
    [int]$DownloadTimeoutMinutes = 120
)
$ErrorActionPreference = 'Stop'

$AppId = 108600

# Mods that need files beside the game EXE. Each entry: workshop id, file name, where it goes.
$IdZombieBuddy     = [uint64]3619862853   # original ZombieBuddy: zbNative.dll
$IdZombieBuddyExt  = [uint64]3807686870   # ZombieBuddy Extensions: replacement ZombieBuddy.jar
$RequiredIds = @($IdZombieBuddy, $IdZombieBuddyExt)
# PZ_Optimization (game class overrides) left the Steam Workshop (item 3805285544 gone, 2026-11). It is installed from
# the author's GitHub releases by the author's own install.ps1 and then updates itself from the game's main menu.
$PzoRepo = 'xD3I/PZ_Optimization'
# $true while there is no PZ_Optimization build for the game version the server runs (42.22.2 since 2026-11-10):
# the step then only removes a build left from the previous version (it can crash the updated game at start) and
# keeps the player's choice, so "Update" installs it again once this is back to $false.
$PzoPaused = $false

function Info($text) { Write-Host $text }
function Step($text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Warn($text) { Write-Host "! $text" -ForegroundColor Yellow }

# ---------------------------------------------------------------- language
# Every message is written as (L 'русский' 'English'); both are evaluated, one is shown.
$StateFile = Join-Path $env:USERPROFILE 'Zomboid\bbb-installer.json'
if (-not $Lang) {
    try { $Lang = (Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json).lang } catch { }
}
if ($Lang -notin @('en', 'ru')) {
    Write-Host '  1 - English'
    Write-Host '  2 - Русский'
    $Lang = if ((Read-Host 'Language / Язык') -eq '2') { 'ru' } else { 'en' }
}
function L([string]$ru, [string]$en) { if ($Lang -eq 'ru') { $ru } else { $en } }

if (-not [Environment]::Is64BitProcess) { throw (L 'Нужен 64-битный PowerShell. Запускайте через Install.cmd.' '64-bit PowerShell is required. Start it with Install.cmd.') }
if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { throw (L 'Steam не запущен. Запустите Steam, войдите в аккаунт с Project Zomboid и повторите.' 'Steam is not running. Start Steam, log in to the account that owns Project Zomboid and try again.') }
if (Get-Process ProjectZomboid64 -ErrorAction SilentlyContinue) { throw (L 'Закройте Project Zomboid перед установкой.' 'Close Project Zomboid before installing.') }

# ---------------------------------------------------------------- game folder
function Find-GameDirectory {
    $steamPath = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steamPath) { return $null }
    $libraries = @($steamPath)
    $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $libraries += $m.Groups[1].Value -replace '\\\\', '\'
        }
    }
    foreach ($lib in $libraries | Select-Object -Unique) {
        $manifest = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        $m = [regex]::Match((Get-Content -LiteralPath $manifest -Raw), '"installdir"\s+"([^"]+)"')
        if ($m.Success) {
            $dir = Join-Path $lib ("steamapps\common\" + $m.Groups[1].Value)
            if (Test-Path -LiteralPath (Join-Path $dir 'ProjectZomboid64.exe')) { return $dir }
        }
    }
    return $null
}

Step (L 'Папка игры' 'Game folder')
if (-not $GameDirectory) { $GameDirectory = Find-GameDirectory }
if (-not $GameDirectory) {
    Warn (L 'Не нашёл игру автоматически.' 'Could not find the game automatically.')
    $GameDirectory = (Read-Host (L 'Вставьте папку игры (Steam > Свойства > Установленные файлы > Обзор)' 'Paste the game folder (Steam > Properties > Installed Files > Browse)')).Trim('"')
}
if (-not (Test-Path -LiteralPath (Join-Path $GameDirectory 'ProjectZomboid64.exe'))) { throw (L "В папке нет ProjectZomboid64.exe: $GameDirectory" "No ProjectZomboid64.exe in: $GameDirectory") }
Info $GameDirectory

# ---------------------------------------------------------------- state and menu
# What this installer put on the PC. "Update" uses it to drop only mods that this installer
# subscribed to earlier and the server no longer uses - never anything the player added himself.
function Read-State {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try { Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { Warn (L "Не читается $StateFile - считаю, что установки не было." "Cannot read $StateFile - treating it as not installed."); $null }
}
$state = Read-State
# Tab-indented JSON, same style as the game's own ProjectZomboid64.json.
function ConvertTo-TabJson($o, [int]$lvl = 0) {
    $t = "`t" * ($lvl + 1); $tc = "`t" * $lvl
    if ($null -eq $o) { return 'null' }
    if ($o -is [string]) { return '"' + ($o.Replace('\', '\\').Replace('"', '\"')) + '"' }
    if ($o -is [bool]) { return $o.ToString().ToLower() }
    if ($o -is [array]) {
        if ($o.Count -eq 0) { return '[]' }
        $items = foreach ($i in $o) { $t + (ConvertTo-TabJson $i ($lvl + 1)) }
        return "[`n" + ($items -join ",`n") + "`n$tc]"
    }
    if ($o -is [pscustomobject]) {
        $props = @($o.PSObject.Properties)
        if ($props.Count -eq 0) { return '{}' }
        $items = foreach ($p in $props) { $t + '"' + $p.Name + '": ' + (ConvertTo-TabJson $p.Value ($lvl + 1)) }
        return "{`n" + ($items -join ",`n") + "`n$tc}"
    }
    return [string]$o
}
function Test-PzoInstalled { Test-Path -LiteralPath (Join-Path $GameDirectory 'pzopt-installed.txt') }
# The author's install.ps1 from the newest GitHub release, saved to %TEMP%. $null when GitHub is unreachable.
function Get-PzoScript {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $script = Join-Path $env:TEMP 'bbb-pzopt-install.ps1'
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$PzoRepo/releases/latest/download/install.ps1" -OutFile $script
        $script
    } catch { Warn ((L 'GitHub недоступен: ' 'GitHub unreachable: ') + $_.Exception.Message); $null }
}
# Newest release that has the classes for this game's revision (asset pzopt-<revision>-classes.zip).
function Get-PzoTag([string]$script) {
    $status = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Dir $GameDirectory -Status 2>&1 | Out-String
    $rev = [regex]::Match($status, 'game revision: (\w+)').Groups[1].Value
    if (-not $rev) { Warn (L 'Не удалось узнать ревизию игры.' 'Could not read the game revision.'); return $null }
    try {
        $rels = Invoke-RestMethod -UseBasicParsing -Headers @{ Accept = 'application/vnd.github+json' } "https://api.github.com/repos/$PzoRepo/releases?per_page=50"
    } catch { Warn ((L 'GitHub недоступен: ' 'GitHub unreachable: ') + $_.Exception.Message); return $null }
    $rel = $rels | Sort-Object published_at -Descending | Where-Object { $_.assets.name -contains "pzopt-$rev-classes.zip" } | Select-Object -First 1
    if (-not $rel) { Warn (L "Для этой версии игры ($rev) сборки PZ_Optimization ещё нет." "No PZ_Optimization build for this game version ($rev) yet."); return $null }
    Info (L "PZ_Optimization: релиз $($rel.tag_name) для ревизии игры $rev" "PZ_Optimization: release $($rel.tag_name) for game revision $rev")
    $rel.tag_name
}
# Runs PZ_Optimization's own install.ps1. Install: newest GitHub release (-Tag, so a stale Steam Workshop copy left on
# disk is never used). Uninstall/Status: the copy it keeps in the game folder, else the GitHub one.
function Invoke-Pzo([ValidateSet('Install', 'Uninstall', 'Status')][string]$Action) {
    $kept = Join-Path $GameDirectory 'pzopt\uninstall\install.ps1'
    $script = if ($Action -ne 'Install' -and (Test-Path -LiteralPath $kept)) { $kept } else { Get-PzoScript }
    if (-not $script) { return $false }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Dir', $GameDirectory)
    switch ($Action) {
        'Install'   { $tag = Get-PzoTag $script; if (-not $tag) { return $false }; $a += @('-Tag', $tag) }
        'Uninstall' { $a += '-Uninstall' }
        'Status'    { $a += '-Status' }
    }
    & powershell.exe @a | Out-Host
    if ($LASTEXITCODE -ne 0) { Warn (L "PZ_Optimization: код $LASTEXITCODE (см. сообщение выше)." "PZ_Optimization: exit code $LASTEXITCODE (see the message above)."); return $false }
    if ($Action -ne 'Status') { Sync-PzoAgent; Set-PzoLaunchOption $Action }
    $true
}
# PZ_Optimization's installer puts its agent into ProjectZomboid64.json, but the game reads ProjectZomboid64.site.json
# when it exists (written by this installer), so without this the agent never loads and its Lua menu errors (2026-11-13).
# The agent has to come first, before ZombieBuddy's zbNative.
$PzoAgentArg = '-javaagent:pzopt/agent/pzopt-agent.jar'
function Set-PzoAgentArg([string[]]$vmArgs) {
    $rest = @($vmArgs | Where-Object { $_ -and $_ -notmatch '(?i)^-javaagent:pzopt/' })
    if (Test-Path -LiteralPath (Join-Path $GameDirectory 'pzopt\agent\pzopt-agent.jar')) { @($PzoAgentArg) + $rest } else { $rest }
}
function Sync-PzoAgent {
    $site = Join-Path $GameDirectory 'ProjectZomboid64.site.json'
    if ($DryRun -or -not (Test-Path -LiteralPath $site)) { return }
    $cfg = Get-Content -LiteralPath $site -Raw | ConvertFrom-Json
    $old = @($cfg.vmArgs); $new = Set-PzoAgentArg $old
    if (($old -join "`n") -eq ($new -join "`n")) { return }
    $cfg.vmArgs = $new
    [IO.File]::WriteAllText($site, (ConvertTo-TabJson $cfg) + "`n", (New-Object Text.UTF8Encoding($false)))
    Info $(if ($new -contains $PzoAgentArg) { (L 'Агент PZ_Optimization добавлен в ProjectZomboid64.site.json.' 'PZ_Optimization agent added to ProjectZomboid64.site.json.') } else { (L 'Агент PZ_Optimization убран из ProjectZomboid64.site.json.' 'PZ_Optimization agent removed from ProjectZomboid64.site.json.') })
}
# Since 42.22 PZ_Optimization loads as a Java agent, and on Windows the game closes at once unless Steam starts it through
# pzopt-launch.cmd (a launch option). Steam keeps launch options in userdata\<account>\config\localconfig.vdf and rewrites
# that file while it runs, so Steam is closed for the edit and started again. If that fails, the player pastes the line.
function Get-PzoLaunchPrefix { "`"$(Join-Path $env:SystemRoot 'System32\conhost.exe')`" --headless `"$(Join-Path $GameDirectory 'pzopt-launch.cmd')`"" }
# Adds the wrapper in front of %command%. -agentlib:zbNative is dropped: the launcher JSON already has it, and a second
# copy could start ZombieBuddy before PZ_Optimization's agent (then the game runs stock).
function Add-PzoLaunchArgs([string]$opts, [string]$prefix) {
    $o = ([regex]::Replace([string]$opts, '(?i)(^|\s)-agentlib:zbNative(?=\s|$)', ' ') -replace '\s+', ' ').Trim()
    if ($o -match '(?i)pzopt-launch\.cmd') { return $(if ($o -eq ([string]$opts).Trim()) { $opts } else { $o }) }
    if ($o.Contains('%command%')) { return $o.Replace('%command%', "$prefix %command%") }
    ("$prefix %command% $o").Trim()
}
function Remove-PzoLaunchArgs([string]$opts) {
    $o = ([regex]::Replace([string]$opts, '(?i)"[^"]*conhost\.exe"\s+--headless\s+"[^"]*pzopt-launch\.cmd"\s*', '')).Trim()
    if ($o -eq '%command%') { return '' }
    if ($o.StartsWith('%command% ')) { return $o.Substring(10).Trim() }
    $o
}
function Get-SteamLocalConfig {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return $null }
    $user = (Get-ItemProperty 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction SilentlyContinue).ActiveUser
    if ($user) { $file = Join-Path $steam "userdata\$user\config\localconfig.vdf"; if (Test-Path -LiteralPath $file) { return $file } }
    Get-ChildItem -Path (Join-Path $steam 'userdata\*\config\localconfig.vdf') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
# Valve KeyValues text: quoted strings (Value unescaped; Start/End span the quotes) and braces; // comments skipped.
function Read-VdfTokens([string]$text) {
    $tokens = New-Object System.Collections.Generic.List[object]
    $i = 0; $n = $text.Length
    while ($i -lt $n) {
        $c = $text[$i]
        if ($c -eq '"') {
            $j = $i + 1; $sb = New-Object Text.StringBuilder
            while ($j -lt $n -and $text[$j] -ne '"') { if ($text[$j] -eq '\' -and $j + 1 -lt $n) { $j++ }; [void]$sb.Append($text[$j]); $j++ }
            $tokens.Add([pscustomobject]@{ Kind = 's'; Value = $sb.ToString(); Start = $i; End = $j + 1 }); $i = $j + 1
        }
        elseif ($c -eq '{' -or $c -eq '}') { $tokens.Add([pscustomobject]@{ Kind = [string]$c; Value = $null; Start = $i; End = $i + 1 }); $i++ }
        elseif ($c -eq '/' -and $i + 1 -lt $n -and $text[$i + 1] -eq '/') { while ($i -lt $n -and $text[$i] -ne "`n") { $i++ } }
        else { $i++ }
    }
    , $tokens
}
# Index of the key token at $path (case-insensitive), or -1.
function Find-VdfKey($tokens, [string[]]$path) {
    $stack = New-Object System.Collections.Generic.List[string]; $key = $null
    for ($k = 0; $k -lt $tokens.Count; $k++) {
        $t = $tokens[$k]
        if ($t.Kind -eq '{') { $stack.Add([string]$key); $key = $null }
        elseif ($t.Kind -eq '}') { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }; $key = $null }
        elseif ($null -ne $key) { $key = $null }
        else {
            $key = $t.Value
            if ($stack.Count -eq $path.Count - 1 -and $key -eq $path[-1]) {
                $same = $true; for ($d = 0; $d -lt $stack.Count; $d++) { if ($stack[$d] -ne $path[$d]) { $same = $false; break } }
                if ($same) { return $k }
            }
        }
    }
    -1
}
# Index of the '}' that closes the block whose key token is at $k.
function Find-VdfBlockEnd($tokens, [int]$k) {
    $depth = 0
    for ($m = $k + 1; $m -lt $tokens.Count; $m++) {
        if ($tokens[$m].Kind -eq '{') { $depth++ } elseif ($tokens[$m].Kind -eq '}') { $depth--; if ($depth -eq 0) { return $m } }
    }
    -1
}
$VdfApps = @('UserLocalConfigStore', 'Software', 'Valve', 'Steam', 'apps')
function ConvertTo-VdfString([string]$s) { '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }
function Get-SteamLaunchOptions([string]$file) {
    $tokens = Read-VdfTokens ([IO.File]::ReadAllText($file))
    $k = Find-VdfKey $tokens ($VdfApps + @([string]$AppId, 'LaunchOptions'))
    if ($k -ge 0 -and $tokens[$k + 1].Kind -eq 's') { $tokens[$k + 1].Value } else { '' }
}
# Writes the value; adds the key (and the game's block) when missing. $false when the file has no apps block.
function Set-SteamLaunchOptions([string]$file, [string]$value) {
    $text = [IO.File]::ReadAllText($file)
    $tokens = Read-VdfTokens $text
    $k = Find-VdfKey $tokens ($VdfApps + @([string]$AppId, 'LaunchOptions'))
    if ($k -ge 0 -and $tokens[$k + 1].Kind -eq 's') {
        $v = $tokens[$k + 1]; $text = $text.Substring(0, $v.Start) + (ConvertTo-VdfString $value) + $text.Substring($v.End)
    }
    else {
        $g = Find-VdfKey $tokens ($VdfApps + @([string]$AppId))
        $line = ("`t" * 6) + '"LaunchOptions"' + "`t`t" + (ConvertTo-VdfString $value) + "`n"
        if ($g -lt 0) {
            $g = Find-VdfKey $tokens $VdfApps
            if ($g -lt 0) { return $false }
            $line = ("`t" * 5) + "`"$AppId`"`n" + ("`t" * 5) + "{`n" + $line + ("`t" * 5) + "}`n"
        }
        $end = Find-VdfBlockEnd $tokens $g
        if ($end -lt 0) { return $false }
        $at = $text.LastIndexOf("`n", $tokens[$end].Start) + 1
        $text = $text.Substring(0, $at) + $line + $text.Substring($at)
    }
    $backup = "$file.bbb-backup"
    if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $file -Destination $backup }
    [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($false)))
    $true
}
function Get-SteamExe { $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath; if ($p) { Join-Path $p 'steam.exe' } }
function Stop-Steam {
    if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { return $true }
    $exe = Get-SteamExe; if (-not $exe) { return $false }
    Info (L 'Закрываю Steam...' 'Closing Steam...')
    Start-Process -FilePath $exe -ArgumentList '-shutdown'
    for ($i = 0; $i -lt 90; $i++) { Start-Sleep -Seconds 1; if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 2; return $true } }
    $false
}
function Show-PzoManualOption([string]$Action, [string]$line) {
    if ($Action -eq 'Uninstall') {
        Warn (L 'Не удалось убрать параметр запуска сам. Steam > Project Zomboid > Свойства > Общие > Параметры запуска: удалите часть с pzopt-launch.cmd, иначе игра не запустится.' 'Could not clear the launch option. Steam > Project Zomboid > Properties > General > Launch Options: remove the part with pzopt-launch.cmd, or the game will not start.')
        return
    }
    Warn (L 'Не удалось вписать параметр запуска сам. Без него игра с PZ_Optimization сразу закрывается.' 'Could not set the launch option. Without it the game closes at once with PZ_Optimization.')
    Info (L 'Steam > правый клик по Project Zomboid > Свойства > Общие > Параметры запуска, вставьте строку (она в буфере обмена):' 'Steam > right-click Project Zomboid > Properties > General > Launch Options, paste the line (it is on the clipboard):')
    Write-Host "  $line" -ForegroundColor Cyan
    try { Set-Clipboard -Value $line } catch { }
    if (-not $Yes) { [void](Read-Host (L 'Вставили? Нажмите Enter' 'Pasted it? Press Enter')) }
}
# Install: put the wrapper into the game's Steam launch options. Uninstall: take it out again.
function Set-PzoLaunchOption([string]$Action) {
    $prefix = Get-PzoLaunchPrefix
    if ($Action -ne 'Uninstall' -and -not (Test-Path -LiteralPath (Join-Path $GameDirectory 'pzopt-launch.cmd'))) { return }
    $compose = { param($o) if ($Action -eq 'Uninstall') { Remove-PzoLaunchArgs $o } else { Add-PzoLaunchArgs $o $prefix } }
    $file = Get-SteamLocalConfig
    $old = if ($file) { try { Get-SteamLaunchOptions $file } catch { $null } }
    if ($null -ne $old -and (& $compose $old) -eq $old) { Info (L 'Параметр запуска Steam уже в порядке.' 'Steam launch option already set.'); return }
    if ($DryRun) { Info (L "Параметр запуска Steam будет: $(& $compose $old)" "Steam launch option would be: $(& $compose $old)"); return }
    $ok = $false; $new = $null
    if ($null -ne $old -and (Stop-Steam)) {
        try {
            $old = Get-SteamLaunchOptions $file; $new = & $compose $old
            $ok = ($new -eq $old) -or (Set-SteamLaunchOptions $file $new)
        } catch { Warn $_.Exception.Message }
        $exe = Get-SteamExe; if ($exe) { Start-Process -FilePath $exe }
        Info (L 'Steam запущен снова.' 'Steam started again.')
    }
    if ($ok) { Info (L "Параметр запуска Steam: $(if ($new) { $new } else { '(пусто)' })" "Steam launch option: $(if ($new) { $new } else { '(empty)' })") }
    else { Show-PzoManualOption $Action "$prefix %command%" }
}
# Asked before PZ_Optimization is installed: it is not from the Workshop and changes the game's launch.
function Confirm-PzoDetails {
    if ($DryRun -or $Yes) { return $true }
    Warn (L 'Перед установкой PZ_Optimization подтвердите:' 'Before installing PZ_Optimization, please confirm:')
    Info (L '  1. Мод ставится из стороннего источника - с GitHub автора (github.com/xD3I/PZ_Optimization), не из мастерской Steam.' '  1. The mod comes from a third-party source - its author''s GitHub (github.com/xD3I/PZ_Optimization), not the Steam Workshop.')
    Info (L '  2. Он вносит изменения в файлы игры: кладёт свои файлы в папку игры и добавляет свой Java-агент в ProjectZomboid64.json и ProjectZomboid64.site.json.' '  2. It changes the game files: puts its files into the game folder and adds its Java agent to ProjectZomboid64.json and ProjectZomboid64.site.json.')
    Info (L '  3. Он меняет параметры запуска игры в Steam: туда впишется команда ниже (Steam для этого закроется на несколько секунд и запустится снова):' '  3. It changes the game''s Steam launch options: the command below is added (Steam closes for a few seconds for this and starts again):')
    Write-Host "     $(Get-PzoLaunchPrefix) %command%" -ForegroundColor Cyan
    Info (L '  Всё это убирается вместе с модом: Install.cmd > Настройки > Удалить PZ_Optimization.' '  All of this is undone with the mod: Install.cmd > Settings > Remove PZ_Optimization.')
    (Read-Host (L 'Подтверждаете? (д/Н)' 'Confirm? (y/N)')) -match '^(?i)(y|yes|д|да)$'
}
function Save-State($changes) {
    if ($DryRun) { return }
    $s = if ($state) { $state } else { [pscustomobject]@{} }
    foreach ($k in $changes.Keys) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $changes[$k] -Force }
    $s | Add-Member -NotePropertyName updated -NotePropertyValue (Get-Date -Format 's') -Force
    [IO.File]::WriteAllText($StateFile, ($s | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

if (-not $Mode) {
    Step (L 'Что сделать?' 'What to do?')
    Info (L '  1 - Первый запуск: подписка на моды, файлы в папку игры, настройки запуска, список модов' '  1 - First install: subscribe to mods, game folder files, launch settings, mod list')
    if ($state) {
        Info (L "  2 - Обновить (установлено $($state.updated)): то же + отписка от модов, которые сервер больше не использует" "  2 - Update (installed $($state.updated)): the same + unsubscribe from mods the server no longer uses")
        Info (L '  3 - Настройки' '  3 - Settings')
    }
    Info (L '  0 - Выход' '  0 - Exit')
    $choice = Read-Host (L 'Номер' 'Number')
    # $Mode has ValidateSet, so it cannot hold "nothing chosen"
    $picked = switch ($choice) { '1' { 'First' } '2' { if ($state) { 'Update' } } '3' { if ($state) { 'Settings' } } default { $null } }
    if (-not $picked) { Info (L 'Выход.' 'Bye.'); exit 0 }
    $Mode = $picked
}
if ($Mode -ne 'First' -and -not $state) { throw (L 'Установка ещё не делалась - выберите "Первый запуск".' 'Nothing is installed yet - choose "First install".') }

if ($Mode -eq 'Settings') {
    Step (L 'Настройки' 'Settings')
    $pzoOn = Test-PzoInstalled
    Info (L "PZ_Optimization (замена классов игры для FPS и подгрузки чанков): $(if ($pzoOn) { 'установлен' } else { 'не установлен' })" "PZ_Optimization (game class replacements for FPS and chunk loading): $(if ($pzoOn) { 'installed' } else { 'not installed' })")
    Info $(if ($pzoOn) { (L '  1 - Удалить PZ_Optimization' '  1 - Remove PZ_Optimization') } else { (L '  1 - Установить PZ_Optimization' '  1 - Install PZ_Optimization') })
    Info (L '  0 - Выход' '  0 - Exit')
    if ((Read-Host (L 'Номер' 'Number')) -ne '1') { Info (L 'Выход.' 'Bye.'); exit 0 }
    if ($pzoOn) {
        if (Invoke-Pzo 'Uninstall') { Save-State @{ pzOptimization = $false; pzoConfirmed = $false; lang = $Lang }; Info (L 'PZ_Optimization удалён; "Обновить" спросит, ставить ли его снова.' 'PZ_Optimization removed; "Update" will ask whether to install it again.') }
    } elseif (-not (Confirm-PzoDetails)) { Info (L 'Не подтверждено.' 'Not confirmed.') }
    else {
        if (Invoke-Pzo 'Install') { Save-State @{ pzOptimization = $true; pzoConfirmed = $true; lang = $Lang }; Info (L 'PZ_Optimization установлен.' 'PZ_Optimization installed.') }
    }
    exit 0
}

# ---------------------------------------------------------------- Steam API
$steamDll = Join-Path $GameDirectory 'steam_api64.dll'
if (-not (Test-Path -LiteralPath $steamDll)) { throw (L "Нет $steamDll" "Missing $steamDll") }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PzSteam {
    const string Dll = "steam_api64";
    const CallingConvention C = CallingConvention.Cdecl;
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibrary(string path);
    // Returns ESteamAPIInitResult, 0 = OK; errMsg is a 1024-byte buffer.
    [DllImport(Dll, CallingConvention = C)] public static extern int SteamAPI_InitFlat(byte[] errMsg);
    [DllImport(Dll, CallingConvention = C)] public static extern void SteamAPI_Shutdown();
    [DllImport(Dll, CallingConvention = C)] public static extern void SteamAPI_RunCallbacks();
    [DllImport(Dll, CallingConvention = C)] public static extern IntPtr SteamAPI_SteamUGC_v021();
    [DllImport(Dll, CallingConvention = C)] public static extern ulong SteamAPI_ISteamUGC_SubscribeItem(IntPtr self, ulong id);
    [DllImport(Dll, CallingConvention = C)] public static extern ulong SteamAPI_ISteamUGC_UnsubscribeItem(IntPtr self, ulong id);
    // The trailing bool (include locally disabled) exists only in newer SDKs; extra args are harmless on x64.
    [DllImport(Dll, CallingConvention = C)] public static extern uint SteamAPI_ISteamUGC_GetNumSubscribedItems(IntPtr self, [MarshalAs(UnmanagedType.I1)] bool includeDisabled);
    [DllImport(Dll, CallingConvention = C)] public static extern uint SteamAPI_ISteamUGC_GetSubscribedItems(IntPtr self, ulong[] ids, uint max, [MarshalAs(UnmanagedType.I1)] bool includeDisabled);
    [DllImport(Dll, CallingConvention = C)] public static extern uint SteamAPI_ISteamUGC_GetItemState(IntPtr self, ulong id);
    [DllImport(Dll, CallingConvention = C)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamUGC_DownloadItem(IntPtr self, ulong id, [MarshalAs(UnmanagedType.I1)] bool highPriority);
    [DllImport(Dll, CallingConvention = C)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamUGC_GetItemDownloadInfo(IntPtr self, ulong id, out ulong downloaded, out ulong total);
    [DllImport(Dll, CallingConvention = C)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamUGC_GetItemInstallInfo(IntPtr self, ulong id, out ulong size, byte[] folder, uint folderSize, out uint timestamp);
}
'@

# EItemState flags
$Subscribed = 1; $Installed = 4; $NeedsUpdate = 8; $Downloading = 16; $DownloadPending = 32

if ([PzSteam]::LoadLibrary($steamDll) -eq [IntPtr]::Zero) { throw (L "Не удалось загрузить $steamDll" "Could not load $steamDll") }
$env:SteamAppId = "$AppId"
$env:SteamGameId = "$AppId"
$initError = New-Object byte[] 1024
if ([PzSteam]::SteamAPI_InitFlat($initError) -ne 0) {
    $reason = [Text.Encoding]::UTF8.GetString($initError).TrimEnd([char]0)
    throw (L "Steam API не запустился ($reason). Проверьте, что Steam запущен и на этом аккаунте куплен Project Zomboid." "Steam API did not start ($reason). Check that Steam is running and this account owns Project Zomboid.")
}

try {
    $ugc = [PzSteam]::SteamAPI_SteamUGC_v021()
    if ($ugc -eq [IntPtr]::Zero) { throw (L 'Steam API не отдал интерфейс Workshop (ISteamUGC v021).' 'Steam API did not provide the Workshop interface (ISteamUGC v021).') }

    function Get-State([uint64]$id) { [PzSteam]::SteamAPI_ISteamUGC_GetItemState($ugc, $id) }
    function Test-Ready([uint64]$id) {
        $s = Get-State $id
        ($s -band $Installed) -and -not ($s -band ($NeedsUpdate -bor $Downloading -bor $DownloadPending))
    }
    function Get-ItemFolder([uint64]$id) {
        $buf = New-Object byte[] 4096
        $size = [uint64]0; $stamp = [uint32]0
        if (-not [PzSteam]::SteamAPI_ISteamUGC_GetItemInstallInfo($ugc, $id, [ref]$size, $buf, 4096, [ref]$stamp)) { return $null }
        $len = [Array]::IndexOf($buf, [byte]0); if ($len -lt 0) { $len = $buf.Length }
        [Text.Encoding]::UTF8.GetString($buf, 0, $len)
    }

    # ------------------------------------------------------------ subscribe
    $idsFile = Join-Path $PSScriptRoot 'workshop-ids.txt'
    $allIds = @()
    if (-not $SkipSubscribe) {
        if (-not (Test-Path -LiteralPath $idsFile)) { throw (L "Нет списка модов: $idsFile" "Mod list missing: $idsFile") }
        $allIds = @(Get-Content -LiteralPath $idsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [uint64]$_ })
    }
    $allIds = @($allIds + $RequiredIds | Select-Object -Unique)

    Step (L "Подписка на моды ($($allIds.Count))" "Subscribing to mods ($($allIds.Count))")
    $toSubscribe = @($allIds | Where-Object { -not ((Get-State $_) -band $Subscribed) })
    Info (L "Уже подписаны: $($allIds.Count - $toSubscribe.Count). Нужно подписаться: $($toSubscribe.Count)." "Already subscribed: $($allIds.Count - $toSubscribe.Count). To subscribe: $($toSubscribe.Count).")
    if ($toSubscribe.Count -and -not $DryRun) {
        $i = 0
        foreach ($id in $toSubscribe) {
            [void][PzSteam]::SteamAPI_ISteamUGC_SubscribeItem($ugc, $id)
            $i++
            if ($i % 10 -eq 0) { [PzSteam]::SteamAPI_RunCallbacks(); Write-Progress -Activity (L 'Подписка' 'Subscribing') -Status "$i / $($toSubscribe.Count)" -PercentComplete (100 * $i / $toSubscribe.Count) }
            Start-Sleep -Milliseconds 100
        }
        Write-Progress -Activity (L 'Подписка' 'Subscribing') -Completed
        # Let Steam process the requests, then report what did not stick.
        $deadline = (Get-Date).AddSeconds(60)
        do {
            [PzSteam]::SteamAPI_RunCallbacks(); Start-Sleep -Milliseconds 500
            $missing = @($toSubscribe | Where-Object { -not ((Get-State $_) -band $Subscribed) })
        } while ($missing.Count -and (Get-Date) -lt $deadline)
        if ($missing.Count) { Warn (L "Steam не подтвердил подписку на $($missing.Count) модов (возможно, удалены автором): $($missing -join ', ')" "Steam did not confirm $($missing.Count) subscriptions (maybe removed by the author): $($missing -join ', ')") }
        else { Info (L 'Подписка подтверждена.' 'Subscriptions confirmed.') }
    }

    # ------------------------------------------------------------ conflicts
    # Only things that actually clash with this server's set are touched; nothing is removed
    # just because an older setup had it. A mod (subscribed, or a local copy in Zomboid\Workshop)
    # conflicts when it:
    #   - ships a mod id the server also uses (an unofficial fix next to the original: the game may
    #     load the wrong one and refuse to join with "File doesn't match the one on the server");
    #   - is declared incompatible (mod.info incompatible=) with a server mod, or the other way round;
    #   - is in conflict-ids.txt: known clashes nobody declared (e.g. pz3d vs Viewpoint, both 3D renderers).
    Step (L 'Конфликты с модами сервера' 'Conflicts with the server mods')
    function Read-ModInfos([string]$folder) {
        Get-ChildItem -LiteralPath $folder -Recurse -File -Filter mod.info -ErrorAction SilentlyContinue | ForEach-Object {
            $t = [IO.File]::ReadAllText($_.FullName)
            $get = { param($k) $m = [regex]::Match($t, "(?im)^\s*$k\s*=\s*(.*?)\s*$"); if ($m.Success) { $m.Groups[1].Value } else { '' } }
            [pscustomobject]@{
                Id = (& $get 'id').TrimStart([char]92)
                Incompatible = @((& $get 'incompatible') -split '[,;]' | ForEach-Object { $_.Trim().TrimStart([char]92) } | Where-Object { $_ })
            }
        }
    }
    $serverModIds = @{}
    Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mod-ids.txt') -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Trim()) { $serverModIds[$_.Trim()] = $true } }
    # conflict-ids.txt: one entry per line, a Workshop item number or a mod id, then "# reason".
    $knownBad = @{}; $knownBadMods = @{}
    Get-Content -LiteralPath (Join-Path $PSScriptRoot 'conflict-ids.txt') -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_ -match '^\s*([^#\s][^#]*?)\s*(?:#\s*(.*))?$') {
            $key = $Matches[1]; $reason = $Matches[2]
            if ($key -match '^\d+$') { $knownBad[$key] = $reason } else { $knownBadMods[$key] = $reason }
        }
    }
    # From the file, not $allIds: with -SkipSubscribe $allIds holds only the required mods.
    $serverItems = @{}
    foreach ($id in @(Get-Content -LiteralPath $idsFile -ErrorAction SilentlyContinue) + $allIds) { if ("$id".Trim() -match '^\d+$') { $serverItems["$id".Trim()] = $true } }
    # ids that server mods declare incompatible with (read from the downloaded server items)
    $serverDeclared = @{}
    foreach ($id in $serverItems.Keys) {
        $f = Get-ItemFolder ([uint64]$id)
        if ($f -and (Test-Path -LiteralPath $f)) { foreach ($mi in Read-ModInfos $f) { foreach ($x in $mi.Incompatible) { $serverDeclared[$x] = $mi.Id } } }
    }
    function Get-Clash([string]$workshopId, [string]$folder) {
        $why = @()
        if ($workshopId -and $knownBad.ContainsKey($workshopId)) { $why += (L "известный конфликт: $($knownBad[$workshopId])" "known conflict: $($knownBad[$workshopId])") }
        foreach ($mi in Read-ModInfos $folder) {
            if (-not $mi.Id) { continue }
            if ($serverModIds.ContainsKey($mi.Id)) { $why += (L "тот же id, что у мода сервера: $($mi.Id)" "same mod id as a server mod: $($mi.Id)") }
            if ($knownBadMods.ContainsKey($mi.Id)) { $why += (L "известный конфликт: $($knownBadMods[$mi.Id])" "known conflict: $($knownBadMods[$mi.Id])") }
            foreach ($x in $mi.Incompatible) { if ($serverModIds.ContainsKey($x)) { $why += (L "$($mi.Id) несовместим с $x" "$($mi.Id) is incompatible with $x") } }
            if ($serverDeclared.ContainsKey($mi.Id)) { $why += (L "$($serverDeclared[$mi.Id]) несовместим с $($mi.Id)" "$($serverDeclared[$mi.Id]) is incompatible with $($mi.Id)") }
        }
        @($why | Select-Object -Unique)
    }
    $count = [PzSteam]::SteamAPI_ISteamUGC_GetNumSubscribedItems($ugc, $true)
    $subscribedList = New-Object 'uint64[]' ([Math]::Max($count, 1))
    $count = [PzSteam]::SteamAPI_ISteamUGC_GetSubscribedItems($ugc, $subscribedList, $subscribedList.Length, $true)
    $conflicts = @()
    if ($count -gt 0) {
        foreach ($id in $subscribedList[0..([int]$count - 1)]) {
            if ($serverItems.ContainsKey([string]$id)) { continue }
            $folder = Get-ItemFolder $id
            if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
            $why = Get-Clash ([string]$id) $folder
            if ($why.Count) { $conflicts += [pscustomobject]@{ Kind = 'sub'; Id = $id; Path = $folder; Why = $why -join '; ' } }
        }
    }
    # Local mods (Zomboid\Workshop\<name>\Contents\mods) take priority over subscriptions.
    $localRoot = Join-Path $env:USERPROFILE 'Zomboid\Workshop'
    foreach ($d in Get-ChildItem -LiteralPath $localRoot -Directory -ErrorAction SilentlyContinue) {
        if ($d.Name -eq 'ModTemplate') { continue }
        # The game writes id=<Workshop item> into workshop.txt after an upload: a folder whose item is on
        # the server is the upload source of that very mod (the player published it), not a conflict.
        $wsTxt = Join-Path $d.FullName 'workshop.txt'
        $published = if (Test-Path -LiteralPath $wsTxt) { [regex]::Match((Get-Content -LiteralPath $wsTxt -Raw), '(?m)^id=(\d+)').Groups[1].Value } else { '' }
        if ($published -and $serverItems.ContainsKey($published)) {
            Info (L "Исходник вашего мода $published ($($d.Name)) - не конфликт. Правки в нём загружайте в Workshop, иначе сервер не пустит." "Source of your mod $published ($($d.Name)) - not a conflict. Upload edits to the Workshop, or the server will not let you in.")
            continue
        }
        $why = Get-Clash '' $d.FullName
        if ($why.Count) { $conflicts += [pscustomobject]@{ Kind = 'local'; Id = $d.Name; Path = $d.FullName; Why = $why -join '; ' } }
    }
    if (-not $serverModIds.Count) { Warn (L 'Нет mod-ids.txt, проверка пропущена.' 'No mod-ids.txt, check skipped.') }
    elseif (-not $conflicts.Count) { Info (L 'Конфликтов нет.' 'No conflicts.') }
    else {
        foreach ($c in $conflicts) {
            $what = if ($c.Kind -eq 'sub') { (L "Подписка $($c.Id)" "Subscription $($c.Id)") } else { (L "Локальный мод $($c.Path)" "Local mod $($c.Path)") }
            Warn "$what - $($c.Why)"
        }
        $answer = if ($DryRun) { 'n' } elseif ($Yes) { 'y' } else { Read-Host (L 'Убрать их (подписки - отписать, локальные - перенести в Zomboid\Workshop-disabled)? Иначе вход или игра могут сломаться (y/n)' 'Remove them (unsubscribe; move local ones to Zomboid\Workshop-disabled)? Otherwise joining or the game may break (y/n)') }
        if ($answer -match (L '^(y|д)' '^(y|д)')) {
            foreach ($c in $conflicts) {
                if ($c.Kind -eq 'sub') { [void][PzSteam]::SteamAPI_ISteamUGC_UnsubscribeItem($ugc, $c.Id); Info (L "отписан: $($c.Id)" "unsubscribed: $($c.Id)") }
                else {
                    $aside = Join-Path $env:USERPROFILE ('Zomboid\Workshop-disabled\' + $c.Id + '-' + (Get-Date -Format 'yyyyMMdd'))
                    New-Item -ItemType Directory -Path (Split-Path $aside) -Force | Out-Null
                    Move-Item -LiteralPath $c.Path -Destination $aside
                    Info (L "перенесён: $($c.Path) -> $aside" "moved: $($c.Path) -> $aside")
                }
            }
            1..10 | ForEach-Object { [PzSteam]::SteamAPI_RunCallbacks(); Start-Sleep -Milliseconds 300 }
        } elseif (-not $DryRun) { Warn (L 'Оставлены как есть.' 'Left as they are.') }
    }

    # ------------------------------------------------------------ mods the server dropped (Update)
    if ($Mode -eq 'Update' -and $state.items) {
        $keep = @{}; foreach ($id in $allIds) { $keep[[string]$id] = $true }
        $dropped = @($state.items | Where-Object { -not $keep.ContainsKey([string]$_) -and ((Get-State ([uint64]$_)) -band $Subscribed) })
        Step (L "Моды, которые сервер больше не использует ($($dropped.Count))" "Mods the server no longer uses ($($dropped.Count))")
        foreach ($id in $dropped) {
            if ($DryRun) { Info (L "будет отписан: $id" "will unsubscribe: $id") }
            else { [void][PzSteam]::SteamAPI_ISteamUGC_UnsubscribeItem($ugc, [uint64]$id); Info (L "отписан: $id (Steam удалит его файлы)" "unsubscribed: $id (Steam will delete its files)") }
        }
        if ($dropped.Count -and -not $DryRun) { 1..10 | ForEach-Object { [PzSteam]::SteamAPI_RunCallbacks(); Start-Sleep -Milliseconds 300 } }
        if (-not $dropped.Count) { Info (L 'Нет.' 'None.') }
    }

    # ------------------------------------------------------------ wait for required mods
    Step (L 'Загрузка модов с файлами для папки игры' 'Downloading mods with files for the game folder')
    if (-not $DryRun) {
        foreach ($id in $RequiredIds) { if (-not (Test-Ready $id)) { [void][PzSteam]::SteamAPI_ISteamUGC_DownloadItem($ugc, $id, $true) } }
        $deadline = (Get-Date).AddMinutes($DownloadTimeoutMinutes)
        while ($true) {
            [PzSteam]::SteamAPI_RunCallbacks()
            $pending = @($RequiredIds | Where-Object { -not (Test-Ready $_) })
            if (-not $pending.Count) { break }
            if ((Get-Date) -gt $deadline) { throw (L "Steam не скачал моды за $DownloadTimeoutMinutes мин: $($pending -join ', '). Дождитесь загрузки в Steam и запустите установщик ещё раз." "Steam did not download these mods in $DownloadTimeoutMinutes min: $($pending -join ', '). Wait for Steam and run the installer again.") }
            $done = [uint64]0; $total = [uint64]0
            [void][PzSteam]::SteamAPI_ISteamUGC_GetItemDownloadInfo($ugc, $pending[0], [ref]$done, [ref]$total)
            $pct = if ($total) { [int](100 * $done / $total) } else { 0 }
            Write-Progress -Activity (L 'Steam качает моды' 'Steam is downloading mods') -Status (L "осталось $($pending.Count), текущий $($pending[0])" "$($pending.Count) left, current $($pending[0])") -PercentComplete $pct
            Start-Sleep -Milliseconds 500
        }
        Write-Progress -Activity (L 'Steam качает моды' 'Steam is downloading mods') -Completed
    }
    # ------------------------------------------------------------ wait for all mods
    # The game would otherwise download missing mods on join, one by one.
    if (-not $DryRun -and -not $SkipSubscribe) {
        Step (L 'Загрузка остальных модов' 'Downloading the other mods')
        $deadline = (Get-Date).AddMinutes($DownloadTimeoutMinutes)
        $asked = @{}
        while ($true) {
            [PzSteam]::SteamAPI_RunCallbacks()
            $pending = @($allIds | Where-Object { ((Get-State $_) -band $Subscribed) -and -not (Test-Ready $_) })
            if (-not $pending.Count) { Info (L "Все моды скачаны ($($allIds.Count))." "All mods downloaded ($($allIds.Count))."); break }
            foreach ($id in $pending) { if (-not $asked.ContainsKey($id)) { [void][PzSteam]::SteamAPI_ISteamUGC_DownloadItem($ugc, $id, $false); $asked[$id] = $true } }
            if ((Get-Date) -gt $deadline) { Warn (L "Не докачано за $DownloadTimeoutMinutes мин: $($pending.Count). Steam докачает сам, или игра при входе." "Not finished in $DownloadTimeoutMinutes min: $($pending.Count). Steam will finish on its own, or the game on join."); break }
            Write-Progress -Activity (L 'Steam качает моды' 'Steam is downloading mods') -Status (L "готово $($allIds.Count - $pending.Count) из $($allIds.Count)" "$($allIds.Count - $pending.Count) of $($allIds.Count) ready") -PercentComplete (100 * ($allIds.Count - $pending.Count) / $allIds.Count)
            Start-Sleep -Seconds 1
        }
        Write-Progress -Activity (L 'Steam качает моды' 'Steam is downloading mods') -Completed
    }

    $folders = @{}
    foreach ($id in $RequiredIds) {
        $folder = Get-ItemFolder $id
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) {
            if ($DryRun) { Warn (L "$id ещё не скачан" "$id not downloaded yet"); continue }
            throw (L "Не найдена папка мода $id" "Mod folder not found: $id")
        }
        $folders[$id] = $folder
        Info "$id -> $folder"
    }
}
finally {
    [PzSteam]::SteamAPI_Shutdown()
}

# ---------------------------------------------------------------- copy files
function Find-ModFile([uint64]$id, [string]$name, [string]$under) {
    if (-not $folders.ContainsKey($id)) { return $null }
    $file = Get-ChildItem -LiteralPath $folders[$id] -Recurse -File -Filter $name |
        Where-Object { $_.FullName -like "*$under*" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $file) { throw (L "В моде $id нет файла $name" "Mod $id has no file $name") }
    $file.FullName
}

# Target is relative to the game folder.
$plan = @(
    @{ Target = 'zbNative.dll';                  Source = Find-ModFile $IdZombieBuddy    'zbNative.dll'       'ZombieBuddy\libs' }
    @{ Target = 'ZombieBuddy.jar';               Source = Find-ModFile $IdZombieBuddyExt 'ZombieBuddy.jar'    'ZombieBuddy_Extensions' }
) | Where-Object { $_.Source }

Step (L 'Файлы в папку игры' 'Files for the game folder')
foreach ($item in $plan) {
    $target = Join-Path $GameDirectory $item.Target
    $same = (Test-Path -LiteralPath $target) -and ((Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $item.Source).Hash)
    if ($same) { Info (L "без изменений: $target" "unchanged: $target"); continue }
    if ($DryRun) { Info (L "будет скопирован: $target" "will copy: $target"); continue }
    # Keep the very first replaced file so the player can roll back by hand.
    if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath "$target.bak")) { Copy-Item -LiteralPath $target -Destination "$target.bak" }
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath $item.Source -Destination $target -Force
    Info (L "скопирован: $target" "copied: $target")
}

# ---------------------------------------------------------------- launcher settings
Step (L 'Параметры запуска (ProjectZomboid64.site.json)' 'Launch settings (ProjectZomboid64.site.json)')
$settings = Join-Path $GameDirectory 'ProjectZomboid64.site.json'
$source = if (Test-Path -LiteralPath $settings) { $settings } else { Join-Path $GameDirectory 'ProjectZomboid64.json' }
$config = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json
if ($config.vmArgs -isnot [Array]) { throw (L "В $source нет массива vmArgs" "No vmArgs array in $source") }
$before = @($config.vmArgs)

# Drop every pz3d loader variant. Everything else stays.
$arguments = New-Object System.Collections.Generic.List[string]
foreach ($a in $before) {
    if ([string]::IsNullOrWhiteSpace([string]$a)) { continue }
    if ([string]$a -match '(?i)pz3dLoader') { continue }
    $arguments.Add([string]$a)
}
if (-not ($arguments | Where-Object { $_ -match '(?i)^-agentlib:zbNative' })) { $arguments.Insert(0, '-agentlib:zbNative') }

# Heap: the player picks the game's memory limit; the default fits the PC's RAM.
# With ~330 mods and Viewpoint the game needs at least 6 GB; more than half of the PC's RAM starves Windows.
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$heapChoices = [ordered]@{
    12 = (L 'для ПК с 32 ГБ памяти и больше' 'for PCs with 32 GB of RAM or more')
    10 = (L 'для ПК с 32 ГБ, если открыто много других программ' 'for PCs with 32 GB when many other programs are open')
    8  = (L 'для ПК с 24 ГБ памяти' 'for PCs with 24 GB of RAM')
    6  = (L 'для ПК с 16 ГБ и меньше (минимум для этой сборки модов)' 'for PCs with 16 GB or less (minimum for this mod set)')
}
# Viewpoint, textures and native libraries take several GB on top of this limit: on a 16 GB laptop
# with -Xmx8g the game reached 18-19 GB commit and crashed in native code (2026-10-17).
$recommended = if ($ramGB -ge 32) { 12 } elseif ($ramGB -ge 24) { 8 } else { 6 }
$current = @($arguments | Where-Object { $_ -match '^-Xmx' }) -join ' '
if ($HeapGB) { $heap = $HeapGB }
elseif ($Mode -eq 'Update' -and $state.heapGB) {
    # keep the player's choice on updates, but offer to lower a value above today's recommendation
    $heap = [int]$state.heapGB
    if ($heap -gt $recommended -and -not ($DryRun -or $Yes)) {
        Warn (L "Игре сейчас отдано $heap ГБ, а для ПК с $ramGB ГБ рекомендуется $recommended ГБ: при нехватке памяти игра виснет и вылетает." "The game now gets $heap GB; for a PC with $ramGB GB, $recommended GB is recommended: short of memory, the game hangs and crashes.")
        if ((Read-Host (L "Снизить до $recommended ГБ? (Д/н)" "Lower it to $recommended GB? (Y/n)")) -notmatch '^(?i)(n|н|no|нет)$') { $heap = $recommended }
    }
}
elseif ($DryRun -or $Yes) { $heap = $recommended }
else {
    Info (L "Память компьютера: $ramGB ГБ. Сейчас для игры: $(if ($current) { $current } else { 'не задано' })." "PC memory: $ramGB GB. Game now gets: $(if ($current) { $current } else { 'not set' }).")
    Info (L 'Сколько памяти отдать игре:' 'How much memory to give the game:')
    foreach ($k in $heapChoices.Keys) { Info ((L "  {0,2} ГБ - {1}{2}" "  {0,2} GB - {1}{2}") -f $k, $heapChoices[$k], $(if ($k -eq $recommended) { (L '  <- рекомендуется' '  <- recommended') } else { '' })) }
    $answer = Read-Host (L "Введите 12, 10, 8 или 6 (Enter = $recommended)" "Type 12, 10, 8 or 6 (Enter = $recommended)")
    $heap = if ($answer -match '^(12|10|8|6)$') { [int]$answer } else { $recommended }
}
if ($heap -gt $ramGB / 2) { Warn (L "Игре отдано $heap ГБ из $ramGB ГБ памяти - Windows и Steam может не хватить." "The game gets $heap GB of $ramGB GB - Windows and Steam may run short.") }
# Replace the first -Xmx in place (keeps the file unchanged when the value is the same), drop extras.
# Required launch arguments, in order. Missing ones are added; unknown existing ones are kept at the end.
$defaultArgs = @(
    '-agentlib:zbNative'
    '-Djava.awt.headless=true'
    '--enable-native-access=ALL-UNNAMED'
    '--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED'
    '{XMX}'
    '-Dzomboid.steam=1'
    '-Dzomboid.znetlog=1'
    '-Djava.library.path=win64/;.'
    '-XX:-CreateCoredumpOnCrash'
    '-XX:-OmitStackTraceInFastThrow'
)
$result = New-Object System.Collections.Generic.List[string]
foreach ($d in $defaultArgs) {
    if ($d -eq '{XMX}') { $result.Add("-Xmx${heap}g") } else { $result.Add($d) }
}
foreach ($a in $arguments) {
    if ($a -match '^-Xmx') { continue }
    if ($a -match '(?i)pz3dLoader') { continue }
    if (-not $result.Contains($a)) { $result.Add($a) }
}
$arguments = Set-PzoAgentArg @($result)
Info (L "Память для игры: $heap ГБ" "Game memory: $heap GB")

# GC for Windows 10 build 17134+: Shenandoah (recommended by the game) instead of ZGC.
$gcOld = ''
if ($config.windows -and $config.windows.'10.0.17134') { $gcOld = (@($config.windows.'10.0.17134'.vmArgs) -join ' ') }
$gcChanged = ($gcOld -ne '-XX:+UseShenandoahGC')

$changed = ($gcChanged) -or (($before -join "`n") -ne ($arguments -join "`n"))
if (-not $changed) { Info (L 'без изменений' 'unchanged') }
elseif ($DryRun) { Info (L "будет: $($arguments -join ' ')" "will be: $($arguments -join ' ')") }
else {
    if (Test-Path -LiteralPath $settings) { Copy-Item -LiteralPath $settings -Destination "$settings.bak" -Force }
    $config.vmArgs = $arguments
    if ($gcChanged) {
        if (-not $config.windows) { $config | Add-Member -NotePropertyName windows -NotePropertyValue ([pscustomobject]@{}) }
        $win = [pscustomobject]@{ vmArgs = @('-XX:+UseShenandoahGC') }
        if ($config.windows.PSObject.Properties['10.0.17134']) { $config.windows.'10.0.17134' = $win }
        else { $config.windows | Add-Member -NotePropertyName '10.0.17134' -NotePropertyValue $win }
    }
    [IO.File]::WriteAllText($settings, (ConvertTo-TabJson $config) + "`n", (New-Object Text.UTF8Encoding($false)))
    Info (L "было:  $($before -join ' ')" "before: $($before -join ' ')")
    Info (L "стало: $($arguments -join ' ')" "after:  $($arguments -join ' ')")
}

# ---------------------------------------------------------------- PZ_Optimization
# Replaces game classes; since 42.22 (signed projectzomboid.jar) through a Java agent plus a Steam launch option.
# Its own install.ps1 checks the game revision, records the files in pzopt-installed.txt and leaves
# Uninstall-PZ-Optimization.cmd; the classes come from the author's GitHub release, updates from the game's menu.
Step 'PZ_Optimization'
if ($PzoPaused) {
    $wantPzo = if ($state) { $state.pzOptimization } else { $null }
    Info (L 'Временно не ставится: под эту версию игры сборки PZ_Optimization ещё нет.' 'Not installed for now: there is no PZ_Optimization build for this game version yet.')
    if (Test-PzoInstalled) {
        if ($DryRun) { Info (L 'будет удалена сборка для прошлой версии игры' 'would remove the build for the previous game version') }
        elseif (Invoke-Pzo 'Uninstall') { Info (L 'Удалена сборка для прошлой версии игры (могла ронять игру при запуске).' 'Removed the build for the previous game version (it could crash the game at start).') }
    }
}
# Update keeps it only for players who confirmed the three points (pzoConfirmed); everyone else is asked, also on Update.
elseif ($Mode -eq 'Update' -and $state.pzOptimization -eq $true -and $state.pzoConfirmed -eq $true) { $wantPzo = $true }
elseif ($DryRun -or $Yes) { $wantPzo = $true }
else {
    Info (L 'PZ_Optimization заменяет часть классов игры: меньше фризов, быстрее подгружаются чанки.' 'PZ_Optimization replaces some game classes: fewer stutters, faster chunk loading.')
    Info (L 'Автор не проверял его в мультиплеере и с другими модами. Удалить можно в любой момент: Install.cmd > Настройки.' 'Its author has not tested it in multiplayer or with other mods. Remove it any time: Install.cmd > Settings.')
    $wantPzo = (Read-Host (L 'Ставить PZ_Optimization? (Д/н)' 'Install PZ_Optimization? (Y/n)')) -notmatch '^(?i)(n|no|н|нет)$'
    if ($wantPzo) { $wantPzo = Confirm-PzoDetails; if (-not $wantPzo) { Info (L 'Не подтверждено.' 'Not confirmed.') } }
}
if ($PzoPaused) { }
elseif (-not $wantPzo) {
    # A build left from an earlier install without the launch option would only make the game close at start.
    if (Test-PzoInstalled) {
        if ($DryRun) { Info (L 'будет удалён установленный PZ_Optimization' 'would remove the installed PZ_Optimization') }
        elseif (Invoke-Pzo 'Uninstall') { Info (L 'Установленный PZ_Optimization удалён.' 'The installed PZ_Optimization was removed.') }
    }
    else { Info (L 'не ставится' 'not installed') }
}
elseif ($DryRun) { [void](Invoke-Pzo 'Status'); Set-PzoLaunchOption 'Install' }
else {
    if (Invoke-Pzo 'Install') { Info (L 'Обновления PZ_Optimization: главное меню игры > PZ OPTIMIZATION > UPDATE.' 'PZ_Optimization updates: game main menu > PZ OPTIMIZATION > UPDATE.') }
}

# ---------------------------------------------------------------- enabled mods
# The game loads Java mods (Viewpoint, ZombieBuddy add-ons) at start-up from the main-menu mod list,
# not from the server's list, so the player's Zomboid\mods\default.txt gets exactly the server's mods,
# in the server's load order. The previous file is kept once per day.
Step (L 'Включённые моды (Zomboid\mods\default.txt)' 'Enabled mods (Zomboid\mods\default.txt)')
$enabledFile = Join-Path $env:USERPROFILE 'Zomboid\mods\default.txt'
$serverMods = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mod-ids.txt') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $serverMods.Count) { Warn (L 'mod-ids.txt пуст - пропущено.' 'mod-ids.txt is empty - skipped.') }
else {
    $nl = "`r`n"
    $text = 'VERSION = 1,' + $nl + $nl + 'mods' + $nl + '{' + $nl +
        (($serverMods | ForEach-Object { "    mod = $_," }) -join $nl) + $nl + '}' + $nl + $nl + 'maps' + $nl + '{' + $nl + '}' + $nl
    $old = if (Test-Path -LiteralPath $enabledFile) { [IO.File]::ReadAllText($enabledFile) } else { '' }
    if ($old -eq $text) { Info (L "без изменений ($($serverMods.Count) модов)" "unchanged ($($serverMods.Count) mods)") }
    elseif ($DryRun) { Info (L "будет включено модов: $($serverMods.Count) (сейчас: $(([regex]::Matches($old, '(?m)^\s*mod = ')).Count))" "mods to enable: $($serverMods.Count) (now: $(([regex]::Matches($old, '(?m)^\s*mod = ')).Count))") }
    else {
        New-Item -ItemType Directory -Path (Split-Path $enabledFile) -Force | Out-Null
        if ($old) { Copy-Item -LiteralPath $enabledFile -Destination ($enabledFile + '.bak-' + (Get-Date -Format 'yyyyMMdd')) -Force }
        [IO.File]::WriteAllText($enabledFile, $text, (New-Object Text.UTF8Encoding($false)))
        Info (L "включено модов: $($serverMods.Count) (прежний список сохранён рядом, .bak-$(Get-Date -Format 'yyyyMMdd'))" "mods enabled: $($serverMods.Count) (previous list saved next to it, .bak-$(Get-Date -Format 'yyyyMMdd'))")
    }
}

# ---------------------------------------------------------------- mod options
# mod-options.txt holds lines in the game's own format (type|group|option|value). First install sets
# all of them; Update only those added since the last install, so a setting the player changed in
# the game afterwards is not reverted. The game rewrites this file on exit - it is closed here.
Step (L 'Настройки модов (Zomboid\Lua\modOptions.ini)' 'Mod options (Zomboid\Lua\modOptions.ini)')
$presets = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mod-options.txt') -ErrorAction SilentlyContinue |
    ForEach-Object { ($_ -replace '\s+#.*$', '').Trim() } | Where-Object { $_ -match '^[^#|]+\|[^|]+\|[^|]+\|' })
$appliedBefore = @(if ($state -and $state.appliedOptions) { $state.appliedOptions })
$todo = @(if ($Mode -eq 'Update') { $presets | Where-Object { $appliedBefore -notcontains $_ } } else { $presets })
if (-not $todo.Count) { Info (L 'без изменений' 'unchanged') }
else {
    $optFile = Join-Path $env:USERPROFILE 'Zomboid\Lua\modOptions.ini'
    $optLines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $optFile) { $optLines.AddRange([string[]][IO.File]::ReadAllLines($optFile)) }
    foreach ($pr in $todo) {
        $key = (($pr -split '\|')[0..2] -join '|') + '|'
        $at = -1
        for ($i = 0; $i -lt $optLines.Count; $i++) { if ($optLines[$i].StartsWith($key)) { $at = $i; break } }
        if ($at -ge 0) { $optLines[$at] = $pr } else { $optLines.Add($pr) }
        Info $(if ($DryRun) { (L "будет: $pr" "will set: $pr") } else { (L "выставлено: $pr" "set: $pr") })
    }
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path (Split-Path $optFile) -Force | Out-Null
        if (Test-Path -LiteralPath $optFile) { Copy-Item -LiteralPath $optFile -Destination ($optFile + '.bak-' + (Get-Date -Format 'yyyyMMdd')) -Force }
        [IO.File]::WriteAllText($optFile, (($optLines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    }
}
$appliedOptions = @(@($appliedBefore) + @($todo) | Where-Object { $_ } | Select-Object -Unique)

# ---------------------------------------------------------------- window layouts
# Zomboid\Lua\layout.ini keeps window positions per resolution ([2560x1440] ...). A window that once
# saved a size bigger than the screen (seen with the radio/TV window: height=390176) is restored
# off-screen and looks like it never opens. Such lines are dropped; the game then uses its default.
Step (L 'Окна интерфейса (Zomboid\Lua\layout.ini)' 'UI windows (Zomboid\Lua\layout.ini)')
$layoutFile = Join-Path $env:USERPROFILE 'Zomboid\Lua\layout.ini'
if (-not (Test-Path -LiteralPath $layoutFile)) { Info (L 'файла нет - нечего чинить' 'no file - nothing to fix') }
else {
    $kept = New-Object System.Collections.Generic.List[string]
    $bad = 0; $scrW = 0; $scrH = 0
    foreach ($ln in [IO.File]::ReadAllLines($layoutFile)) {
        if ($ln -match '^\[(\d+)x(\d+)\]') { $scrW = [int]$Matches[1]; $scrH = [int]$Matches[2]; $kept.Add($ln); continue }
        $w = if ($ln -match '\bwidth=(-?\d+)') { [long]$Matches[1] } else { 0 }
        $h = if ($ln -match '\bheight=(-?\d+)') { [long]$Matches[1] } else { 0 }
        if ($scrW -gt 0 -and ($w -gt $scrW -or $h -gt $scrH)) {
            $bad++
            Info (L "убрано окно больше экрана: $(($ln -split ' ')[0]) ${w}x$h при ${scrW}x$scrH" "dropped a window bigger than the screen: $(($ln -split ' ')[0]) ${w}x$h at ${scrW}x$scrH")
        }
        else { $kept.Add($ln) }
    }
    if (-not $bad) { Info (L 'без изменений' 'unchanged') }
    elseif (-not $DryRun) {
        Copy-Item -LiteralPath $layoutFile -Destination ($layoutFile + '.bak-' + (Get-Date -Format 'yyyyMMdd')) -Force
        [IO.File]::WriteAllText($layoutFile, (($kept -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    }
}

$installed = @(@(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'workshop-ids.txt') -ErrorAction SilentlyContinue) + $RequiredIds |
    ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique)
Save-State @{ items = $installed; heapGB = $heap; pzOptimization = $(if ($null -eq $wantPzo) { $null } else { [bool]$wantPzo }); pzoConfirmed = $(if ($PzoPaused) { [bool]$state.pzoConfirmed } else { $wantPzo -eq $true }); mode = $Mode; lang = $Lang; appliedOptions = $appliedOptions }

Write-Host ''
if ($DryRun) { Write-Host (L 'Пробный прогон: ничего не изменено.' 'Dry run: nothing changed.') -ForegroundColor Green }
else {
    Write-Host (L 'Готово.' 'Done.') -ForegroundColor Green
    Info (L 'Дождитесь, пока Steam докачает все моды (Библиотека > Загрузки), затем запускайте игру через Steam' 'Wait until Steam finishes downloading the mods (Library > Downloads), then start the game from Steam')
    Info (L 'и подключайтесь к серверу.' 'and join the server.')
}