# keylight

Rekordbox' trafiklys til Serato DJ Pro 4: et lille flydende panel, der viser toneart og BPM
for hvert deck, der har et nummer loadet, og de tonearter, der passer til det: samme toneart,
naboerne på Camelot-hjulet og dur/mol-parallellen.

```
sh make-app.sh       # bygger ~/Applications/keylight.app (ligger i Dock'en)
./keylight-start     # alternativ: start binaren direkte i baggrunden
```

Panelet ligger over alle vinduer, også når Serato har fokus, og tager ikke fokus, når man
trækker i det. Flyt det ved at trække i selve panelet; placeringen huskes. Menuen findes både
som `♪` i menulinjen og ved højreklik på panelet: vis/skjul, notation (Camelot, standard eller
begge), størrelse (lille/mellem/stor), "vis kun mens Serato kører" og "start ved login".
Med de to sidste slået til dukker panelet op, når Serato starter, og forsvinder, når Serato lukkes.

Tonearterne vises som farvefelter i præcis de farver, Serato selv bruger i Key-kolonnen
(aflæst fra et skærmbillede; 12B er udledt). Ligger der numre på flere decks, bliver decknummeret
grønt, når nummeret passer i toneart med et af de andre decks, efter Rekordbox' regel.

Sådan virker det: Serato 4 skriver inden for et sekund ned i sit bibliotek
(`~/Library/Application Support/Serato/Library/master.sqlite`, tabellen `history_entry`),
hvad der er loadet på hvert deck. keylight læser den database read-only en gang i sekundet.
Den skriver aldrig i den. Bryder Serato formatet i en opdatering, viser panelet bare ingenting.

Filer: `main.swift` (vindue og menu), `camelot.swift` (tonearter og kompatibilitet),
`camelot_test.swift` + `test.sh` (test af tonearts-logikken), `build.sh`, `make-app.sh` + `make-icon.swift`
(app-bundle med ikon til Dock'en).
Kræver kun Xcode Command Line Tools (Swift).
