# Idea progettuale — `freeze`

> Questo è il disegno di **`freeze`**, il progetto da cui `npz` discende. `freeze`
> non vive più in questo repo; il documento resta perché le tre invarianti — un
> solo lock, formato versionato, costruisci prima di cancellare — e le misure che
> le hanno prodotte sono sue, e `npz` le eredita per intero. Dove qui si legge
> `.freeze-blobs`, in `npz` si legge `.npz`: è la parametrizzazione del §4 del
> [piano di implementazione](<piano di implementazione.md>).

## Motivazione

Sempre più spesso duplichiamo alberi nello sviluppo del software. Non è tanto lo
spazio a pesare: sono i **file**. Un `node_modules` sono decine di migliaia di
inode che attraversano ogni backup, ogni indicizzazione, ogni scansione
antivirus, ogni `du` lanciato per capire dove sia finito il disco. Sette progetti
React su questa macchina fanno **258.450 file**. Non uno di quei file è
interessante per chi ci lavora: sono un effetto collaterale di `npm install`.

`freeze` li fa sparire. Ognuna di quelle cartelle diventa **un solo file**, una
immagine di sola lettura montabile all'istante. Sette cartelle, sette file.

| | prima | dopo |
| --- | --- | --- |
| file | 258.450 | **7** |
| spazio occupato | 2,2 GiB | **736 MiB** |

Lo spazio è il beneficio secondario, ma non è piccolo: un terzo dell'originale,
perché il contenuto di un albero di dipendenze è JavaScript e JSON, cioè testo,
e il testo si comprime a metà. Il resto lo recupera l'impacchettamento: su ext4
un albero di 258.450 file occupa 2,2 GiB per 1,4 GiB di dati veri, perché ogni
file si arrotonda al blocco. Mettendoli tutti dentro una immagine, quello spreco
sparisce.

**Anche una cartella sola ci guadagna.** Non serve che esistano copie multiple,
non serve condivisione fra progetti: il beneficio viene dal comprimere e
dall'impacchettare, non dal deduplicare. Questo è un punto su cui il progetto ha
cambiato idea a metà strada, e il perché sta nel
[taccuino di viaggio](<taccuino di viaggio.md>).

## Vincoli

| Vincolo | Significato |
| --- | --- |
| **Semplicità** | il sistema non deve apparire complesso |
| **Scalarità** | il sistema non deve inchiodare a fronte della complessità |
| **Sicurezza** | il sistema non deve perdere dati |
| **Snellimento** | il sistema deve ridurre significativamente il file sparse |
| **Velocità di avvio** | il sistema deve avviarsi velocemente |
| **Velocità di uscita** | il sistema deve fermarsi velocemente |
| **Trasparenza** | il sistema deve sembrare parte del sistema operativo |
| **Integrazione nel s.o.** | utilizzo di strumenti di sistema ove possibile, per velocizzare l'applicativo |

## Obiettivo operativo

Nel sistema operativo Linux c'è un nuovo comando `freeze`.

| Comando | Effetto |
| --- | --- |
| `freeze init` | dichiara la directory corrente come radice di lavoro |
| `freeze imageA` | prende la cartella `imageA` e sembra farla scomparire |
| `freeze decompress imageA` | riporta in vita la sottocartella `imageA` |
| `freeze list` | torna la lista delle immagini presenti |
| `freeze purge` | lancia la procedura di riconciliazione (vedi oltre) |
| `freeze fsck` | verifica l'integrità e ricostruisce ciò che è derivabile |

Nella radice compare una sola sottocartella di servizio, `.freeze-blobs`, che
contiene tutto: immagini, delta e metadati. Il punto iniziale la rende invisibile
a `ls`, ai file manager e ai glob della shell — il sistema non si vede, come
richiede il vincolo di trasparenza.

## Cosa produce `freeze`

Una immagine [EROFS] compressa per cartella congelata, e nient'altro. Non c'è un
object store, non ci sono oggetti condivisi fra immagini, e di conseguenza non
esistono garbage collection, oggetti orfani, refcount da mantenere allineati né
un ciclo di vita da mettere in sicurezza. **Ogni immagine è autosufficiente**:
si può copiare, spostare, cancellare da sola, e ciò che vale per una non tocca
le altre.

Questa autosufficienza è ciò che rende il sistema semplice, e la semplicità era
il primo dei vincoli.

