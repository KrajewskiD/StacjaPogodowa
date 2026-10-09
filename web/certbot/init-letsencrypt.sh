#!/usr/bin/env bash
#
# Wystawia certyfikat Let's Encrypt (webroot) dla domen, a następnie włącza
# konfigurację HTTPS w nginx. Uruchamiasz to RAZ; odnowienia robi kontener certbot.
#
# Wymaga działającego stosu (nginx na porcie 80) oraz `.env` z APP_HOSTS i
# LETSENCRYPT_EMAIL.
set -euo pipefail

cd "$(dirname "$0")/.."

# Ładowanie .env (prosty parser: nie obsługuje cudzysłowów ani zmiennych zagnieżdżonych).
if [ -f .env ]; then set -a; . ./.env; set +a; fi

HOSTS="${APP_HOSTS:?ustaw APP_HOSTS w .env}"
EMAIL="${LETSENCRYPT_EMAIL:?ustaw LETSENCRYPT_EMAIL w .env}"

domains_args=()
for d in ${HOSTS//,/ }; do domains_args+=( -d "$d" ); done

echo "==> Wystawiam certyfikat dla: ${HOSTS}"
docker compose run --rm --no-deps --entrypoint certbot certbot \
  certonly --webroot -w /var/www/certbot \
  --email "$EMAIL" --agree-tos --no-eff-email \
  "${domains_args[@]}"

echo "==> Włączam konfigurację HTTPS i przeładowuję nginx"
cp nginx/conf.d/default.conf.https nginx/conf.d/default.conf
docker compose exec nginx nginx -s reload

echo "==> Gotowe. HTTPS aktywny."