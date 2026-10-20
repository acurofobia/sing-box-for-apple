# План адаптера подписки Remnawave и экономного failover

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This request authorizes planning only; implementation and production deployment are separate actions.

**Goal:** Выдавать приложению четыре персональных VLESS-выхода из подписки Remnawave, переключать их без перезапуска VPN и удерживать исправный резерв до восстановления основного при ограниченном расходе памяти.

**Architecture:** VPN backend адаптирует уже сформированный персональный Xray JSON, извлекая параметры четырёх выходов и цепочку приоритетов. Приложение сохраняет их единым комплектом и создаёт обычный sing-box selector; отдельная политика передаётся через существующий Libbox override. Проверки выполняет существующий контроллер внутри работающего ядра, последовательно и без второго экземпляра sing-box.

**Tech Stack:** Существующие Python/FastAPI/httpx/Pydantic/SQLModel и unittest проекта VPN; Swift/NetworkExtension; Go/Libbox и XCTest проекта sing-prototype. Новые зависимости и миграции БД не требуются.

**Spec:** Решения текущего чата от 2026-10-20 и раздел «Согласованное поведение» ниже. Старый `docs/superpowers/specs/2026-09-30-priority-failover-design.md` используется только как справка по жизненному циклу контроллера: его конкретные серверы, ручной редактор профилей и статический primary НЕ являются требованиями этого плана.

## Global Constraints

- Сейчас создаётся только план. Не менять продуктовый код, production, тарифы, группы, ключи, устройства HWID или настройки Remnawave.
- Не коммитить, не пушить и не создавать PR без отдельной команды пользователя. Существующие незакоммиченные изменения принадлежат пользователю.
- Реальный backend: `/Users/acurofobia/code/VPN/backend`; production: SSH alias `panel`, исходники backend в `/opt/app/backend`, сервис `vpn-backend`.
- Клиент: `/Users/acurofobia/code/sing-prototype`, схема `VKTurnPrototype`; ядро: вложенный checkout `upstream/sing-box`. Перед реализацией проверить состояние обоих Git checkout.
- Сохранить общую ссылку `/api/sub/{short_uuid}`, прежнюю выдачу HAPP/других клиентов, существующие UI schemaVersion=1 и идентификаторы блоков.
- Не копировать Xray DNS, routing, inbounds, loopback и observatory в sing-box. DNS, маршруты и rule-set остаются под управлением приложения.
- VK TURN остаётся отдельным режимом. Автоматического перехода VLESS → VK TURN в этом плане нет.
- Не зашивать группу A–H, конкретный primary или соответствие пользователей серверам в клиенте либо адаптере.
- Четыре выхода, один selector, одно ядро, один TUN. Максимум одна прикладная проверка выхода одновременно; без постоянного прогрева резервов.
- Реальные ключи, JSON подписок и персональные URL не включать в документы, Git, логи и тестовые fixtures.
- Любой deployment или pilot на production выполнять только после отдельного разрешения; подготовка к нему входит в план, выполнение сейчас не разрешено.

## Review Focus

1. Несколько Xray-конфигов в ответе, переставленные массивы и селекторы-префиксы: определить единственную валидную цепочку, не выбирать первый массивный элемент. Проверяется задачей 1.
2. Отзыв ссылки, исчерпанный основной лимит или смена группы во время сетевого запроса: не выдать чужой/отозванный комплект и не запретить независимый WDTT только из-за LIMITED. Проверяется задачами 2–3.
3. Сбой конфига после успешного descriptor, повреждённый кэш или запоздалый ответ предыдущей ссылки: сохранить целостность и не смешать пользователей/политику. Проверяется задачей 4.
4. Холодный старт на мёртвом primary, сон/пробуждение, stop/reload во время проверки: ограничить время, отменить устаревшую работу, не запустить второй контроллер. Проверяется задачами 5–6.
5. Все выходы недоступны либо недоступны только контрольные адреса: ограничить работу, не перейти в direct, не показывать успешную доступность интернета только по NEVPNStatus. Проверяется задачами 6–7.

## Согласованное поведение и исходные факты

Пользователь выбрал: адаптер существующей подписки; последовательные проверки; допускается оставаться на исправном резерве до восстановления основного. Приоритеты берутся из Remnawave для конкретного пользователя.

Прочитанные настройки production: Remnawave 2.6.4, внешние группы Failover A–H, две четвёрки маршрутов. Каждая группа использует свой XRAY_JSON-шаблон; `injectHosts` подставляет четыре VLESS RAW/REALITY с тегами хостов. Цепочка состоит из loopback → inbound rule → balancer с одним выходом → fallbackTag; завершение — blackhole. Observatory использует интервал 10s. В установленном REQUEST_TEMPLATE_TYPE значение XRAY_JSON равно `json`; endpoint — `/api/sub/{shortUuid}/json`. Middleware использует route clientType как override. Точное содержимое реальной сформированной подписки ещё не получали: изучены шаблоны, метаданные хостов и установленный код обработчиков.

Исходники: `PrototypeApp/Subscription.swift` сохраняет один `vlessOutbound`; `protocol/vkturn/config.go` переназывает его в `vk-wg`. `Library/Network/ExtensionProvider.swift` создаёт пустой Libbox override. В ядре уже есть `daemon/priority_failover*.go`, Libbox API в `experimental/libbox/priority_failover.go`, ранняя проверка на этапе готовности outbounds и остановка контроллера при закрытии instance.