| Strumento | Ruolo |
| --- | --- |
| **mkfs.erofs** | costruisce l'immagine, con i contenuti compressi dentro |
| **erofsfuse** | la monta in sola lettura, in user space |
| **fuse-overlayfs** | ci sovrappone il delta scrivibile, in user space |
| **EROFS** (kernel) | l'alternativa privilegiata, più veloce, quando root c'è |
| **overlayfs** (kernel) | idem, per il delta |

La compressione va scelta **`lz4hc`**. Misurato sull'accesso sparso a cache
fredda — il carico di un bundler che risolve moduli, che è il caso peggiore —
un'immagine compressa `lz4hc` è **più veloce** di una non compressa e occupa il
40% in meno: comprimere significa leggere meno byte dal supporto, e `lz4`
decomprime più in fretta di quanto il supporto consegni. `zstd` comprime uguale
ma decomprime più lentamente, e torna ai tempi del grezzo senza guadagnare
spazio. La compressione, in questo sistema, **non si paga**.

### Niente privilegi

Lo stack si monta interamente in user space: `erofsfuse` per lo strato di sola
lettura, `fuse-overlayfs` per il delta. Verificato da utente non privilegiato:
lettura, scrittura nel delta, copy-up, whiteout, rotazione del delta e
consolidamento funzionano tutti senza `sudo`.

Dove root è disponibile si può usare la via del kernel — `mount -t erofs` più
`mount -t overlay` — che è più veloce. Ma è un'ottimizzazione, non un requisito,
e il modulo di mount tiene le due dietro la stessa interfaccia.

## Dove vive `.freeze-blobs`

`freeze` non è vincolato alla cartella corrente: **risale l'albero** come fa
`git` con `.git`, e si aggancia al primo `.freeze-blobs` che incontra. Lo si può
quindi lanciare da qualsiasi sottocartella.

La radice non serve più a definire un perimetro di deduplicazione — non c'è
niente da deduplicare. Serve a dare un posto solo al demone, un solo lock, una
sola configurazione, e a tenere l'albero autosufficiente e trasportabile.

Due limiti alla risalita, entrambi a tutela dei dati:

- **La risalita trova, non crea.** Lo store nasce solo con un `freeze init`
  esplicito. Altrimenti un `freeze` lanciato per errore in una directory
  qualsiasi si aggancerebbe in silenzio a una radice che sta otto livelli più su,
  e l'utente non avrebbe idea di dove siano finiti i suoi dati.
- **La risalita si ferma al confine di filesystem.** Lo strato scrivibile di
  overlayfs deve stare sullo stesso filesystem del suo workdir, quindi una radice
  trovata oltre un mount point sarebbe inutilizzabile.

Non tutti i filesystem possono ospitare `.freeze-blobs`, e `freeze init` deve
rifiutarsi di crearlo dove non ha senso. Il requisito è che il filesystem regga
un `upperdir` di overlayfs e conservi i permessi POSIX — il che esclude di fatto
tutto ciò che passa da FUSE. Su NTFS via `ntfs-3g`, per dirne una misurata,
`chmod 700` viene riletto come `777`: i permessi non sopravvivono nemmeno al giro
di andata.

Il filesystem sottostante non incide invece sulla dimensione: l'immagine è un
file solo, quindi non c'è arrotondamento al blocco da pagare e non serve il
reflink.

## Cosa avviene dietro le quinte

### La struttura interna è di questo tipo

```text
~/lavoro/                            ← radice: qui è stato lanciato `freeze init`
│
├── .freeze-blobs/
│   │
│   ├── static/                      ← immagini EROFS, sola lettura
│   │   ├── cliente-x/
│   │   │   ├── node_modules.img
│   │   │   └── node_modules.meta
│   │   └── cliente-y/
│   │       ├── node_modules.img
│   │       └── node_modules.meta
│   │
│   └── dynamic/                     ← delta scrivibili, il "purgatorio"
│       ├── cliente-x/node_modules/
│       └── cliente-y/node_modules/
│
├── cliente-x/
│   ├── src/
│   └── node_modules.freeze.txt      ← segnaposto: congelata
│
└── cliente-y/
    ├── src/
    └── node_modules/                ← congelata, ma attualmente montata
```

### La catena inversa

