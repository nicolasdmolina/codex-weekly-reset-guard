# Design contract

Second Wind is a compact, calm macOS utility, not a dashboard or a marketing page.
It is the native translation of the Astryx system: semantic tokens, a 4-point
spacing scale, radii 8/12/16 and motion at 175/280/410 ms. Tokens live in
`Sources/SecondWind/DesignTokens.swift`; views never use raw colours or sizes.

## Shell

- An `NSStatusItem` with the `wind` symbol and the lowest headroom across all
  accounts. It switches to a warning triangle when an account needs attention.
- A 380 × 560 pt popover: header (mark, name, one-line summary, check now),
  scrolling content, footer (add account, last checked, ••• menu).
- Accounts are grouped by service in inset sections, one row per account, divided
  by hairlines. No nested cards.

## Colour

- Teal (`#0E9F8E` light, `#3FD9C3` dark) is the only accent: primary buttons,
  healthy meters, the brand mark.
- Amber means near a limit. Coral means the user must act. Neither is decorative.
- Every status pairs its colour with an SF Symbol and text.
- Canvas, surface and raised surface are neutral greys; secondary text stays
  neutral, never tinted.

## Signature: the headroom meter

Each limit is a 6 pt capsule of remaining headroom with a 1 pt tick at the alert
line (3% for Codex auto-redeem, 10% for Claude alerts). When a reset lands, the
fill sweeps back on the slow motion token. Reduce Motion removes the sweep.

## Behaviour

- Background refresh never dismisses or reorders the open popover.
- Every action reports an inline result; Codex events go to the local history.
- Copy names the action and the recovery. No taglines or helper captions that the
  layout could carry instead.
- Deterministic previews cover onboarding, connect, paused, healthy, near limit,
  redeemed, auth error, both services together, Claude low and Claude sign-in.
