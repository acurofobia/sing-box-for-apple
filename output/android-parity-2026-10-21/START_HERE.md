# Исправление Android клиента по текущему прототипу

Основной документ — [SPECIFICATION.md](SPECIFICATION.md). Он заменяет ограничения прежней спецификации в части текущего продукта. Объём: 72 требования; приёмка — [93 сценария](ACCEPTANCE.csv), каждый имеет статус not-run до проверки реализованного Android.

Порядок чтения:

1. SPECIFICATION.md — конечное поведение, HTTP/UI/provisioning, экранные состояния, routing/DNS, сервис и миграция.
2. CHANGE_HISTORY.md — изменения с 14 октября и точные расхождения старого Android.
3. design-handoff/START_HERE.html — галерея 11 финальных макетов, screenshots, layouts и исходный Sketch.
4. reference/README.md — дополнительные runtime/core/Android-снимки; SOURCE_MANIFEST.json фиксирует исходные файлы.
5. ACCEPTANCE.csv — шаги, ожидаемый результат и обязательные доказательства; actual_result заполняется исполнителем.

Особенно важно:

- Android уже содержит VPN-сервис, Keystore, socket protection и отмену. Сохраните их.
- Переносится полноценный поток одной подписки с серверным UI. Старые три технические вкладки и direct baseline не являются конечным продуктом.
- Четырёхузловое VLESS резервирование обязательно; Auto между VLESS/TURN остаётся недоступным.
- Финальный DNS задаётся дополнительно к Go builder; списки должны остаться remote с persistent cache.
- Требуется SRTP-паритет со Swift parser, а не только WRAP-A старого Android.
- Screenshot с synthetic connected не доказывает работающую сеть. Для сетевой приёмки нужны реальные Android-устройство и test gateway.

Исходный архив сохранён распакованным в design-handoff без изменений. Его ранние docs/BEHAVIOR/API_AND_FIXTURES и инструкции не переопределяют новую спецификацию при расхождении. OLD_SPECIFICATION_2026-10-14.md — исторический исходник. Примеры example.org, token и keys искусственные.

Дополнение fixtures содержит native provisioning и SRTP payload для contract tests. Исходный fixture server из design-handoff обслуживает только свою папку; новые файлы нужно подключить в тестовом harness согласно fixtures/README.md.

Проверка целостности после распаковки: `python3 tools/verify_bundle.py`. Подробности фактической проверки подготовки — VERIFICATION.md. Этот комплект содержит спецификацию и эталоны; APK с доработками ещё не создавался.
