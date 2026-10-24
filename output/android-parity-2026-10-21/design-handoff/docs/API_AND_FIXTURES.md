# Контракт подписки и тестовые данные

Источник истины для строгой валидации — Subscription.swift, SubscriptionUIDocument.swift,
SubscriptionLoader.swift и SubscriptionStore.swift в reference/ios-source/PrototypeApp/.

Ответ на ссылку подписки: sing_box_url, vk_turn_link, ui_url, ui_token. Для полной подписки
требуется валидный UI-документ; наличие транспорта само по себе не заменяет UI. Конфигурация
sing-box и документ UI скачиваются до фиксации снимка. Native-профиль отправляет
X-Subscription-Format: vipin-v1 и X-Subscription-Capabilities: vless-failover-v1. В iOS
User-Agent содержит платформу iOS; в Android это значение должно отражать Android.
Если ответ маркирован vipin-v1, ui_token обязателен, конфигурация и UI должны быть на том же
origin, а bearer-токен не должен уходить на другой адрес. Redirect запрещён. Публичный native
origin требует HTTPS; локальные loopback-fixtures используют HTTP. Ограничения загрузки:
8 MiB для ответа/конфигурации, 1 MiB для UI; таймаут запроса 35 s, ресурса 90 s.

schemaVersion UI = 1. Корень содержит blocks и pages. Слоты:

| ID | Тип | Роль |
|---|---|---|
| block01 | card | Тариф, ID, срок, кнопки тарифа |
| block02 | valueRow | Баланс и пополнение |
| block03 | actionSheet | Telegram/сайт личного кабинета |
| block04 | selectionList | Режимы option01/option02/option03 |
| block05 | menu | Серверные пункты меню |
| block06 | progress | Расход, максимум, единицы и период |

visible по умолчанию true; скрытые блоки/пункты не отображаются. Допустимые виды действий:
openExternalUrl(url), openScreen(targetId), openBlock(targetId). В текущем клиенте screen01 —
замена подписки. detailsPageId ссылается на pages. Нельзя выполнять произвольные неизвестные
действия. Строковые/числовые ограничения, URL-политика и ссылки валидируются до отображения.

Валидатор iOS проверяет неизвестные поля, повторяющиеся JSON-ключи, глобально уникальные ID,
типы слотов и корректные ссылки. Идентификаторы начинаются с буквы и содержат до 64 символов
из букв/цифр/_/-. Короткие строки ограничены 4096 Unicode scalars, текст страницы — 32768.
Числа прогресса — неотрицательные целые Int64 без дробного/экспоненциального представления,
maximum > 0, value <= maximum. Структурная JSON Schema в fixtures не заменяет эти семантические
проверки. Неподдерживаемая версия отклоняется; рабочий сохранённый снимок остаётся.

Native VLESS provisioning дополнительно поддерживает kind=vless-failover, четыре outbound,
primary+три backup и валидируемую policy. Правила этого протокола приведены полностью в
Subscription.swift. Это отдельная часть сетевого порта, а не требование к отрисовке макетов.

## Запуск локального сервера на Windows

В PowerShell из корня комплекта: `py -3 fixtures/serve.py`.
По умолчанию сервер слушает только 127.0.0.1:18081; остановка — Ctrl+C.
Для эмулятора настройте `adb reverse tcp:18081 tcp:18081`.
Тестовая ссылка: `http://localhost:18081/subscription-normal.json`.
С ограничением: `http://localhost:18081/subscription-restricted.json`.
Без транспорта: `http://localhost:18081/subscription-no-transport.json`.

Все данные искусственные. Значения UUID, ui_token и wdtt-пароль — публичные заглушки,
не настоящие доступы. Сервер отдаёт JSON, но не реализует VPN, оплату или Telegram-бота.
Для первого визуального прохода можно читать ui-normal.json напрямую из ресурсов приложения.

Варианты UI: normal, restricted, changed, hidden, long, long-dialog, empty-lists, ban-current.
Файл ui-invalid-schema.json намеренно некорректен (schemaVersion=2) для проверки ошибки.
В normal Auto помечен available сервером; клиент всё равно обязан оставить «В разработке».
В наборе no-transport UI остаётся валидным, но клиент не должен включать кнопку подключения.
