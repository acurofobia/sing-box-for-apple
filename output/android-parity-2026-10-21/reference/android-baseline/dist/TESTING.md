# Проверки тестовой сборки WhiteLink 0.1.0

14 октября 2026 года. APK предназначен для установки и самостоятельного сетевого тестирования на Android 7.0+ (ARM64; также включён x86_64).

## Автоматические проверки

- Android Kotlin/JNI compile и упаковка debug APK с одним libbox.aar.
- 34 JUnit-теста строгого VLESS/TURN импорта, выбора режима и настоящего локального HTTP round trip: ошибки статуса, redirects, origin policy, gzip/body limits, отмена, атомарное сохранение прежнего снимка и корректного второго режима.
- Go core tests: PacketConn/deadlines/cancel/full queue, generations, VLESS configuration и настоящий loopback TCP через VLESS, старт общего routing с загрузкой всех 21 встроенных .srs.
- TURN tests: WRAP-A framing/round trip/wrong key, GETCONF validation/denials/redaction, protection failure, физический DNS/socket close, согласованность provision, stop и запрет запоздавших workers.
- ELF LOAD alignment 0x4000 (16 КиБ) для обоих libbox.so и обеих libandroidx.graphics.path.so. Это проверка бинарной совместимости; устройство с 16 КиБ страниц здесь не запускалось.
- APK Signature Scheme v2, package io.whitelink.android; проверка подписи apksigner и zipalign.

Итоговый Gradle build/lint и результаты тестов находятся в `build-logs/android-final.log`, `app/build/reports` и `app/build/test-results`. Go-логи — `build-logs/core-tests.log`, `turn-tests.log`. Race прогон не состоялся: на Windows отсутствует host C compiler gcc.

В manifest сохранено точечное подавление ForegroundServicePermission из SFA: lint проверяет alarm permission, но пропускает отдельное основание для подготовленного VPN. Оно описано в [официальной документации Android](https://developer.android.com/develop/background-work/services/fgs/service-types#system-exempted). Избыточные разрешения exact alarm не запрашиваются.

## Что проверить на телефоне

1. Установка, системное VPN permission и foreground notification; отказ в permission, отзыв permission, stop из уведомления.
2. Подписка с обоими режимами/одним режимом/двумя null; ручной JSON и TURN import; запуск после закрытия приложения без обновления подписки.
3. Реальные HTTPS/TCP/UDP/DNS через VLESS и VK TURN; серверные TLS/REALITY/Vision параметры и WRAP-A/DTLS/GETCONF совместимость.
4. Direct/reject правила белых списков, блокировка YouTube QUIC, отсутствие неподдерживаемого IPv6 bypass на dual-stack/IPv6-only сети.
5. Переключение режима, Wi-Fi ↔ mobile, потеря сети, stop во время bootstrap, Doze/sleep/wake.
6. Минимум двухчасовой TURN сеанс с нагрузкой и 30 connect/stop циклов; отсутствие утечки ресурсов и фактические RSS/PSS.
7. Android Keystore: настройки после перезапуска; очистка и повторный импорт при повреждении/потере ключа; новая привязка device ID после переустановки.

На этом компьютере нет подключённого Android-устройства или AVD, аппаратная виртуализация недоступна. Поэтому установка/интерфейс на устройстве, Android VPN lifecycle и соединение с пользовательским шлюзом не заявлены проверенными. Пользователь выполняет эти проверки самостоятельно.

## Ограничения этой версии

- Интерактивный экран VK CAPTCHA не реализован. Если автоматическое получение anonymous credentials требует ручного действия, выводится понятная терминальная ошибка без автоматического повторения.
- Фиксированный TURN профиль WRAP-A + DTLS + GETCONF с паролем. Legacy SRTP, video/NoDTLS/raw-IP/account modes не принимаются.
- IPv6 захватывается VPN и блокируется; полноценный IPv6 через proxy отсутствует.
- Нет автоматического переключения между VLESS/TURN, нескольких профилей и сетевого обновления rule sets.
- Счётчик активных TURN-сессий показывает установленные transport sessions. Отдельного transient allocations/wire socket overhead счётчика нет. WG transport bytes считаются до RTP/DTLS/STUN обёртки.
- Компактная Android-оболочка использует адаптированную SFA integration, а не весь SFA editor/Room/IPC UI. Core и UI находятся в одном процессе.
- Android always-on/lockdown и бесшовный kill switch не заявлены проверенными. При отключении/перезапуске без системного lockdown обычная сеть может восстановиться.

APK подписан debug-ключом и является тестовой сборкой. Исходники, лицензии, воспроизводимые scripts и build manifest входят в комплект.
