# Security

This app can redeem an existing Codex reset credit after the user enables
automatic redemption. It cannot issue or purchase credits. A redeemed credit
cannot be restored by this app.

## Reporting a vulnerability

After this repository is published, use the **Security → Report a vulnerability**
button for private reporting. The maintainer must enable private vulnerability
reporting before publication. If that button is unavailable, open an issue asking
for a private contact channel without including exploit details or private data.

Never include credentials, sign-in URLs, account identifiers, reset-credit IDs,
idempotency keys, or files from the app's runtime directory. Use synthetic data.

## Scope and support

The initial public release is a source preview. Security fixes target the latest
published source revision; older revisions do not have a separate support window.
The project does not promise response times or uninterrupted monitoring.

The safety boundary includes canonical weekly classification, expected-account
verification, explicit opt-in, durable idempotency, disable/reconnect races,
app-server process isolation, and local state permissions. See
[privacy and runtime data](docs/PRIVACY.md) and [architecture](docs/ARCHITECTURE.md).