В VPN `app/subscriptions/service.py` пока возвращает `sing_box_url=null`; endpoint config отвечает `config_not_configured`; `ui.py` делает option01 недоступным. Бесплатный основной тариф имеет собственный лимит (сейчас 2 GiB/день), поэтому нельзя вводить правило «VLESS только для standard». Состояние LIMITED основного Remnawave-пользователя не должно само по себе закрывать отдельный WDTT-режим.

Настройки первой версии — предложенные технические значения для реализации и измерений, а не измеренные гарантии:

| Параметр | Значение |
|---|---|
| Интервал | 10000 ms после завершения предыдущего цикла |
| Общий deadline одной проверки выхода | 5000 ms на оба контрольных адреса вместе |
| Порог отказа текущего выхода | 2 последовательные неудачи |
| Порог возврата на основной | 3 последовательных успеха основного |
| Параллельные проверки | 1 |
| HTTP-проверка | HEAD с ожидаемым 204 через выбранный конкретный outbound |
| Контрольные адреса | Существующие gstatic и Cloudflare из `priority_failover_probe.go` |
| Повтор при all-down | Тот же последовательный цикл с интервалом, без мгновенного повторения |

На основном проверять только основной. На резерве проверять основной и, пока возврат не подтверждён, текущий резерв. Другие резервы проверять при отказе текущего. Здоровый резерв не заменять восстановившимся резервом выше по списку. Холодный старт сразу ищет исправный выход, не ожидая двух циклов; предыдущий кэш выбора не отменяет приоритет primary.

Четыре последовательных проверки на холодном старте могут суммарно занять до примерно 20s при полностью неотвечающих выходах; это не обещание старта за 5s. При работе задержка отказа включает фазу интервала, два неуспешных цикла и поиск резерва. На резерве один цикл может проверять два выхода. Фиксировать фактическое время в тестах; не заменять последовательность параллельными проверками без пересмотра требований по памяти.

Переключение selector не переносит существующие TCP-сеансы. Для первой версии использовать `interrupt_exist_connections=true`: закрывать прежние соединения при смене выхода, не оставлять их на отказавшем пути. Возврат после трёх успехов также может оборвать соединения; бессшовный перенос и отдельная политика мягкого возврата в объём не входят.

## Контракт между backend и приложением

Сохранить descriptor с четырьмя прежними полями. Новый клиент ко всем трём запросам добавляет `X-Subscription-Capabilities: vless-failover-v1` наряду с существующими User-Agent и X-Subscription-Format. Это технический маркер совместимости, не способ авторизации. Старые сборки без него сохраняют прежнюю выдачу без нового VLESS-документа.

Новый ответ существующего `/api/sub/{short_uuid}/app/v1/config` — документ provisioning, НЕ полный стандартный sing-box config:

```json
{
  "schemaVersion": 1,
  "kind": "vless-failover",
  "state": "available",
  "reason": null,
  "outbounds": [],
  "failover": {
    "selector": "vk-wg",
    "primary": "example-primary",
    "backups": ["example-backup-1", "example-backup-2", "example-backup-3"],
    "intervalMilliseconds": 10000,
    "timeoutMilliseconds": 5000,
    "failureThreshold": 2,
    "recoveryThreshold": 3
  }
}
```

В примере `outbounds` сокращён: в available-ответе ОБЯЗАТЕЛЬНО ровно четыре валидных sing-box VLESS outbound, и множество их тегов равно primary + backups. Теги `direct` и `vk-wg` для реальных узлов запрещены. Selector создаёт приложение; `vk-wg` сохраняет существующие ссылки из DNS, маршрутов и загрузчика rule-set, хотя в VLESS-режиме это selector, а не WireGuard.

- `state=restricted` или `unavailable` допускает только пустой outbounds и failover=null; reason — фиксированный безопасный код. LIMITED → unavailable/traffic_limited. Нет права по существующей модели → restricted/not_allowed. Неизвестный статус → ошибка, без выдачи ключей.
- Ошибка HTTP, timeout, неверный формат upstream или неоднозначный граф → 503 с безопасным кодом. Не выдавать это как успешное отключение режима: клиент сохраняет предыдущий полный snapshot.
- Подтверждённое отсутствие доступа в успешном документе удаляет VLESS из нового snapshot. Это не останавливает уже работающий туннель; серверы продолжают обеспечивать права по старым сохранённым ключам.
- На config нужны текущий short_uuid, действующий Bearer и маркер capabilities; переиспользовать существующие проверки и no-store. Отсутствующий/неподдержанный capability у прямого config-запроса → 406. Выключенная функция → прежний 404 config_not_configured.
- UI option01 использует право/статус основного режима и capability; прочие блоки и VK TURN не меняются. Недоступность адаптации приводит к ошибке полной загрузки, а не к ложному успешному UI available.
- Native Vary дополнить X-Subscription-Capabilities. Legacy-заголовки не менять.
- Не добавлять backend-кэш пользовательских ключей и не хранить подписки в БД. У клиента остаётся один атомарный snapshot. Последующие обновления получают новую группу; активный туннель использует старый неизменяемый runtime snapshot до следующего подключения.

## Карта файлов

Backend root: `/Users/acurofobia/code/VPN/backend`.

