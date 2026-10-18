Bad boys Band - installer for the Project Zomboid server (Build 42)
==================================================================

1. Start Steam and log in to the account that owns Project Zomboid. Close the game.
2. Unpack the whole archive into any folder.
3. Double-click Install.cmd, pick a language, then a menu item:
   1 - First install - everything needed to play on the server (see below);
   2 - Update        - the same, plus unsubscribing from mods the server no longer uses;
   3 - Settings      - install or remove PZ_Optimization.
   Items 2 and 3 appear after the first install.
4. Wait until Steam finishes downloading the mods (Library > Downloads).
5. Start the game from Steam and join the server.

What the installer does:
- subscribes to all server mods in Steam and waits for the downloads;
- looks for mods that clash with this set (the same mod in another version, a declared
  incompatibility, known conflicts from conflict-ids.txt) and offers to remove them;
- copies the ZombieBuddy files into the game folder (zbNative.dll, ZombieBuddy.jar);
- sets up the game launch (ProjectZomboid64.site.json) and asks how much memory to give the game;
- optionally installs PZ_Optimization (fewer stutters, faster map loading);
- enables exactly the server's mods in the game (Zomboid\mods\default.txt; the previous list is
  kept next to it as .bak-DATE).

It never removes anything of yours: it only unsubscribes from what it installed itself earlier, or
from a conflict it found - and asks first. What is installed is recorded in Zomboid\bbb-installer.json.

Dry run, changes nothing: Install.cmd -DryRun

The game crashed? Run Crash-Report.cmd right after the crash. It collects crash logs, game logs,
Windows error events and PC details into PZ-crash-report-<date>.zip on the Desktop (reads only,
no passwords). Send that zip to the server admin.


Bad boys Band - установщик для сервера Project Zomboid (Build 42)
=================================================================

1. Запустите Steam и войдите в аккаунт с Project Zomboid. Игру закройте.
2. Распакуйте архив целиком в любую папку.
3. Дважды щёлкните Install.cmd, выберите язык, затем пункт меню:
   1 - Первый запуск - всё, что нужно для игры на сервере (см. ниже);
   2 - Обновить      - то же, плюс отписка от модов, которые сервер больше не использует;
   3 - Настройки     - установить или удалить PZ_Optimization.
   Пункты 2 и 3 появляются после первой установки.
4. Дождитесь, пока Steam докачает моды (Библиотека > Загрузки).
5. Запускайте игру через Steam и подключайтесь к серверу.

Что делает установщик:
- подписывается в Steam на все моды сервера и ждёт, пока они скачаются;
- ищет моды, которые конфликтуют со сборкой (тот же мод в другой версии, объявленная
  несовместимость, известные конфликты из conflict-ids.txt) и предлагает их убрать;
- копирует в папку игры файлы ZombieBuddy (zbNative.dll, ZombieBuddy.jar);
- настраивает запуск игры (ProjectZomboid64.site.json) и спрашивает, сколько памяти ей отдать;
- по желанию ставит PZ_Optimization (меньше фризов, быстрее подгрузка карты);
- включает в игре ровно те моды, что на сервере (Zomboid\mods\default.txt; прежний список
  сохраняется рядом с расширением .bak-ДАТА).

Ничего вашего установщик не удаляет: отписывает только от того, что сам ставил раньше, или от
найденного конфликта - и то с вопросом. Что установлено, записано в Zomboid\bbb-installer.json.

Пробный прогон без изменений: Install.cmd -DryRun

Игра вылетела? Сразу после вылета запустите Crash-Report.cmd. Он соберёт журналы вылетов, логи игры,
ошибки из журнала Windows и сведения о ПК в PZ-crash-report-<дата>.zip на рабочем столе (только
читает, паролей не берёт). Отправьте этот архив администратору сервера.
