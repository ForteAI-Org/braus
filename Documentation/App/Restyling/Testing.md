# Braus restyling: come provarlo

Data: 22 ottobre 2026. Worktree `../mecum-app-restyling`, branch `elio/app-restyling`
(tutto il restyling integrato, più le correzioni della verifica finale, l'ottimizzazione e la CPU a riposo a zero).

Questa è la guida per provare la nuova interfaccia prima di decidere su `main`. Si prova su una
**copia** del workspace, mai su quello vero: vedi «Perché una copia» in fondo.

---

## 1. Compilare e lanciare su una copia

Prima **chiudi Braus** (quello di tutti i giorni): la copia di un database aperto può venire
incoerente, e due Braus insieme si contendono il Mac (display virtuale, Seat).

```sh
# 1. La copia del workspace (113 MB oggi), una volta sola
ditto ~/Library/Application\ Support/Braus ~/Braus-copia

# 2. La build, dal worktree
cd ~/Forte_Projects/mecum-app-restyling
xcodebuild -workspace BrausApp/AgentEnvironment.xcworkspace -scheme Braus \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .scratch/dd build

# 3. Il lancio, sulla copia
BRAUS_APP_SUPPORT_DIR="$HOME/Braus-copia" \
  .scratch/dd/Build/Products/Debug/Braus.app/Contents/MacOS/Braus
```

L'app compilata è `.scratch/dd/Build/Products/Debug/Braus.app`. Lanciata così usa i tuoi account
veri (portachiavi, Claude, Codex, Ollama) e le tue impostazioni (`dev.forte.Braus`): le
preferenze che cambi qui (per esempio Stanze/Righe) valgono anche per il Braus normale.

Per ricominciare da capo: chiudi l'app, `rm -rf ~/Braus-copia` e rifai il passo 1.

---

## 2. Cosa c'è di nuovo

- **La casa**: una sola finestra, scura. I worker sono stanze illuminate dal loro stato (verde
  libero, ambra al lavoro, blu ti aspetta: approvazione o risposte non lette, luce di luna se non
  configurato), o righe compatte (Impostazioni > Sidebar > Rooms/Rows).
- **Forme**: ogni worker ha una forma (cerchio, quadrato, triangolo, rombo, pentagono, esagono,
  capsula, lente), scelta alla creazione e cambiabile nell'inspector; resta dopo il riavvio.
- **L'eroe** in cima alla conversazione: nome, ruolo e cosa sta facendo («Searched the web for…»,
  «Working»); la stanza scelta si svuota e mostra la targa «In chat with you».
- **Inspector**: sezione Worker modificabile (nome, ruolo, forma) sopra Now, Model, Last Turn.
- **Movimento**: il messaggio vola dal composer nella conversazione o nella coda, la citazione
  vola nella striscia, il cambio di worker sfuma la conversazione e fa saltare l'eroe; sotto
  Riduci movimento tutto diventa dissolvenza.
- **Archivio** nel toolbar della sidebar (popover con Ripristina ed Elimina…), **⌘F** cerca per
  nome e ruolo, **frecce e Invio** nelle stanze.
- **Prestazioni**: stanze fuori vista non disegnano, CPU a riposo bassa (vedi §4).

Corretto durante questa verifica: la prima scelta di un worker dopo l'avvio non dava la tastiera
al composer; la sidebar restava compatta dopo aver riallargato la finestra (anche al riavvio);
«Show the search field» non aveva effetto; frecce premute in fretta portavano il fuoco nel
composer; il punto delle stanze per la tastiera non aveva nome per VoiceOver.

---

## 3. Da provare (in ordine, ~30 minuti)

**Finestra e sidebar**
1. I worker sono in ordine alfabetico e i colori delle stanze corrispondono allo stato.
2. Con una conversazione aperta, in cima non c'è nessuna striscia grigia sotto il toolbar,
   anche scorrendo la conversazione.
3. Stringi la finestra con l'inspector aperto: prima la sidebar diventa compatta, poi l'inspector
   si chiude. Riallargala: la sidebar torna larga (era il difetto corretto oggi).
4. ⌘F, cerca per nome e per ruolo; Impostazioni > Sidebar > «Show the search field» spento toglie
   il campo.