| Файл | Ответственность |
|---|---|
| Create `app/subscriptions/xray_adapter.py` | Чистый разбор графа и ограниченное преобразование VLESS RAW/REALITY |
| Create `app/subscriptions/remna_subscription.py` | Ограниченный HTTP-запрос персонального Xray JSON по доверенному upstream |
| Modify `app/subscriptions/service.py`, `ui.py` | Связь с правами, descriptor/config/UI, существующая авторизация |
| Modify `app/config.py`, `../.env.example` | Флаг APP_SUBSCRIPTION_VLESS_ENABLED=false |
| Create `tests/test_xray_subscription_adapter.py`, `test_app_vless_subscription.py` | Адаптер, HTTP и native выдача |
| Modify `tests/test_app_subscription.py`, `test_subscription_proxy.py` | Совместимость существующей выдачи |

Client/core root: `/Users/acurofobia/code/sing-prototype`.

| Файл | Ответственность |
|---|---|
| Modify `PrototypeApp/Subscription.swift`, `SubscriptionLoader.swift`, `SubscriptionStore.swift` | Типизированный набор, декодирование, миграция кэша |
| Modify `PrototypeApp/Application.swift` | Сохранение единого runtime-документа перед запуском |
| Modify `Extension/PacketTunnelProvider.swift`, `Library/Network/ExtensionProvider.swift` | Чтение runtime, генерация конфига, передача policy в Libbox |
| Modify `upstream/sing-box/protocol/vkturn/config.go`, `experimental/libbox/vk_turn_prototype.go` | Генерация четырёх выходов и selector без изменения legacy single-node |
| Existing `upstream/sing-box/daemon/priority_failover*.go` | Переиспользовать контроллер; менять только при выявленном несоответствии |
| Modify `PrototypeApp/LogView.swift`, `Application.swift`, `Localizable.xcstrings` | Ограниченная диагностика failover и понятное all-down |
| Existing Swift/Python/Go/XCTest suites | Проверки новых границ в существующих harness |

Не создавать новый UI редактора серверов, отдельный движок переключения на Swift, дополнительный proxy-процесс или общий слой абстракций над подписками.

## Задача 1. Чистый адаптер Xray → четыре выхода и политика

**Files:** Create backend `app/subscriptions/xray_adapter.py`, `tests/test_xray_subscription_adapter.py`.

**Interfaces:** `adapt_xray_subscription(payload: bytes) -> VLESSProvisioning`; Pydantic-модели `VLESSProvisioning`, `PriorityFailoverPolicy`, `VLESSOutbound` в этом же модуле; `SubscriptionAdaptationError(code: str)` с безопасным кодом. `VLESSProvisioning` сериализуется с именами полей контракта выше.

- [ ] Написать синтетические fixtures для восьми существующих порядков A–H и тест `test_adapts_each_group_without_group_name_mapping`: четыре выхода, точный primary/backups, сохранённые UUID/адрес/порт/TLS/REALITY/flow; размер ответа <=8 MiB.
- [ ] Добавить `test_follows_graph_after_array_reordering`: перестановка outbounds/balancers/rules не меняет результат; массив с посторонним node5 и единственной валидной failover-конфигурацией выбирает именно её.
- [ ] Добавить `test_rejects_ambiguous_or_unsafe_graph`: несколько валидных графов, цикл, отсутствующая ссылка, duplicate tag, две цели префикса, три/пять выходов, fallback в freedom, тег direct/vk-wg → ошибка, без частичного результата.
- [ ] Добавить `test_rejects_unsupported_transport_or_vless_options`: WS/gRPC/XHTTP/KCP, неизвестное шифрование вместо encryption=none, неизвестный flow, отсутствие REALITY/ключа, неверные UUID/порты/shortId → ошибка, без потери параметров «по умолчанию».
- [ ] Запустить `python -m unittest tests.test_xray_subscription_adapter -v` в backend, зафиксировать ожидаемые падения до реализации.
- [ ] Реализовать граф: от loopback outbound `proxy` через его settings.inboundTag найти однозначное правило балансировщика; разрешить его selector по Xray-семантике префикса в единственный VLESS; через fallbackTag перейти к следующему loopback. После четырёх уникальных VLESS требовать blackhole. Числа в BALANCER_1 и порядок массива не использовать как источник приоритета.
- [ ] Преобразовать только VLESS encryption=none + RAW/TCP + REALITY; сохранить server/port/UUID/flow, serverName, fingerprint, publicKey, shortId, ALPN при наличии. Не поддерживаемые значимые socket/mux/transport-настройки отклонять, а не молча удалять. Разрешённые незначимые поля Xray перечислить явно в коде и покрыть fixtures после сверки сформированного JSON.
- [ ] Повторить тесты; проверить утечку секретов через repr модели/исключения/логи на синтетическом UUID. Payload/модели не логировать.

**Результат:** детерминированный адаптер не зависит от названия группы и не принимает неизвестные конструкции за рабочую конфигурацию.

## Задача 2. Получение персонального Xray JSON

**Files:** Create backend `app/subscriptions/remna_subscription.py`; tests в `tests/test_app_vless_subscription.py`; reuse `app/config.py`, `app/utils/remna_client.py`.

