# Снимки исходников для сверки

`android-baseline/` содержит исходники оболочки старого клиента и его build/test metadata.
`ios-runtime/` дополняет Swift/UI-срез из `design-handoff/reference/ios-source/` runtime-вызовами и тестами.
`current-core/` содержит выбранные исходники pinned core, включая four-node builder, bootstrap, failover и отмену старта.
`android-to-ios-core-comparison.diff` — сравнение после нормализации CRLF. Это обзор различий, НЕ готовый Android patch.

Папки не являются полными отдельно собираемыми проектами. Полный существующий Android-проект остаётся основой реализации.
Не заменяйте Android core Apple-копией: в Android есть собственные socket protection/bind, resolver, worker cancellation,
IPv6 и no-plaintext-cache изменения. Сопоставьте их с новыми builder/bootstrap/command_server исправлениями.
Эталонные Go/Swift/Python тесты запускаются в исходном дереве с его зависимостями; скопированные пути не превращают их в Android-тесты.
