# StacjaPrudnik — publiczny panel pogodowy Ruby on Rails + Apache

## Adresy

- Na tym komputerze: **http://localhost:8080**
- Z telefonu/komputera w tej samej sieci: **http://192.168.100.65:8080**
  (to adres komputera, nie ESP; może zmienić się przez DHCP).
- API: `/api/weather`, opcjonalnie `?hours=24`.
- Panel, historia i CSV są przypisane na stałe do czujnika `0000DE3E`.
  Parametr `sensor_id` w adresie nie zmienia czujnika. W menu nie ma listy wyboru.
- Historia i eksport: `/history`.
- Alerty pogodowe (tylko odczyt): `/alerts`.

## Konfiguracja wyłącznie na serwerze

Publiczna strona nie udostępnia formularzy ani endpointów zmiany konfiguracji.
`/settings` i `/devices` zwracają 404, także dla POST/PATCH/PUT/DELETE.
Lokalizację i progi alertów administrator zmienia w `config/station.yml`.
Po edycji uruchom:

```bash
systemctl --user restart stacja-web stacja-udp
```

Plik zachowuje wcześniejszą lokalizację 51,07°N, 17,02°E (okolice Wrocławia).
Nie zmieniono jej automatycznie na Prudnik. Pola `latitude` i `longitude`
muszą być podane razem; można pozostawić oba puste, aby wyłączyć obliczenia
słoneczne. Konfiguracja jest walidowana przy odczycie. Historyczna tabela
`station_settings` pozostaje w bazie, ale nie jest już źródłem ustawień.

API i CSV zawierają tylko dane pogodowe; nie publikują identyfikatorów
czujnika/ESP, adresów IP, RSSI, kanału, numeracji pakietów, czasu pracy,
stanu baterii ani diagnostyki odbiornika. Plik konfiguracji leży poza
katalogiem `public` i nie jest serwowany przez Apache/Rails.

Apache 2.4 nasłuchuje na porcie 8080 i przekazuje żądania do Rails/Puma na
`127.0.0.1:3000`. Konfiguracja: `config/apache.conf`.

## Dane

```text
GARNI → CC1101 → ESP8266 → UDP :8680 → Ruby → PostgreSQL (pełna historia)
                                              ↓ transakcyjny outbox
                                            Redis (ostatnie 72 h)
                                              ↓
przeglądarka ← Apache :8080 ← Rails/Puma :3000 ←─┘
```

Odbiornik `script/receive.rb` zapisuje oryginalne pomiary z każdej poprawnej
ramki, czas odbioru i adres źródłowy. Baza: PostgreSQL `stacja_production`.
Od 28.09.2026 historia jest zbierana od nowa, bez importu danych SQLite.
Instrukcja PostgreSQL, Redis, awarii, kopii zapasowych i loggera: **[STORAGE.md](STORAGE.md)**.
Historia gromadzi się od uruchomienia usługi; wcześniejsze odczyty terminalowe
nie były zapisywane do tej bazy.

Panel aktualizuje się co 5 sekund. Historia obejmuje zakresy 1 h, 6 h, 24 h
i 7 dni, wykresy temperatury, wilgotności, wiatru i licznika opadów oraz
osiem ostatnich ramek z wybranego okresu. CSV eksportuje wszystkie ramki
danego czujnika z wybranego zakresu, bez agregacji wykresu.
Po 180 sekundach bez pomiaru oznacza dane jako nieaktualne. Brakujące pola
są prezentowane jako `—`. Licznik opadów pochodzi z czujnika i nie oznacza
sumy dobowej. Widok jest dostosowany do telefonu i komputera.

Usługa Ruby zajmuje port UDP 8680. Aby skorzystać ze starego `receiver.py`,
najpierw zatrzymaj `stacja-udp`; w tym czasie pomiary nie będą zapisywane
do bazy panelu. Nowe funkcje panelu działają z dotychczasowym firmware ESP.
Do równoległego podglądu bez zatrzymywania odbiornika służy teraz:

```bash
bin/weather-log --last 20 --follow --diagnostics
bin/weather-log --last 100 --json
```

## Obliczenia i jakość danych

- Punkt rosy: wzór Magnusa; brak wyniku dla wilgotności 0% lub spoza zakresu.
- Wind chill: temperatura od −50 do 10°C i wiatr od 4,8 km/h.
- Heat index: przybliżenie Rothfusza dla temperatur 26,7–50°C i wilgotności
  40–100%, z korektą dla wysokiej wilgotności.
