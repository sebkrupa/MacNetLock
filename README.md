# netlock

CLI dla macOS. Dopóki działa, blokuje ruch sieciowy (wychodzący i przychodzący)
dla wszystkich procesów poza wybranymi aplikacjami. Aplikacje mogą już działać,
nic nie trzeba restartować. W trakcie pokazuje na żywo, ile danych przesłał każdy
proces w systemie od startu. Po zakończeniu (Ctrl+C, SIGTERM, zamknięcie
terminala) przywraca domyślną konfigurację sieci. Odpowiednik TripMode bez
Network Extension. Czysty bash, zero zależności.

## Pliki

```
netlock         # główna komenda (sudo)
netlock-apps    # interaktywny wybór dozwolonych aplikacji (bez sudo)
install.sh      # kopiuje oba do /usr/local/bin
uninstall.sh    # usuwa wszystko, co netlock zostawił w systemie
```

## Jak to działa

- Filtrowanie przez `pf` (`pfctl`). Główny ruleset blokuje wszystko poza DNS
  i `lo0`, a przed blokadą stoi anchor `netlock`.
- pf nie zna procesów, więc netlock co 0,5 s szuka procesów dozwolonych
  aplikacji (`ps`, dopasowanie `/Nazwa.app/` w ścieżce, procesy potomne też),
  pyta `lsof` o ich gniazda i ładuje do anchora reguły przepuszczające te
  porty lokalne: `pass out quick proto tcp from any port { 51597 51612 } flags any`
  plus lustrzane `pass in`. Port lokalny jest unikalny per gniazdo, więc reguła
  dotyczy dokładnie tego połączenia. Reszta zostaje pod `block drop out all`.
- `flags any`: połączenie otwarte zanim powstała jego reguła (aplikacja już
  działała) jest przechwytywane w trakcie, bez zrywania.
- Nowe połączenie dozwolonej aplikacji: pierwszy SYN ginie, bo gniazdo jeszcze
  nie ma reguły. macOS ponawia SYN po 1 s i wtedy przechodzi. Czyli około 1 s
  opóźnienia na każde nowe połączenie. Przeglądarki trzymają połączenia otwarte,
  więc czuć to głównie przy pierwszym wejściu na stronę. QUIC (UDP) traci
  pierwsze pakiety, przeglądarka wraca do TCP.
- Port 53 (DNS) przepuszczony globalnie, bo DNS robi `mDNSResponder` (osobny proces).
- Po załadowaniu reguł `pfctl -F states` czyści tablicę stanów: połączenia
  zablokowanych aplikacji otwarte wcześniej nie przeżywają. Dozwolone wracają
  przez `flags any`.
- Restore = `pfctl -f /etc/pf.conf`, wyczyszczenie anchora i zwolnienie
  referencji pf (`pfctl -X`). Jeśli pf było włączone przed startem (np. VPN),
  zostaje włączone z domyślnym rulesetem.
- Monitor czyta `nettop` (wbudowane w macOS) i sumuje przyrosty per proces.
- Lista dozwolonych aplikacji: `~/.config/netlock/allow`, jedna nazwa na linię.
  netlock czyta ją przy starcie i łączy z `--allow`.

Główny ruleset (`--dry-run` go wypisuje):

```
# netlock
set skip on lo0
pass out quick proto { tcp udp } to any port { 53 }
anchor "netlock"
block drop out all
block drop in all
```

## Instalacja

```bash
./install.sh
```

Nie ma kroku `setup`. Starsze wersje tworzyły grupę `netallow`; `uninstall.sh`
ją usuwa, a `sudo netlock setup` tylko o tym informuje.

## Użycie

```
sudo netlock [--allow <app>[,<app>...]] [--allow-port <port>[,...]] [--no-monitor] [--dry-run] [--verbose]
sudo netlock status
sudo netlock restore
netlock-apps
```

