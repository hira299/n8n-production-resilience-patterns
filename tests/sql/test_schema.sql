-- Behavioral tests for sql/schema.sql.
-- Runs inside one transaction and rolls back, so it leaves no data behind.
-- Any failed ASSERT aborts the run with a non-zero exit code (psql -v ON_ERROR_STOP=1).

\set ON_ERROR_STOP 1
BEGIN;

-- 1. Idempotent enqueue ------------------------------------------------------
DO $$
DECLARE r record; n int;
BEGIN
  SELECT * INTO r FROM resilience.enqueue_job('t-idem-1', 'test', '{"a":1}');
  ASSERT r.duplicate = false, 'first enqueue should not be a duplicate';
  SELECT * INTO r FROM resilience.enqueue_job('t-idem-1', 'test', '{"a":2}');
  ASSERT r.duplicate = true, 'second enqueue with same key should be a duplicate';
  SELECT count(*) INTO n FROM resilience.jobs WHERE idempotency_key = 't-idem-1';
  ASSERT n = 1, 'exactly one job per idempotency key';
  ASSERT (SELECT payload->>'a' FROM resilience.jobs WHERE idempotency_key = 't-idem-1') = '1',
    'duplicate enqueue must not overwrite the original payload';
  RAISE NOTICE 'ok: idempotent enqueue';
END $$;

DO $$
BEGIN
  ASSERT resilience.idempotency_key('{"a":1,"b":2}') = resilience.idempotency_key('{"b":2, "a":1}'),
    'key derivation must not depend on JSON key order or whitespace';
  BEGIN
    PERFORM resilience.enqueue_job('', 'test');
    ASSERT false, 'empty key must be rejected';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  RAISE NOTICE 'ok: key derivation and validation';
END $$;

-- 2. Claiming ----------------------------------------------------------------
DO $$
DECLARE a resilience.jobs; b resilience.jobs; n int;
BEGIN
  PERFORM resilience.enqueue_job('t-claim-1', 'claimtest');
  PERFORM resilience.enqueue_job('t-claim-2', 'claimtest');
  SELECT * INTO a FROM resilience.claim_jobs('w1', 1, 'claimtest');
  SELECT * INTO b FROM resilience.claim_jobs('w2', 1, 'claimtest');
  ASSERT a.id <> b.id, 'two claims must not return the same job';
  ASSERT a.status = 'processing' AND a.attempts = 1 AND a.locked_by = 'w1', 'claim sets lock and attempt';
  SELECT count(*) INTO n FROM resilience.claim_jobs('w3', 10, 'claimtest');
  ASSERT n = 0, 'no ready jobs left to claim';
  RAISE NOTICE 'ok: claiming';
END $$;

-- 3. Completion is fenced by lock owner ---------------------------------------
DO $$
DECLARE j resilience.jobs;
BEGIN
  PERFORM resilience.enqueue_job('t-fence-1', 'fencetest');
  SELECT * INTO j FROM resilience.claim_jobs('owner', 1, 'fencetest');
  ASSERT resilience.complete_job(j.id, 'intruder', '{}') = false, 'non-owner cannot complete';
  ASSERT resilience.complete_job(j.id, 'owner', '{"ok":true}') = true, 'owner can complete';
  ASSERT resilience.complete_job(j.id, 'owner', '{}') = false, 'completion is not repeatable';
  ASSERT (SELECT status FROM resilience.jobs WHERE id = j.id) = 'succeeded';
  RAISE NOTICE 'ok: fenced completion';
END $$;

-- 4. Transient failure reschedules with backoff --------------------------------
DO $$
DECLARE j resilience.jobs; f record; delay numeric;
BEGIN
  PERFORM resilience.enqueue_job('t-transient-1', 'transienttest');
  SELECT * INTO j FROM resilience.claim_jobs('w', 1, 'transienttest');
  SELECT * INTO f FROM resilience.fail_job(j.id, 'w', 'HTTP 503', 'transient');
  ASSERT f.job_status = 'failed', 'transient failure keeps the job alive';
  delay := extract(epoch FROM f.next_attempt_at - now());
  ASSERT delay BETWEEN 15 AND 30, format('attempt 1 delay should be 15..30s, got %s', delay);
  ASSERT (SELECT count(*) FROM resilience.claim_jobs('w', 1, 'transienttest')) = 0,
    'job is not claimable before next_attempt_at';
  RAISE NOTICE 'ok: transient failure and backoff';
END $$;

DO $$
DECLARE j resilience.jobs; f record;
BEGIN
  PERFORM resilience.enqueue_job('t-retryafter-1', 'retryaftertest');
  SELECT * INTO j FROM resilience.claim_jobs('w', 1, 'retryaftertest');
  SELECT * INTO f FROM resilience.fail_job(j.id, 'w', 'HTTP 429', 'transient', 600);
  ASSERT extract(epoch FROM f.next_attempt_at - now()) >= 600, 'Retry-After floor is respected';
  RAISE NOTICE 'ok: minimum delay (Retry-After)';
END $$;