**Interfaces:** `fetch_xray_subscription(short_uuid: str, *, device_headers: Mapping[str, str]) -> bytes`; `resolve_vless_provisioning(user: User, remote: RemnaUser, *, device_headers: Mapping[str, str]) -> VLESSProvisioning` в `service.py`. Последняя функция использует адаптер задачи 1, не вызывает создание WDTT.

- [ ] Зафиксировать подтверждённый установленным кодом 2.6.4 endpoint `/api/sub/{shortUuid}/json` (REQUEST_TEMPLATE_TYPE.XRAY_JSON=`json`) в HTTP-тесте; route clientType передаётся в SRR как override. Не использовать вымышленный suffix xray-json и не подделывать User-Agent HAPP. Проверка результата реальных response rules входит в следующий шаг.
- [ ] На изолированном тестовом экземпляре получить сформированный JSON с синтетической учётной записью: убедиться, что injectHosts действительно подставляет четыре нужных узла, external squad сохранён, HWID и SRR не заменяют ответ заглушкой. Не запрашивать произвольного production-пользователя и не регистрировать ему устройство ради теста.
- [ ] Написать `test_fetch_uses_trusted_upstream_explicit_format_and_user_key`: URL строится из REMNA_SUBSCRIPTION_UPSTREAM_API_URL либо REMNA_API_URL с quote(short_uuid); никогда из URL, присланного приложением, и не через публичный alias, возвращающий в этот же backend.
- [ ] Написать тесты: redirects запрещены, timeout 10s на полный fetch, потоковое ограничение тела 8 MiB, HTML/base64/невалидный JSON/ошибки HTTP → безопасная ошибка; upstream URL и ключ не попадают в логи.
- [ ] Определить по установленному extractHwidHeaders точный allowlist заголовков устройства. Передавать существующий UA VipinApp и только требуемые device/HWID-поля, X-Forwarded-Proto=https; не передавать native Bearer, Cookie, произвольные query-параметры или присланный клиентом X-Forwarded-For. Не придумывать HWID. Если политика требует HWID, добавить один стабильный app-install ID с хранением в существующем Keychain и передачей под подтверждённым заголовком; это обязательная часть этой задачи и клиентского HTTP-теста, только если требование подтверждено.
- [ ] Реализовать fetch через существующий httpx без административного токена на публичный subscription endpoint. Сетевые запросы не должны начислять бонусы, менять группу, тариф или создавать дополнительные аккаунты.
- [ ] Возвращать из `_verify_remna(user)` уже полученный `RemnaUser`. ACTIVE допускает запрос с существующим доступом, включая free; LIMITED даёт unavailable/traffic_limited без ключей. Сохранить существующие проверки остальных статусов, не переносить LIMITED в общий запрет WDTT.
- [ ] До и после fetch проверить актуальность user/short_uuid и remote identity; при смене externalSquadUuid во время fetch отбросить результат с 503 subscription_changed, следующий refresh повторит попытку. Не держать DB-транзакцию открытой ради сетевого ожидания; использовать текущий session-паттерн с refresh.
- [ ] Запустить `python -m unittest tests.test_app_vless_subscription tests.test_remna_client -v`; тесты включают revocation/group change во время await, free/standard/partner/нулевой баланс и LIMITED с доступным WDTT.

**Результат:** пользовательский комплект формируется тем же механизмом Remnawave, который учитывает доступ и группу; адаптер не читает production-БД напрямую.

## Задача 3. Native descriptor/config/UI и совместимость

**Files:** Modify backend `app/subscriptions/service.py`, `ui.py`, `app/config.py`, `/Users/acurofobia/code/VPN/.env.example`, `tests/test_app_subscription.py`, `test_subscription_proxy.py`, `test_app_vless_subscription.py`.

**Interfaces:** existing `handle(kind, short_uuid, request, session)` и `UIState`; добавить к UIState `vless_state` и `vless_reason` с прежними значениями по умолчанию. Флаг `APP_SUBSCRIPTION_VLESS_ENABLED: bool = False`; capability и JSON-контракт из раздела выше.

- [ ] Написать failing tests полного descriptor → config → UI для нового capability; без capability или с выключенным флагом сохранить прежние sing_box_url=null/option01 unavailable. Проверить Vary и no-store.
- [ ] Реализовать ссылку на существующий config endpoint; брать Bearer и origin из прежнего контракта, не выдавать административные токены. Прямой запрос config без Bearer/с чужим Bearer/с отозванным ключом не должен запускать fetch.
- [ ] Разделить получение config от `_state(... provision=True)`: запрос config не создаёт WDTT и не зависит от его доступности. Для UI использовать статус/права, не повторять загрузку полного Xray JSON.
- [ ] Обработать LIMITED/нет доступа успешным пустым provisioning; transient upstream/adapter failure — 503, не 200 с пустыми ключами. Клиент доверяет config как источнику доступности VLESS; UI не может разрешить старт при пустом наборе.
- [ ] Добавить legacy-тесты, запрещающие вызов адаптера/fetch/WDTT при HAPP, sing-box, браузере, неизвестном UA и старой сборке VipinApp. Существующие тела/статусы/значимые заголовки на фиксированном upstream сохраняются.
- [ ] Выполнить `python -m unittest tests.test_xray_subscription_adapter tests.test_app_vless_subscription tests.test_app_subscription tests.test_app_subscription_validation tests.test_subscription_proxy tests.test_subscription_profiles_api tests.test_split_tariff_billing tests.test_wdtt_service -v`.

