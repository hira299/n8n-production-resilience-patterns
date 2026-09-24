-- n8n-production-resilience-patterns: reference schema
-- Requires PostgreSQL 13 or later. Safe to run more than once.
--
-- Everything lives in the "resilience" schema so it can sit next to other
-- application tables without name clashes. Workflows only call the functions
-- defined here; they never update these tables directly. That keeps the
-- state-transition rules in one place where they can be tested with plain SQL.

CREATE SCHEMA IF NOT EXISTS resilience;

-- ---------------------------------------------------------------------------
-- Jobs: explicit, durable workflow state
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS resilience.jobs (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  idempotency_key  text        NOT NULL UNIQUE,
  job_type         text        NOT NULL,
  payload          jsonb       NOT NULL DEFAULT '{}'::jsonb,
  status           text        NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'processing', 'succeeded', 'failed', 'dead')),
  attempts         integer     NOT NULL DEFAULT 0,
  max_attempts     integer     NOT NULL DEFAULT 5 CHECK (max_attempts > 0),
  next_attempt_at  timestamptz NOT NULL DEFAULT now(),
  locked_by        text,
  locked_at        timestamptz,
  last_error       text,
  result           jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  completed_at     timestamptz
);

CREATE INDEX IF NOT EXISTS jobs_ready_idx
  ON resilience.jobs (next_attempt_at, id) WHERE status IN ('pending', 'failed');
CREATE INDEX IF NOT EXISTS jobs_processing_idx
  ON resilience.jobs (locked_at) WHERE status = 'processing';

CREATE TABLE IF NOT EXISTS resilience.job_events (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job_id       bigint      NOT NULL REFERENCES resilience.jobs (id) ON DELETE CASCADE,
  from_status  text,
  to_status    text        NOT NULL,
  detail       jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS job_events_job_idx ON resilience.job_events (job_id, created_at);

-- ---------------------------------------------------------------------------
-- Dead-letter queue
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS resilience.dead_letters (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_workflow  text        NOT NULL,
  source_node      text,
  execution_id     text,
  job_id           bigint      REFERENCES resilience.jobs (id) ON DELETE SET NULL,
  idempotency_key  text,
  error_class      text        NOT NULL DEFAULT 'unknown'
                   CHECK (error_class IN ('transient', 'permanent', 'unknown')),
  error_message    text        NOT NULL,
  payload          jsonb,
  status           text        NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open', 'replaying', 'resolved', 'discarded')),
  occurrences      integer     NOT NULL DEFAULT 1,
  replay_count     integer     NOT NULL DEFAULT 0,
  first_seen_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now(),
  resolved_at      timestamptz,
  resolution_note  text
);

-- One active dead letter per (source, key). Repeated failures of the same
-- work item increment "occurrences" instead of flooding the table.
CREATE UNIQUE INDEX IF NOT EXISTS dead_letters_active_key_uq
  ON resilience.dead_letters (source_workflow, idempotency_key)
  WHERE status IN ('open', 'replaying') AND idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS dead_letters_status_idx
  ON resilience.dead_letters (status, last_seen_at);

-- ---------------------------------------------------------------------------
-- Rate limiting (fixed window, shared across executions)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS resilience.rate_limit_windows (
  bucket        text        NOT NULL,
  window_start  timestamptz NOT NULL,
  used          integer     NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket, window_start)
);

