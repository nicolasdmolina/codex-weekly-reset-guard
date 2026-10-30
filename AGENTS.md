# Second Wind

- Build with `swift build`; test with `swift test`.
- Keep the core target UI-independent and deterministic.
- Never read, copy, print, or persist OAuth token values. Authentication belongs to the Codex app-server inside an app-owned `CODEX_HOME`.
- Never call private ChatGPT backend endpoints. Use the stable Codex app-server JSON-RPC methods only.
- Claude: never read Claude credentials or Keychain items and never call Anthropic endpoints directly. Use the official `claude` executable inside an app-owned `CLAUDE_CONFIG_DIR` with `ANTHROPIC_*`/`CLAUDE_*` stripped.
- Claude usage polling must stay zero-cost: only `/usage` with `local_command == "usage"` and zero turns is accepted; anything else stops polling. Never run `/limit-reset`; Claude resets are redeemed by the user on claude.ai.
- Live verification may read account and rate-limit state but must not consume a real reset.
- A reset may be requested only from the canonical Codex weekly window; 5-hour and model-specific windows must fail closed.
- Persist an idempotency key before any consume request and reuse it after ambiguous failures.
- Use `apply_patch` for source edits and preserve unrelated workspace changes.
- Public release preparation is source-only unless publication is explicitly requested.
- Keep new profiles and launch at login opt-in; preserve existing saved preferences.
- Never require CodexBar or a particular number of accounts for enrollment.
- Run `./scripts/test_tooling.sh` for script changes and the native release check for UI changes.
- UI uses the tokens in `Sources/SecondWind/DesignTokens.swift`; follow `DESIGN.md`. Add new preview kinds to `scripts/native_release_check.sh`.
- Every change goes through a branch and a pull request; merge after CI passes.
- Keep private planning, runtime files, and generated QA/build output out of Git.