**Tastiera**
5. Clic su una stanza: il cursore va nel composer, anche alla prima scelta dopo l'avvio.
6. Ctrl-Tab dal composer (una o due volte, l'ordine dipende da AppKit) fino alle stanze
   («Workers»), frecce per cambiare worker (il fuoco resta nelle stanze), Invio torna al composer.
   Nel composer Tab indenta: per uscire serve Ctrl-Tab.

**Conversazione**
7. Invio: il messaggio vola, la stanza diventa ambra, l'eroe dice cosa fa, poi torna verde.
8. Durante una risposta: metti in coda due messaggi; prova ‹ ›, Send Now, modifica (clic sul
   testo in coda), rimuovi (×). Stop con ⌘. .
9. Rispondi: passa sopra una risposta e premi il pulsante di risposta; oppure clic sul messaggio
   e ⌘R. La citazione appare sopra il composer, Esc la toglie, il messaggio inviato la porta e un
   clic sulla citazione riporta al messaggio citato.
10. Comandi `/`: `/model`, `/effort`, `/usage`, `/context`, `/compact`, `/new`.
11. Popup del modello nel composer (modello ed effort); Team > Providers….
12. Anello del contesto e contatore nel toolbar: i due popover, Compact e Start Fresh.

**Worker**
13. Nuovo worker (+) con una forma; nell'inspector cambia nome, ruolo e forma; chiudi e riapri
    l'app: restano.
14. Menu contestuale di una stanza (Edit Worker…, Stop Response, Choose Provider…, Archive,
    Delete…) e menu Team; archivia, apri dall'archivio, ripristina, elimina.
15. Badge: risposte non lette (numero, stanza blu) e risposta fallita (!) appaiono e spariscono
    aprendo la conversazione.
16. Esci con una bozza scritta: al riavvio la bozza c'è.

**Solo con te** (qui non si poteva provare)
17. Un worker che usa un'app: riga Computer, luce dello schermo nella stanza, scheda dello
    schermo, finestra propria, ingrandimento, Release Computer.
18. Un'approvazione di un adapter: il foglio e la stanza blu.
19. Riduci movimento e Riduci trasparenza (Impostazioni di Sistema > Accessibilità > Display),
    e un giro con VoiceOver.

---

## 4. Limiti noti e punti aperti

- **Non provati qui** (nessun account vero, nessuna app da guidare): turni veri dei provider,
  Computer/schermo del Seat, approvazioni degli adapter, profili di Chrome nell'inspector,
  Riduci movimento/trasparenza dal vivo (sono impostazioni di sistema), VoiceOver dal vivo (solo
  l'albero di accessibilità), macOS 26 e M1. I test automatici coprono la logica di questi casi.
- **Sidebar compatta**: il campo di ricerca sparisce (come su `main`); il pulsante Archivio finisce
  nel menu » in fondo a destra del toolbar.
- **CPU a riposo**: 0% anche con una conversazione aperta e dopo citazioni, coda, copia del
  codice e Impostazioni > Brain (corretto dopo la verifica: vedi Performance.md §8). Unica
  eccezione: lo slider di sistema della timeline del Brain (e probabilmente quello di Ollama) su
  macOS 27 lascia ~0,7% finché l'app resta aperta; sostituirlo vorrebbe dire disegnare un
  controllo nostro, quindi è una tua decisione.
- **Ordine di Tab**: stanze → ricerca → conversazione → composer (macOS costruisce il giro dalla
  struttura della finestra; nelle righe è lo stesso).
- **Due scelte di prestazioni in sospeso** (Performance.md): griglia «pigra» per squadre grandi
  (cambierebbe un po' il movimento della compattazione) e uscita dalla stanza preparata al
  passaggio del mouse (meno memoria, ma da tastiera parte per un attimo col ripiego).
- **⌘↓** porta in fondo alla conversazione ma non salva la posizione di lettura (solo lo
  scorrimento la salva), come su `main`.
- **Citazioni**: mostrano il markdown grezzo (`**`, ```` ``` ````), come già su `main`.
- **⌘N** apre una nuova finestra, non un nuovo worker (come su `main`); il nuovo worker è il +.
- Prima del primo controllo dei provider il popup dei modelli resta su «Loading models…»: succede
  solo nei lanci isolati (`BRAUS_ISOLATED_RUN=1`), che non controllano i provider all'avvio.

---

## 5. Perché una copia

Questa build aggiunge al database la colonna `shape` dei worker (migrazione leggera, automatica
all'apertura). Una volta aperto con questa build, il workspace potrebbe **non aprirsi più con la
build vecchia** (`main`). Per questo si prova su `~/Braus-copia`: il workspace vero resta
com'è finché la colonna non arriva su `main`.

---

## 6. Se hai un Mac con macOS 26 o un M1

- In cima alla conversazione nessuna striscia grigia (la barra del titolo trasparente), e i vetri
  (composer, toolbar, popover) leggibili.
- Su M1 le stanze usano la luce precalcolata (niente ray tracing): devono accendersi subito e non
  scattare nel ridimensionare la sidebar.
- CPU a riposo con la finestra in vista (Monitoraggio Attività), con 5 e con 30 worker.
- Crea, rinomina, cambia forma, archivia: su macOS 26 i predicati di SwiftData con enum fallivano;
  la forma è salvata come testo proprio per questo.