- Gdy nie stosuje się wind chill ani heat index, panel oblicza apparent
  temperature: `AT = T + 0,33e − 0,70v − 4`, gdzie
  `e = RH/100 × 6,105 × exp(17,27T/(237,7+T))`, temperatura jest w °C,
  wiatr w m/s, a ciśnienie pary w hPa. Etykieta: „Odczuwalna w cieniu — szacunek”.
  Wymagane są wszystkie trzy pomiary; brak wiatru nie jest traktowany jako
  cisza. Wynik nie uwzględnia bezpośredniego nasłonecznienia ani ubioru.
- Wiatr: km/h, 16 kierunków, kompas i skala Beauforta. Przy ciszy
  (poniżej 0,3 m/s) kierunek oznaczany jest jako niemiarodajny.
- Statystyki dobowe: minima/maksima z czasami wystąpienia oraz średnie
  ważone czasem między próbkami. Przerwy ponad 120 s są wyłączane ze średniej.
  Podawane jest pokrycie danymi; niepełny dzień jest oznaczany.
- Trendy: zmiana temperatury i wilgotności w 30 min i 3 h, tylko przy
  wystarczająco ciągłej historii. Zmiana wilgotności jest w punktach procentowych.
- Opady: ostatnia godzina, dzisiaj, ostatnie 24 h, tydzień od poniedziałku,
  miesiąc. Przedziały kalendarzowe liczone są w Europe/Warsaw. Licznik
  narastający jest analizowany osobno dla każdego ID czujnika. Spadek licznika
  oznacza możliwy reset/przepełnienie; nie jest zamieniany na dodatni opad.
  Dodatni przyrost przecinający granicę okresu jest pomijany jako niejednoznaczny.
  Luki, reset oraz brak pełnej historii oznaczają sumę jako niepełną (`*`).
  Pozytywne przyrosty przez lukę wewnątrz jednego okresu są uwzględniane,
  ale okres nadal jest oznaczony jako niepełny.
- Natężenie deszczu to szacunek z ostatnich 10 minut w mm/h; nie jest
  podawane, gdy okno ma niepełne dane.
- Wykresy agregują dane w przedziałach 15 s / 1 min / 5 min / 30 min,
  zależnie od zakresu. Licznik deszczu używa ostatniej wartości, pozostałe
  wykresy średniej w przedziale. Luki ponad 2 minuty przerywają linię.

Statystyki są buforowane na 30 s, serie wykresów na 10 s. Najnowszy pomiar
jest pobierany przy każdym odświeżeniu API.

## Diagnostyka i alerty

Pakiety `status` są zapisywane w tabeli `gateways`. Diagnostyka jest dostępna
wyłącznie administratorowi na serwerze, np. z katalogu aplikacji:

```bash
RAILS_ENV=production bundle exec ruby bin/rails runner 'pp Gateway.all.map(&:diagnostics)'
journalctl --user -u stacja-udp -n 50
```

Restarty są wykrywane heurystycznie, gdy czas pracy maleje i numeracja wraca
do pierwszych pięciu wiadomości; pominięto typowe przepełnienie `millis()`.
Brak pierwszych pakietów może uniemożliwić wykrycie restartu.
Luki numeracji to przybliżenie brakujących datagramów UDP, nie strat radia.
Diagnostyka zaczyna się od uruchomienia nowej wersji odbiornika.

Alerty (brak danych, niska/wysoka temperatura, poryw wiatru, UV, bateria)
są oceniane w usłudze UDP co około 5 s, również bez otwartej strony.
Reguły w `config/station.yml`: temperatura poniżej 0°C przez 120 s (wyłączenie
powyżej 1°C), powyżej 30°C przez 300 s (wyłączenie poniżej 29°C), poryw od
15 m/s natychmiast (wyłączenie po 600 s poniżej 12 m/s), UV od 6 przez 120 s
(wyłączenie po 300 s poniżej 5). Potwierdzają je kolejne nowe pomiary;
luka ponad 60 s przerywa potwierdzanie. Brak danych po 180 s bez dodatkowej zwłoki.
Alert aktywny podczas utraty danych pozostaje do potwierdzenia poprawy
nowym pomiarem. Alerty pogodowe i brak danych są publiczne; alert baterii
pozostaje tylko w bazie diagnostycznej. Odwiedzający nie zmienia progów.

## Astronomia