**Результат:** дополнительный режим включается только для совместимого клиента; обычная выдача и тарификация не зависят от нового адаптера.

## Задача 4. Типизированный комплект и атомарный кэш в приложении

**Files:** Modify `PrototypeApp/Subscription.swift`, `SubscriptionLoader.swift`, `SubscriptionStore.swift`; tests `scripts/tests/test_prototype_subscription.py`, `test_prototype_subscription_lifecycle.py`, `test_prototype_subscription_ui.py`.

**Interfaces:** `PrototypeVLESSProvisioning: Codable, Sendable` и `PrototypePriorityFailoverPolicy: Codable, Sendable` в Subscription.swift; `PrototypeSubscription.vlessProvisioning: PrototypeVLESSProvisioning?`; `static decodeVLESSProvisioning(_ data: Data) throws -> PrototypeVLESSProvisioning`. Существующий `vlessOutbound: Data?` оставить только как legacy single-node путь; оба варианта одновременно запрещены.

- [ ] Написать тесты available-документа: ровно четыре VLESS, валидные и уникальные теги, primary/backups образуют то же множество; фиксированные timing-параметры и selector=vk-wg. Проверить unknown kind/schemaVersion, bool вместо порта, неверный UUID, detour и группы вместо VLESS — rejection.
- [ ] Проверить restricted/unavailable: отсутствие ключей и доступности VLESS, при этом VK TURN продолжает декодироваться. Невалидный новый формат должен прерывать транзакцию, не попадать в существующий catch с успешным сохранением snapshot без VLESS.
- [ ] Добавить capabilities ко всем native запросам, сохранить same-origin HTTPS/Bearer и запрет редиректов. Если задача 2 подтвердила необходимость HWID, добавить стабильный ID и тест его сохранения между запросами/перезапусками без вывода в логи.
- [ ] Различать новый документ по kind/schemaVersion; legacy JSON с одним VLESS по-прежнему импортируется по существующим правилам без автоматизации. Не применять выбор R3-N1 к новому комплекту.
- [ ] Проверить миграцию старого Codable-кэша: отсутствие нового поля допустимо; повреждённый новый комплект не разрешает старт. При загрузке нового кэша повторно валидировать все четыре выхода и policy, а не только UI.
- [ ] Проверить 503 после descriptor, повреждённый policy, отмену, смену ссылки и запоздалый ответ: предыдущие bytes кэша не меняются; новый успешный restricted снимает старый VLESS из snapshot. Обновление не изменяет runtime работающего туннеля.
- [ ] Выполнить из client root: `python3 -m unittest discover -s scripts/tests -p 'test_prototype_subscription*.py' -v`.

**Результат:** параметры всех выходов и политика сохраняются и обновляются вместе; офлайн-запуск использует последний валидный комплект.

## Задача 5. Сборка sing-box config и передача политики в extension

**Files:** Modify `PrototypeApp/Application.swift`, `Extension/PacketTunnelProvider.swift`, `Library/Network/ExtensionProvider.swift`, core `protocol/vkturn/config.go`, `experimental/libbox/vk_turn_prototype.go`; tests core `protocol/vkturn/vless_test.go`, `experimental/libbox/vk_turn_prototype_test.go`, `scripts/tests/test_vk_turn_switching.py` и `test_prototype_subscription_lifecycle.py`.

**Interfaces:** добавить Go `BuildVLESSFailoverConfiguration(route json.RawMessage, outbounds []json.RawMessage, primary string) (string, error)`; в StartVKTurnPrototype добавить вход `vless_outbounds` и `vless_primary`, оставив старое `vless`. Swift передаёт JSON policy отдельно в start option `priorityFailoverJSON`, который ExtensionProvider переносит в `LibboxOverrideOptions.priorityFailoverJSON`.

- [ ] Написать тест генератора: четыре исходных тега + selector vk-wg(default=primary, interrupt_exist_connections=true) + direct; DNS detour, route.final и rule-set transport указывают на selector; bootstrap DNS не зависит от самого туннеля. Нет TURN/WireGuard endpoint и дополнительных TUN.
- [ ] Реализовать генератор с повторной валидацией и без переноса ключей provisioning в обычный sing-box config. `failover` остаётся внешним override, неподдерживаемых JSON-полей ядру не передавать.
- [ ] Application атомарно пишет весь runtime provisioning в существующий `prototype-vless.json` перед start. Extension различает legacy single-node и новый документ; формирует четыре выхода и policy из одного прочитанного snapshot. При переключении на VK TURN очищать VLESS runtime/override существующим порядком, не смешивать режимы.
- [ ] Перед запуском вызвать существующий LibboxValidatePriorityFailover для конечного config+policy; отсутствующие выходы, неверный selector или повреждённая policy → ошибка запуска, без тихого запуска single-node/direct.
- [ ] ExtensionProvider принимает опциональную строку policy, проверяет тип и передаёт её в override. При отсутствии policy сохраняется прежнее поведение обычных профилей, baseline и VK TURN. Проверить stop/start/reload/system start без foreground-приложения.
- [ ] Добавить тест cold start: selector cache содержит backup, primary мёртв, рабочий резерв выбирается на существующем outbound-ready этапе до сетевых загрузок; persistent rule-set cache и bundled initial_path сохраняются.
- [ ] Проверить отсутствие секретов в дополнительном start_options snapshot: сохранить существующее удаление файла после запуска; не создавать новый plaintext config dump. Проверить также failure/stop пути.
- [ ] Выполнить targeted Go/Swift tests из раздела команд ниже, затем пересобрать используемый проектом Libbox.xcframework и схему VKTurnPrototype.

