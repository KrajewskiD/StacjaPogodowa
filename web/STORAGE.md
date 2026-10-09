# PostgreSQL, Redis i logger SSH

## Bezpieczeństwo przyjmowania danych

Zaufane urządzenia są podane w `config/station.yml` (klucze `sensors` i `devices`).
`Measurement.ingest!` i `Gateway.observe!` odrzucają identyfikatory spoza listy.
Puste listy oznaczają akceptację wszystkiego — używane wyłącznie w testach.

Oprócz valdacji formatu (schemat, typ, identyfikatory hex, typy liczbowych pól)
pakiety są sprawdzane pod kątem:
- znanych pól (`IngestPolicy::WEATHER_KEYS` / `STATUS_KEYS`) — nieznane pole = odrzucenie,
- maksymalnej liczby pól (40) i rozmiaru datagramu (4096 B),
- limitu częstości na adres źródłowy (60 wiadomości/min w `script/receive.rb`).

HTTP jest ograniczany przez `RequestRateLimit` (app/middleware): `/api/weather` 120/min,
`/export.csv` 30/min i `/api/measurements` 120/min na adres IP. To prosty limiter
w pamięci, wystarczający dla jednego procesu Puma; przy skalowaniu wymień go na
Rack::Attack z Redis.

Przyjmowanie pomiarów przez internet: `POST /api/measurements` (`MeasurementsController`)
jest dostępne wyłącznie po tokenie `INGEST_TOKEN` (porównanie stało-czasowe).
Zwraca: 201 dla pomiaru, 202 dla statusu, 401 przy złym tokenie, 503 gdy token
nie jest skonfigurowany, 400/413/422 dla błędnego payloadu. Wykorzystuje tę samą
transakcję co odbiorca UDP (`ingest!` + `observe!` + `evaluate!`), więc allowlista
i deduplikacja działają identycznie. Token jest w `.env` (Docker) — poza obrazem
i repozytorium. Firmware ESP wysyła tędy HTTPS z walidacją certyfikatu (ISRG Root X1).

Apache (config/apache.conf) dodaje nagłówki: `X-Content-Type-Options: nosniff`,
`X-Frame-Options: SAMEORIGIN`, `Permissions-Policy`, `Content-Security-Policy`.
Log dostępowy jest rotowany przez `rotatelogs` (86400 s). W środowisku Dockerowym
te same nagłówki (oraz TLS/HSTS) stawia nginx — patrz `DEPLOY.md`.

## Model danych

Każdy pomiar jest zapisywany do PostgreSQL wraz z rekordem `measurement_deliveries`
w jednej transakcji. Usługa `stacja-redis-sync` kopiuje pomiary do Redis i usuwa
potwierdzone wpisy kolejki. Ponowne ZADD jest idempotentne. Błąd Redis nie cofa
pomiaru i nie blokuje odbiornika. Kolejka przechowuje tylko odniesienie do rekordu.
Powtórzony datagram z identyczną zawartością, numerem `seq` i `uptime_ms` jest
wykrywany po SHA-256 całego payloadu; unikalny indeks zapobiega podwójnemu zapisowi.
Wiadomości bez obu pól nie są deduplikowane. Transport HTTPS uwzględnia `uptime_ms`
i `seq` w odcisku, a komentarz w `measurement.rb` wskazuje, by w razie potrzeby dodać
jawne `boot_id`. Lokalny odbiornik UDP pozostaje wsparciem w sieci domowej; docelowo
ESP używa HTTPS (patrz `include/config.h` w repo firmware).

Redis utrzymuje posortowane według czasu odbioru zbiory surowych pomiarów przez
72 godziny. Przy każdym cyklu starsze wpisy są usuwane także dla nieaktywnych
czujników; klucze mają dodatkowe TTL. Redis ma limit 256 MB i `noeviction`:
brak pamięci powoduje ponowienie synchronizacji, a nie ciche usuwanie części historii.

Odczyt okna 5 minut, statystyk dobowych i krótkich wykresów korzysta z Redis,
jeśli zakres mieści się w ostatnich 72 h i synchronizacja ma aktualny heartbeat.
Synchronizacja odbywa się co 2 s; heartbeat wygasa po 10 s. Brak gotowości,
brak połączenia lub starszy zakres powoduje odczyt z PostgreSQL. Pełne okresy
starsze niż 72 h (np. wykres 7 dni) są pobierane z PG bez łączenia dwóch źródeł.
Podsumowania tygodniowe/miesięczne, ostatnie surowe odczyty, alerty, diagnostyka,
CSV i logger korzystają z PostgreSQL. Obliczenia i istniejące cache 10/30 s zachowane.

Ścieżka „na żywo” nie ładuje już całego miesiąca do pamięci Ruby. Trendy liczone
są z okna 4 godzin, a suma opadów z zapytań celowanych na każdy okres, z rzutowaniem
tylko `received_at, device_id, rain_total_mm, startup` (`WeatherHistory#live_analytics`),
więc generuje się mniej i lżejsze zapytania niż poprzedni pełny materializowany
zbiór AR. Średnie dzienne pochodzą z `DailyWeather`, a nie z podsumowania miesięcznego.

