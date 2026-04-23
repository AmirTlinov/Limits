# side-review-tray-swiftui

Локальный короткий preflight.

## Рамка review
- Проверять не архитектуру, а узкий UI-контракт `MenuBarContentView`: секции `Codex CLI` и `Claude Code` должны сворачиваться независимо и не ломать текущий quick switch.
- Видимая кнопка `Импорт` должна исчезнуть из footer, но импорт должен остаться доступен через `ellipsis` menu.
- Побочные риски review: не потерять actions `activateAccount` / `activateClaudeAccount`, не сломать тексты счётчиков, не сломать persist состояния через `@AppStorage`.

## Cheap probe
- `git diff --unified=2 -- Sources/Limits/Views/MenuBarContentView.swift`
- Что он показал: изменение сейчас локализовано в одном view-файле; quick switch всё ещё висит на stored rows, импорт убран только из видимого footer, а collapsible состояние хранится в `@AppStorage`.
