#!/bin/bash
set -e

DEFAULT_SERVICE_NAME="$(echo "${APP_NAME:-SHARE_RIDE}_${SERVICE_MODE:-UNKNOWN}" | tr '[:upper:]' '[:lower:]')"
export SERVICE_NAME="${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}"
export PYTHONPATH="/app/"

wait_for_migrations(){
    echo "Waiting for database migrations to complete..."
    while true; do
        rev=$(alembic -c alembic.ini current)
        if [[ $rev == *"head"* ]]; then
            return
        fi
        sleep 5
    done
}

if [ "${SERVICE_MODE}" = "MIGRATE" ]; then
    echo "Starting DB migrations"

    cd /app
    python scripts/create_migration.py
    alembic -c alembic.ini upgrade head

elif [ "${SERVICE_MODE}" = "RUN" ]; then
    echo "Starting application"

    WORKER_COUNT="${WORKER_COUNT:-1}"

    # Run migrations before starting the app
    cd /app
    python scripts/create_migration.py
    alembic -c alembic.ini upgrade head

    # Use reload flag for development (requires WORKER_COUNT=1)
    if [ "$WORKER_COUNT" = "1" ]; then
        exec uvicorn --host 0.0.0.0 --port 8000 --reload src.app:app
    else
        exec uvicorn --host 0.0.0.0 --port 8000 --workers "$WORKER_COUNT" src.app:app
    fi
else
    echo "Unknown SERVICE_MODE: ${SERVICE_MODE}"
    exit 1
fi