Poiché la radice può trovarsi molti livelli sopra la cartella su cui si sta
lavorando, il solo nome dell'immagine non basta a identificarla: un
`node_modules` congelato in `cliente-x/` e uno in `cliente-y/` collidono.

Per questo `static/` e `dynamic/` **rispecchiano il percorso relativo alla
radice**. È la catena inversa: dal segnaposto si risale alla radice, e dalla
radice si ridiscende nello store fino all'immagine corrispondente.

```text
   cliente-x/node_modules.freeze.txt
        │
        │  risalita fino alla radice
        ▼
   ~/lavoro/.freeze-blobs/
        │
        │  ridiscesa lungo lo stesso percorso relativo
        ▼
   static/cliente-x/node_modules.img   +   dynamic/cliente-x/node_modules/
```

Il percorso diventa così esso stesso l'indice: nessun registro separato da
tenere allineato, `freeze list` è una scansione di `static/`, e lo stato resta
ispezionabile a mano con i normali strumenti di sistema.

### Il segnaposto

Dove c'era la cartella congelata resta un piccolo file di testo,
`imageA.freeze.txt`. Non è un archivio, e lo dichiara apertamente: è un
segnaposto leggibile che spiega cosa è successo e come tornare indietro.

```text
Questa non è una cartella compressa: è un segnaposto.
La cartella "node_modules" è stata congelata dal comando `freeze`.
I dati NON si trovano in questo file: copiarlo altrove non copia nulla.

Per riportarla in vita:      freeze decompress node_modules

radice           ../.freeze-blobs
percorso         cliente-x/node_modules
immagine         static/cliente-x/node_modules.img
creata           2026-07-31 15:44:02
incardinata      2026-08-07 03:12:55

File generato automaticamente: se viene cancellato, `freeze fsck` lo ricostruisce.
```

Il segnaposto assolve tre funzioni: dice **dove** la cartella va ricreata,
dichiara **cosa non è** — disinnescando l'illusione di avere fra le mani un file
da backuppare — e riporta le due date che raccontano il ciclo di vita
dell'immagine, quella di costruzione e quella di incardinamento nell'immagine
statica.

