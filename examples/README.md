# Examples

Importable n8n workflows, one folder per pattern. Each one has a sticky note stating its origin and how to run it.

**Origin labels**
- **Derived:** a reduced, sanitized version of a pattern from a workflow I built. External services are replaced with the mock API; credentials, prompts, and business-specific logic are removed.
- **New:** written for this repository to demonstrate a pattern in isolation.

| File | Workflow | Origin | Shows |
|---|---|---|---|
| [retry/http-retry-with-backoff.json](retry/http-retry-with-backoff.json) | HTTP retry with backoff | New | classify responses, exponential backoff with jitter, `Retry-After`, dead-letter on permanent failure |
| [error-trigger/global-error-handler.json](error-trigger/global-error-handler.json) | Global error handler | New | Error Trigger to a classified dead letter, metadata only |
| [error-trigger/failing-workflow-demo.json](error-trigger/failing-workflow-demo.json) | Failing workflow (error handler demo) | New | a workflow that fails on purpose, with a webhook for trigger-started testing |
| [dlq/dead-letter-digest.json](dlq/dead-letter-digest.json) | Dead-letter digest | New | daily summary of open dead letters |
| [state-machine/guardrail-delta-gate.json](state-machine/guardrail-delta-gate.json) | Guardrail delta gate | Derived: [Financial Profitability Guardrail](https://github.com/hira299/Financial-Profitability-Guardrail) | stored state, alert only on transitions, source failure to DLQ; state is saved before the alert gate |
| [state-machine/sql-delta-gate.json](state-machine/sql-delta-gate.json) | SQL delta gate | New (hardened variant of the above) | transition and alert job in one transaction |
| [state-machine/job-worker.json](state-machine/job-worker.json) | Job worker | New, following the queue-worker approach of my cloud compliance engine | reclaim, claim with `SKIP LOCKED`, rate limit, complete or fail |
| [idempotency/idempotent-webhook-intake.json](idempotency/idempotent-webhook-intake.json) | Idempotent webhook intake | New | 202 new, 200 duplicate, 400 missing key |
| [rate-limiting/rate-limited-sender.json](rate-limiting/rate-limited-sender.json) | Rate-limited sender | New | shared per-window budget across executions |
| [replay/replay-dead-jobs.json](replay/replay-dead-jobs.json) | Replay dead jobs | New | guarded requeue of dead jobs |
| [replay/checks-errors-as-data.json](replay/checks-errors-as-data.json) | Checks with errors as data | Derived: audit engine of my [cloud security audit platform](https://github.com/hira299/Cloud-Security-Audit-Compliance-Automation-Platform) | PASS / FAIL / MANUAL_REVIEW verdicts; a crashed check never passes |
| [replay/replay-manual-review.json](replay/replay-manual-review.json) | Replay manual-review checks | Derived: DLQ workflow of the same platform | allow-list replay; stored rows cannot choose what runs |
| [ai-output-validation/defensive-llm-json-parser.json](ai-output-validation/defensive-llm-json-parser.json) | Defensive LLM JSON parser | Derived: output parser of my [Competitor Intelligence & SEO pipeline](https://github.com/hira299/Autonomous-Competitor-Intelligence-SEO-Pipeline) | fence stripping, shape and field validation, rejections to DLQ |

## Importing

1. Start the stack in [docker/](../docker/) and create a Postgres credential for the `resilience` database.
2. Import `error-trigger/global-error-handler.json` first. Other workflows reference it by its ID (`RPerrorHandler01`) in their Error Workflow setting.
3. Import the rest, then select your Postgres credential on each Postgres node.
4. Publish (activate) the error handler and any workflow with a webhook or schedule trigger you want to run on its own.

URLs such as `http://mock-api:8080` point at the local mock API. Placeholders such as `https://YOUR_ALERT_WEBHOOK_URL` are on disabled nodes; configure them before enabling.