-- 5. Permanent failure goes straight to the DLQ -------------------------------
DO $$
DECLARE j resilience.jobs; f record; d resilience.dead_letters;
BEGIN
  PERFORM resilience.enqueue_job('t-perm-1', 'permtest', '{"order":42}');
  SELECT * INTO j FROM resilience.claim_jobs('w', 1, 'permtest');
  SELECT * INTO f FROM resilience.fail_job(j.id, 'w', 'HTTP 422 validation', 'permanent');
  ASSERT f.job_status = 'dead' AND f.dead_letter_id IS NOT NULL, 'permanent failure is dead-lettered';
  SELECT * INTO d FROM resilience.dead_letters WHERE id = f.dead_letter_id;
  ASSERT d.job_id = j.id AND d.payload->>'order' = '42' AND d.status = 'open', 'dead letter keeps job and payload';
  RAISE NOTICE 'ok: permanent failure';
END $$;

-- 6. Exhausted attempts go to the DLQ -----------------------------------------
DO $$
DECLARE j resilience.jobs; f record;
BEGIN
  PERFORM resilience.enqueue_job('t-exhaust-1', 'exhausttest', '{}', 2);
  SELECT * INTO j FROM resilience.claim_jobs('w', 1, 'exhausttest');
  SELECT * INTO f FROM resilience.fail_job(j.id, 'w', 'timeout', 'transient');
  ASSERT f.job_status = 'failed';
  UPDATE resilience.jobs SET next_attempt_at = now() WHERE id = j.id;  -- skip the wait
  SELECT * INTO j FROM resilience.claim_jobs('w', 1, 'exhausttest');
  ASSERT j.attempts = 2;
  SELECT * INTO f FROM resilience.fail_job(j.id, 'w', 'timeout', 'transient');
  ASSERT f.job_status = 'dead', 'job with no attempts left is dead-lettered';
  RAISE NOTICE 'ok: attempt exhaustion';
END $$;

-- 7. Lost lock: stale worker cannot report back --------------------------------
DO $$
DECLARE j resilience.jobs; n int; f record;
BEGIN
  PERFORM resilience.enqueue_job('t-stale-1', 'staletest');
  SELECT * INTO j FROM resilience.claim_jobs('crashed-worker', 1, 'staletest');
  UPDATE resilience.jobs SET locked_at = now() - interval '1 hour' WHERE id = j.id;
  n := resilience.reclaim_stale_jobs(interval '15 minutes');
  ASSERT n >= 1, 'stale job is reclaimed';
  ASSERT (SELECT status FROM resilience.jobs WHERE id = j.id) = 'failed';
  SELECT * INTO f FROM resilience.fail_job(j.id, 'crashed-worker', 'late report', 'transient');
  ASSERT f IS NULL OR f.job_status IS NULL, 'late failure report from old owner is ignored';
  ASSERT resilience.complete_job(j.id, 'crashed-worker', '{}') = false, 'late completion is ignored';
  RAISE NOTICE 'ok: stale lock recovery';
END $$;

-- 8. Release does not spend an attempt ----------------------------------------
DO $$
DECLARE j resilience.jobs;
BEGIN
  PERFORM resilience.enqueue_job('t-release-1', 'releasetest');
  SELECT * INTO j FROM resilience.claim_jobs('w', 1, 'releasetest');
  ASSERT resilience.release_job(j.id, 'w', 0) = true;
  ASSERT (SELECT attempts FROM resilience.jobs WHERE id = j.id) = 0, 'released job keeps its attempt budget';
  RAISE NOTICE 'ok: release';
END $$;

-- 9. Replay -------------------------------------------------------------------
DO $$
DECLARE j resilience.jobs; f record; r record; dl bigint;
BEGIN
  PERFORM resilience.enqueue_job('t-replay-1', 'replaytest');
  SELECT * INTO j FROM resilience.claim_jobs('w', 1, 'replaytest');
  SELECT * INTO f FROM resilience.fail_job(j.id, 'w', 'downstream bug', 'permanent');
  dl := f.dead_letter_id;

  SELECT * INTO r FROM resilience.replay_dead_letters(ARRAY[dl]);
  ASSERT r.action = 'requeued', 'dead job behind an open dead letter is requeued';
  ASSERT (SELECT status FROM resilience.dead_letters WHERE id = dl) = 'replaying';
  ASSERT (SELECT attempts FROM resilience.jobs WHERE id = j.id) = 0, 'replay resets the attempt budget';

  SELECT * INTO j FROM resilience.claim_jobs('w', 1, 'replaytest');
  PERFORM resilience.complete_job(j.id, 'w', '{}');
  ASSERT (SELECT status FROM resilience.dead_letters WHERE id = dl) = 'resolved', 'successful replay resolves the dead letter';
  RAISE NOTICE 'ok: replay resolves';
END $$;

