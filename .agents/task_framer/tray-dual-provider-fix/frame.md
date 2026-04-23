# tray-dual-provider-fix — short frame

Короткий локальный preflight. `task_framer` в этой сессии не поднялся из-за лимита открытых агентских тредов, поэтому ниже честная деградированная рамка.

## Вопросы и наблюдения, которые реально меняют правку

1. **Трей сейчас CLI-only, не dual-provider.** `MenuBarContentView` читает только `currentCLIOverview()`, `currentCLIRateLimitSections()` и `menuPanelAccounts() -> [StoredAccount]`; пути `currentClaudeOverview()` / `claudeAccounts` в трее нет. Если цель — видеть и Codex, и Claude, это не косметика, а смена data source и секций.
2. **Нужно решить, что значит “все аккаунты”.** Сейчас `menuPanelAccounts()` специально скрывает текущий Codex-аккаунт из списка и показывает его отдельно верхней карточкой. Если нужен плоский список всех логинов, фильтр и верхняя композиция меняются.
3. **Для Claude нужен честный контракт трея.** В модели есть `activateClaudeAccount(_:)` и `currentClaudeOverview()`, но живые лимиты Claude зависят от statusline bridge/snapshot. Нужно решить: трей показывает только текущий Claude-логин, или ещё и лимиты, когда есть снимок.
4. **Верхняя стекляшка выглядит структурно лишней, не только стилистически.** Compact `CurrentCLIOverviewCard` сама рисует `.trayPanelSectionChrome(...)`, и на macOS 26 она ещё оборачивается в `GlassEffectContainer`. Это похоже на glass-on-glass и хорошо объясняет “бесполезную заблюренную стекляшку”.
5. **Нужно выбрать действие по нажатию для второго провайдера.** Для Codex верх/список сейчас означает quick switch глобальной CLI-авторизации. Для Claude аналог возможен (`activateClaudeAccount` уже есть), но UX может быть другим: переключать, импортировать текущий, или просто открывать окно.

## Cheap probe по коду

Проба: `rg -n "MenuBarExtra|MenuBarContentView|currentClaudeOverview|claudeAccounts|menuPanelAccounts|trayPanelSectionChrome|GlassEffectContainer" Sources/Limits`

Что подтвердила проба:
- `Sources/Limits/Views/MenuBarContentView.swift` — трей собран только вокруг CLI-состояния и `StoredAccount`.
- `Sources/Limits/App/AppModel.swift` — `menuPanelAccounts()` возвращает только Codex-аккаунты и исключает текущий stored CLI.
- `Sources/Limits/Views/CurrentCLIOverviewCard.swift` + `Sources/Limits/Views/GlassPanelChrome.swift` — верхняя компактная карточка действительно сидит на кастомном glass chrome, что объясняет лишний blur.
