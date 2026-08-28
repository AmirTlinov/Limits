## Result

Describe the owner that changed, what it now does, and the visible consequence.

## Proof

List the exact commands and observed results. Add sanitized before-and-after screenshots for a visible UI change.

## Sensitive surfaces

- [ ] Credential, Keychain, auth-file, rollout, or Claude settings behavior is unchanged, or the new contract is covered by focused tests.
- [ ] `PRIVACY.md` and the in-app Settings disclosure still match every field the app reads, stores, or sends.
- [ ] Fixtures and logs contain no real credentials, account identifiers, email addresses, prompts, responses, or private project paths.
- [ ] `./script/generate_xcode_project.rb` was run when sources or resources changed.
- [ ] Non-interactive `./script/ci_gate.sh` and the isolated GitHub Actions CI pass, or the omitted part and reason are stated above.
