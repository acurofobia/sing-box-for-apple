# Проверки слоя конфигураций

Запуск: `gradlew.bat :app:testDebugUnitTest` из каталога `android-client` с JDK 17 или совместимым JDK Android Studio.

34 JVM-теста используют синтетические настройки и локальный HTTP-сервер на `ServerSocket` с ограниченной очередью и пулом потоков, без внешних зависимостей. Рабочие URL, токены, пароли и ключи пользователя не используются.

- `ConfigurationParserTest`: выбор VLESS, сохранение неизвестных TLS/REALITY/transport-полей, неоднозначность, UUID/port/detour, запрет файловых ссылок, ограничения размера; WDTT, обе разновидности Base64, отклонение legacy SRTP/WireGuard до bootstrap, несовместимые режимы и локальный device ID.
- `StrictJsonTest`: синтаксис RFC 8259, дубликаты ключей, ограничения глубины/UTF-8, строгий Base64.
- `SubscriptionRepositoryTest`: атомарный commit обоих режимов, сохранение валидного второго режима, очистка двумя `null`, сохранение прежнего снимка при HTTP/redirect/origin/JSON/size-ошибках, лимит распакованного gzip, отмена без commit, debug/release-политика URL и отвязка источника при ручном импорте.

JVM-тесты проверяют сетевую транзакцию через in-memory `ProfileStorage`. Android Keystore, AES-GCM, восстановление `AtomicFile` после аварии и исключение backup требуют отдельной проверки на Android. Эти тесты также не подтверждают работу реального VLESS/VK TURN-шлюза или отсутствие утечек трафика на устройстве.
