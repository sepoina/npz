# Taccuino di viaggio

Le decisioni della fase 1 e i numeri che le hanno prodotte. Quasi ogni voce è
un'idea ragionevole smontata da una misura. Il disegno che ne è uscito è in
[claim.md](claim.md); le misure di `npz` stanno in
[report-fase0.md](../archive/npz_python-0.2.7.tar.gz) (nell'archivio del Python). Le
voci **5**, **6** e **7**
sono quelle che il [piano fase 2](<piano di implementazione fase 2.md>) rimette in
discussione.

---

**1. Il disco di lavoro non può ospitare il sistema.** NTFS via `ntfs-3g` è FUSE:
`chmod 700` viene riletto come `777`, e overlayfs non accetta un `upperdir` su FUSE.
Senza permessi il round-trip byte a byte è impossibile per costruzione. Ha morso una
seconda volta: un loop device su file servito da FUSE accumula pagine sporche più in
fretta di quanto il demone le scarichi, e il kernel esaurisce la memoria. Si rifiuta
anche il backing, non si sconsiglia.

**2. Lo stack di montaggio regge.** Copy-up, whiteout, `fsync` e il `rename` fra
directory diverse — il candidato più probabile alla rottura — funzionano su entrambe
le vie provate, e dopo ogni scrittura l'immagine statica resta bit-identica. È
l'unica voce in cui la misura ha confermato l'ipotesi.

**3. Il merge lo fa il kernel.** Non si leggono whiteout né xattr: si rimonta lo
stack in sola lettura e si dà al costruttore **la vista già fusa**. Il `purge` sono
tre righe. Costa O(albero) e non O(delta), ma vale il **4%** del primo freeze:
rileggere costa molto meno che costruire. Il timore era fondato nella forma e
irrilevante nella grandezza.

**4. La rotazione del delta, ovvero un bug nel disegno.** Fra la lettura del delta e
il suo svuotamento passa tutto il tempo di costruzione, e le scritture dell'utente in
quell'intervallo sparirebbero — una perdita silenziosa dentro l'operazione che deve
mettere i dati al sicuro. Il delta si **ruota** al primo tempo, e il terzo cancella
il ruotato. Va fatto fra smontaggio e rimontaggio, perché overlayfs non tollera che i
propri layer cambino sotto di sé: **17 ms**.

---

## 5. La deduplicazione non paga

Smonta la premessa da cui il progetto era nato: un object store content-addressed
condiviso, e nessun beneficio per una cartella isolata.

Su tre copie identiche la dedup è quasi perfetta (−66,4% in byte, contro un massimo
teorico del −66,7%). Su **quattro progetti reali e distinti**, 95.952 file:
**−1,1%**. La dedup pura valeva −12,6%, i metadati +11,4%, e lo spazio degli oggetti
era per il **54% arrotondamento al blocco** — taglia media 2.816 byte. Metà dello
store era aria.

La variabile decisiva non è quanta duplicazione ci sia, ma **quanto sono grandi i
file**: in un `node_modules` il 97% sta sotto i 5 KB. Sotto la dimensione del blocco,
un object store che tiene un file per oggetto non può vincere.

L'ibrido — piccoli inline, grandi nello store — è fattibile e perde lo stesso. Sette
progetti reali, 258.450 file:

| cartelle | ibrido | compresso |
| --- | --- | --- |
| 1 | 54,8 MiB | **26,4 MiB** |
| 3 | 88,9 MiB | **44,1 MiB** |
| 5 | 225,8 MiB | **125,3 MiB** |
| 7 | 1,1 GiB | **736,3 MiB** |

La dedup *stava funzionando* — il rapporto cumulato scendeva da 2,08 a 1,53 — ma il
costo **marginale** non è mai sceso sotto **1,29**, e per un incrocio dovrebbe
scendere sotto 1: cioè una nuova cartella dovrebbe essere già quasi tutta nello
store, che è la definizione di copia.

Il conto di fondo: la compressione toglie il **48%** dei byte, la dedup circa il
**20%**, e deduplicare con gli strumenti disponibili significa rinunciare a
comprimere. **Niente object store**: una immagine compressa autosufficiente per
cartella. Cadono con lui garbage collection, orfani, refcount e ciclo di vita
condiviso — la parte più delicata del progetto — e il requisito di root. E la
premessa si rovescia: il beneficio viene dal comprimere e dall'impacchettare, quindi
**una cartella isolata ci guadagna**.

*Non misurato:* l'handicap dell'ibrido è la compressione mancante, non la dedup. Su
btrfs con `compress=zstd` l'esito potrebbe rovesciarsi.

## 6. La compressione non costa: accelera

Il carico che conta è un bundler che risolve moduli — accessi sparsi, ordine non
prevedibile — cioè il caso peggiore, perché l'ordine casuale annulla il readahead. A
cache fredda, su 5.000 file:

| | grezzo | lz4hc | zstd |
| --- | --- | --- | --- |
| file/s | 7.874 | **8.591** | 7.974 |
| latenza mediana | 122,6 µs | **108,9 µs** | 122,2 µs |
| spazio | 191,4 MiB | 113,8 MiB | 112,5 MiB |

**`lz4hc` è più veloce del non compresso** e occupa il 40% in meno: comprimere
significa leggere meno byte, e `lz4` decomprime più in fretta di quanto il supporto
consegni. `zstd` comprime uguale ma decomprime più lentamente. La compressione non è
una voce da valutare in futuro: è il meccanismo principale del risparmio.

---

**7. I privilegi: da obbligatori a non necessari.** Prima conclusione:
`fuse-overlayfs` non implementa i layer data-only (`lowerdir=a::b`), che è il
meccanismo con cui composefs rimanda al suo object store — quindi serve root. Ma quel
verdetto valeva per lo store, non per lo stack: **senza store il `::` non serve**, e
tutto funziona da utente non privilegiato. Vale la pena notare l'ordine: **è stata la
rinuncia alla dedup a regalare l'esecuzione non privilegiata.** Non era un obiettivo,
è arrivata come conseguenza.

**8. Il perimetro si è svuotato.** I divieti di partenza — hardlink, socket, fifo,
device node, file sparsi — erano imposti dall'object store, non da EROFS, che
conserva tutto (un file sparso da 64 MiB sta in 319 KiB). Restano **processi attivi**
e **ownership che richiede privilegi**. Il rifiuto degli hardlink era comunque giusto
quando fu scritto: nello store la struttura si perdeva *in silenzio*.

---

## 9. Errori di misura che hanno rischiato di sviare

Ognuno ha prodotto per un po' una conclusione sbagliata che sembrava solida.

- **`du -sb` misura la dimensione apparente**, non l'occupazione: i file sparsi
  risultavano innocui. Serve `du -s --block-size=1`.
- **`du -s` con più argomenti stampa una riga per argomento**: un `tail -1` ha fatto
  risultare 17 MiB un sorgente da 181.
- **`printf '%.3f'` rifiuta il punto decimale sotto locale italiano**: tutti i tempi
  uscivano `0,000`. Serve `LC_NUMERIC=C`.
- **Una funzione dentro `$(...)` gira in un subshell**, e perde ogni globale che
  tocca. Capitato due volte, la seconda cancellando tutte le misure.
- **`mount -o loop` marca il device `AUTOCLEAR`**, che si stacca in modo asincrono: il
  successivo riprende lo stesso numero mentre la page cache conserva i blocchi del
  precedente. Serve `losetup --find --show` più `blockdev --flushbufs`.
- **Un banco su btrfs non dice cosa succede su ext4**: i file sparsi risultavano
  preservati perché il reflink clona anche i buchi. Giusto per il testbed, sbagliato
  per l'utente.
- **Il conteggio dei file va in timeout in silenzio**: 155.298 file misurati 57.811.

---

## Quel che resta aperto

- **Il linguaggio della CLI** — *chiuso da N6 e dal
  [piano Go](<piano di implementazione go.md>): il movente è la distribuzione, non la
  velocità.*
- **Il costo del `purge` su alberi molto grandi**, misurato fino a 12.000 file —
  *risposto da N4: tredici secondi, sette volte il 4% atteso.*
- **La taratura di `tc` e della soglia del 30%.** Nessun test la può dare: serve la
  crescita giornaliera del delta sull'uso reale.
