# Bad boys Band — Project Zomboid B42 + MP

Installer and mod lists for the **Bad boys Band** Project Zomboid server (Build 42.21).
Steam collection: https://steamcommunity.com/sharedfiles/filedetails?id=2983549098

## Players

1. Download `PZ-3dpz-client.zip` from the [latest release](../../releases/latest).
2. Start Steam, close the game, unpack the archive, double-click `Install.cmd`.
3. Pick a language, then **1 – First install**. Later: **2 – Update** or **3 – Settings**.

See `client/README.txt` for what it does. It subscribes to the server's mods, checks for mods that
clash with this set, copies the files ZombieBuddy needs into the game folder, sets the game memory,
optionally installs PZ_Optimization and enables exactly the server's mods.

## Server owners

`server-config/3dpz-mods.ini` holds the `Mods=`, `WorkshopItems=` and `Map=` lines of the server.

## Maintainers

- `Build-ClientPack.ps1` — regenerates `client/workshop-ids.txt`, `client/mod-ids.txt`,
  `server-config/` from the server `.ini` and builds `dist/PZ-3dpz-client.zip`.
- `check-load-order.py` — checks `Mods=` against each mod's `mod.info` (require / loadModAfter /
  loadModBefore / incompatible), using the version folder the game actually loads.
- `mod-info.py ID...` — lists the mods inside Workshop items.
- `client/extra-ids.txt` — client-only items; `client/conflict-ids.txt` — known conflicts.

---

## Игрокам (RU)

1. Скачай `PZ-3dpz-client.zip` из [последнего релиза](../../releases/latest).
2. Запусти Steam, закрой игру, распакуй архив, дважды щёлкни `Install.cmd`.
3. Выбери язык, затем **1 – Первый запуск**. Потом — **2 – Обновить** или **3 – Настройки**.

Владельцам серверов: строки `Mods=`, `WorkshopItems=`, `Map=` — в `server-config/3dpz-mods.ini`.
