# Privacy

Limits is a local macOS application. It has no developer analytics, advertising SDK, account service, or crash-reporting service.

## Data the app reads

Limits reads only the local data needed to show and switch the accounts that you choose to manage:

- Codex authorization from `~/.codex/auth.json` when importing, validating, or switching an account.
- Codex rollout files under `~/.codex/sessions` and `~/.codex/archived_sessions`. From those JSONL files, Limits extracts thread and turn identifiers, model and reasoning metadata, token counters, repository URL or working-directory path, and a task label made from at most the first 96 characters of the first meaningful user-request line.
- Claude Code credentials from the macOS Keychain when importing, validating, or switching a Claude account.
- Claude Code rate-limit fields delivered to the local status-line bridge. The bridge preserves an existing command-style status line and writes only the five-hour and seven-day limit windows to its snapshot.

Limits does not save full prompts, responses, transcripts, source files, or project contents. The short task label is derived from prompt text and is stored locally so the app can group usage by task.

## Data the app stores

- Saved Codex and Claude credential snapshots live in the macOS Keychain under the Limits service.
- Account labels, identities, state revisions, and credential references live in `~/Library/Application Support/Limits/state.json`.
- Usage counters, model metadata, account-limit observations, repository or path labels, and task labels live in `~/Library/Application Support/Limits/usage.sqlite3`.
- Raw per-turn usage events are retained for 90 days. Daily aggregates and the metadata needed to explain them remain until the user resets the app data.
- The WidgetKit App Group snapshot contains display labels, current limit windows, freshness timestamps, and the Codex summary shown by the widget. It contains no authorization blobs, Keychain credentials, project paths, or task labels.
- Limits may install a local Claude status-line bridge in `~/Library/Application Support/Limits` and update `~/.claude/settings.json`. It records and restores an existing compatible command-style status line.

Files created by Limits use owner-only permissions where macOS exposes POSIX permissions. The main app is intentionally outside the App Sandbox because account switching requires access to the Codex authorization file, local rollout files, the Claude settings file, and the Claude Keychain entry. The widget extension is sandboxed and can read only the App Group snapshot.

## Network activity

Limits makes these outbound requests:

- It starts the locally installed Codex app server to validate accounts and request official account usage and limit data. The Codex process communicates with OpenAI under the user's existing Codex authorization.
- It downloads the official Codex and OpenAI pricing documents used to refresh the versioned local rate card.
- Sparkle checks the public EdDSA-signed update feed and downloads an update only through the published release channel.

Limits does not send local rollout metadata, project labels, task labels, saved credential snapshots, or widget snapshots to the Limits developer.

## Removing local data

Removing an account in Limits deletes that account's saved credential and account-owned usage records. **Clear statistics** starts a new analytics period; it keeps account data, authorization history, rate cards, import positions, and work labels needed to group later activity.

To remove all Limits data, quit the app, remove `~/Library/Application Support/Limits`, remove the Limits App Group container, and delete Keychain items whose service is `com.amir.Limits.authblob`. If the Claude status-line bridge is enabled, disable it from Limits before deleting the app so the previous Claude Code status line is restored.

## Independent project

Limits is an independent project and is not affiliated with, sponsored by, or endorsed by OpenAI or Anthropic. OpenAI, ChatGPT, Codex, Anthropic, and Claude are trademarks of their respective owners.
