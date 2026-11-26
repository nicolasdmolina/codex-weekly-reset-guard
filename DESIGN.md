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

- Teal (`#0A8274` light, `#3FD9C3` dark) is the only accent: primary buttons,
  healthy meters, the brand mark.
- Amber means near a limit. Coral means the user must act. Neither is decorative.
- Every status pairs its colour with an SF Symbol and text.
- Canvas, surface and raised surface are neutral greys; secondary text stays
  neutral, never tinted.

## Signature: the headroom meter

Each reported limit uses a 6 pt capsule. The fill and its label both show the
amount left by default, or the amount used when the user chooses Used. A 1 pt
tick marks 3% remaining on a Codex weekly window with Auto-redeem enabled and
10% on other windows. An absent window reads “Not reported” and has no meter.
Stale figures dim. Reduce Motion removes the refill animation.

## Behaviour

- Background refresh never dismisses or reorders the open popover.
- “All clear” requires every provider to load and every account to have a
  confirmed reading. The menu bar labels its figure “left” or “used”.
- Each account shows the age of its reading. “Refill due” stays on screen
  until the provider confirms the next window.
- Rename and removal happen in the account row. A failed action stays visible
  until the user retries, cancels or dismisses it.
- A notification opens the popover and briefly highlights the affected account.
- Every action reports an inline result; Codex events go to the local history.
- Copy names the action and the recovery. No taglines or helper captions that the
  layout could carry instead.
- The [visual QA fixtures](docs/VISUAL-QA.md) cover enrollment, account states,
  display preferences, alert settings and recovery.