-- ---------------------------------------------------------------------------
-- Entity state machine with transition log
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS resilience.entity_state (
  entity_id   text        PRIMARY KEY,
  state       text        NOT NULL,
  metric      numeric,
  version     integer     NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS resilience.entity_transitions (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id     text        NOT NULL REFERENCES resilience.entity_state (entity_id) ON DELETE CASCADE,
  from_state    text        NOT NULL,
  to_state      text        NOT NULL,
  metric        numeric,
  alert_job_id  bigint      REFERENCES resilience.jobs (id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Check results: errors stored as data (PASS / FAIL / MANUAL_REVIEW)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS resilience.check_results (
  check_name  text        PRIMARY KEY,
  status      text        NOT NULL CHECK (status IN ('PASS', 'FAIL', 'MANUAL_REVIEW')),
  evidence    text        NOT NULL,
  raw         jsonb,
  attempts    integer     NOT NULL DEFAULT 1,
  checked_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Exponential backoff with "equal jitter": half of the delay is fixed, half is
-- random. The fixed half keeps a floor under the delay; the random half spreads
-- out retries from many jobs that failed at the same moment.
CREATE OR REPLACE FUNCTION resilience.backoff_delay(
  p_attempt       integer,
  p_base_seconds  numeric DEFAULT 30,
  p_cap_seconds   numeric DEFAULT 3600,
  p_jitter        boolean DEFAULT true
) RETURNS interval
LANGUAGE sql VOLATILE AS $$
  SELECT make_interval(secs => CASE WHEN p_jitter THEN d / 2 + random() * d / 2 ELSE d END)
  FROM (
    SELECT LEAST(p_cap_seconds::double precision,
                 p_base_seconds::double precision * power(2, LEAST(GREATEST(p_attempt, 1), 30) - 1)) AS d
  ) s;
$$;

-- Stable key from business identity fields. jsonb normalizes key order and
-- whitespace, so {"a":1,"b":2} and {"b":2,"a":1} produce the same key.
CREATE OR REPLACE FUNCTION resilience.idempotency_key(p_parts jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to(p_parts::text, 'UTF8')), 'hex');
$$;

-- ---------------------------------------------------------------------------
-- Job lifecycle
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION resilience.enqueue_job(
  p_idempotency_key  text,
  p_job_type         text,
  p_payload          jsonb   DEFAULT '{}'::jsonb,
  p_max_attempts     integer DEFAULT 5
) RETURNS TABLE (job_id bigint, job_status text, duplicate boolean)
LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint;
BEGIN
  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'enqueue_job: idempotency key is required';
  END IF;

  INSERT INTO resilience.jobs (idempotency_key, job_type, payload, max_attempts)
  VALUES (p_idempotency_key, p_job_type, COALESCE(p_payload, '{}'::jsonb), p_max_attempts)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    INSERT INTO resilience.job_events (job_id, from_status, to_status, detail)
    VALUES (v_id, NULL, 'pending', jsonb_build_object('event', 'enqueued'));
    RETURN QUERY SELECT v_id, 'pending'::text, false;
  ELSE
    RETURN QUERY
      SELECT j.id, j.status, true FROM resilience.jobs j WHERE j.idempotency_key = p_idempotency_key;
  END IF;
END;
$$;

-- Claims up to p_limit ready jobs. FOR UPDATE SKIP LOCKED lets several
-- executions (or queue-mode workers) claim concurrently without taking the
-- same job twice.
CREATE OR REPLACE FUNCTION resilience.claim_jobs(
  p_worker    text,
  p_limit     integer DEFAULT 10,
  p_job_type  text    DEFAULT NULL
) RETURNS SETOF resilience.jobs
LANGUAGE sql AS $$
  WITH picked AS (
    SELECT j.id, j.status
    FROM resilience.jobs j
    WHERE j.status IN ('pending', 'failed')
      AND j.next_attempt_at <= now()
      AND j.attempts < j.max_attempts
      AND (p_job_type IS NULL OR j.job_type = p_job_type)
    ORDER BY j.next_attempt_at, j.id
    FOR UPDATE SKIP LOCKED
    LIMIT p_limit
  ), updated AS (
    UPDATE resilience.jobs j
    SET status = 'processing', locked_by = p_worker, locked_at = now(),
        attempts = j.attempts + 1, updated_at = now()
    FROM picked
    WHERE j.id = picked.id
    RETURNING j.*
  ), logged AS (
    INSERT INTO resilience.job_events (job_id, from_status, to_status, detail)
    SELECT u.id, p.status, 'processing', jsonb_build_object('worker', p_worker, 'attempt', u.attempts)
    FROM updated u JOIN picked p ON p.id = u.id
  )
  SELECT * FROM updated ORDER BY next_attempt_at, id;
$$;

-- Moves a job to "dead" and records (or refreshes) its dead letter.
CREATE OR REPLACE FUNCTION resilience._kill_job(
  p_job_id  bigint,
  p_error   text,
  p_class   text,
  p_source  text
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_job  resilience.jobs;
  v_dl   bigint;
BEGIN
  UPDATE resilience.jobs
  SET status = 'dead', last_error = p_error, locked_by = NULL, locked_at = NULL, updated_at = now()
  WHERE id = p_job_id
  RETURNING * INTO v_job;

  INSERT INTO resilience.dead_letters
    (source_workflow, job_id, idempotency_key, error_class, error_message, payload)
  VALUES
    (p_source, v_job.id, v_job.idempotency_key, p_class, left(p_error, 4000), v_job.payload)
  ON CONFLICT (source_workflow, idempotency_key)
    WHERE status IN ('open', 'replaying') AND idempotency_key IS NOT NULL
  DO UPDATE SET
    status        = 'open',
    occurrences   = resilience.dead_letters.occurrences + 1,
    error_class   = EXCLUDED.error_class,
    error_message = EXCLUDED.error_message,
    last_seen_at  = now()
  RETURNING id INTO v_dl;

  RETURN v_dl;
END;
$$;

-- Only the worker that holds the lock can complete a job. If the lock expired
-- and another worker reclaimed the job, the late completion is rejected.
CREATE OR REPLACE FUNCTION resilience.complete_job(
  p_job_id  bigint,
  p_worker  text,
  p_result  jsonb DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE resilience.jobs
  SET status = 'succeeded', result = p_result, completed_at = now(), updated_at = now(),
      locked_by = NULL, locked_at = NULL, last_error = NULL
  WHERE id = p_job_id AND status = 'processing' AND locked_by = p_worker;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  INSERT INTO resilience.job_events (job_id, from_status, to_status, detail)
  VALUES (p_job_id, 'processing', 'succeeded', jsonb_build_object('worker', p_worker));

  UPDATE resilience.dead_letters
  SET status = 'resolved', resolved_at = now(),
      resolution_note = concat_ws('; ', resolution_note, 'replay succeeded')
  WHERE job_id = p_job_id AND status = 'replaying';

  RETURN true;
END;
$$;

-- Records a failed attempt. Transient failures are rescheduled with backoff;
-- permanent failures, and jobs out of attempts, go to the dead-letter queue.
CREATE OR REPLACE FUNCTION resilience.fail_job(
  p_job_id             bigint,
  p_worker             text,
  p_error              text,
  p_error_class        text    DEFAULT 'transient',
  p_min_delay_seconds  numeric DEFAULT NULL,
  p_source             text    DEFAULT 'job-worker'
) RETURNS TABLE (job_status text, next_attempt_at timestamptz, dead_letter_id bigint)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  v_job    resilience.jobs;
  v_delay  interval;
  v_dl     bigint;
BEGIN
  IF p_error_class NOT IN ('transient', 'permanent', 'unknown') THEN
    RAISE EXCEPTION 'fail_job: unknown error class %', p_error_class;
  END IF;

  SELECT * INTO v_job FROM resilience.jobs
  WHERE id = p_job_id AND status = 'processing' AND locked_by = p_worker
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;  -- lock lost; another worker owns this job now
  END IF;

  IF p_error_class = 'permanent' OR v_job.attempts >= v_job.max_attempts THEN
    v_dl := resilience._kill_job(v_job.id, p_error, p_error_class, p_source);
    INSERT INTO resilience.job_events (job_id, from_status, to_status, detail)
    VALUES (v_job.id, 'processing', 'dead',
            jsonb_build_object('error', left(p_error, 500), 'class', p_error_class, 'attempt', v_job.attempts));
    RETURN QUERY SELECT 'dead'::text, NULL::timestamptz, v_dl;
    RETURN;
  END IF;

  v_delay := GREATEST(resilience.backoff_delay(v_job.attempts),
                      make_interval(secs => COALESCE(p_min_delay_seconds, 0)::double precision));

  UPDATE resilience.jobs
  SET status = 'failed', last_error = left(p_error, 4000), next_attempt_at = now() + v_delay,
      locked_by = NULL, locked_at = NULL, updated_at = now()
  WHERE id = v_job.id;

  INSERT INTO resilience.job_events (job_id, from_status, to_status, detail)
  VALUES (v_job.id, 'processing', 'failed',
          jsonb_build_object('error', left(p_error, 500), 'class', p_error_class,
                             'attempt', v_job.attempts, 'retry_in_seconds', round(extract(epoch FROM v_delay))));

  RETURN QUERY SELECT 'failed'::text, now() + v_delay, NULL::bigint;
END;
$$;

-- Returns a claimed job to the queue without spending an attempt. Used when
-- the worker backs off for a reason that is not the job's fault, such as a
-- local rate limit.
CREATE OR REPLACE FUNCTION resilience.release_job(
  p_job_id         bigint,
  p_worker         text,
  p_delay_seconds  numeric DEFAULT 0
) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE resilience.jobs
  SET status = 'pending', attempts = GREATEST(attempts - 1, 0),
      next_attempt_at = now() + make_interval(secs => p_delay_seconds::double precision),
      locked_by = NULL, locked_at = NULL, updated_at = now()
  WHERE id = p_job_id AND status = 'processing' AND locked_by = p_worker;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  INSERT INTO resilience.job_events (job_id, from_status, to_status, detail)
  VALUES (p_job_id, 'processing', 'pending', jsonb_build_object('event', 'released', 'delay_seconds', p_delay_seconds));
  RETURN true;
END;
$$;

-- Recovers jobs whose worker disappeared mid-execution (crash, restart,
-- timeout). Without this, a job claimed by a dead execution stays in
-- "processing" forever.
CREATE OR REPLACE FUNCTION resilience.reclaim_stale_jobs(
  p_lock_timeout  interval DEFAULT interval '15 minutes'
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_job    resilience.jobs;
  v_count  integer := 0;
BEGIN
  FOR v_job IN
    SELECT * FROM resilience.jobs
    WHERE status = 'processing' AND locked_at < now() - p_lock_timeout
    FOR UPDATE SKIP LOCKED
  LOOP
    IF v_job.attempts >= v_job.max_attempts THEN
      PERFORM resilience._kill_job(v_job.id, 'lock expired on final attempt', 'unknown', 'job-worker');
      INSERT INTO resilience.job_events (job_id, from_status, to_status, detail)
      VALUES (v_job.id, 'processing', 'dead', jsonb_build_object('event', 'lock_expired'));
    ELSE
      UPDATE resilience.jobs
      SET status = 'failed', last_error = 'lock expired; worker did not report back',
          next_attempt_at = now(), locked_by = NULL, locked_at = NULL, updated_at = now()
      WHERE id = v_job.id;
      INSERT INTO resilience.job_events (job_id, from_status, to_status, detail)
      VALUES (v_job.id, 'processing', 'failed', jsonb_build_object('event', 'lock_expired', 'worker', v_job.locked_by));
    END IF;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- Dead letters from outside the job queue (Error Trigger workflows)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION resilience.record_dead_letter(
  p_source_workflow  text,
  p_source_node      text,
  p_execution_id     text,
  p_error_message    text,
  p_error_class      text  DEFAULT 'unknown',
  p_payload          jsonb DEFAULT NULL,
  p_idempotency_key  text  DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO resilience.dead_letters
    (source_workflow, source_node, execution_id, idempotency_key, error_class, error_message, payload)
  VALUES
    (p_source_workflow, p_source_node, p_execution_id, NULLIF(p_idempotency_key, ''),
     COALESCE(NULLIF(p_error_class, ''), 'unknown'), left(COALESCE(p_error_message, 'unknown error'), 4000), p_payload)
  ON CONFLICT (source_workflow, idempotency_key)
    WHERE status IN ('open', 'replaying') AND idempotency_key IS NOT NULL
  DO UPDATE SET
    occurrences   = resilience.dead_letters.occurrences + 1,
    execution_id  = EXCLUDED.execution_id,
    error_message = EXCLUDED.error_message,
    last_seen_at  = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Replay
-- ---------------------------------------------------------------------------

-- Requeues dead jobs behind open dead letters. Only dead letters linked to a
-- job are replayable here, because only those have a stored payload and an
-- idempotency key that protects against double side effects.
CREATE OR REPLACE FUNCTION resilience.replay_dead_letters(
  p_ids          bigint[] DEFAULT NULL,
  p_error_class  text     DEFAULT NULL,
  p_limit        integer  DEFAULT 50,
  p_max_replays  integer  DEFAULT 3,
  p_note         text     DEFAULT NULL
) RETURNS TABLE (dead_letter_id bigint, job_id bigint, action text)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  v_dl resilience.dead_letters;
BEGIN
  FOR v_dl IN
    SELECT * FROM resilience.dead_letters d
    WHERE d.status = 'open'
      AND (p_ids IS NULL OR d.id = ANY (p_ids))
      AND (p_error_class IS NULL OR d.error_class = p_error_class)
    ORDER BY d.first_seen_at
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    IF v_dl.job_id IS NULL THEN
      RETURN QUERY SELECT v_dl.id, NULL::bigint, 'skipped_no_job'::text;
    ELSIF v_dl.replay_count >= p_max_replays THEN
      RETURN QUERY SELECT v_dl.id, v_dl.job_id, 'skipped_replay_limit'::text;
    ELSE
      UPDATE resilience.jobs
      SET status = 'pending', attempts = 0, next_attempt_at = now(), last_error = NULL, updated_at = now()
      WHERE id = v_dl.job_id AND status = 'dead';

      IF FOUND THEN
        INSERT INTO resilience.job_events (job_id, from_status, to_status, detail)
        VALUES (v_dl.job_id, 'dead', 'pending', jsonb_build_object('event', 'replayed', 'dead_letter_id', v_dl.id));

        UPDATE resilience.dead_letters
        SET status = 'replaying', replay_count = replay_count + 1,
            resolution_note = concat_ws('; ', resolution_note, p_note)
        WHERE id = v_dl.id;

        RETURN QUERY SELECT v_dl.id, v_dl.job_id, 'requeued'::text;
      ELSE
        RETURN QUERY SELECT v_dl.id, v_dl.job_id, 'skipped_job_not_dead'::text;
      END IF;
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION resilience.discard_dead_letter(p_id bigint, p_note text)
RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE resilience.dead_letters
  SET status = 'discarded', resolved_at = now(), resolution_note = concat_ws('; ', resolution_note, p_note)
  WHERE id = p_id AND status = 'open';
  RETURN FOUND;
END;
$$;

-- ---------------------------------------------------------------------------
-- Rate limiting
-- ---------------------------------------------------------------------------

-- Atomically takes one unit from a fixed-window budget. The conditional
-- ON CONFLICT update means the counter never exceeds p_limit, even when many
-- executions call this at the same time.
CREATE OR REPLACE FUNCTION resilience.try_acquire_rate_limit(
  p_bucket          text,
  p_limit           integer,
  p_window_seconds  integer
) RETURNS TABLE (allowed boolean, retry_after_seconds numeric)
LANGUAGE plpgsql AS $$
DECLARE
  v_now     timestamptz := clock_timestamp();
  v_window  timestamptz;
  v_used    integer;
BEGIN
  v_window := to_timestamp(floor(extract(epoch FROM v_now) / p_window_seconds) * p_window_seconds);

  INSERT INTO resilience.rate_limit_windows AS w (bucket, window_start, used)
  VALUES (p_bucket, v_window, 1)
  ON CONFLICT (bucket, window_start) DO UPDATE
    SET used = w.used + 1
    WHERE w.used < p_limit
  RETURNING w.used INTO v_used;

  IF v_used IS NULL THEN
    RETURN QUERY SELECT false,
      round(extract(epoch FROM (v_window + make_interval(secs => p_window_seconds) - v_now))::numeric, 3);
  ELSE
    RETURN QUERY SELECT true, 0::numeric;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION resilience.prune_rate_limit_windows(p_older_than interval DEFAULT interval '1 day')
RETURNS integer
LANGUAGE sql AS $$
  WITH d AS (
    DELETE FROM resilience.rate_limit_windows WHERE window_start < now() - p_older_than RETURNING 1
  )
  SELECT count(*)::integer FROM d;
$$;

-- ---------------------------------------------------------------------------
-- State machine with delta-gated alerts
-- ---------------------------------------------------------------------------

-- Applies a reading, derives the new state, and, only when the state changed
-- into a non-healthy state, enqueues an alert job in the same transaction.
-- If the transaction rolls back, neither the state change nor the alert exists.
CREATE OR REPLACE FUNCTION resilience.apply_reading(
  p_entity_id  text,
  p_metric     numeric,
  p_warning    numeric DEFAULT 80,
  p_critical   numeric DEFAULT 100
) RETURNS TABLE (entity_id text, previous_state text, new_state text, changed boolean, alert_job_id bigint)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  v_prev   text;
  v_new    text;
  v_trans  bigint;
  v_job    bigint;
BEGIN
  v_new := CASE WHEN p_metric >= p_critical THEN 'CRITICAL'
                WHEN p_metric >= p_warning  THEN 'WARNING'
                ELSE 'HEALTHY' END;

  INSERT INTO resilience.entity_state (entity_id, state, metric)
  VALUES (p_entity_id, 'NEW', NULL)
  ON CONFLICT (entity_id) DO NOTHING;

  SELECT s.state INTO v_prev FROM resilience.entity_state s WHERE s.entity_id = p_entity_id FOR UPDATE;

  UPDATE resilience.entity_state s
  SET state = v_new, metric = p_metric, updated_at = now(),
      version = s.version + CASE WHEN v_prev <> v_new THEN 1 ELSE 0 END
  WHERE s.entity_id = p_entity_id;

  IF v_prev = v_new THEN
    RETURN QUERY SELECT p_entity_id, v_prev, v_new, false, NULL::bigint;
    RETURN;
  END IF;

  INSERT INTO resilience.entity_transitions (entity_id, from_state, to_state, metric)
  VALUES (p_entity_id, v_prev, v_new, p_metric)
  RETURNING id INTO v_trans;

  IF v_new <> 'HEALTHY' THEN
    SELECT e.job_id INTO v_job FROM resilience.enqueue_job(
      'state-alert:' || v_trans,
      'state_alert',
      jsonb_build_object('entity_id', p_entity_id, 'from', v_prev, 'to', v_new, 'metric', p_metric, 'transition_id', v_trans)
    ) e;
    UPDATE resilience.entity_transitions SET alert_job_id = v_job WHERE id = v_trans;
  END IF;

  RETURN QUERY SELECT p_entity_id, v_prev, v_new, true, v_job;
END;
$$;
