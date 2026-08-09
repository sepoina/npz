# Idea progettuale — `freeze`

> Il disegno di **`freeze`**, il progetto da cui `npz` discende. `freeze` non vive
> più in questo repo; il documento resta perché le tre invarianti — un solo lock,
> formato versionato, costruisci prima di cancellare — e le misure che le hanno
> prodotte sono sue, e `npz` le eredita per intero. Dove qui si legge
> `.freeze-blobs`, in `npz` si legge `.npz`.

## Motivazione

Duplichiamo alberi in continuazione, e non è lo spazio a pesare: sono i **file**. Un
`node_modules` sono decine di migliaia di inode che attraversano ogni backup, ogni
indicizzazione, ogni scansione antivirus, ogni `du`. Sette progetti React su questa
macchina fanno **258.450 file**, e nessuno è interessante per chi ci lavora: sono un
effetto collaterale di `npm install`. `freeze` li fa sparire — ogni cartella diventa
**un solo file**, una immagine di sola lettura montabile all'istante.

| | prima | dopo |
| --- | --- | --- |
| file | 258.450 | **7** |
| spazio occupato | 2,2 GiB | **736 MiB** |

Lo spazio è il beneficio secondario, ma è un terzo dell'originale: il contenuto è
testo e si comprime a metà, e il resto lo recupera l'impacchettamento — su ext4 quei
file occupano 2,2 GiB per 1,4 GiB di dati veri, perché ognuno si arrotonda al blocco.

**Anche una cartella sola ci guadagna**: il beneficio viene dal comprimere e
dall'impacchettare, non dal deduplicare. È il punto su cui il progetto ha cambiato
idea a metà strada — voce 5 del [taccuino](<taccuino di viaggio.md>).

**I vincoli**, in ordine: semplicità, scalarità, sicurezza dei dati, snellimento,
velocità di avvio e di uscita, trasparenza — il sistema deve sembrare parte del
sistema operativo — e integrazione, cioè strumenti di sistema ove possibile.

## Obiettivo operativo

| Comando | Effetto |
| --- | --- |
| `freeze init` | dichiara la directory corrente come radice di lavoro |
| `freeze imageA` | prende la cartella `imageA` e sembra farla scomparire |
| `freeze decompress imageA` | la riporta in vita |
| `freeze list` | le immagini presenti |
| `freeze purge` | la procedura di riconciliazione |
| `freeze fsck` | verifica l'integrità e ricostruisce ciò che è derivabile |

Nella radice compare una sola sottocartella di servizio, `.freeze-blobs`, che
contiene tutto. Il punto iniziale la rende invisibile a `ls`, ai file manager e ai
glob: il sistema non si vede, come chiede il vincolo di trasparenza.

## Cosa produce

Una immagine [EROFS] compressa per cartella, e nient'altro. Niente object store,
niente oggetti condivisi, e quindi **niente garbage collection, orfani, refcount né
ciclo di vita da mettere in sicurezza**. Ogni immagine è autosufficiente: si può
copiare, spostare, cancellare da sola. È questa autosufficienza a rendere il sistema
semplice, e la semplicità era il primo dei vincoli.

| Strumento | Ruolo |
| --- | --- |
| **mkfs.erofs** | costruisce l'immagine, contenuti compressi dentro |
| **erofsfuse** | la monta in sola lettura, in user space |
| **fuse-overlayfs** | ci sovrappone il delta scrivibile, in user space |
| **EROFS / overlayfs** (kernel) | l'alternativa privilegiata, più veloce, quando root c'è |

La compressione va scelta **`lz4hc`**: misurata sull'accesso sparso a cache fredda —
il caso peggiore — è più veloce di una immagine non compressa e occupa il 40% in
meno. Qui la compressione non si paga (voce 6 del taccuino).

**Niente privilegi.** Lo stack si monta interamente in user space, verificato da
utente non privilegiato per lettura, scrittura, copy-up, whiteout, rotazione e
consolidamento. La via del kernel è un'ottimizzazione dietro la stessa interfaccia,
non un requisito.

## Dove vive `.freeze-blobs`

`freeze` **risale l'albero** come `git` con `.git`. La radice non serve a definire un
perimetro di deduplicazione — non c'è niente da deduplicare — ma a dare un posto solo
al demone, un lock, una configurazione. Due limiti, entrambi a tutela dei dati: **la
risalita trova, non crea** (lo store nasce solo con un `init` esplicito, altrimenti un
`freeze` lanciato per errore si aggancerebbe in silenzio a una radice otto livelli più
su), e **si ferma al confine di filesystem**, perché l'upperdir di overlayfs deve
stare sullo stesso filesystem del suo workdir.

Serve un filesystem che regga un `upperdir` e conservi i permessi POSIX, il che
esclude di fatto tutto ciò che passa da FUSE. La dimensione invece non dipende dal
supporto: l'immagine è un file solo, niente arrotondamento al blocco, niente reflink.

## Come è fatto dentro

```text
~/lavoro/                          ← radice: qui è stato lanciato `freeze init`
├── .freeze-blobs/
│   ├── static/cliente-x/node_modules.img · .meta   ← immagini, sola lettura
│   └── dynamic/cliente-x/node_modules/             ← delta, il "purgatorio"
├── cliente-x/node_modules.freeze.txt   ← segnaposto: congelata
└── cliente-y/node_modules/             ← congelata, ma attualmente montata
```

`static/` e `dynamic/` **rispecchiano il percorso relativo alla radice**, perché il
solo nome non basta a identificare un'immagine: un `node_modules` in `cliente-x/` e
uno in `cliente-y/` collidono. È la **catena inversa** — dal segnaposto si risale
alla radice, e da lì si ridiscende nello store. Il percorso è così esso stesso
l'indice: nessun registro da tenere allineato, `list` è una scansione di `static/`, e
lo stato resta ispezionabile a mano.

