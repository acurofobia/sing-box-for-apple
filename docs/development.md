# Разработка основной версии

Основной репозиторий: https://github.com/acurofobia/sing-box-for-apple, ветка `main`.
Локальный основной проект: `/Users/acurofobia/code/sing-prototype`.
Код приложения: `PrototypeApp/`; Xcode target: `SFI`; схема сборки: `VKTurnPrototype`.
Имена схемы, bundle ID и App Group сохранены для совместимости с установленным приложением.

## Репозитории и версии

| Компонент | Наш репозиторий и ветка | Источник обновлений |
| --- | --- | --- |
| Приложение | `acurofobia/sing-box-for-apple`, `main` | `SagerNet/sing-box-for-apple` |
| Ядро, `upstream/sing-box` | `acurofobia/sing-box`, `main` | `SagerNet/sing-box` |
| TURN, `ThirdParty/VKTurnProxy` | `acurofobia/vk-turn-proxy-ios`, `main` | `anton48/vk-turn-proxy-ios` |

`origin` обозначает наш репозиторий, `upstream` — репозиторий автора.
Сабмодули закреплены конкретными коммитами. Обычный `git submodule update --init --recursive`
восстанавливает именно эти версии. Обновление зависимостей выполняется отдельной задачей.
Go module VK TURN сохраняет исходное имя `github.com/cacggghp/vk-turn-proxy`; локальный
`replace` ядра по-прежнему указывает на `../../ThirdParty/VKTurnProxy`.

## Новая рабочая копия

```sh
git clone --recurse-submodules https://github.com/acurofobia/sing-box-for-apple.git
cd sing-box-for-apple
git remote add upstream https://github.com/SagerNet/sing-box-for-apple.git

git -C upstream/sing-box remote add upstream https://github.com/SagerNet/sing-box.git
git -C ThirdParty/VKTurnProxy remote add upstream https://github.com/anton48/vk-turn-proxy-ios.git
```

После клонирования сабмодули находятся на закреплённых коммитах без выбранной ветки.
Перед редактированием выберите соответствующую ветку:

```sh
git -C upstream/sing-box switch main
git -C ThirdParty/VKTurnProxy switch main
```

## Обычная задача приложения

```sh
git switch main
git pull --ff-only
git submodule update --init --recursive
git switch -c codex/my-change

# Edit files and run the relevant checks.
git status
git diff
git add <files-for-this-task>
git diff --cached
git commit -m "Describe the change"
git push -u origin HEAD
```

Создайте PR в нашем репозитории с базовой веткой `main`. После его слияния вернитесь
на `main`, выполните `git pull --ff-only` и восстановите закреплённые сабмодули.
Для небольшого изменения прямо в `main` после проверок достаточно `git commit` и `git push`.

## Изменение зависимости

Сначала закоммитьте и отправьте изменения в репозитории зависимости. Затем закоммитьте
ссылку на новый коммит в приложении. Пример для VK TURN:

```sh
git -C ThirdParty/VKTurnProxy switch main
# Edit the dependency and run its tests.
git -C ThirdParty/VKTurnProxy add <changed-files>
git -C ThirdParty/VKTurnProxy commit -m "Describe the TURN change"
git -C ThirdParty/VKTurnProxy push

git add ThirdParty/VKTurnProxy
git commit -m "Update VK TURN integration"
git push
```

Для ядра порядок такой же с путём `upstream/sing-box` и веткой
`main`. При работе в ветке задачи приложения её push
остаётся направленным в эту ветку, а PR объединяет изменение с `main`.

## Обновление из источников

Обновляйте ядро и TURN по одному, на чистой рабочей копии, в отдельных ветках.
Выберите конкретный релиз или коммит автора после изучения его изменений.
Для TURN схема следующая:

```sh
git -C ThirdParty/VKTurnProxy fetch upstream --tags
git -C ThirdParty/VKTurnProxy switch main
git -C ThirdParty/VKTurnProxy switch -c codex/update-vk-turn
# Replace <upstream-release-or-commit> with the selected real revision.
git -C ThirdParty/VKTurnProxy merge <upstream-release-or-commit>
```

Разберите конфликты, сохранив наши изменения. Обновите `UPSTREAM.txt` в зависимости:
`Revision` обозначает последнюю интегрированную ревизию anton48. Запустите тесты и
пересоберите приложение. Отправьте ветку зависимости и объедините её PR в
`main`, затем зафиксируйте проверенный итоговый коммит в приложении.

Для sing-box используйте тот же порядок: путь `upstream/sing-box`, базовая ветка
`main`, источник `SagerNet/sing-box`. Текущая основа ядра —
`v1.14.2`. При обновлении проверьте Go toolchain, build tags, мост Libbox и строку версии
в `scripts/build_vk_turn_prototype.sh`. Наши изменения уже находятся в Git-коммитах;
повторно накатывать сохранённые `patches/*.patch` после merge не нужно.

Обновление Apple-интерфейса от SagerNet выполняется отдельно в корне приложения:
`git fetch upstream`, затем merge выбранного коммита в ветку задачи, разбор конфликтов
и проверка текущего target `SFI`. Изменения автора могут затрагивать прежний интерфейс,
который больше не является нашей основной версией.

## Проверки и сборка

```sh
python3 -m unittest discover -s scripts/tests -v
python3 -m unittest discover -s subscription-server/tests -v
(cd ThirdParty/VKTurnProxy && go test -race ./pkg/proxy)
(cd upstream/sing-box && go test -race -ldflags=-checklinkname=0 \
  -tags with_wireguard,with_gvisor,badlinkname,tfogo_checklinkname0 \
  ./daemon ./experimental/libbox ./protocol/group ./protocol/vkturn)
scripts/build_vk_turn_prototype.sh
```

Скрипт пересобирает iOS/simulator Libbox с интегрированным TURN и приложение.
При изменении отдельного старого WireGuardBridge его framework собирается командой
`make -C ThirdParty/VKTurnProxy/WireGuardBridge`; основной прототип этот bridge не использует.
Новые frameworks и build output остаются локальными и не коммитятся.

Приватные `.env`, конфигурации серверов, ключи и скачанная Apple UI Kit остаются
локальными. Архив старой версии: тег `archive/legacy-app-2026-10-14`; архив её ядра:
`archive/priority-failover-2026-10-14`. Старые ветки удалены из активной разработки.
