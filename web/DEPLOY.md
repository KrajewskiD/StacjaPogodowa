# Wdrożenie na VPS z Dockerem (stacjaprudnik.online)

Ten katalog zawiera gotowe środowisko do uruchomienia strony na dowolnym VPS:

- `Dockerfile` — obraz Rails/Puma,
- `docker-compose.yml` — PostgreSQL + Redis + web + redis_sync + nginx + certbot,
- `nginx/conf.d/` — reverse proxy (HTTP → HTTPS),
- `certbot/` — wystawianie i odnawianie certyfikatu Let's Encrypt,
- `.env.example` — wzór zmiennych (sekrety),
- `entrypoint.sh` — przygotowanie bazy przed startem.

## Wymagania na VPS

- Linux (Debian/Ubuntu), `docker` + plugin `docker compose`,
- domena `stacjaprudnik.online` (i opcjonalnie `www`) wskazująca rekordem `A` na IP VPS,
- otwarte porty **80** i **443** (firewall / security group).

## 1. Wgranie kodu

Na VPS (przez `git` albo `scp`/`rsync`) skopiuj ten katalog `web/`. Zakładamy `git`:

```bash
cd /opt
git clone <adres-repo> stacja && cd stacja/web
```

(Jeśli nie masz repo, wgraj katalog `web/` np. `rsync -av web/ user@vps:/opt/stacja/web/`.)

## 2. Konfiguracja sekretów

```bash
cp .env.example .env
```

Uzupełnij `.env`:

- `POSTGRES_PASSWORD` — silne, losowe hasło,
- `SECRET_KEY_BASE` — wygeneruj: `docker compose run --rm --no-deps web bundle exec rails secret`
  (lub `openssl rand -hex 64`),
- `LETSENCRYPT_EMAIL` — e-mail dla Let's Encrypt,
- `APP_HOSTS` — zostaw `stacjaprudnik.online,www.stacjaprudnik.online` (albo dostosuj).

Sprawdź też `config/station.yml` (współrzędne, progi alertów, lista `sensors`/`devices`) —
powinna zgadzać się z Twoim ESP. Plik jest częścią obrazu, więc po zmianie trzeba
`docker compose build`.

## 3. Uruchomienie (najpierw HTTP)

```bash
docker compose up -d --build
docker compose ps          # wszystkie kontenery: running/healthy
docker compose logs -f web # migracje i start Puma
```

Strona działa na `http://stacjaprudnik.online` (port 80). Sprawdź:

```bash
curl http://localhost/up
docker compose exec web bin/weather-log --last 5
```

## 4. Włączenie HTTPS (certyfikat)

```bash
chmod +x certbot/init-letsencrypt.sh certbot/renew.sh
./certbot/init-letsencrypt.sh
```

Skrypt wystawi certyfikat (webroot, port 80), podmieni konfigurację nginx na HTTPS
i przeładuje. Od tej pory `https://stacjaprudnik.online`.

Odnowienia robi kontener `certbot` automatycznie co 12 h; ręcznie:

```bash
./certbot/renew.sh
```

## 5. Codzienna obsługa

```bash
docker compose ps                 # stan
docker compose logs -f web redis_sync nginx
docker compose exec web bin/weather-log --last 20 --follow          # podgląd na żywo (SSH)
docker compose exec web bin/weather-log --last 20 --follow --diagnostics
docker compose up -d --build      # po zmianie kodu
docker compose restart web        # po zmianie samej konfiguracji .env
```

Kopie bazy (PostgreSQL):

```bash
docker compose exec -T postgres pg_dump -U stacja stacja_production > backup.sql
```

## 6. Odtworzenie z kopii / reset

```bash
docker compose down -v   # UWAGA: usuwa wolumeny pgdata/redisdata (pełny reset)
docker compose up -d --build
```

## 7. Transport pomiarów z ESP (HTTPS)

Endpoint przyjmujący pomiary jest gotowy: `POST /api/measurements` z nagłówkiem
`Authorization: Bearer <token>`. Firmware jest też przygotowany — wysyła HTTPS do
`https://stacjaprudnik.online/api/measurements` z walidacją certyfikatu (Let's Encrypt
ISRG Root X1). Pozostaje tylko wgrać firmware i ustawić wspólny token.

1. W `.env` ustaw `INGEST_TOKEN` (losowy).
2. W `include/secrets.h` (repo firmware, skopiuj z `.example` i dodaj do
   `.gitignore`) ustaw ten sam token co `.env` (`INGEST_TOKEN`) oraz
   `SERVER_HOST=stacjaprudnik.online`.
3. Skompiluj i wgraj firmware (PlatformIO):

```bash
pio run -t upload
```

Po tym ESP łączy się z lokalnym Wi-Fi i wysyła pomiary do VPS; na serwerze
zweryfikujesz je przez SSH: `docker compose exec web bin/weather-log --last 20 --follow`.