- `<app>`: nazwa z `/Applications`, `~/Applications` lub `/System/Applications`
  (np. `Firefox`, `Slack`), pełna ścieżka do binarki lub bundle `.app`, albo
  `bundle:com.foo.bar`. Aplikacja może działać albo wystartować później.
  Procesy potomne liczą się jako aplikacja: dozwolony Terminal oznacza sieć
  dla wszystkiego, co w nim uruchomisz.
- `--allow-port`: dodatkowe porty przepuszczane globalnie dla wszystkich procesów
  (np. `123` NTP, `67` DHCP). Domyślnie tylko 53.
- Bez `--allow` i z pustą listą w `netlock-apps`: blokuje wszystko poza DNS
  (tryb „pełna cisza”).
- `--no-monitor`: bez tabeli na żywo, tylko statyczne podsumowanie.
- `--dry-run`: wypisuje ruleset i kończy, nie dotyka pf.
- `status`: czy pf włączone, czy ruleset netlock załadowany, jakie porty
  przepuszcza anchor w tej chwili.

Przykład:

```bash
sudo netlock --allow Firefox,Slack --allow-port 123
```

Ctrl+C kończy netlock i przywraca sieć. Aplikacje działają dalej, po prostu
znów wszystkie mają internet.

## Wybór aplikacji: netlock-apps

```bash
netlock-apps
```

Dwie kolumny: po lewej dozwolone, po prawej reszta zainstalowanych aplikacji
(`/Applications`, `~/Applications`, `/System/Applications`). Dwie pierwsze
linie ekranu to ściąga klawiszy. Po zmianie w nagłówku pojawia się
`[unsaved changes]`.

| Klawisz | Działanie |
|---|---|
| Enter | **zapisz** do `~/.config/netlock/allow` i wyjdź |
| Esc | wyjdź **bez zapisu** (wypisuje `changes discarded`) |
| Tab, ←/→ | zmiana kolumny |
| ↑/↓ | ruch w kolumnie |
| Spacja | przenieś aplikację do drugiej kolumny |
| litery | filtr obu kolumn (bez rozróżniania wielkości) |
| Backspace | kasuj znak filtra |

Następne `sudo netlock` przepuści wszystko z listy. `--allow` dokłada do niej
jednorazowo. Aplikacja z listy, której już nie ma na dysku, zatrzymuje start
(`cannot find app`); usuń ją w `netlock-apps`.

## Live monitor

Domyślnie włączony, gdy stdout jest terminalem. Odświeżany co sekundę:

```
netlock  4 KB  (in 2 KB, out 2 KB)  up 00:00:03   Ctrl+C restores network
allowed: Firefox   ports: 53
* = allowed app (has network)   no *: out = blocked retries, tiny in = DNS

PROCESS                   IN        OUT      TOTAL
*firefox              1 KB       1 KB       3 KB  ====================
 mDNSResponder        1 KB       40 B       1 KB  ========
 Mail                  0 B       32 B       32 B
```

- Liczy od startu netlocka. Pierwsza próbka `nettop` (stan skumulowany) jest pomijana.
  Ruch loopback nie jest liczony (`nettop -t external`).
- `*` oznacza proces dozwolonej aplikacji (razem z potomnymi).
- Proces bez `*`, który ma tylko OUT: zablokowana aplikacja ponawia połączenia.
  `nettop` liczy bajty na gnieździe, zanim pf je odrzuci, więc widać KB prób,
  nie realny transfer.
- Proces bez `*` z małym, symetrycznym IN i OUT (setki bajtów): własny resolver
  DNS (Chromium, Electron, Go). Port 53 jest otwarty dla wszystkich.
- `nettop` ucina nazwy do 15 znaków i liczy per proces, nie per bundle `.app`
  (helpery Chrome, Claude itd. to osobne wiersze).
- Każda linia jest ucinana do szerokości terminala. Zawinięta linia przewijałaby
  ekran przy każdym odświeżeniu.
- `nettop` buforuje wyjście do pipe, więc działa pod pseudo-terminalem
  (`script -q /dev/null`). Jak zginie, netlock dalej blokuje i wypisuje komunikat.

## Ręczne przywrócenie sieci

Po `kill -9` netlocka trap nie zadziała i ruleset zostaje w pf. Wtedy:

