# Codex Weekly Reset Guard

- Build with `swift build`; test with `swift test`.
- Keep the core target UI-independent and deterministic.
- Never read, copy, print, or persist OAuth token values. Authentication belongs to the Codex app-server inside an app-owned `CODEX_HOME`.
- Never call private ChatGPT backend endpoints. Use the stable Codex app-server JSON-RPC methods only.
- Live verification may read account and rate-limit state but must not consume a real reset.
- A reset may be requested only from the canonical Codex weekly window; 5-hour and model-specific windows must fail closed.
- Persist an idempotency key before any consume request and reuse it after ambiguous failures.
- Use `apply_patch` for source edits and preserve unrelated workspace changes.
- Public release preparation is source-only unless publication is explicitly requested.
- Keep new profiles and launch at login opt-in; preserve existing saved preferences.
- Never require CodexBar or a particular number of accounts for enrollment.
- Run `./scripts/test_tooling.sh` for script changes and the native release check for UI changes.
- Keep private planning, runtime files, and generated QA/build output out of Git.
