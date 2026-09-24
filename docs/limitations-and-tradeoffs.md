# Limitations and tradeoffs

These patterns reduce specific failure modes under stated assumptions. This page collects what they do not do.

## Delivery semantics

The job queue delivers **at least once**. A job whose worker dies after the side effect but before recording it will run again ([failure scenarios](failure-scenarios.md), rows 10 and 11). Exactly-once effects need the downstream system to deduplicate, usually through an idempotency key. If it cannot, check for evidence of the earlier attempt before repeating it, or route ambiguous cases to a person.

## Throughput

A Postgres table polled by workflows is a good queue for moderate volumes: easy to inspect, transactional with your other state, no extra infrastructure. It is not a message broker. Polling adds latency (a one-minute schedule means up to a minute of wait), and row locking and index churn become costs at high job rates. If you need sustained high throughput or sub-second latency, use SQS, RabbitMQ, Kafka, or similar, and keep the idempotency and dead-letter ideas.

n8n's own queue mode (Redis plus worker processes) distributes executions, not your business jobs. It works alongside these patterns: several n8n workers can run the job worker concurrently, and `SKIP LOCKED` keeps them from colliding.

## Rate limiting

The fixed-window limiter allows up to twice the limit across a window boundary, adds a database round trip per call, and only knows about calls that go through it. Keep handling 429 responses regardless.

## Error classification

HTTP status is a heuristic for "retryable". Some APIs misuse status codes; some errors are transient despite a 4xx. The Error Trigger handler classifies by message text, which is coarser still. Review dead letters periodically and adjust the classifiers.

## Code nodes versus SQL

The examples keep state transitions in SQL and business logic in Code nodes. That makes transitions atomic and testable, but splits logic across two places, and changing a function is a database migration. For a single low-stakes workflow, the [code-node guardrail](../examples/state-machine/guardrail-delta-gate.json) style may be the better trade.

## n8n versions

The workflows were exported for, and tested on, n8n 2.10.3. Node type versions and parameter names change between n8n releases; an import into a much older or newer version may need adjustments. Error Trigger payload fields and CLI commands (for example `publish:workflow` in 2.x versus `update:workflow --active` in 1.x) also differ.

## What none of this does

- It does not make a model's output correct. [Validation](patterns/ai-output-validation.md) catches malformed output, not wrong content.
- It does not replace monitoring, backups, or incident response for the database that now holds your state.
- It does not remove the need to understand the APIs you call: their limits, retry semantics, and idempotency support.