Odliczanie do wschodu/zachodu zmniejsza się co sekundę, na podstawie czasu
serwera. W historii pokazujemy godziny zdarzeń dla wybranej daty bez odliczania.

## Wybór dnia i pomoc

### Bieżące wskazania — ruchome okno 5 minut

`LiveWeather` przelicza wskazania przy każdym odczycie API z pomiarów odebranych
w ostatnich 300 sekundach. Temperatura, wilgotność, UV i światło są medianami;
punkt rosy i odczuwalna to mediany wyników obliczonych osobno dla każdej próbki.
Wiatr jest średnią ważoną czasem (trapezy), poryw maksimum, kierunek średnią
kołową ważoną prędkością i czasem. Cisza i znoszące się wektory nie mają kierunku.
Przerwy ponad 60 sekund są wyłączane z całkowania. Bez pary próbek nie ma
średniej ważonej wiatru. Opady pozostają sumą przyrostów licznika.

Wynik jest oznaczony jako wstępny do zebrania co najmniej 10 próbek i 240 sekund
pokrycia, z ostatnią próbką nie starszą niż 60 sekund. Statusy są osobne dla
każdego parametru. Po wyjściu próbek z okna dane znikają zamiast pozostawać
bezterminowo jako aktualne. Czas odczytu jest czasem ostatniej surowej próbki.
Pole `display` API zawiera wygładzone wartości, `smoothing` opis metod i pokrycia,
a `latest`, historia, CSV, statystyki dobowe i alerty zachowują dane źródłowe.

26.09.2026 wykonano reset całej bazy produkcyjnej po zatrzymaniu usług.
Zweryfikowana kopia: `storage/backups/before-five-minute-reset-20260926-124818.sqlite3`.
Nową bazę utworzono z aktualnego schematu; wszystkie tabele aplikacji były puste
przed ponownym uruchomieniem odbiornika. Konfiguracja `config/station.yml` została
zachowana. Historia i diagnostyka są zbierane od nowa.

Widok główny ma szybki wybór dzisiaj, wczoraj i przedwczoraj. W „Historii i wykresach”
dostępne są dzisiaj i siedem poprzednich dni oraz przycisk `…` otwierający kalendarz
całej historii (`date=YYYY-MM-DD` w odczytowym `/api/weather` i `/export.csv`).
Wykres, ostatnie pomiary w tabeli i CSV dotyczą tego samego lokalnego dnia.
Wybór ruchomego zakresu 1/6/24/168 godzin wyłącza filtr konkretnej daty.
API zwraca `date_bounds`: pierwszy dzień pomiarów wybranego czujnika i dzisiaj.
Daty wcześniejsze i przyszłe są niedostępne; dni z lukami pokazują brak danych.
Dzisiaj karty pokazują bieżące pomiary; historyczne
karty pokazują średnie ważone czasem, poryw i UV jako maksimum, opady jako sumę
przyrostów licznika. Kierunek wiatru nie jest uśredniany arytmetycznie.

`DailyWeather` całkuje liniowo między pomiarami z odstępem do 120 sekund,
przycinając przedziały na północy, wschodzie i zachodzie. Doby są lokalne
(Europe/Warsaw), również 23- i 25-godzinne. Dzisiejszy okres kończy się na czasie
obliczenia. Średnia nocy łączy części przed wschodem i po zachodzie tej samej doby.
Brak danych, za mało próbek, niepełne dane i przyszły przedział mają odrębne stany.
Wyniki są buforowane osobno dla dat i współrzędnych przez 30 sekund.

Przyciski `?` otwierają dostępne klawiaturą okna pomocy. Widoczne są tylko symbole
`?` i zamknięcia `×`, bez tła i obramowania. Zachowano tam
usunięte z głównego widoku opisy: resety/zmiany licznika, luki, niepełne okresy,
nieobliczanie natężenia przy niepełnych danych, średnie ważone czasem i pomijanie
przerw ponad 2 minuty. Pomoc opadów zawiera też aktualne liczby resetów i luk.
Okno zamyka Escape, przycisk zamknięcia lub kliknięcie poza oknem.

## Lokalizacja astronomii

W `config/station.yml` administrator ustawia współrzędne lokalizacji.
Panel oblicza przybliżony wschód, zachód i długość dnia na dzisiaj i jutro
oraz czas do następnych zdarzeń. Godziny są w Europe/Warsaw.
Warunki polarne są obsługiwane bez wymyślania godziny wschodu/zachodu.
Przybliżona faza Księżyca pochodzi z wieku synodycznego od nowiu referencyjnego.

