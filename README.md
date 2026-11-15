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

## Onderdelen
- **Zoeken** en **Sets** (blader per set, met voortgang van je collectie)
- **Collectie:** kaarten met staat, aantal, betaalde prijs en jouw eigen prijs; totale waarde en winst/verlies
- **Binders:** eigen binders met pagina's van vakjes, kaarten slepen om te wisselen
- **Watchlist** met prijsalerts, prijsvergelijking en dealbeoordeling

## Deals, verkopen en account
- **Dealscore (0–100)** per aanbieding: prijs incl. geschatte verzending tegenover de mediaan van gelijke staat én variant, verkoper, foto, levertijd, TCGplayer-controle. Beste deals bovenaan.
- **Verkoop:** kaarten in je collectie markeren als te koop met vraagprijs; beoordeling (te duur / marktconform / scherp), advies en netto na commissie; Marktcheck.
- **Slim bundelen:** verkopers met meerdere kaarten van je watchlist, met geschatte verzendbesparing.
- **Koopjes-alerts**, winnaars/verliezers, waardeverloop, CSV-export, privacymodus, sets offline opslaan.
- **Cardmarket-account:** inloggen in een webweergave; de app ziet je wachtwoord niet. *Mijn aanbod beoordelen* is experimenteel.
- Tests: `xcodebuild -scheme Cards -destination 'platform=macOS' test`

## Sync, widget en meer
- **iCloud-sync** van collectie, watchlist, binders en prijsgeschiedenis tussen Mac en iPhone (iCloud Drive-container); bij een conflict worden beide versies samengevoegd.
- **Widget** met je collectiewaarde en de grootste stijger (via een App Group).
- **Sets:** hoofdset samengevoegd, varianten (reverse holo, 1e editie, patronen) gegroepeerd op fysieke kaart, kaartnummer en V.1/V.2-labels, compleet-maken-kosten, CSV-import.
- Tests met lokale entitlements: `xcodebuild -scheme Cards -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=Cards/CardsLocal.entitlements test`

## Alerts
- **Trend-alert:** op de Cardmarket-trendprijs (alle staten). Wordt gecontroleerd bij het starten (en op iOS best effort op de achtergrond).
- **Alert per staat** (NM/EX/GD/LP of beter): kijkt naar de goedkoopste aanbieding op de Cardmarket-pagina via een webweergave. Dat werkt alleen met de app open (bij het starten, op de Mac elke 30 min, of via *Watchlist controleren*). Vraagt Cardmarket een Cloudflare-controle, dan krijg je een melding om die zelf aan te tikken.

## Nog niet
Kopen/verkopen, serverside pushmeldingen. Daarvoor is Cardmarket-API-toegang (OAuth) en een backend nodig.
