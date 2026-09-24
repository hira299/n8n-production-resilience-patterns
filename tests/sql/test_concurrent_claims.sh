#!/usr/bin/env bash
# Starts several claimers at the same time against the same queue and checks
# that no job was claimed by more than one of them.
# Usage: DATABASE_URL=postgresql://user:pass@host:port/db tests/sql/test_concurrent_claims.sh
set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL}"
JOBS=${JOBS:-200}
WORKERS=${WORKERS:-8}
TYPE="concurrency-test-$$"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAt -c \
  "SELECT count(*) FROM generate_series(1, $JOBS) g, resilience.enqueue_job('$TYPE-' || g, '$TYPE');" >/dev/null

for w in $(seq 1 "$WORKERS"); do
  (
    while :; do
      n=$(psql "$DATABASE_URL" -qAt -c "SELECT count(*) FROM resilience.claim_jobs('w$w', 7, '$TYPE');")
      [ "$n" = "0" ] && break
    done
  ) &
done
wait

result=$(psql "$DATABASE_URL" -qAt -F ' ' -c "
  SELECT
    (SELECT count(*) FROM resilience.jobs WHERE job_type = '$TYPE' AND status = 'processing'),
    (SELECT count(*) FROM resilience.jobs WHERE job_type = '$TYPE' AND attempts <> 1),
    (SELECT count(*) FROM (
       SELECT e.job_id FROM resilience.job_events e JOIN resilience.jobs j ON j.id = e.job_id
       WHERE j.job_type = '$TYPE' AND e.to_status = 'processing'
       GROUP BY e.job_id HAVING count(*) > 1) d),
    (SELECT count(DISTINCT locked_by) FROM resilience.jobs WHERE job_type = '$TYPE');")

psql "$DATABASE_URL" -qAt -c "DELETE FROM resilience.jobs WHERE job_type = '$TYPE';" >/dev/null

read -r claimed wrong_attempts double_claims workers_used <<<"$result"
echo "claimed=$claimed wrong_attempts=$wrong_attempts double_claims=$double_claims workers_used=$workers_used"
[ "$claimed" = "$JOBS" ] && [ "$wrong_attempts" = "0" ] && [ "$double_claims" = "0" ] || {
  echo "FAIL: concurrent claim check"; exit 1; }
echo "ok: $JOBS jobs claimed exactly once by $workers_used concurrent workers"
