# TC Cinema Player

Player video per Mac (Apple Silicon) che riproduce le tracce **Dolby Atmos** con il
rendering a oggetti vero, su uscite audio discrete, senza installare nient'altro.

Apre MKV, MP4, MOV, M2TS e gli altri formati che legge mpv. Le tracce TrueHD Atmos,
DD+ Atmos (JOC), DTS:X e IAMF vengono decodificate con gli oggetti e distribuite sui
canali del layout scelto. Le altre tracce si riproducono normalmente.

## Scaricare l'app

1. Apri la scheda **Actions** del repository e scegli l'ultima esecuzione riuscita (spunta verde).
2. In fondo alla pagina, in **Artifacts**, scarica **TC-Cinema-Player-macOS**.
3. Estrai lo zip (a volte serve due volte: GitHub mette lo zip dentro un altro zip) e
   sposta **TC Cinema Player** in Applicazioni.
4. La prima volta macOS la blocca perché non è firmata da Apple. Prova ad aprirla, chiudi
   l'avviso, poi vai in Impostazioni di Sistema → **Privacy e sicurezza**: in fondo c'è
   **Apri comunque**. Basta farlo una volta. In alternativa, dal Terminale:
   `xattr -dr com.apple.quarantine "/Applications/TC Cinema Player.app"`

Serve macOS 15 o successivo su un Mac con chip Apple.

## Uso

- **Aprire un file:** ⌘O, trascinandolo sulla finestra, oppure "Apri con" dal Finder.
- **Tracce audio e sottotitoli:** menu *Audio* e *Sottotitoli*, oppure i due pulsanti
  nella barra dei controlli. Le tracce con oggetti sono segnate **ATMOS**; durante la
  riproduzione di una traccia Atmos compare il riquadro giallo **ATMOS** nella barra.
- **Vista 3D:** menu *Vista → Vista 3D* (tasto 3). Mostra la stanza con i diffusori del
  layout e gli oggetti in tempo reale; la dimensione delle sfere segue il livello.
  Trascina per ruotare, scorri per lo zoom. Il cursore "Ritardo" allinea il movimento a
  quello che senti (le posizioni arrivano prima del suono, di quanto dura il buffer audio).
- **Preferenze (⌘,):**
  - *Generale:* lingue audio e sottotitoli preferite (predefinite: audio inglese poi
    italiano, sottotitoli italiano) e "Preferisci le tracce Atmos". Vince la lingua;
    dentro la lingua si sceglie l'Atmos. Sottotitoli: se l'audio è in un'altra lingua si
    attivano quelli completi, se è nella stessa lingua solo i forced (anche quando cambi
    traccia audio durante la visione). Se scegli tu un sottotitolo, l'app non lo cambia più
    per quel file.
  - *Audio:* dispositivo di uscita e layout dei canali, con l'ordine dei canali.
  - *Scorciatoie:* tutte personalizzabili.

### Scorciatoie predefinite

| Azione | Tasto |
| --- | --- |
| Play / Pausa | Spazio |
| Avanti / Indietro 10 s | → / ← |
| Avanti / Indietro 1 min | ⇧→ / ⇧← |
| Volume su / giù | ↑ / ↓ |
| Muto | M |
| Schermo intero | F (Esc per uscire) |
| Traccia audio successiva | A |
| Sottotitoli successivi | S |
| Vista 3D | 3 |
| Apri | ⌘O |

## Uscita audio

L'app manda i canali **in ordine, uno per uscita**, secondo il layout scelto. Esempio
7.1.4: 1 FL · 2 FR · 3 C · 4 LFE · 5 BL · 6 BR · 7 SL · 8 SR · 9 TFL · 10 TFR · 11 TBL · 12 TBR.
Ci sono anche le varianti **senza centrale** (5.1.2 e 7.1.4): il centro viene ricostruito
come immagine fantasma tra FL e FR.

Perché macOS non riduca i canali, il dispositivo deve averne abbastanza e, in
**Configurazione MIDI Audio** → dispositivo → **Configura altoparlanti**, conviene
impostare la configurazione multicanale con il numero di canali giusto.

Le tracce non Atmos (stereo, 5.1, 7.1) passano anch'esse dal motore e finiscono sui
diffusori corrispondenti del layout.

## Video

Il video è disegnato da mpv. Su schermi che supportano l'HDR (XDR o monitor HDR esterni)
i contenuti HDR10/HLG vengono mostrati in HDR; altrimenti sono convertiti in SDR.
I metadati Dolby Vision (profili 5 e 8) vengono interpretati da mpv. Il secondo strato
dei dischi UHD (profilo 7 FEL) per ora non viene ricostruito.

## Come è fatta

- **Interfaccia:** Swift/AppKit (`app/Sources`), con libmpv per la riproduzione.
- **mpv:** il fork [mgth/mpv](https://github.com/mgth/mpv) (progetto
  [mpv-omniphony](https://github.com/mgth/mpv-omniphony)), che aggiunge il decoder
  spaziale `ad_orender`.
- **Motore di rendering:** [Omniphony](https://github.com/mgth/Omniphony) (`liborender`,
  rendering VBAP) di mgth.
- **Decoder:** [harletty-bridge](https://github.com/harletty/harletty-bridge) di harletty,
  basato su [truehdd](https://github.com/truehdd/truehdd) di Rainbaby.
- **Analisi delle tracce Atmos prima della riproduzione:** FFmpeg (`AtmosProbe.c`).

La vista 3D riceve le posizioni degli oggetti dal motore via OSC sulla porta locale 9137,
quindi non interferisce con Omniphony Studio se è installato (porta 9000). La
configurazione del motore usata dall'app sta in
`~/Library/Application Support/TC Cinema Player/omniphony/config.yaml` e viene riscritta
dalle preferenze.

### Compilazione

La compila GitHub Actions a ogni modifica (`.github/workflows/build.yml`): scarica e
compila mpv, Omniphony e harletty-bridge alle versioni indicate in cima al file, poi
`scripts/build-app.sh` crea l'app con tutte le librerie dentro.

Per aggiornare i componenti si cambiano insieme `MPV_FORK_TAG`, `OMNIPHONY_REF` e
`HARLETTY_TAG`: il decoder si carica solo in un motore con la stessa versione di
`bridge_api`, e mpv-omniphony indica quale versione di Omniphony richiede.

## Licenza

GPL-3.0, come mpv, Omniphony e i decoder di harletty-bridge che contiene. Le licenze dei
componenti sono dentro l'app, in `Contents/Resources/licenses`.

Il rendering non è quello certificato Dolby: è un decoder e un renderer open source,
pensati per l'ascolto e non come riferimento per il controllo di un master.