**Результат:** один packet tunnel запускает четыре выхода с существующим контроллером; переходы не требуют reloadService или перезапуска NEVPN.

## Задача 6. Зафиксировать экономный алгоритм и диагностику

**Files:** existing core `daemon/priority_failover.go`, `priority_failover_probe.go`, `priority_failover_test.go`, `priority_failover_integration_test.go`; Libbox `priority_failover.go`; Swift `Application.swift`, `LogView.swift`, `Extension/PacketTunnelProvider.swift`, `Localizable.xcstrings`.

**Interfaces:** existing `PriorityFailoverStatus()`, `PriorityFailoverState` и cycle. В существующем `prototype-status.json` добавить опциональный объект failover без ключей: mode, selected, primaryHealth, allDown; использовать существующий updatedAt. Получать состояние из работающего commandServer в уже существующем семплере, с корректной отменой/освобождением ссылки при остановке. Читать только при работающем VLESS failover; устаревшие данные старше 5s не считать текущими. Отдельный status-файл, таймер и история в RAM не нужны.

- [ ] Сначала добавить тест `TestPriorityKeepsHealthyBackupWhenHigherBackupRecovers`: основной остаётся down, текущий b2 здоров, b1 восстановился → selected остаётся b2, b1 не проверяется. Существующий контроллер должен проходить этот тест без переписывания.
- [ ] Проверить healthy primary при большей задержке, failureThreshold=2, recoveryThreshold=3, reset счётчиков после успеха/неудачи, начальный поиск, all-down, ручной режим, повторный Start, отмену stop/pause/reload и единственную проверку одновременно. Использовать существующий test backend с максимальным concurrent-probes=1.
- [ ] Проверить реальный probe: dial идёт через конкретный outbound текущего instance, HEAD 204, второй адрес после неудачи первого в пределах общего 5000ms, HTTP 503 не считается здоровьем, ответ/соединение закрываются. Не вызывать временные ProbeConfig/ProbePriorityFailover в периодическом цикле.
- [ ] Проверить один и тот же контроллер при повторных reload; устаревший результат не переключает новый instance. Не сбрасывать ни весь TUN, ни DNS/rule-set при обычной смене selector.
- [ ] Вывести различие «VPN-туннель поднят» / «все выходы недоступны» в существующем статусе/журнале. Логи ограничить переходами состояния и безопасными тегами; никаких периодических дампов/проверок всех резервов ради UI списка.
- [ ] Подтвердить, что all-down не меняет route на direct: явные существующие direct-правила сохраняются, проксируемый трафик остаётся на proxy пути. Отказ двух контрольных адресов может дать ложный all-down; не маскировать это переключением напрямую.
- [ ] Выполнить policy/integration tests и native UI tests. Менять реализацию контроллера только для конкретных упавших требований, сохраняя покрытие существующих lifecycle-сценариев.

**Результат:** ограниченная последовательная работа и понятное состояние без второго ядра, бесконечных повторов и накопления проверок.

## Задача 7. Сквозная проверка и память на физическом iPhone

**Files:** Modify `docs/testing/vk-turn-prototype.md`; add credential-free report `docs/testing/remnawave-failover-memory.md`; reuse `scripts/analyze_vk_turn_memory.py`, existing XCTest `SFIUITests/PrototypeSmokeTests.swift`, `PrototypeDeviceRoutingTests.swift` и локальные fixtures.

- [ ] Подготовить изолированные fixtures для двух пользователей в разных группах, изменения группы и отзыва ссылки. Пройти весь backend → importer → generated config → policy validation без production ключей. Обновление группы меняет следующий запуск, не текущий runtime.
- [ ] На устройстве проверить реальный VLESS+REALITY, DNS, TCP, UDP/QUIC, обе настройки маршрутизации, работу с закрытым приложением и заблокированным экраном. HTTP health не заменяет проверку UDP.
- [ ] Управляемо эмулировать отказ primary/backup на тестовом окружении или диагностическим fault injection, без изменения production-серверов. Отдельно обозначать симуляцию результата проверки и настоящий сетевой отказ.
- [ ] Сравнить один VLESS без автоматики и четыре VLESS с автоматикой на одном устройстве/сборке/сети/одинаковых правилах и workload: 2 min warm-up + 10 min measurement каждого. Повторить пары запусков, чтобы определить естественный разброс.
- [ ] Отдельно измерить рабочий резерв, all-down, не менее 20 failure/recovery переходов + 5 min после них, блокировку экрана и смену Wi-Fi/мобильной сети. Нагрузка — одинаковые видео/загрузки и idle; idle отдельно не считать доказательством безопасности под трафиком.
- [ ] Использовать уже существующий TASK_VM_INFO.phys_footprint VPN extension; CSV писать на диск без RAM-истории. Указать устройство/iOS/build, медиану, p95, startup-inclusive peak, разницу с одним VLESS и память после переходов. Для неравномерных sample intervals использовать равные окна/взвешивание, не выдавать sample-weighted median за time-weighted.
- [ ] Подтвердить один экземпляр ядра/контроллера, concurrent-probes<=1 и отсутствие роста числа goroutines/соединений при all-down и после переходов. Оценивать settled memory с учётом Go GC/естественного разброса, а не требовать побайтового возврата heap.
- [ ] Критерий допуска: корректный failover без утечки в direct, ограниченный startup/поиск, отсутствие crash/OOM/перезапуска и устойчивого накопления памяти; фактическая прибавка к baseline опубликована. Если пик близок к наблюдаемому memory pressure либо преимущество по памяти не подтверждено, не включать массово: устранить источник/повторить измерения. Не назначать вымышленный лимит iOS или обещание «+N MB» до измерений.

