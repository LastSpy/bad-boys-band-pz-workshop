#requires -Version 5.1
<#
  Collects what is needed to analyse a Project Zomboid crash into one zip on the Desktop.
  Run it with Crash-Report.cmd right after a crash (the game can be closed or not).
  Reads only - nothing on the PC is changed. Passwords are not collected; the files do contain
  the Windows user name (in paths) and the Steam name (in game logs).

  What goes in:
    crashes\     Java crash logs (hs_err_pid*.log), Windows error reports (Report.wer),
                 the newest crash dump of the game if Windows wrote one (CrashDumps)
    logs\        Zomboid\console.txt and the newest game DebugLog files
    events.txt   Windows Application/System events about the game, Java, the video driver,
                 hardware errors and power loss (last 30 days)
    config\      ProjectZomboid64.json / .site.json (memory and launch options), options.ini,
                 the enabled mod list, the installer state, Steam launch options for the game
    system.txt   Windows, CPU, memory, page file, video cards and drivers, monitors, disks,
                 antivirus, overlays and other programs that hook into games, extra DLLs in the game folder
  -Days N       how far back to look (default 30)
  -OutDir X     where to put the zip (default: Desktop); -NoOpen  do not open Explorer
#>
param([int]$Days = 30, [string]$OutDir, [switch]$NoOpen)

$ErrorActionPreference = 'Continue'
$ru = (Get-UICulture).Name -like 'ru*'
function L([string]$r, [string]$e) { if ($ru) { $r } else { $e } }
function Say([string]$t) { Write-Host "  $t" }

$AppId = 108600
$since = (Get-Date).AddDays(-$Days)
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$work = Join-Path $env:TEMP "pz-crash-report-$stamp"
$desktop = if ($OutDir) { $OutDir } else { [Environment]::GetFolderPath('Desktop') }
$zip = Join-Path $desktop "PZ-crash-report-$stamp.zip"
$zomboid = Join-Path $env:USERPROFILE 'Zomboid'
New-Item -ItemType Directory -Path $work, "$work\crashes", "$work\logs", "$work\config" -Force | Out-Null

Write-Host ''
Write-Host (L 'Сбор данных о вылете Project Zomboid' 'Collecting Project Zomboid crash data') -ForegroundColor Cyan

# ---------------------------------------------------------------- game folder (same as install.ps1)
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
$game = Find-GameDirectory
Say ((L 'Папка игры: ' 'Game folder: ') + $(if ($game) { $game } else { L 'не найдена' 'not found' }))

function Copy-Newest([string[]]$dirs, [string]$filter, [int]$count, [string]$to, [switch]$Recurse) {
    $files = foreach ($d in $dirs) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            Get-ChildItem -LiteralPath $d -Filter $filter -File -Recurse:$Recurse -ErrorAction SilentlyContinue
        }
    }
    $files = @($files | Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime -Descending | Select-Object -First $count)
    foreach ($f in $files) {
        $name = $f.LastWriteTime.ToString('MMdd-HHmm') + '_' + $f.Name
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $to $name) -Force -ErrorAction SilentlyContinue
    }
    return $files.Count
}

# ---------------------------------------------------------------- crash files
Say (L 'Ищу журналы вылетов...' 'Looking for crash logs...')
$n = Copy-Newest @($game, $zomboid, $env:USERPROFILE, (Join-Path $env:USERPROFILE 'Desktop')) 'hs_err_pid*.log' 5 "$work\crashes"
Say ((L 'Java-вылеты (hs_err): ' 'Java crash logs (hs_err): ') + $n)

$wer = 0
foreach ($root in @("$env:LOCALAPPDATA\Microsoft\Windows\WER", "$env:ProgramData\Microsoft\Windows\WER")) {
    foreach ($sub in 'ReportArchive', 'ReportQueue') {
        $p = Join-Path $root $sub
        if (-not (Test-Path -LiteralPath $p)) { continue }
        Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)ProjectZomboid|java|zomboid' -and $_.LastWriteTime -ge $since } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
                $r = Join-Path $_.FullName 'Report.wer'
                if (Test-Path -LiteralPath $r) {
                    Copy-Item -LiteralPath $r -Destination (Join-Path "$work\crashes" ($_.Name + '.wer.txt')) -Force
                    $wer++
                }
            }
    }
}
Say ((L 'Отчёты Windows об ошибках: ' 'Windows error reports: ') + $wer)