DO $$
DECLARE j resilience.jobs; f record; r record; dl bigint;
BEGIN
  PERFORM resilience.enqueue_job('t-replay-2', 'replaytest2');
  SELECT * INTO j FROM resilience.claim_jobs('w', 1, 'replaytest2');
  SELECT * INTO f FROM resilience.fail_job(j.id, 'w', 'still broken', 'permanent');
  dl := f.dead_letter_id;
  PERFORM resilience.replay_dead_letters(ARRAY[dl]);
  SELECT * INTO j FROM resilience.claim_jobs('w', 1, 'replaytest2');
  SELECT * INTO f FROM resilience.fail_job(j.id, 'w', 'still broken', 'permanent');
  ASSERT f.dead_letter_id = dl, 'failed replay reopens the same dead letter';
  ASSERT (SELECT status || ':' || occurrences FROM resilience.dead_letters WHERE id = dl) = 'open:2';

  SELECT * INTO r FROM resilience.replay_dead_letters(ARRAY[dl], NULL, 50, 1);
  ASSERT r.action = 'skipped_replay_limit', 'replay limit stops endless replays';

  dl := resilience.record_dead_letter('some-workflow', 'HTTP', '99', 'boom');
  SELECT * INTO r FROM resilience.replay_dead_letters(ARRAY[dl]);
  ASSERT r.action = 'skipped_no_job', 'dead letters without a job are not auto-replayed';
  RAISE NOTICE 'ok: replay guards';
END $$;

-- 10. record_dead_letter deduplicates by key ----------------------------------
DO $$
DECLARE a bigint; b bigint; c bigint; d bigint;
BEGIN
  a := resilience.record_dead_letter('wf', 'node', '1', 'err', 'transient', NULL, 'k1');
  b := resilience.record_dead_letter('wf', 'node', '2', 'err again', 'transient', NULL, 'k1');
  ASSERT a = b, 'same active key reuses the dead letter';
  ASSERT (SELECT occurrences FROM resilience.dead_letters WHERE id = a) = 2;
  c := resilience.record_dead_letter('wf', 'node', '3', 'no key');
  d := resilience.record_dead_letter('wf', 'node', '4', 'no key');
  ASSERT c <> d, 'entries without a key are not merged';
  RAISE NOTICE 'ok: dead letter dedupe';
END $$;

-- 11. Rate limiting -----------------------------------------------------------
DO $$
DECLARE r record; i int; allowed_count int := 0;
BEGIN
  FOR i IN 1..5 LOOP
    SELECT * INTO r FROM resilience.try_acquire_rate_limit('t-bucket', 3, 3600);
    IF r.allowed THEN allowed_count := allowed_count + 1; END IF;
  END LOOP;
  ASSERT allowed_count = 3, format('expected 3 allowed, got %s', allowed_count);
  ASSERT r.allowed = false AND r.retry_after_seconds > 0, 'denied call reports retry_after';
  ASSERT (SELECT max(used) FROM resilience.rate_limit_windows WHERE bucket = 't-bucket') = 3,
    'counter never exceeds the limit';
  RAISE NOTICE 'ok: rate limiting';
END $$;

-- 12. State machine with delta-gated alerts -----------------------------------
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM resilience.apply_reading('t-proj', 10);
  ASSERT r.previous_state = 'NEW' AND r.new_state = 'HEALTHY' AND r.changed AND r.alert_job_id IS NULL,
    'NEW to HEALTHY is a change without an alert';
  SELECT * INTO r FROM resilience.apply_reading('t-proj', 85);
  ASSERT r.new_state = 'WARNING' AND r.alert_job_id IS NOT NULL, 'entering WARNING enqueues one alert';
  SELECT * INTO r FROM resilience.apply_reading('t-proj', 90);
  ASSERT NOT r.changed AND r.alert_job_id IS NULL, 'staying in WARNING does not alert again';
  SELECT * INTO r FROM resilience.apply_reading('t-proj', 120);
  ASSERT r.new_state = 'CRITICAL' AND r.alert_job_id IS NOT NULL, 'WARNING to CRITICAL alerts';
  SELECT * INTO r FROM resilience.apply_reading('t-proj', 5);
  ASSERT r.new_state = 'HEALTHY' AND r.changed AND r.alert_job_id IS NULL, 'recovery is logged without an alert';
  ASSERT (SELECT count(*) FROM resilience.jobs WHERE job_type = 'state_alert' AND payload->>'entity_id' = 't-proj') = 2;
  ASSERT (SELECT count(*) FROM resilience.entity_transitions WHERE entity_id = 't-proj') = 4;
  RAISE NOTICE 'ok: state machine';
END $$;

-- 13. Backoff shape -----------------------------------------------------------
DO $$
DECLARE s numeric;
BEGIN
  ASSERT resilience.backoff_delay(1, 30, 3600, false) = interval '30 seconds';
  ASSERT resilience.backoff_delay(3, 30, 3600, false) = interval '120 seconds';
  ASSERT resilience.backoff_delay(50, 30, 3600, false) = interval '3600 seconds', 'delay is capped';
  FOR i IN 1..200 LOOP
    s := extract(epoch FROM resilience.backoff_delay(4, 30, 3600, true));
    ASSERT s BETWEEN 120 AND 240, format('jittered delay out of range: %s', s);
  END LOOP;
  RAISE NOTICE 'ok: backoff';
END $$;

ROLLBACK;
\echo 'all SQL tests passed'
