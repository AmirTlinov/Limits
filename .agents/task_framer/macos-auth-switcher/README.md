# macos-auth-switcher preflight

status: need_answers

true_goal:
- Сделать v1 menu bar app для безопасного переключения Codex CLI auth-снимков.
- Не ломать `~/.codex/auth.json` и не придумывать status из воздуха.

least_lie_interpretation:
- Это локальный операторский инструмент поверх существующего Codex auth.
- Источник правды надо брать из живой Codex surface, а не из парсинга файлов или веба.

honest_acceptance:
- Приложение хранит несколько снимков, вручную переключает активный auth и показывает account/limit/reauth status из проверяемого источника.
- Login идёт через поддерживаемый Codex app-server flow.

critical_question:
- Ок ли для v1 считать truth-surface только Codex app-server account/rate-limit/auth-refresh surfaces, без веб-парсинга и без чтения limit-статуса прямо из `auth.json`?

cheap_probe:
- Live probe на 2026-04-23, Codex CLI 0.123.0: у `codex app-server` есть machine-readable surfaces `GetAccountResponse`, `GetAccountRateLimitsResponse`, `AccountRateLimitsUpdatedNotification`, `AccountUpdatedNotification`, `LoginAccountParams`, `ChatgptAuthTokensRefreshParams/Response`.
- `codex login status` сейчас даёт только грубый статус `Logged in using ChatGPT`, значит его одного для честного limit/reauth UI мало.

next_move:
- Если ответ на critical_question = да, v1 надо строить app-server-first.
- Если нет, сначала отдельно доказать другой truth-surface.

possible_miss:
- В репо пока нет стартового macOS проекта, значит первый реальный ход будет bootstrap приложения, не patch.