## Opcjonalne rozszerzenie firmware

W `../src/main.cpp` dodano przesyłanie flagi `startup` czujnika. Firmware
został skompilowany, ale podczas wdrożenia panelu nie został ponownie wgrany
ze względu na brak uprawnień do `/dev/ttyUSB0`. Panel obsługuje obie wersje.
Po wgraniu użyje flagi jako dodatkowej przesłanki resetu licznika opadów.
Pozostałe metadane i pakiety statusowe są już dostępne ze starego firmware.

## Uruchomienie i obsługa

Trzy usługi użytkownika są włączone i uruchamiają się przy logowaniu:

```bash
systemctl --user status stacja-web stacja-udp stacja-apache
systemctl --user restart stacja-web stacja-udp stacja-apache
systemctl --user stop stacja-apache stacja-udp stacja-web
systemctl --user start stacja-web stacja-udp stacja-apache
```

Log odbioru radiowego:

```bash
journalctl --user -u stacja-udp -f
```

Logi aplikacji i Apache: `log/production.log`, `log/apache-error.log`,
`log/apache-access.log`. Gdy strona działa lokalnie, ale nie na telefonie,
sprawdź tę samą sieć LAN i dostępność TCP 8080 w zaporze.

## Odtworzenie instalacji na tym komputerze

Wymagania systemowe: Ruby, Bundler, Apache, PostgreSQL, Redis oraz narzędzia
do budowania rozszerzeń gemów (gcc, make i nagłówki Ruby/OpenSSL).

```bash
sudo pacman -S --needed ruby ruby-bundler apache postgresql base-devel
# Redis i usługi bazowe: patrz STORAGE.md (lokalnie uruchomione jako usługi użytkownika).
cd /home/krajewski/Developer/ESP32/StacjaPogodowa/web
bundle config set --local path vendor/bundle
bundle install
ruby script/setup.rb
mkdir -p ~/.config/systemd/user
systemctl --user link "$PWD"/deploy/stacja-{web,udp,apache}.service
systemctl --user daemon-reload
systemctl --user enable --now stacja-web stacja-udp stacja-apache
```

Konfiguracje usług i Apache zawierają bezwzględną ścieżkę projektu — przy
przenoszeniu projektu trzeba ją zmienić. `script/setup.rb` tworzy sekret
Rails z uprawnieniami 0600, przygotowuje bazę produkcyjną i sprawdza Apache.
Gemy są lokalne dla projektu; wersje zapisano w `Gemfile.lock`.

## Testy

```bash
RAILS_ENV=test bundle exec ruby bin/rails db:prepare
bundle exec ruby bin/rails test
node --check public/dashboard.js
httpd -t -f "$PWD/config/apache.conf"
curl http://localhost:8080/api/weather
```

Testy używają osobnej bazy PostgreSQL `stacja_test` i kluczy Redis `stacja:test:*`.
Sprawdzają poprawne pomiary,
brak danych, ich przedawnienie, filtrowanie czujników, niepełne ramki,
odrzucanie błędnych danych, wzory pogodowe, opady na granicy okresu i po
resecie, luki, alerty, astronomię, ustawienia i CSV. Ostatni wynik:
66 testów, 367 asercji, bez błędów. Testy obejmują kolejkę Redis, retencję 72 h,
ponowienia, odtwarzanie i odczyt awaryjny z PostgreSQL, mediany, ważenie wiatru,
kierunek kołowy, wygasanie okna oraz granice doby,
zmianę czasu, ważenie nieregularnych próbek, przerwy, podział na dzień/noc i niedostępność
endpointów konfiguracji i diagnostyki oraz brak metadanych urządzeń w API i CSV.
Dodatkowo: allowlistę czujników/urządzeń, odrzucanie nieznanych pól i zbyt dużych
payloadów, limiter HTTP, kompaktowy zapis w Redis, blokadę jednej instancji
synchronizatora, sumowanie opadów z zapytań celowanych oraz uwierzytelniony
tokenem endpoint przyjmujący pomiary `POST /api/measurements`.

Potwierdzono również rzeczywisty odbiór UDP z ESP `192.168.100.69` i odczyt
zapisanych pomiarów przez API za Apache. Przykładowy odczyt podczas uruchomienia:
czujnik `0000DE3E`, temperatura 22,2 °C, wilgotność 38%, UV 1,8.
