# Cards

SwiftUI-app (iPhone + Mac) voor actuele Cardmarket-prijzen van Pokémon-kaarten.

## Draaien
```
brew install xcodegen
xcodegen generate
open Cards.xcodeproj
```

## Hoe het werkt
- Prijzen komen uit de openbare Cardmarket-downloads (productlijst + price guide, idGame 6). Geen API-sleutel nodig.
- Zoeken, kaartdetails (trend/gem./laagste, holo), watchlist met prijsalerts (lokale notificaties).
- iOS ververst op de achtergrond (BGAppRefresh, best effort) en controleert dan de alerts.

## Afbeeldingen en setnamen
Komen van [TCGdex](https://tcgdex.dev) via `Cards/Resources/cardmap.json` (gebundeld). Opnieuw genereren:
```
python3 Scripts/build_map.py        # haalt ~24k kaarten op (~10 min), schrijft cards2.jsonl naast het script
python3 Scripts/make_cardmap.py cards2.jsonl set_names.json products_singles_6.json
```

## Alerts
- **Trend-alert:** op de Cardmarket-trendprijs (alle staten). Wordt gecontroleerd bij het starten (en op iOS best effort op de achtergrond).
- **Alert per staat** (NM/EX/GD/LP of beter): kijkt naar de goedkoopste aanbieding op de Cardmarket-pagina via een webweergave. Dat werkt alleen met de app open (bij het starten, op de Mac elke 30 min, of via *Watchlist controleren*). Vraagt Cardmarket een Cloudflare-controle, dan krijg je een melding om die zelf aan te tikken.

## Nog niet
Kopen/verkopen, serverside pushmeldingen. Daarvoor is Cardmarket-API-toegang (OAuth) en een backend nodig.