**Результат:** воспроизводимый отчёт с реальными пределами поведения и памяти; отсутствие устройства означает, что hardware acceptance не завершён.

## Задача 8. Подготовка включения и отката на panel

**Files:** backend config/.env.example и существующая deployment-инструкция; результаты и команды обновить в этом плане. Не менять production до отдельного разрешения.

- [ ] Проверить исходные версии локального VPN checkout и production, составить минимальный diff. Локальные и удалённые пользовательские изменения не перезаписывать.
- [ ] Подготовить backend-образ с APP_SUBSCRIPTION_VLESS_ENABLED=false; проверить, что config flag и capability сохраняют прежнее поведение. Remnawave, группы и её шаблоны не обновлять ради этой функции.
- [ ] Проверить наличие старых и новых endpoints через оба существующих origin/alias на тестовом окружении; no-store, Bearer, Vary и отсутствие рекурсии backend → alias → backend. Новые proxy-маршруты Caddy не добавлять без необходимости.
- [ ] После отдельного разрешения deploy: сначала backend с выключенной функцией и regression старых клиентов; затем совместимое приложение и существующий APP_SUBSCRIPTION_PILOT_USER_IDS с тестовыми ID; только затем флаг VLESS. Сохранить текущий pilot allowlist, не расширять на всех автоматически.
- [ ] На pilot проверить группы из обеих четвёрок, смену группы, offline start, all-down/recovery, отсутствие лишних WDTT provisioning и стабильность старого HAPP. Не менять группу реального пользователя ради эксперимента.
- [ ] Откат: выключить APP_SUBSCRIPTION_VLESS_ENABLED либо вернуть прежний backend-образ. Это не требует смены ссылок/групп/ключей и не обрывает текущий туннель. Важно: следующий успешный ответ с sing_box_url=null отключит VLESS для будущего старта нового приложения; выключение функции не обещает сохранить VLESS доступность после refresh. Ошибка 503, напротив, сохраняет последний полный кэш.
- [ ] Массовое включение только после задач 1–7 и отдельной команды пользователя. Наблюдать безопасные коды ошибок, длительность адаптации и переходы failover без URL/UUID/конфигов в логах.

## Команды проверки при реализации

Backend: использовать существующее Python-окружение проекта (Dockerfile сейчас Python 3.13), зависимости из `backend/requirements.txt`. Не устанавливать/обновлять их в рамках составления плана.

```sh
# Working directory: /Users/acurofobia/code/VPN/backend
python -m unittest tests.test_xray_subscription_adapter tests.test_app_vless_subscription tests.test_app_subscription tests.test_app_subscription_validation tests.test_subscription_proxy tests.test_subscription_profiles_api tests.test_split_tariff_billing tests.test_wdtt_service -v

# Working directory: /Users/acurofobia/code/sing-prototype
python3 -m unittest discover -s scripts/tests -v

# Working directory: /Users/acurofobia/code/sing-prototype/upstream/sing-box
go test -race -ldflags=-checklinkname=0 -tags with_wireguard,with_gvisor,with_utls,with_clash_api,with_low_memory,badlinkname,tfogo_checklinkname0 ./daemon -run '^TestPriority' -count=1
go test -ldflags=-checklinkname=0 -tags with_wireguard,with_gvisor,with_utls,with_clash_api,with_low_memory,badlinkname,tfogo_checklinkname0 ./protocol/vkturn ./experimental/libbox -run 'TestVLESS|TestPriority' -count=1

# Working directory: /Users/acurofobia/code/sing-prototype
scripts/build_vk_turn_prototype.sh
xcodebuild test -project sing-box.xcodeproj -scheme VKTurnPrototype -destination 'platform=iOS Simulator,id=<installed-UDID>' -only-testing:SFIUITests/PrototypeSmokeTests -only-testing:SFIUITests/PrototypeDeviceRoutingTests
```

Запустить существующий HTTP fixture для UI tests согласно harness. Проверить diff после SwiftFormat только изменённых Swift-файлов; SwiftLint с настройками репозитория. Общий `make fmt` без необходимости не запускать. Сборка SFI не заменяет проверку изменённой схемы VKTurnPrototype. Test-only fault injection не включать в release.

На момент планирования `go` отсутствует в PATH и обычных путях установки, поэтому Go checks не выполнены. Перед реализацией найти установленный toolchain или подготовить совместимую версию по go.mod и существующему build script; не обновлять зависимости ядра. В этом чате выполнены чтение исходников и read-only SSH-проверки, не тесты новой функции.

## Самопроверка плана

