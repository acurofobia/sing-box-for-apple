# История изменений и расхождений Android

Исходная точка — спецификация от 14 октября 2026 года. Целевой срез — рабочее дерево sing-prototype от 20 октября, обследованное 20–21 октября. Даты ниже приведены в Asia/Yekaterinburg. Полные SHA и списки файлов сохранены в GIT_HISTORY.txt, CORE_HISTORY.txt и SOURCE_MANIFEST.json.

## Зафиксированный старый клиент

Переданный android-client не содержит .git. Его версия — WhiteLink 0.1.0-test, package io.whitelink.android, сборка из dist/build-manifest.json от 14 октября. Сверка всех 44 записей applicationSource с действительными файлами дала полное совпадение SHA-256. Это позволяет считать предоставленные исходники именно исследованным baseline. Историю работы другого разработчика или предыдущие Android-чаты этот каталог не содержит.

Основной код — самостоятельная оболочка app/src/main/java/io/whitelink/android. В settings.gradle.kts включён только :app. vendor/sfa не является запускаемым приложением; переносить задачу в него вместо WhiteLink неверно.

## 14 октября

Коммит 04a05706e4e6f3b103609ae6e30c11070466957f сохранил VK TURN prototype, подписки и дизайн. Его модель интерфейса — техническое приложение с ручным выбором двух транспортов и диагностикой. В этот момент контракт подписки состоял из двух transport-полей; UI с сервера и новый профиль не были обязательной частью клиента.

Коммит c61c59856e024159dec63893927c9d41b82e3151 сделал PrototypeApp основной оболочкой iOS. Старое стандартное SFI-приложение удалено из этой роли. Большое число удалённых ThirdParty-файлов в diff связано с переводом TURN в git submodule, а не с удалением транспорта из продукта. Текущий указатель TURN — bbab2a7c09b0894a120496b6d506db66eb998798, с интеграцией sing-box и отменяемой очередью пакетов.

Для Android важно сохранить уже сделанный интегрированный путь TUN → sing-box → native WireGuard → TURN. Повторное заимствование CLI go_client или WireGuardBridge не нужно. Android уже имеет собственные socket/network/cancellation исправления поверх исходного core af6e64c3.

## 15 октября

Коммит 38a875ec93e490249240e08ddb16a369b603a7b1 добавил remote rule sets с persistent cache, отдельную настройку маршрутизации и Russia inside. Затронуты PrototypeRouting, Application, RoutingView, routing.json, FilePath, PacketTunnelProvider, bundled russia-inside.srs и routing/cache/device tests.

Изменения поведения:

- Списки остаются remote, стартуют с кеша или bundled fallback, обновляются раз в сутки через выбранный VPN.
- Выбор роутинга независим от VLESS/VK TURN; в connected выполняется stop/wait/start, в stopped только сохранение.
- Russia inside направляет перечисленные домены в proxy, остальное в direct; сохраняет reverse DNS mapping для opaque traffic.
- Старое сохранённое значение disabled обозначает Russia inside.

Android остался на 21 local rule set: WhiteLinkVpnService копирует assets, меняет descriptors на local и удаляет URL. Настройки роутинга в его моделях и интерфейсе нет. Поэтому одного нового макета вкладки недостаточно: нужно изменить runtime builder и хранение кеша.

Накопительный docs/testing/vk-turn-prototype.md содержит раннее описание «Без роутинга» без restart и старый DNS 1.1.1.1. Позднейшие разделы, текущие исходники и тесты уточняют фактическое поведение; первые абзацы нельзя использовать изолированно как конечные требования.

## 16 октября

Коммит 973267e45e2272c1dfc2aa2eeb7cf9663954bd86 добавил Windows client specification. Он не реализовал новый Android-клиент и не является свидетельством выполнения требований на Android.

## Дизайн 18 октября и реализация 20 октября

Дизайн подключения интерфейса к серверу датирован 18 октября. Основная реализация сохранена коммитом 730327533726f22331d4ec2df17c77cd4ef97dcb от 20 октября. Этот коммит объединяет несколько дней работы, поэтому даты отдельных локальных редактирований не выдаются за отдельные Git-коммиты.

Крупные изменения:

- SubscriptionUIDocument — строгий version-one контракт, шесть семантических слотов, страницы, actions, global IDs и проверки исходной формы чисел/дубликатов.
- SubscriptionLoader — загрузка UI, native headers, auth scope и same-origin policy для vipin-v1.
- SubscriptionStore — полный атомарный снимок, generation/cancellation, отделение provisioning от работающего туннеля.
- Application — новые правила выбора, доступности, обновления во время VPN, сохранение работающей сессии при отзыве режима, запрет следующего старта.
- PrototypeView/PrototypeStyle — onboarding, три нижние вкладки, карточки подписки/расхода, профиль, внешние действия, настройки.
- ModeDrawer — верхняя шторка с модальностью и gesture control; option03 не включается.
- VPNCard — раскрытие вверх, фиксированная кнопка, жесты на всей карточке, nested scroll, реальные core-метрики и URL test.
- PresentationCoordinator — один modal owner, последовательные переходы, закрытие исчезнувших целей, ошибки поверх компоновки.
- LogView — поиск, pause/resume, copy visible lines, empty states и foreground subscription.
- UI smoke tests — состояния Sketch, gestures/flick/anchor, длинный текст, вкладки, keyboard, restrictions, refresh, ошибки и cancel.