```bash
sudo netlock restore
```

To ładuje `/etc/pf.conf`, czyści anchor i wyłącza pf (`pfctl -d`). Bez netlocka
pod ręką:

```bash
sudo pfctl -f /etc/pf.conf && sudo pfctl -d
```

## Odinstalowanie

```bash
./uninstall.sh
```

Odmawia, gdy netlock działa. Potem po kolei: jeśli ruleset netlock jest w pf,
ładuje `/etc/pf.conf`, czyści anchor i wyłącza pf; usuwa grupę `netallow`, jeśli
została po starszej wersji; usuwa `/usr/local/bin/netlock` i
`/usr/local/bin/netlock-apps`; usuwa `~/.config/netlock`. Działające aplikacje
zostają. Katalog repo zostaje.

## Testy akceptacyjne (manualne)

1. Firefox już działa. `sudo netlock --allow Firefox`. Firefox po około sekundzie
   ładuje strony dalej. Safari albo `curl https://example.com` z innego
   terminala: timeout.
2. Ctrl+C. `curl https://example.com` działa natychmiast.
3. `sudo netlock` w jednym terminalu, w drugim `sudo kill -9 <pid netlocka>`.
   Sieć nadal zablokowana. `sudo netlock restore` przywraca.
4. `sudo pfctl -s rules > before; sudo netlock --dry-run; sudo pfctl -s rules > after; diff before after`
   nie pokazuje różnic.
5. Przy działającym netlocku odpal Firefox z Docka (był zamknięty). Działa bez
   restartu netlocka.
6. `sudo netlock status` w trakcie działania: `pf: enabled`,
   `netlock rules: loaded`, lista `pass out quick proto tcp from any port {...}`.
7. W trakcie testu 1 tabela pokazuje `*firefox` z rosnącym ruchem, a np. `Mail`
   bez `*` z pojedynczymi KB tylko w OUT. Po Ctrl+C nie zostaje proces `nettop`
   (`pgrep nettop`).
8. Przed startem otwórz długie pobieranie w Safari (nie na liście), potem
   `sudo netlock`. Pobieranie staje w ciągu sekundy.
9. `netlock-apps`: przenieś Firefox w lewo, Enter. `cat ~/.config/netlock/allow`
   zawiera `Firefox`. `sudo netlock` bez `--allow` przepuszcza Firefox. Zwęź
   terminal do 60 kolumn: lista nie skacze przy ↑/↓.
10. `./uninstall.sh`, potem `which netlock` nic nie znajduje,
    `~/.config/netlock` nie istnieje.

## Znane ograniczenia

- Około 1 s opóźnienia na każde nowe połączenie dozwolonej aplikacji (zgubiony
  pierwszy SYN). Bez Network Extension nie da się tego uniknąć.
- Inne narzędzia filtrujące sieć (TripMode, VPN z własnym filtrem) działają
  równolegle z pf i mieszają wynik. Na czas testów netlocka zamknij TripMode.
- Aplikacje sandboxowane i systemowe są dopasowywane po `/Nazwa.app/` w ścieżce
  procesu. Helper poza bundle i poza drzewem procesów aplikacji nie dostanie sieci.
- Blokuje też rzeczy systemowe (iCloud, push, aktualizacje). To feature.
- Odnowienie DHCP jest zablokowane (port 67). Przy bardzo długiej sesji lease
  może wygasnąć. Dodaj `--allow-port 67` jeśli to problem.
- ICMP (ping) przechodzi na wyjściu, odpowiedzi blokuje `block drop in all`.
- Ruch przychodzący przechodzi tylko na porty lokalne dozwolonych aplikacji
  (także nasłuchujące). Reszta zablokowana.
- `netlock-apps` widzi tylko bundle `.app` na pierwszym poziomie trzech katalogów.
  Binarki spoza nich dodasz przez `--allow /ścieżka` lub ręcznie w pliku.
- Monitor pokazuje bajty per proces z `nettop`, nie per aplikacja. Brak limitu
  danych per app. Poza zakresem.