Indeks `(sensor_id, received_at, id)` na `measurements` obsługuje zakresy i porządek
`ORDER BY received_at, id` dla jednego czujnika (zastąpił `(sensor_id, received_at)`).
Klient Redis na ścieżce webowej jest jeden, współdzielony między wątkami
(`RecentMeasurements.client`; redis-client utrzymuje wewnętrzną pulę) i nie otwiera
nowego połączenia przy każdym odczycie. Skrypt i testy używają fabryki `redis`.
Konfiguracja z `station.yml` jest odczytywana raz na proces (`StationSetting.configured`),
a każdy `current` zwraca nowy, zwalidowany egzemplarz.

W Redis przechowywany jest kompaktowy element: `{id, received_at, device_id, payload}`,
bez zbędnych kolumn (`source_ip`, `packet_fingerprint`, pełna serializacja atrybutów).
Odczyt dekoduje go do `RecentMeasurements::Sample` (Data), nie materializując obiektów AR.
Klient Redis z fabryki `redis` i `client` mają krótkie czasy połączenia, więc awaria
Redis nie blokuje żądania.

Synchronizator jest zabezpieczony blokadą w Redis (`RecentMeasurements::LOCK_KEY`):
`SET NX EX` z tokenem i odnawianiem przez Lua (`renew_lock!`), więc działa dokładnie
jedna instancja na środowisko; druga czeka, zamiast równolegle odtwarzać dane.
TTL blokady to 60 s i jest odnawiany co ~2 s w pętli synchronizacji.

Limiter HTTP (`RequestRateLimit`) kluczuje po `env["action_dispatch.remote_ip"]`
(poprawka `config.action_dispatch.trusted_proxies = [127.0.0.1, ::1]`): przez Apache
adres klienta nie jest maskowany jako pętla, a spoofowane `X-Forwarded-For` od klienta
jest ignorowane. Mapa kubłów i przepustnica UDP mają twarde limity rozmiaru i okresowe
czyszczenie pustych wpisów, więc spoofowane adresy nie rosną w nieskończoność.

Pętla synchronizatora wykonuje zapytania w `ActiveRecord::Base.uncached`.
Bez tego długotrwały `rails runner` może zapamiętać pustą kolejkę i nie zobaczyć
pomiarów dodanych przez osobny proces UDP. Przed odczytem Redis aplikacja
dodatkowo sprawdza bez query cache, czy istnieją zaległe dostawy. Jeśli tak,
odczytuje PostgreSQL nawet przy obecnym znaczniku gotowości Redis.

Start synchronizatora i utrata przestrzeni kluczy powodują odtworzenie danych
z PG. Do czasu ukończenia odtwarzania i obsługi zaległej kolejki panel odczytuje PG.
Do tego celu wystarczy pojedyncza instancja synchronizatora (wymuszona blokadą).

Agregacja min/max nie jest przenoszona do SQL: odczyty krótkich okien trafiają do
Redis, a średnia ważona czasem (trapezy) i tak wymaga sąsiednich par próbek, więc
min/max jest liczony „przy okazji” po już załadowanych danych — zapytanie SQL po
min/max nic by nie przyspieszyło. `Rails.cache` pozostaje w pamięci procesu; przeniesienie
do Redis ma sens dopiero przy więcej niż jednym procesie Puma (wtedy cache byłby współdzielony).

## Obecna instalacja lokalna

Bez uprawnień sudo zainstalowano binaria PostgreSQL 18.6 w
`~/.local/share/stacja-infra/usr` i Redis 7.4.2 w `~/.local/share/stacja-infra/bin`.
Usługi są jednostkami systemd użytkownika, z automatycznym restartem i startem
w sesji użytkownika:

| Usługa | Adres / dane |
|---|---|
| `stacja-postgres` | `127.0.0.1:5433`, `~/.local/share/stacja-postgres` |
| `stacja-redis` | `127.0.0.1:6380`, `~/.local/share/stacja-redis`, AOF co sekundę |
| `stacja-redis-sync` | trwała kolejka PostgreSQL → Redis |
| `stacja-udp` | odbiór UDP 8680, zapis do PostgreSQL |
| `stacja-web`, `stacja-apache` | istniejąca aplikacja i proxy |

Hasło lokalnej roli `stacja` jest w `~/.config/stacja/pg_password` (0600), poza
repozytorium i katalogiem publicznym. Dane PG oraz lokalny socket są w katalogu 0700.
Redis i PostgreSQL nie nasłuchują na interfejsie publicznym.

```bash
systemctl --user status stacja-postgres stacja-redis stacja-redis-sync stacja-web stacja-udp
journalctl --user -u stacja-redis-sync -f
journalctl --user -u stacja-udp -f
```

Pliki jednostek w `deploy/` zawierają ścieżki aktualnego komputera. Przy przenoszeniu
na VPS należy dostosować je do ścieżek instalacji i sposobu zarządzania usługami.
Dla działania usług użytkownika po wylogowaniu SSH potrzebny jest włączony linger
(`loginctl enable-linger NAZWA_UŻYTKOWNIKA`, zależnie od uprawnień administratora)
albo uruchamianie ich jako systemowych usług dedykowanego użytkownika.