Из прежнего пользовательского интерфейса удалены ручной JSON/TURN import, CSV и memory reports; число TURN sessions фиксировано на 30. Логи сохранены. Внешние переходы к оплате и личному кабинету входят в продукт, но платежный SDK и встроенный кабинет не реализованы.

Старый Android не содержит ни SubscriptionUIDocument, ни ui_url/ui_token в Snapshot, ни новой структуры экранов. Он продолжает требовать остановки VPN для refresh и автоматически подбирает другой доступный transport через withAvailableMode. Эти политики нужно заменить наряду с внешним видом.

## Резервирование VLESS

Core 1c3c78d566f28a2df7c72bcf3e63099beea8493f добавляет к core 8dfc5f32:

- BuildVLESSFailoverConfiguration для четырёх ограниченных VLESS/REALITY outbound и selector vk-wg.
- vless_outbounds/vless_primary в bootstrap вместо потери четырёхузлового документа при попытке выбрать один node.
- Подключение policy через OverrideOptions, дополнительные проверки отмены command_server startup и соответствующие тесты.

Сам priority controller был в старом vendored Android: production-файлы priority_failover.go, priority_failover_config.go, priority_failover_probe.go и libbox/priority_failover.go совпадают с текущим эталоном после CRLF-нормализации. Писать новый Kotlin-failover controller не требуется. Нужно подключить parser → storage → builder → override → status и пересобрать AAR.

VLESS failover не равен «Авто» между VLESS и TURN. Первый обязателен по текущему эталону, второй остаётся недоступным. Все четыре недоступных VLESS не дают разрешения выпускать proxy-трафик напрямую или менять транспорт на TURN.

## 20 октября после основного коммита

Коммит 2a6a6dfe3a082af405a3105b12a41b366cb5e136 сохраняет описание персонального пилота. Он не добавляет сетевой реализации. В аппаратном memory acceptance по-прежнему не измерены four-node overhead и полный workload; эти строки не превращаются в pass при переносе на Android.

После HEAD в рабочем дереве добавлен configurationWithDNSPolicy и его вызов перед стартом extension. Он заменяет старый DNS 1.1.1.1 на:

- dns-direct/77.88.8.8 HTTPS без detour;
- dns/8.8.8.8 HTTPS через vk-wg;
- bootstrap/77.88.8.8 HTTPS независимо от создаваемого VLESS;
- DNS rules с тем же порядком доменных direct/proxy/reject исключений и response matching для IP-правил;
- отдельную политику для Russia inside и сохранение reverse mapping.

Тесты проверяют реальный локальный DoH/core path, не только форму JSON. Важно включить и функцию, и её вызов: Go builder отдельно всё ещё строит промежуточный старый DNS.

Финальный Sketch также изменён без коммита. Все общие исходники в reference/ios-source исходного handoff совпали с соответствующими текущими файлами. Но исходный handoff не включает весь runtime/core: PacketTunnelProvider, новые Go builder/bootstrap и command_server нужно сверять по дополнению reference.

## Дополнительное расхождение по TURN

Текущий VKTurnConfiguration.swift принимает WRAP-A и legacy SRTP. Старый Android ConfigurationParser отклоняет SRTP явным guard, хотя ниже сохранилась часть построения WG-полей; Android libbox имеет второй WRAP-A-only guard. Поэтому полное соответствие требует снять именно ограничение профиля с надлежащими проверками, а не просто переименовать экран.

Socket protection/bind, physical resolver, проверка остановки workers и запрет plaintext credentials cache в старом Android остаются полезными. Apple core не должен затереть эти исправления. Сравнительный diff в reference — материал для ручного переноса, не patch для автоматического применения.

## Объём доказательств

Исходные 11 изображений приложения в design-handoff получены с искусственной подпиской, connected в UI мог симулироваться. Они подтверждают внешний вид. Старые build/test logs Android описывают проверки от 14 октября; текущая спецификация не объявляет их свежим тестированием Android.

В рамках подготовки этой передачи проверены целостность исходного handoff, совпадение baseline-хешей, текущие routing/DNS tests и синтетические provisioning/parser примеры. Android-приложение не изменялось, не собиралось и не запускалось; ни один пункт будущей ACCEPTANCE.csv поэтому не помечен pass.
