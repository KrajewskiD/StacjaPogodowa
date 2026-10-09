#!/usr/bin/env bash
# Ręczne odnowienie certyfikatu + przeładowanie nginx. Kontener certbot robi to
# automatycznie co 12 h; ten skrypt jest wygodny do natychmiastowego sprawdzenia.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose run --rm --no-deps --entrypoint certbot certbot renew
docker compose exec nginx nginx -s reload
echo "==> Certyfikat odnowiony, nginx przeładowany."