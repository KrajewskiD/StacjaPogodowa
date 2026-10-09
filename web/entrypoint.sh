#!/bin/sh
set -e

# Idempotentne przygotowanie bazy (tworzy bazę + uruchamia migracje) przed startem
# aplikacji. Dla kontenerów pomocniczych (redis_sync) ustaw RUN_DB_PREPARE=0.
if [ "${RUN_DB_PREPARE:-1}" = "1" ]; then
  echo "==> Przygotowanie bazy danych (rails db:prepare)"
  bundle exec rails db:prepare
fi

exec "$@"