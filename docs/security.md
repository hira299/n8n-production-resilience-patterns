# Security considerations

Reliability features collect data: payloads in job tables, errors in dead-letter tables, context in logs. Each one is a place sensitive data can end up. These are the points to get right.

## Credentials

- **Use the n8n credential store,** never literal values in node parameters. A key typed into an HTTP header field is saved in the workflow JSON and travels with every export, backup, and copy. I have found exactly this in one of my own older workflows: an API key in a header parameter, invisible in normal use and fully visible in the export.
- **Protect `N8N_ENCRYPTION_KEY`.** It encrypts stored credentials. Keep it out of the repository and back it up; without it, saved credentials cannot be decrypted after a rebuild.
- **Strip credentials before sharing workflows.** Exports include credential references and can include pinned sample data. See the checklist in [CONTRIBUTING.md](../CONTRIBUTING.md).
- **Database users:** give n8n a Postgres role with access to the `resilience` schema only, not a superuser.

## Data in state tables

- **Payloads:** store what a job needs to run, not everything the source sent. If a payload must include personal data, apply the same retention and access rules as the source system.
- **Dead letters and events:** store identifiers, error classes, and truncated messages. The global error handler deliberately does not copy input data or stacks. Error messages from some APIs echo request content, so the 2,000-character cap limits, but does not remove, that risk.
- **Retention:** decide how long resolved dead letters, succeeded jobs, and events are kept, and delete on a schedule.

## Replay and executing stored instructions

Never let data in a table decide what code or command runs. The [allow-list replay](patterns/replay.md#replaying-checks-errors-as-data) resolves a stored check name through a fixed map inside the workflow; an unknown name is skipped. The same applies to URLs: build them from configuration, not from stored rows, or an attacker who can write one row can make your workflow call anything.

## Webhooks

- Webhook paths are not secrets. For anything that triggers work, use the Webhook node's authentication options (header auth, basic auth, or JWT), or verify the sender's signature in a Code node.
- The idempotency intake stores whatever body it receives. Validate size and shape before enqueueing when the sender is untrusted.

## Deployment

- The local stack binds n8n and Postgres to 127.0.0.1 and does not expose the mock API. Keep that property when you adapt it.
- In production, put n8n behind HTTPS (a reverse proxy or a tunnel), remove `N8N_SECURE_COOKIE=false`, and pin the n8n image to a specific version.
- Environment variable access from expressions is restricted by default in recent n8n versions. Leave it that way unless you need it, and prefer credentials for secrets.

## What this repository does not contain

No real credentials, internal URLs, client data, or private prompts are included. The example credential values in `docker/.env.example` and `tests/e2e/e2e.env` are placeholders or throwaway test values that only work inside the local stack.
