# Security policy

Limits handles local authorization snapshots and changes the active credentials used by Codex and Claude Code. Please report a suspected vulnerability privately.

## Report a vulnerability

Use GitHub's **[Report a vulnerability](https://github.com/AmirTlinov/Limits/security/advisories/new)** form. Include the affected version or commit, macOS version, a minimal reproduction, and the security consequence. Remove access tokens, authorization files, session text, email addresses, and Keychain contents from every attachment.

Send credential disclosure, unsafe account switching, update-signature bypass, path traversal, command injection, and other user-risk reports only through that private form. Public issues are for reports that contain no sensitive security details.

The maintainer will acknowledge a usable report within seven days, keep the discussion in the private advisory, and publish a fix and advisory together when the fix is ready. Timing may change when coordination with OpenAI, Anthropic, Apple, or Sparkle is required.

## Supported versions

Security fixes target the latest published release and the `main` branch. Older builds receive a fix only when the same change can be released safely.

## Security boundaries

The most sensitive owners are:

- `KeychainAuthVault`, `GlobalCodexAuthService`, and `GlobalClaudeCredentialService` for credential storage and replacement.
- `CodexAuthSwitchTransaction` and `ClaudeCredentialSwitchTransaction` for validation and rollback.
- `CodexRolloutUsageImporter` and `CodexRolloutContextParser` for local-session parsing and data minimization.
- `ClaudeStatuslineBridgeService` for preserving and invoking an existing status-line command.
- `SoftwareUpdateController`, the pinned Sparkle public key, and the release workflow for update authenticity.
