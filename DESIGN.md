# Design Contract

The app is a compact, calm macOS utility—not a dashboard or marketing page.

- Use an `NSStatusItem` and a compact 380 × 560-point SwiftUI popover.
- Show one truthful state indicator per profile row.
- Use native typography, spacing, materials, and SF Symbols with one blue accent.
- Reserve orange/red strictly for near-limit and attention states.
- Keep background refresh from dismissing or rearranging the active popover.
- Every action reports an inline result and material events are written to the local history.
- Deterministic preview modes cover healthy, near-limit, redeemed, and authentication-error states.