**Il segnaposto non è mai la fonte di verità.** Tutto ciò che contiene è
derivato dai metadati conservati in `.freeze-blobs` (il file `.meta` accanto
all'immagine): se un `rm`, un tool di build o una `.gitignore` distratta lo
fanno sparire, non si è perso nulla e `freeze fsck` lo rigenera.

Fa eccezione un caso solo: se la cartella che contiene il segnaposto viene
**rinominata**, la catena inversa si spezza, e il segnaposto è l'unico posto in
cui sopravvive il percorso originale. Per quel caso è autorevole, e `fsck` deve
saperlo usare per riagganciare.

### Quando il mount non c'è più

Al montaggio il segnaposto sparisce e la cartella prende il suo posto. Ma il
mountpoint è una cartella vera sul filesystem sottostante: se il mount cade —
un riavvio, un `umount`, uno smontaggio di sistema — quella cartella resta lì
**vuota**. È l'aspetto esatto di una perdita di dati, e sarebbe la reazione
istintiva di chiunque la trovasse così.

Dentro il mountpoint viene perciò creato un file nascosto,
`.freeze_fsck_for_reconstruct_this_dir`, che risiede sul filesystem sottostante:

- con il mount attivo è **coperto dall'overlay**, quindi invisibile;
- senza mount è **l'unica cosa presente** nella cartella, e dichiara nel proprio
  nome tanto la natura del problema quanto il modo di risolverlo.

Del ripristino vero e proprio si occuperà il demone. Nel frattempo il file rende
la situazione riconoscibile sia a occhio sia a `freeze fsck`.

### Il freeze, la prima volta

L'immagine viene creata **subito**, non dopo un periodo di attesa:

- `mkfs.erofs` costruisce l'immagine compressa nel percorso rispecchiato dentro
  `static/`, contenuti inclusi;
- il delta scrivibile in `dynamic/` nasce vuoto;
- **solo a questo punto** la cartella originale scompare e al suo posto compare
  `imageA.freeze.txt`.

```text
   PRIMA                          DOPO

   cliente-x/                     cliente-x/
   └── node_modules/              └── node_modules.freeze.txt   ← segnaposto
       ├── src/
       │   ├── a.js               .freeze-blobs/
       │   └── b.js               ├── static/…/node_modules.img ← tutto qui dentro
       └── pkg/                   └── dynamic/…/node_modules/   ← vuota
           └── c.js
```

Costruire l'immagine da subito è economico — 258.450 file in 8,5 secondi — e fa
sì che il beneficio si manifesti al primo `freeze`, non a distanza di giorni.

### Il decompress

- nuova creazione della cartella `imageA` al posto del segnaposto;
- montaggio dell'immagine come strato di sola lettura;
- sovrapposizione del delta in `dynamic/` come strato scrivibile;
- tutte le modifiche finiscono nel delta, mentre l'immagine statica resta tale.

```text
                 imageA/            ← ciò che l'utente vede
                    ▲
        ┌───────────┴───────────┐
        │                       │
   dynamic/…/imageA        static/…/imageA.img
   scrivibile              sola lettura
   (le modifiche)          (tutto il contenuto)
```

Il montaggio costa meno di un decimo di secondo.

## Come evolve l'immagine statica

Questa è la parte centrale del progetto. In una fase iniziale la cosa può
avvenire manualmente, ma si prevede l'esistenza di un daemon che lavori a basso
livello.

La regola generale è che ci sia un tempo di cristallizzazione, chiamiamolo `tc`,
ipotizziamo una settimana. **A comandare è il timestamp dell'immagine, non
quello dei singoli file.**

Al lancio della procedura di riconciliazione (`freeze purge`) ogni immagine viene
guardata nel suo insieme. Due condizioni indipendenti possono farla consolidare:

| Condizione | Azione |
| --- | --- |
| delta fermo da più di `tc` | **consolidamento totale** |
| delta cresciuto oltre il **30%** della dimensione dell'immagine | **consolidamento alla prima finestra utile** |
| nessuna delle due | **si lascia stare** |

La seconda condizione esiste perché il tempo da solo non basta. Una cartella su
cui si lavora ogni giorno non raggiunge mai `tc`, e per via del copy-up di
overlayfs basta un `npm install` o un `chmod -R` perché interi file vengano
copiati nel delta: senza una soglia dimensionale il contenuto finirebbe per
esistere due volte, nell'immagine e nel delta, annullando il risparmio.

### Il merge lo fa il kernel

Il consolidamento non interpreta whiteout né xattr. Si rimonta lo stack in sola
lettura e si dà a `mkfs.erofs` **la vista già fusa**, che è il modo in cui
overlayfs presenta il risultato del merge. Verificato end-to-end: whiteout
assorbiti, directory opache risolte, permessi e symlink conservati, e l'immagine
risultante coincide byte a byte con ciò che l'utente vedeva prima.

Il consolidamento sono tre righe, e non c'è alcuna logica di merge da scrivere né
da mantenere.

### I tre tempi

1. **rotazione e costruzione** — il delta corrente viene rinominato in un nome
   di lavoro e al suo posto ne nasce uno vuoto; la nuova immagine viene generata
   dalla vista fusa del delta ruotato, su un nome temporaneo; nulla di esistente
   viene toccato;
2. **applicazione** — la nuova immagine sostituisce la precedente con un rename
   atomico;
3. **cancellazione** — solo ora il delta *ruotato* viene rimosso e la data di
   incardinamento registrata nei metadati.

La rotazione non avviene sotto il mount attivo: overlayfs non tollera che i
propri layer cambino sotto di sé. Va fatta fra uno smontaggio e un rimontaggio,
che misurati costano **17 millisecondi** di indisponibilità.

La rotazione al primo tempo non è un abbellimento: senza, il consolidamento
perde dati. Fra la lettura del delta e il suo svuotamento passa tutto il tempo di
costruzione dell'immagine, e in quell'intervallo l'utente può scrivere. Quelle
scritture verrebbero cancellate senza essere mai entrate nell'immagine — una
perdita silenziosa proprio dentro l'operazione che dovrebbe mettere i dati al
sicuro. Ruotando il delta prima di leggerlo, le scritture successive atterrano
nel delta nuovo e sopravvivono: verificato scrivendo nella cartella mentre il
consolidamento era in corso, e ritrovando la scrittura al suo posto a operazione
conclusa.

In questo modo i file molto dinamici evitano operazioni di scrittura infinita
sull'immagine: finché ci si lavora sopra, non viene mai toccata. Una cartella
ferma per più di una settimana finisce invece interamente per diventare immagine
statica. `dynamic` è l'immagine di un "purgatorio".

Ragionare per immagine anziché per singolo file evita di dover riconciliare un
delta a metà — con whiteout e cancellazioni applicati solo in parte — e rende
ogni `purge` un'operazione atomica e ripetibile.

## Perimetro: cosa si può congelare

Quasi tutto. EROFS conserva hardlink con il loro `nlink` e lo stesso inode, fifo,
socket, device node, symlink rotti, xattr utente e permessi; e i file sparsi non
vengono riespansi, perché la compressione riduce gli zeri a nulla — un file
sparso da 64 MiB entra in un'immagine da 319 KiB. Tutti i divieti che il progetto
si era dato all'inizio erano imposti dall'object store, non dal formato, e sono
caduti con lui.

Restano due casi:

| Condizione | Comportamento |
| --- | --- |
| processi attivi dentro la cartella | **rifiuta** |
| ownership che richiede privilegi | **avvisa** che serve `sudo`, altrimenti procede a livello utenza |

I processi attivi si rilevano con `fuser -m`, o leggendo `/proc/*/cwd` dove
`fuser` non c'è.

Sull'ownership: se l'albero appartiene interamente all'utente, freeze e
ripristino funzionano senza privilegi. Se contiene file di altri utenti, l'uid e
il gid finiscono correttamente nell'immagine, ma un mount FUSE non privilegiato
non li rende accessibili agli altri utenti senza `allow_other` — e `freeze` lo
dice prima di cominciare, invece di produrre un ripristino silenziosamente
sbagliato.

## Invarianti operative

Tre regole che valgono per ogni operazione che scrive. Vanno rispettate fin
dalla prima implementazione: costano poco adesso e molto dopo.

**Prima si costruisce, poi si applica, infine si cancella.** Nessuna operazione
distruttiva precede la creazione della struttura che la sostituisce. Vale per il
freeze — l'immagine esiste ed è verificata prima che la cartella originale
sparisca — e vale per il purge. Il corollario operativo è che ciò che si cancella
al terzo tempo non deve mai essere ciò che il sistema sta ancora usando: da qui
la rotazione del delta.

Ne discende una proprietà preziosa: **ogni operazione è idempotente**. Se manca
la corrente a metà, rilanciarla porta allo stesso risultato — riapplicare un
delta a un'immagine che lo contiene già produce la stessa immagine, e cancellare
ciò che è già assente è un no-op. Non serve un journal.

**Un solo lock.** Ogni operazione che scrive prende un `flock` esclusivo su
`.freeze-blobs/lock`. Due `freeze` in parallelo, o il futuro demone insieme alla
CLI, altrimenti si pestano i piedi. Un lock granulare si potrà sempre aggiungere;
introdurre il *primo* lock in un codice scritto assumendo l'esclusività è invece
doloroso.

**Il formato è versionato.** Un campo `version` in `.freeze-blobs/config` e in
ogni `.meta`, più la versione del formato EROFS e l'algoritmo di compressione
usati per generare l'immagine. Senza, il primo cambio di formato renderebbe
illeggibili le immagini esistenti — cioè perderebbe dati.

## Fuori scope in questa fase

- **Deduplicazione fra cartelle.** Misurata e scartata: su progetti reali e
  distinti costa il 50% di spazio in più della semplice compressione, migliaia
  di inode, sei volte il tempo di costruzione, e richiede root. Paga solo su
  copie quasi identiche. Il ragionamento completo è nel
  [taccuino di viaggio](<taccuino di viaggio.md>).
- **Situazioni e flag** che saranno necessari per rendere sicuro l'approccio
  (duplicazione cartelle in elaborazione, etc).
- **Cancellazione di una cartella.** Al momento essa sopravvive perché è solo
  speculare di qualcosa che si trova in `.freeze-blobs`.

## Rimandi

- [taccuino di viaggio.md](<taccuino di viaggio.md>) — cosa è stato misurato,
  cosa ne è seguito, e le idee che i numeri hanno smontato.
- [piano di implementazione.md](<piano di implementazione.md>) — il piano di `npz`,
  che di questo disegno eredita le invarianti.

Il piano di `freeze` e i suoi banchi — `test/fase1.sh`, `test/confronto.sh` — sono
usciti da questo repo insieme al suo codice.
