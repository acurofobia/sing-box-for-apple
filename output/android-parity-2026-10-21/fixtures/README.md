# Дополнительные искусственные документы

Три `vless-failover` документа available/restricted/unavailable проходят структурный контракт текущего импортера.
`vless-failover-invalid-policy.json` намеренно нарушает фиксированный native failureThreshold: документ должен быть отклонён целиком.
`turn-legacy-srtp-settings.json` — payload version=1/type=connection для base64url data в vkturnproxy://import?data=… .
Все адреса, UUID, ключи и hash здесь — публичные искусственные значения. Они не являются рабочими доступами или серверами.

Это входы для unit/contract tests, а не готовый backend. Исходный fixture server из design-handoff/fixtures обслуживает
только собственную папку и не публикует эти дополнительные файлы автоматически. В тестовом HTTP harness подставьте
нужный документ как ответ sing_box_url, выставьте native response headers и проверяйте Bearer/Capabilities.
Положительные проверки протокола не доказывают, что example.org и эти ключи передают VPN-трафик.
