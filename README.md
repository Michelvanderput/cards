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

## Nog niet
Kopen/verkopen, serverside pushmeldingen. Daarvoor is Cardmarket-API-toegang (OAuth) en een backend nodig.