- Поведение пользователя и последовательные проверки: задачи 5–6; уже существующий контроллер переиспользуется.
- Персональность, группа и существующая тарификация: задачи 1–3; free и LIMITED явно учтены.
- Формат, совместимость старой сборки и старых клиентов: задачи 3–4; capability не заменяет Bearer.
- Целостность кэша и background/system start: задачи 4–5.
- Проверки в текущем instance, отмена и отсутствие direct fallback: задачи 5–6.
- Фактическая память и проверка на устройстве: задача 7, без неподтверждённого обещания в MB.
- Production pilot и откат: задача 8, отдельное разрешение на deployment.
- Остающийся технический риск до завершения задач 1–2: подтвердить результат SRR/HWID и точный состав полей на сформированном синтетическом ответе по подтверждённому endpoint `/json`. Если текущая панель не позволяет получить этот документ с сохранением контроля доступа, остановить этот этап и пересмотреть способ fetch; не обходить ограничения и не заменять его общим конфигом.

## Локальное выполнение 2026-10-20

Реализация разрешена отдельной командой пользователя после согласования плана.
Изменения оставлены без commit/push/deployment; прежний пользовательский diff
сохранён. Production использован только для read-only чтения версий/кода/статуса.

| Задача | Состояние |
|---|---|
| 1 | Строгий адаптер и синтетические графы реализованы; реальный сформированный документ относится к незакрытому этапу 2 |
| 2 | Bounded fetch, allowlist заголовков и повторная проверка identity реализованы; изолированная SRR/HWID-приёмка не выполнена (пользователь подтвердил отсутствие стенда) |
| 3 | Flag/capability/Bearer/native UI/legacy совместимость реализованы, targeted tests проходят |
| 4 | Типизированный документ, атомарный кэш и повторная валидация реализованы |
| 5 | Четыре выхода + selector и внешний override реализованы; Libbox и VKTurnPrototype пересобраны |
| 6 | Контроллер сохранён, новый backup/cold-cache/cancellation coverage; статус в существующем sampler, all-down отличается от поднятого туннеля |
| 7 | Сквозные synthetic fixtures и анализатор готовы; физические сеть/нагрузка/память не измерены, hardware acceptance не завершён |
| 8 | Инструкция включения/отката подготовлена; Docker-образ не собран (нет runtime), staging aliases не проверены; deployment/pilot не выполнялись |

Применён Go 1.26.0 по существующему go.mod, без обновления зависимостей.
Python 3.13 использован из существующего `/private/tmp/vpn-id-test-env`:
локальные `.venv` ссылаются на отсутствующий системный интерпретатор.
SwiftFormat 0.64.0 применён только к семи изменённым Swift-файлам;
SwiftLint 0.65.1: 0 serious, 1 прежний prefer_type_checking warning в ExtensionProvider.

Проверки:

- Backend команда из плана: **123/123 OK** после исправлений ревью.
- Полный backend: **335 tests, 6 failures**. Сравнение с исходным HEAD `a5a125e`
  в том же cwd/settings: те же 6 failures на 322 тестах. Это существующие
  ожидания URL и legacy BS traffic, не регрессии новой подписки:
  `test_revoke_subscription_rotates_only_primary_key`,
  `test_revoke_subscription_skips_missing_bs_key`,
  `test_new_user_uses_public_subscription_proxy_url`,
  `test_response_normalizes_existing_panel_subscription_url`,
  `test_get_traffic_ignores_legacy_bs_identity`,
  `test_reset_traffic_with_bs_target_reports_external_management`.
- Go race: daemon, protocol/vkturn, experimental/libbox с фильтром
  `TestVLESS|TestPriority` — все пакеты OK. Среди проверок: сохранённый мёртвый
  backup на cold start, выбор до rule-set fetch, удержание здорового backup,
  отмена настоящего заблокированного probe/соединения и запрет позднего старта.
- Сквозной fixture: два синтетических пользователя → backend HTTP → Swift →
  Go config → Libbox policy; новая группа видна следующему snapshot, отзыв
  ссылки запрещает следующий запрос. Production ключей в fixture нет.
- Libbox.xcframework и подписанный Debug VKTurnPrototype: **BUILD SUCCEEDED**.
- Полный XCTest на iPhone 18 Pro simulator: **21 passed, 1 device test skipped**.
  Устройство не проверяется симулятором. После исправлений ревью выполняется
  отдельный smoke с новой сборкой; итог ниже.

Независимое ревью: два Important исправлены в одном проходе с RED→GREEN:
повторное захватывание SQLAlchemy connection перед HTTP await и ожидание старта
VLESS до отмены ядра. Для второго добавлен отменяемый контекст commandServer и
защёлка на Swift-границе; ресурсы закрываются после выхода startup. Сам алгоритм
priority failover не переписывался. Critical/Minor замечаний нет.

Отчёт памяти: `docs/testing/remnawave-failover-memory.md` — **не измерено**.
iPhone 13 / iOS 27.0.1 обнаружен, но paired реальные VLESS/workload прогоны не
выполнялись. Idle/симулятор/старые VK TURN CSV не выданы за новую приёмку.
Массовое включение не готово и требует закрытия этих этапов и отдельной команды.

Итог после исправлений ревью: полный клиентский suite с настроенным
`VPN_BACKEND_PYTHON` — **71/71 OK**; повторный native UI smoke — **1 passed,
1 device test skipped, TEST SUCCEEDED**. `git diff --check` в приложении,
ядре и backend — без ошибок. Все исходные незакоммиченные изменения сохранены.
