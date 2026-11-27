# Design contract

Second Wind is a compact, calm macOS utility, not a dashboard or a marketing page.
It is the native translation of the Astryx system: semantic tokens, a 4-point
spacing scale, radii 8/12/16 and motion at 175/280/410 ms. Tokens live in
`Sources/SecondWind/DesignTokens.swift`; views never use raw colours or sizes.

## Shell

- An `NSStatusItem` with the `wind` symbol and the lowest headroom across all
  accounts. It switches to a warning triangle when an account needs attention.
- A 380 × 560 pt popover: header (the bare `wind` symbol in primary text, 22 pt
  medium in a 24 pt box aligned with the cards' left edge; name; one-line summary;
  check now), scrolling content, footer (add account, last checked, ••• menu).
- Accounts are grouped by service in inset sections, one row per account, divided
  by hairlines. No nested cards.

## Colour

- Teal (`#0A8274` light, `#3FD9C3` dark) is the only accent: primary buttons and
  healthy meters.
- Amber means near a limit. Coral means the user must act. Neither is decorative.
- Every status pairs its colour with an SF Symbol and text.
- Canvas, surface and raised surface are neutral greys; secondary text stays
  neutral, never tinted.

## Signature: the headroom meter

Each reported limit uses a 6 pt capsule. The fill and its label both show the
amount left by default, or the amount used when the user chooses Used. A 1.5 pt
coral tick marks the alert line: 3% remaining on a Codex weekly window with
Auto-redeem enabled and 10% on other windows. It is coral because it marks where
the user will need to act; where the fill covers it, a hairline gap is cut on each
side so it stays crisp. An absent window reads “Not reported” and has no meter.
Stale figures dim, the tick with them. Reduce Motion removes the refill animation.

## Adding an account

- A page, not a card: choose the service, sign in in the browser, then see the
  account's first reading. Nothing is typed: the first sign-in supplies the email,
  and the name comes from it ("Personal" for a consumer mailbox, otherwise the
  organisation) and is editable on the result.
- Services are shown by their own marks: OpenAI's mark for Codex (it signs in with
  ChatGPT) in the text colour, and Claude's spark in Claude's orange. Brand colour
  identifies the service only and is never used as an accent. The marks are vector
  paths in `ProviderMarks.swift`.
- After the service list, every step shares one service tile that never fades.
  While waiting, an accent stroke travels round its border; a badge shows the
  result. Waiting and problem steps keep their message and actions together near
  the middle; the result lifts the tile to make room for the reading and pins Done
  to the bottom. Steps cross-fade under the tile.
- The header names the service being added ("Add Codex account"). While a
  sign-in is under way or stopped it shows a named Cancel that ends it and
  discards the unfinished account; the back chevron appears only where it
  navigates.
- The popover closes while the browser has focus and reopens on its own when the
  sign-in succeeds or hits a problem the user must act on. A sign-in that simply
  ends unfinished waits for the next click instead of taking focus.
- An account already in the list is caught at its first sign-in. A private window
  is the main recovery: the link is copied, not opened in the same browser
  session. Auto-redeem is offered on the result and starts off.

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