$dump = Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\CrashDumps" -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '(?i)ProjectZomboid|java' -and $_.LastWriteTime -ge $since } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($dump) {
    if ($dump.Length -le 300MB) {
        Copy-Item -LiteralPath $dump.FullName -Destination "$work\crashes" -Force
        Say ((L 'Дамп памяти: ' 'Crash dump: ') + $dump.Name + (' ({0:N0} MB)' -f ($dump.Length / 1MB)))
    } else {
        Say ((L 'Дамп слишком большой, не добавлен: ' 'Crash dump too large, not added: ') + $dump.FullName)
    }
}

# ---------------------------------------------------------------- game logs
Say (L 'Копирую логи игры...' 'Copying game logs...')
if (Test-Path -LiteralPath "$zomboid\console.txt") { Copy-Item -LiteralPath "$zomboid\console.txt" -Destination "$work\logs" -Force }
$n = Copy-Newest @("$zomboid\Logs") '*DebugLog*.txt' 4 "$work\logs" -Recurse
Say ((L 'Логи игры: ' 'Game logs: ') + ($n + [int](Test-Path "$work\logs\console.txt")))

# ---------------------------------------------------------------- Windows events
Say (L 'Читаю журнал событий Windows...' 'Reading the Windows event log...')
$events = New-Object System.Collections.Generic.List[string]
try {
    $app = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since; ProviderName = 'Application Error', 'Windows Error Reporting', 'Application Hang' } -ErrorAction Stop |
        Where-Object { $_.Message -match '(?i)ProjectZomboid|java|zomboid|jvm' }
    foreach ($e in $app) { $events.Add("[$($e.TimeCreated)] Application $($e.ProviderName) $($e.Id)`r`n$($e.Message)`r`n") }
} catch { }
try {
    # video driver resets (Display 4101, nvlddmkm 13/14/153, amdkmdag), hardware errors (WHEA), power loss (Kernel-Power 41)
    $sys = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since; Level = 1, 2, 3 } -ErrorAction Stop |
        Where-Object { $_.ProviderName -match '(?i)Display|nvlddmkm|amdkmdag|amdwddmg|igfx|WHEA|Kernel-Power|disk|volmgr|Ntfs' }
    foreach ($e in $sys | Select-Object -First 200) { $events.Add("[$($e.TimeCreated)] System $($e.ProviderName) $($e.Id)`r`n$($e.Message)`r`n") }
} catch { }
if (-not $events.Count) { $events.Add((L "Событий за $Days дней не найдено." "No events in the last $Days days.")) }
[IO.File]::WriteAllLines("$work\events.txt", $events, (New-Object Text.UTF8Encoding($true)))
Say ((L 'Событий: ' 'Events: ') + $events.Count)

# ---------------------------------------------------------------- config
Say (L 'Копирую настройки игры...' 'Copying game settings...')
foreach ($f in @("$game\ProjectZomboid64.json", "$game\ProjectZomboid64.site.json", "$zomboid\options.ini", "$zomboid\mods\default.txt", "$zomboid\bbb-installer.json", "$env:USERPROFILE\.zombie_buddy\mod_approvals.json")) {
    if ($f -and (Test-Path -LiteralPath $f)) { Copy-Item -LiteralPath $f -Destination "$work\config" -Force }
}
$steamPath = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
$launch = foreach ($cfg in Get-ChildItem -Path (Join-Path "$steamPath" 'userdata\*\config\localconfig.vdf') -ErrorAction SilentlyContinue) {
    $t = Get-Content -LiteralPath $cfg.FullName -Raw
    $m = [regex]::Match($t, '"' + $AppId + '"\s*\{(?:[^{}]|\{[^{}]*\})*?"LaunchOptions"\s+"([^"]*)"')
    if ($m.Success) { $m.Groups[1].Value }
}
[IO.File]::WriteAllText("$work\config\steam-launch-options.txt", (($launch | Select-Object -Unique) -join "`r`n"))