**Il segnaposto.** Dove c'era la cartella resta `imageA.freeze.txt`, che dichiara
apertamente di non essere un archivio: dice dove la cartella va ricreata, che
copiarlo non copia nulla, e le due date del ciclo di vita. **Non è mai la fonte di
verità** — tutto è derivato dal `.meta`, e `fsck` lo rigenera. Fa eccezione un caso
solo: se la cartella che lo contiene viene **rinominata**, la catena inversa si
spezza e il segnaposto è l'unico posto in cui sopravvive il percorso originale.

**Quando il mount non c'è più**, il mountpoint resta lì **vuoto**, che è l'aspetto
esatto di una perdita di dati. Dentro si crea perciò un file nascosto sul filesystem
sottostante, `.freeze_fsck_for_reconstruct_this_dir`: col mount attivo è coperto
dall'overlay, senza mount è l'unica cosa presente e dichiara nel proprio nome tanto il
problema quanto il rimedio.

**Il freeze e il decompress.** L'immagine si costruisce **subito**: si crea in
`static/`, nasce il delta vuoto, e **solo allora** la cartella originale scompare.
Costruire da subito è economico — 258.450 file in 8,5 s — e fa sì che il beneficio si
veda al primo `freeze`. Il `decompress` ricrea la cartella, monta l'immagine e ci
sovrappone il delta: meno di un decimo di secondo.

## Come evolve l'immagine statica

C'è un tempo di cristallizzazione `tc`, ipotizziamo una settimana, e **a comandare è
il timestamp dell'immagine, non quello dei singoli file**. A ogni `purge`: delta fermo
da più di `tc` → consolidamento totale; delta oltre il **30%** della dimensione
dell'immagine → consolidamento alla prima finestra; altrimenti si lascia stare.

La soglia dimensionale esiste perché il tempo da solo non basta: una cartella su cui
si lavora ogni giorno non raggiunge mai `tc`, e per via del copy-up basta un
`npm install` perché interi file finiscano nel delta — senza soglia il contenuto
esisterebbe due volte.

**Il merge lo fa il kernel**: si rimonta lo stack in sola lettura e si dà a
`mkfs.erofs` la vista già fusa. Nessuna logica di whiteout da scrivere. **I tre
tempi**: si ruota il delta e si costruisce la nuova immagine su un nome temporaneo,
senza toccare nulla di esistente; si applica con un rename atomico; **solo allora** si
cancella il delta *ruotato*.

La rotazione non è un abbellimento: senza, fra la lettura del delta e il suo
svuotamento passa tutto il tempo di costruzione, e le scritture dell'utente in
quell'intervallo sparirebbero. Va fatta fra smontaggio e rimontaggio — overlayfs non
tollera che i propri layer cambino sotto di sé — al costo di **17 ms**. Ragionare per
immagine anziché per file evita di riconciliare un delta a metà, e rende ogni `purge`
atomico e ripetibile.

## Perimetro

Quasi tutto si congela: EROFS conserva hardlink con `nlink` e stesso inode, fifo,
socket, device node, symlink rotti, xattr utente e permessi, e i file sparsi non si
riespandono — 64 MiB stanno in 319 KiB. I divieti iniziali erano imposti dall'object
store, non dal formato, e sono caduti con lui. Restano due casi: **processi attivi**
dentro la cartella, che fanno rifiutare l'operazione (`fuser -m`, o `/proc/*/cwd`), e
**ownership che richiede privilegi**, che fa avvisare che serve `sudo`. Su
quest'ultima: uid e gid finiscono correttamente nell'immagine, ma un mount FUSE non
privilegiato non li rende accessibili ad altri utenti senza `allow_other` — e
`freeze` lo dice prima di cominciare, invece di produrre un ripristino
silenziosamente sbagliato.

## Invarianti operative

Tre regole per ogni operazione che scrive. Costano poco adesso e molto dopo.

**Prima si costruisce, poi si applica, infine si cancella.** Nessuna operazione
distruttiva precede la creazione della struttura che la sostituisce; il corollario è
che ciò che si cancella al terzo tempo non deve mai essere ciò che il sistema sta
ancora usando — da qui la rotazione. Ne discende una proprietà preziosa: **ogni
operazione è idempotente**, quindi non serve un journal.

**Un solo lock.** Ogni scrittura prende un `flock` esclusivo su `.freeze-blobs/lock`.
Un lock granulare si potrà sempre aggiungere; introdurre il *primo* lock in un codice
scritto assumendo l'esclusività è invece doloroso.

**Il formato è versionato.** Un campo `version` in `config` e in ogni `.meta`, più
versione EROFS e algoritmo di compressione. Senza, il primo cambio di formato
renderebbe illeggibili le immagini esistenti — cioè perderebbe dati.

## Fuori scope in questa fase

- **Deduplicazione fra cartelle.** Misurata e scartata: costa il 50% di spazio in più
  della semplice compressione, migliaia di inode, sei volte il tempo di costruzione, e
  richiede root ([taccuino](<taccuino di viaggio.md>), voce 5).
- **Situazioni e flag** per rendere sicuro l'approccio, e la **cancellazione di una
  cartella**.

## Rimandi

- [taccuino di viaggio.md](<taccuino di viaggio.md>) — le misure, e le idee che hanno
  smontato.
- [piano di implementazione.md](<piano di implementazione.md>) — il piano di `npz`,
  che di questo disegno eredita le invarianti.

[EROFS]: https://docs.kernel.org/filesystems/erofs.html
