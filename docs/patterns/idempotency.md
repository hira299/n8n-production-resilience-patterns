# Idempotency

## The failure

A webhook sender retries because your response was slow. A worker crashes after calling an API but before recording that it did. A replay re-runs work that had half-succeeded. Each time, the same side effect happens twice: a duplicate order, a second email, a double charge.

With retries, redelivery, and replay in the system, "exactly once" is not something a workflow can promise. What it can do is make repeated execution produce the same result as a single execution. That is idempotency.

## Idempotency keys

Every unit of work gets a key that is the same every time that work is attempted.

Good keys:

- a key the sender supplies (an `Idempotency-Key` header)
- the business identity of the event: `source + external_id`, `order_id + event_type`
- for derived work, the identity of what caused it: the alert job in the [SQL delta gate](../../examples/state-machine/sql-delta-gate.json) uses `state-alert:<transition_id>`

Bad keys: anything that changes on retry. Arrival time, the n8n execution ID, a random UUID generated inside the workflow.

When you must derive a key from content, use `resilience.idempotency_key(jsonb)`. Because `jsonb` normalizes key order and whitespace, `{"a":1,"b":2}` and `{"b":2, "a":1}` produce the same key. Be careful: two genuinely different events with identical content will also share a key.

## Where the key is enforced

**At intake.** The [idempotent webhook intake](../../examples/idempotency/idempotent-webhook-intake.json) derives a key and calls `enqueue_job()`, which inserts with `ON CONFLICT (idempotency_key) DO NOTHING`. The first request gets 202 and a new job; a repeat gets 200, the same job ID, and `duplicate: true`. A request with no usable key gets 400, because accepting it would make duplicates undetectable.

**At state writes.** Upserts (`INSERT ... ON CONFLICT DO UPDATE`) keyed on a stable identifier make re-running a state update harmless. This is how the [guardrail example](../../examples/state-machine/guardrail-delta-gate.json) saves project state, as did the original workflow it is derived from.

**At the side effect.** The job worker sends the job's key as an `Idempotency-Key` header. If the downstream API honors it (Stripe and many payment APIs do; the mock API in this repo does), a repeated call is recognized there. This is the only protection that covers the gap between "the call succeeded" and "we recorded that it succeeded".

## The gap that keys cannot close alone

Look at the order of operations in any workflow that sends something:

```
1. read work item
2. perform side effect      <- succeeds
3. record that it is done   <- execution dies here
```

On the next run, step 1 finds the item still pending, and step 2 runs again.

I have this exact shape in two of my own workflows:

- My email agent treats "unread" as "not yet handled": it replies, then marks the message read. If marking fails after the reply went out, the next poll replies again.
- A status-driven outreach workflow sends an approved email, then sets the row to Sent. A failure between the two sends the email again on the next run.

Both are safe most of the time and wrong under exactly the failure the workflow should survive. The fixes, in order of strength:

1. **Claim before acting.** Move the item to an in-progress state (`processing`, `Sending`) with an owner before the side effect. A crash leaves the item visibly stuck instead of silently pending; a stale-lock sweep (`reclaim_stale_jobs()`) returns it to the queue deliberately. This is what `claim_jobs()` does.
2. **Pass the key downstream,** so the receiver can drop the repeat.
3. **Check before acting,** when the receiver cannot dedupe: look for evidence the effect already happened (a sent-mail search, a record lookup) before repeating it.

## Fencing

Claiming introduces its own race: a worker's lock expires, another worker takes the job, and then the first worker finishes. `complete_job()` and `fail_job()` only succeed for the current lock owner, so the late report is rejected instead of overwriting the newer attempt. The side effect of the first worker still happened, which is why fix 2 above matters.

## Tradeoffs

- Keys must be stored as long as duplicates can arrive. The `jobs` table keeps them indefinitely; if you prune it, pick a retention longer than any sender's retry window.
- Rejecting keyless requests is strict. For internal senders you control, it is the right default; for public webhooks, derive a key from the event's identity.
- Idempotency protects against repeats of the same work, not against two different requests that should be mutually exclusive. That needs a constraint or a lock on the business entity.