# ---------------------------------------------------------------- system
Say (L 'Собираю сведения о ПК...' 'Collecting PC information...')
$s = New-Object System.Collections.Generic.List[string]
function Add([string]$title, $value) { $s.Add("== $title"); $s.Add(($value | Out-String -Width 220).TrimEnd()); $s.Add('') }
$os = Get-CimInstance Win32_OperatingSystem
Add 'Windows' ("{0} {1} build {2}, {3}, uptime {4:N1} h" -f $os.Caption, $os.Version, $os.BuildNumber, $os.OSArchitecture, ((Get-Date) - $os.LastBootUpTime).TotalHours)
Add 'CPU' (Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed)
$cs = Get-CimInstance Win32_ComputerSystem
Add 'Memory' ("total {0:N1} GB, free now {1:N1} GB" -f ($cs.TotalPhysicalMemory / 1GB), ($os.FreePhysicalMemory * 1KB / 1GB))
Add 'Memory modules' (Get-CimInstance Win32_PhysicalMemory | Select-Object Manufacturer, PartNumber, @{n = 'GB'; e = { $_.Capacity / 1GB } }, ConfiguredClockSpeed)
Add 'Page file' ("automatic: {0}" -f $cs.AutomaticManagedPagefile), (Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage)
Add 'Video' (Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, DriverDate, CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate, Status)
$vram = Get-ItemProperty 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*' -ErrorAction SilentlyContinue |
    Where-Object { $_.'HardwareInformation.qwMemorySize' } | ForEach-Object { '{0}: {1:N1} GB' -f $_.DriverDesc, ($_.'HardwareInformation.qwMemorySize' / 1GB) }
Add 'Video memory' $vram
Add 'Disks' (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object DeviceID, @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } }, @{n = 'FreeGB'; e = { [math]::Round($_.FreeSpace / 1GB, 1) } })
Add 'Power plan' ((powercfg /getactivescheme) 2>$null)
Add 'Antivirus' (Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | Select-Object -ExpandProperty displayName)
$hooks = 'RTSS|RTSSHooksLoader|MSIAfterburner|Discord|Overwolf|obs64|obs32|nvcontainer|NVIDIA (Share|Overlay|app)|GameBar|XboxGameBar|RadeonSoftware|AMDRSServ|ReShade|SteelSeries|razer|Synapse|iCUE|LGHUB|lghub|Wallpaper|FPSMonitor|Medal|Outplayed|Bandicam|fraps|ShareX'
Add 'Running programs that hook into games' (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match "(?i)$hooks" } | Select-Object -ExpandProperty ProcessName -Unique)
if ($game) {
    $stock = 'steam_api64.dll', 'steam_api.dll', 'zbNative.dll', 'fmod.dll', 'fmod64.dll', 'fmodintegration64.dll', 'fmodstudio64.dll', 'PZBullet64.dll', 'Lighting64.dll', 'PZClipper64.dll', 'PZPathFind64.dll', 'PZPopMan64.dll', 'RakNet64.dll', 'ZNetJNI64.dll', 'ZNetNoSteam64.dll', 'jinput-dx8_64.dll', 'jinput-raw_64.dll', 'lwjgl64.dll', 'lwjgl.dll', 'OpenAL64.dll', 'OpenAL32.dll', 'bink2w64.dll', 'bink64.dll', 'fmodstudio.dll', 'imgui-java64.dll', 'jassimp64.dll', 'jnidispatch.dll'
    Add 'DLL files in the game folder (overlay/injector suspects first)' (Get-ChildItem -LiteralPath $game -Filter '*.dll' -File -ErrorAction SilentlyContinue |
        Sort-Object { $stock -contains $_.Name }, Name | Select-Object Name, Length, LastWriteTime, @{n = 'stock'; e = { $stock -contains $_.Name } })
    Add 'Game folder files changed in the last 30 days' (Get-ChildItem -LiteralPath $game -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since } | Select-Object Name, Length, LastWriteTime)
}
[IO.File]::WriteAllLines("$work\system.txt", $s, (New-Object Text.UTF8Encoding($true)))

# ---------------------------------------------------------------- pack
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path "$work\*" -DestinationPath $zip -CompressionLevel Optimal
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
$size = (Get-Item -LiteralPath $zip).Length / 1MB

Write-Host ''
Write-Host (L 'Готово. Архив:' 'Done. The archive:') -ForegroundColor Green
Write-Host "  $zip  ($('{0:N1}' -f $size) MB)"
Write-Host (L '  Отправьте этот файл администратору сервера. Паролей в нём нет; есть имя пользователя Windows и Steam.' '  Send this file to the server admin. It holds no passwords; it does contain the Windows and Steam user names.')
if ($size -gt 24) { Write-Host (L '  Файл больше 25 МБ: Discord его не пропустит, загрузите на Google Диск или аналог и пришлите ссылку.' '  The file is over 25 MB: Discord will not take it, upload it to Google Drive or similar and send the link.') -ForegroundColor Yellow }
if (-not $NoOpen) { Start-Process explorer.exe -ArgumentList "/select,`"$zip`"" }