## Konfiguracja nowego serwera

Wymagane: PostgreSQL, Redis, Ruby/Bundler i istniejący serwer aplikacji. Można użyć
pakietów dystrybucji. Ustaw w środowisku wszystkich usług aplikacji i loggera:

```text
DATABASE_URL=postgresql://USER:PASSWORD@127.0.0.1:5432/stacja_production
REDIS_URL=redis://127.0.0.1:6379/0
RAILS_ENV=production
```

Alternatywnie dostępne są `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`.
Do tworzenia bazy potrzebna jest rola z uprawnieniem CREATEDB albo utworzenie bazy
wcześniej przez administratora. Testy używają `stacja_test`, nie produkcji.

```bash
bundle install
RAILS_ENV=production bundle exec ruby bin/rails db:prepare
RAILS_ENV=production bundle exec ruby bin/rails runner script/redis_sync.rb
```

Redis powinien mieć politykę `noeviction`; ciche wyrzucanie kluczy uniemożliwia
zagwarantowanie kompletności kopii. Pełna historia nie jest usuwana z PostgreSQL.
Istniejące pliki SQLite nie są już używane ani importowane.

### Checklista wdrożenia na VPS z publiczną domeną

1. **`config.hosts`** — obecnie dopuszcza tylko lokalne i prywatne adresy.
   `ActionDispatch::HostAuthorization` zwróci 403 dla publicznej domeny, dopóki nie
   dopiszesz jej do tej listy (np. `config.hosts << "pogoda.example.com"`).
2. **`config.action_dispatch.trusted_proxies`** — ustawione na `127.0.0.1`/`::1`
   dla pojedynczego proxy (Apache). Jeśli przed aplikacją stanie jeszcze CDN albo
   load balancer, **dopisz ich adresy**, inaczej `remote_ip` zatrzyma się na IP LB
   i limiter HTTP stanie się znów współdzielony dla wszystkich klientów.
3. **`SECRET_KEY_BASE`** i **token transportu pomiarów** — ustaw jako zmienne
   środowiskowe (nie w repozytorium).
4. **TLS/HSTS** — docelowo na brzegu; obecny transport to UDP lokalnie, więc HTTPS
   wprowadzisz razem z endpointem przyjmującym dane i uwierzytelnieniem urządzenia.
5. **Linger dla usług użytkownika** — `loginctl enable-linger` albo usługi systemowe
   dedykowanego użytkownika, by procesy działały po wylogowaniu z SSH.

## Logger przez SSH

Z katalogu `web`:

```bash
bin/weather-log --last 20 --follow
bin/weather-log --last 20 --follow --diagnostics
bin/weather-log --last 100 --json > pomiary.jsonl
bin/weather-log --last 0 --follow --json >> nowe-pomiary.jsonl
```

Logger domyślnie korzysta z produkcyjnej bazy i czujnika `0000DE3E`. Nie zajmuje
portu UDP. Pokazuje czas przyjęcia, ID rekordu i surowe wartości przed wygładzaniem.
`--json` zawiera wszystkie zapisane pola, także wewnętrzną diagnostykę. Komunikaty
o przerwie i stanie Redis są kierowane na stderr, by nie psuć JSONL na stdout.
Ctrl+C kończy podgląd. Tryb follow odpytuje PG co sekundę, według rosnącego ID,
co odpowiada obecnemu pojedynczemu odbiornikowi zapisującemu sekwencyjnie.
Odrzucone pakiety są widoczne w `journalctl --user -u stacja-udp`.

## Kopie i awarie

Kopie trwałej historii wykonuje się przez `pg_dump`, nie kopiowanie plików aktywnej
bazy. Dla lokalnych binariów ustaw `LD_LIBRARY_PATH=~/.local/share/stacja-infra/usr/lib`
(użyj rozwiniętej ścieżki) oraz hasło przez `PGPASSWORD` lub chroniony plik `.pgpass`.
Przykład przy `pg_dump` dostępnym w PATH:

```bash
pg_dump -h 127.0.0.1 -p 5433 -U stacja -Fc stacja_production > stacja.dump
```

Przy awarii Redis pozostawić aktywne PG i odbiornik; przywrócenie Redis powoduje
ponowienie kolejki. Restart `stacja-redis-sync` wymusza pełne odtworzenie 72 h.
Monitorować rozmiar kolejki, wolne miejsce PG i logi. AOF Redis nie zastępuje
kopii PostgreSQL. Jeśli samo PG nie działa, UDP nie gwarantuje dostarczenia:
docelowy transport do VPS wymaga potwierdzeń i bufora powtórzeń po stronie ESP.

## Weryfikacja

```bash
RAILS_ENV=test bundle exec ruby bin/rails db:prepare
bundle exec ruby bin/rails test
```

Testy integracji wymagają działających PG i Redis. Używają wyłącznie przestrzeni
Redis `stacja:test:*`, bez czyszczenia całego serwera. Sprawdzają transakcyjność
kolejki, deduplikację, retencję, odtwarzanie i fallback podczas braku Redis.
