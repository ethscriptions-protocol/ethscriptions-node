#!/usr/bin/env bash
set -euo pipefail

export RAILS_ENV="${RAILS_ENV:-production}"

# Initialize DBs on first run if using a fresh/mounted volume
set +e
if [ ! -f "storage/production.sqlite3" ] || [ ! -f "storage/production_queue.sqlite3" ]; then
    echo "Initializing databases..."
    DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bundle exec rails db:setup db:schema:load:queue
else
    echo "Running any pending migrations..."
    bundle exec rails db:migrate
fi
set -e

echo "Starting SolidQueue workers..."
bundle exec bin/jobs &
JOBS_PID=$!

echo "Starting importer..."
bundle exec clockwork config/derive_ethscriptions_blocks.rb &
CLOCKWORK_PID=$!

cleanup() {
    echo "Shutting down..."
    kill "${JOBS_PID:-}" "${CLOCKWORK_PID:-}" 2>/dev/null || true

    # Optionally reap children to avoid zombies (tini also reaps)
    wait "${JOBS_PID:-}" "${CLOCKWORK_PID:-}" 2>/dev/null || true
}
trap cleanup SIGTERM SIGINT

# Wait for either process to exit and preserve its exit code
set +e
wait -n
exit_code=$?
set -e
echo "One process exited, shutting down..."
kill "${JOBS_PID:-}" "${CLOCKWORK_PID:-}" 2>/dev/null || true
if [[ "${DEBUG_KEEP_ALIVE:-0}" == "1" && $exit_code -ne 0 ]]; then
    echo "Process died with $exit_code; keeping container up for debugging."
    if [[ -t 1 ]]; then
        exec bash -li
    else
        exec tail -f /dev/null
    fi
fi
exit "$exit_code"
