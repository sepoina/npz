# npz — piano di implementazione, fase 2

La fase 1 ha consegnato un wrapper che funziona: una immagine, un delta, un
consolidamento. La fase 2 tocca l'unica cosa che la fase 0 ha misurato e che
nessuno aveva stimato — **i tredici secondi del consolidamento** — e lo fa con
una sola idea: *smettere di avere una immagine sola.*

Non è un'ottimizzazione del meccanismo esistente. Cambia `FORMATO`, e va decisa
con la stessa disciplina della fase 0: **nessun codice di prodotto prima dei
numeri di §10.**

---

## 1. Da dove nasce: una immagine sola fa pagare tutto a ogni cambiamento

Il numero da cui parte tutto sta in
[report-fase0.md](../npz_python/test/report-fase0.md), N4: **12–15 s** per assorbire un delta,
contro **1,74 s** del primo freeze. È la voce di costo più alta del progetto, e
il piano principale la dichiara «il prezzo vero di `npz`».

La ragione non è la velocità di `mkfs.erofs`. È la granularità:

| | misurato | |
| --- | --- | --- |
| `mkfs.erofs` su 588 MiB da ext4 | **1,74 s** | il primo freeze |
| consolidamento dalla vista fusa | **12–15 s** | rilegge gli stessi byte attraverso due strati FUSE |
| delta dopo un `npm install` | **5,4 MiB, 1.056 voci** | il 3% delle voci dell'albero |

Un'installazione tocca circa **1.056 voci su 31.667**, cioè — a 36 voci per
pacchetto sulla fixture — **una decina di pacchetti su 879**. E per assorbirle si
ricostruisce l'intera immagine, rileggendo attraverso FUSE anche gli 869
pacchetti che nessuno ha toccato. **Il costo è proporzionale all'albero, il
cambiamento all'installazione**, e i tredici secondi sono esattamente quel
rapporto.

Da cui la domanda della fase 2, che è una sola: **si può rendere il costo
proporzionale a ciò che è cambiato?**

---

## 2. K, e i due costi che tirano in direzioni opposte

Chiamiamo **K** il numero di immagini che compongono lo strato di sola lettura.
Oggi K vale 1. La proposta da cui nasce questo documento — *una immagine per
libreria* — è K = 879. Fra i due estremi non c'è una scelta di gusto: ci sono due
costi che si muovono al contrario.

| | al crescere di K |
| --- | --- |
| costo di assorbire un cambiamento | **scende**, come ~1/K: si ricostruisce solo l'immagine toccata |
| costo di una ricerca negativa | **sale**, linearmente: per dire che un nome non c'è bisogna guardare in tutti gli strati |
| numero di demoni FUSE | **sale**: `erofsfuse` è un processo per immagine montata |
| ratio di compressione | **scende**: mille archivi non condividono il dizionario che uno solo condivide |

La seconda riga è quella che può uccidere il progetto, e la fase 0 lo dice già:
**la resolve storm è l'unica metrica che si avvicina al criterio di uscita** —
1,30–1,93× con K = 1. La risoluzione dei moduli di Node è dominata dalle ricerche
*negative*: `require('react')` prova `node_modules/react` risalendo ogni livello,
e ogni tentativo fallito deve interrogare ogni strato. Moltiplicare K moltiplica
esattamente quel costo.

Quindi K ha un **tetto imposto dal meccanismo**, non dal disegno, e va trovato
per misura (N10). E il tetto è basso: fra i due estremi la strada non è continua.

---

## 3. Non è l'object store che il taccuino ha bocciato

Va detto subito, perché la somiglianza è forte e la conclusione opposta.

La voce 5 del [taccuino](<taccuino di viaggio.md>) — «la deduplicazione non
paga» — ha smontato con le misure la premessa da cui `freeze` era nato. Sette
progetti reali, 258.450 file: l'ibrido con object store perdeva contro la
semplice immagine compressa a ogni scala, e il costo marginale non è mai sceso
sotto 1,29. La decisione che ne è seguita — niente store, una immagine
autosufficiente — è ciò che ha fatto cadere refcount, orfani, garbage collection
e requisito di root, cioè la parte più delicata del progetto.

**Una immagine per libreria assomiglia a quello store. Non lo è, per due
ragioni misurabili.**

**La prima è la granularità.** Il taccuino individua la variabile decisiva e non
è quanta duplicazione ci sia: è **quanto sono grandi gli oggetti**. Lo store
bocciato teneva *un file per oggetto*, taglia media 2.816 byte, e il 54% dello
spazio occupato era arrotondamento al blocco. Il 97% dei file di un
`node_modules` sta sotto i 5 KB: **sotto la dimensione del blocco, un object
store non può vincere.**

Un'immagine per pacchetto sta due ordini di grandezza dall'altra parte:

| unità | oggetti sulla fixture | taglia media | rispetto al blocco da 4 KiB |
| --- | --- | --- | --- |
| il file (store bocciato) | 258.450 | 2.816 B | **sotto** — 54% era aria |
| **il pacchetto** | **879** | **≈ 272 KiB compressi** (685 KiB grezzi) | **68× sopra** |
| l'albero (oggi) | 1 | 234 MiB | irrilevante |

L'arrotondamento su 879 file da 272 KiB è circa **1,7 MiB su 234**, cioè lo
0,7%. Resta però un costo fisso che il taccuino non ha mai dovuto misurare:
**il superblocco e i metadati di ogni immagine EROFS**. Su un pacchetto da tre
file quel costo fisso può essere tutto. È N13, ed è mezza giornata.

**La seconda ragione è la più importante, ed è un vero rovesciamento.** Il
taccuino chiude così: «deduplicare, con gli strumenti disponibili, significa
rinunciare a comprimere. Due contro uno e un quarto» — la compressione toglieva
il 48% dei byte, la dedup il 20%, e il costruttore di composefs non espone alcuna
opzione di compressione. **Il difetto fatale dell'ibrido non era la
deduplicazione: era che le due cose si escludevano.**

A granularità di pacchetto non si escludono più. Ogni immagine per pacchetto è
una immagine EROFS `lz4hc` come quella di oggi: **si comprime e si deduplica allo
stesso tempo**, e il conto «due contro uno e un quarto» non si applica perché
non si sta scambiando la prima con la seconda.

**Quel che torna, e va accettato.** Se lo store diventa condiviso fra progetti,
tornano refcount, orfani, ciclo di vita condiviso — proprio ciò che la voce 5
aveva eliminato. Per questo la fase 2 **non condivide niente**: lo store è per
progetto e muore con `npz detach` (§9). La condivisione è materia di fase 3, e
solo se N14 la giustifica.

E vale la regola del taccuino: *questa sezione non rovescia niente.* Argomenta
che il verdetto della voce 5 non si applica a questa granularità. Lo rovesciano
N13 e N14, o non è rovesciato.

---

## 4. La separazione dei metadati, e perché qui non è un'ottimizzazione

Il costo che fa salire la seconda riga di §2 non è il numero di immagini in sé:
è la **frammentazione dei metadati**. Con K immagini indipendenti, sapere se un
nome esiste vuol dire interrogare K indici; e a cache fredda vuol dire K letture
random su posizioni scorrelate, dove ognuna costa un page fault da 4 KiB per
leggerne duecento byte.

Il rimedio è dividere i due piani:

- **piano dati** → le K immagini, immutabili, ognuna compressa per conto suo;
- **piano metadati** → **un solo** indice, che dice dove sta ogni cosa.

Con l'indice unico il costo di una ricerca torna indipendente da K. Senza,
cresce con K e la resolve storm sfonda il criterio di uscita.

**Il precedente da copiare è git**, che ha lo stesso problema — milioni di
oggetti content-addressed, quasi tutti minuscoli — e la stessa soluzione:
oggetti *loose* per i nuovi, **packfile** per il resto, un `.idx` separato per il
lookup, e un repack periodico. L'identità degli oggetti resta per oggetto; il
layout su disco no. È esattamente la distinzione che serve qui: **tenere
l'identità per pacchetto e disaccoppiarla dal numero di file su disco.**

### Dove sta l'indice, in questo progetto

Qui c'è una fortuna: **l'indice esiste già e non è un file.** `lib/immagine.py`
lo dice in una riga — *«le immagini presenti: il percorso è esso stesso
l'indice, nessun registro»* — e
[`elenca()`](../npz_python/lib/immagine.py#L55) le trova con una `glob`. La fase 2 non deve
introdurre un registro: deve mettere la generazione **nel nome**.

```text
static/node_modules.000.img
static/node_modules.001.img     ← l'ordine di sovrapposizione è l'ordine dei nomi
static/node_modules.002.img
```

Ne segue una proprietà che nessun file di manifest darebbe: **la comparsa del
file è il commit.** Si costruisce `…002.img.new`, si fa `os.replace`, e da quel
momento lo strato esiste. Niente registro da tenere allineato alla verità, niente
generation number da scrivere da nessuna parte, nessuna fonte di verità nuova che
possa divergere dal disco. È la stessa scelta di §5 del piano principale, dove il
*nome* della cartella di servizio è lo stato invece di descriverlo.

Nota sul `npm ls` da cui è partita la domanda: **non è la fonte di verità.** Ha
bisogno di un albero già installato e costa **276 ms** misurati in §7 del piano
principale. La fonte è `package-lock.json`, che dà il grafo risolto *con gli
integrity hash* — e quegli hash sono le chiavi dello store, gratis (§8).

---

## 5. Le tre vie, e la quarta che si scarta

Il piano principale ha una virtù che va difesa: **non contiene un filesystem.**
Compone `erofsfuse` e `fuse-overlayfs`, il merge lo fa il kernel, e non serve
alcun privilegio. Ogni via che porta a K > 1 va giudicata prima di tutto su
quanto di quella virtù consuma.

### Via A — la stratificazione (K per *generazione*)

Gli strati sono immagini sovrapposte, e ognuna è un cambiamento sigillato.
`fuse-overlayfs` li compone come già compone due strati, perché
[`monta_fusione(strati, punto)`](../npz_python/lib/mount.py#L36) **accetta già una lista**.

- **Costo in codice nuovo: quasi zero.** Il meccanismo c'è.
- **Costo in K:** basso. Un demone per strato, e le ricerche negative crescono.
- **Cosa compra:** i tredici secondi. Assorbire un delta da 5,4 MiB diventa
  `mkfs.erofs` su 5,4 MiB — per proporzione con il primo freeze, **decine di
  millisecondi invece di 12–15 s**.
- **Cosa non compra:** niente condivisione fra progetti, e niente `npm ci`
  economico. La decomposizione è per *tempo*, non per *identità*.

### Via B — la composizione nativa di EROFS (K per *identità*)

EROFS sa già fare la separazione dei metadati: un'immagine di metadati che
rimanda a **blob esterni come device** (`--chunksize`, `--device`) — è il modo in
cui composefs la usa. Una immagine per pacchetto come blob, un'immagine di
metadati che li indicizza, **un solo demone**.

- **Cosa compra:** tutto. K = 879 con una sola ricerca, `npm ci` dal lockfile,
  e la condivisione fra progetti di §3.
- **Il rischio:** non è verificato che `erofsfuse` monti immagini multi-device,
  né che `mkfs.erofs` produca l'immagine di metadati da blob costruiti
  separatamente. **Non misurato.** È N12.
- **Attenzione a un falso allarme.** La voce 7 del taccuino ha bocciato una cosa
  che assomiglia a questa: `fuse-overlayfs` non implementa i layer *data-only*
  (`lowerdir=a::b`), che era il meccanismo con cui l'immagine composefs
  rimandava al suo store. Ma il `::` è un concetto di *overlayfs*. Se i blob
  sono device di EROFS, li risolve `erofsfuse` dentro di sé e overlayfs non ne
  sa niente. **Il blocco della voce 7 potrebbe non applicarsi**, ed è
  precisamente ciò che N12 deve stabilire.

### Via C — un demone proprio

Un filesystem FUSE scritto da noi: un mount, un indice, fan-out su K immagini.
Chiude tutto per costruzione. **Fuori dalla fase 2**, e non per prudenza: la
resolve storm è a 1,30–1,93× con demoni scritti in C, e un demone in Python su
quel carico non è una variante lenta, è un prodotto diverso. Costerebbe un
componente compilato che *non è* quello di §11.

### La via che si scarta: l'indice solo a tempo di costruzione

Tentazione ragionevole: tenere lo store per pacchetto solo come cache di
costruzione, e continuare a montare una immagine sola. Il montaggio non si
tocca, i 0,07 s restano.

**Non funziona, e vale dirlo perché sembra la scelta prudente.** Per costruire
l'immagine unica servono i byte dei pacchetti; se stanno in 879 immagini EROFS,
leggerli vuol dire montarle tutte — la patologia che si voleva evitare — oppure
estrarle, cioè riscrivere 588 MiB. E tenerli come alberi estratti su ext4
significherebbe **31.667 inode permanenti nello store**, cioè restituire il
beneficio principale del progetto. Il premio richiede la composizione a runtime:
non esiste una versione a tempo di costruzione che lo consegni.

### La decisione

| Via | Fase 2 | Perché |
| --- | --- | --- |
| **A — stratificazione** | **si costruisce** | prende i tredici secondi con il codice che c'è già |
| **B — EROFS multi-device** | **si sonda** (N12) | se regge, la fase 3 ha una strada; se non regge, si sa presto |
| C — demone proprio | no | costa un filesystem, e la resolve storm dice che va scritto in C |
| indice a sola costruzione | no | non consegna il premio (sopra) |

Le due decomposizioni **non sono in conflitto**: per generazione è ciò che si può
avere adesso, per identità è lo stato finale. Il giorno in cui B regge, gli
strati restano per generazione e i loro *contenuti* diventano riferimenti per
identità.

---

## 6. Il sigillo: il delta non si assorbe, si chiude

È la fase 2 in una riga, ed è una generalizzazione del §9 del piano principale
invece di una sua sostituzione.

Oggi, dopo un comando mutante che supera la soglia:

```text
  smonta → ricostruisci l'immagine dalla vista fusa (12-15 s) → rimonta
```

Con la via A:

```text
  smonta → mkfs.erofs sul solo delta → nuovo strato N+1 → delta vuoto → rimonta
```

Il delta non viene **assorbito** dall'immagine: viene **sigillato** in una
immagine propria, che si sovrappone alle precedenti. Quel che si paga è
`mkfs.erofs` su 5,4 MiB invece che su 588, più i 17 ms di
smontaggio/rimontaggio già misurati.

Il consolidamento vero non sparisce: diventa una **fusione periodica** degli
strati, che è esattamente il repack di git, e si paga quando K supera il tetto di
N10 invece che a ogni installazione.

### Le due cose che il sigillo deve dimostrare

**I whiteout.** Un delta non contiene solo file nuovi: contiene cancellazioni. In
overlayfs una cancellazione è un nodo di device carattere 0:0, e in
`fuse-overlayfs` non privilegiato è un'altra convenzione ancora, perché un utente
non può fare `mknod`. La domanda è secca: **una cancellazione sigillata dentro
una immagine EROFS viene ancora onorata quando quella immagine è uno strato
inferiore?** Se la risposta è no, la via A non esiste — non degradata: non
esiste. È **N9**, ed è la misura più importante di tutta la fase 2. Costa un'ora.

**La fusione non ha una finestra insicura, e va costruita perché resti così.**
Uno strato inferiore reso *ridondante* è invisibile: tutto ciò che contiene è
già in uno strato superiore, che vince nella ricerca. Ma questo vale solo per le
aggiunte. Se lo strato fuso rappresenta un file cancellato come *assente* invece
che come whiteout, e gli strati assorbiti sono ancora sotto, **il file
resuscita.** Da cui la fusione non sostituisce gli strati uno per uno: costruisce
l'insieme nuovo di fianco e lo scambia in blocco.

```text
  static/strati/        ← quelli in uso
  static/strati.new/    ← i sopravvissuti in hardlink, piu' lo strato fuso
                          os.rename(strati, strati.old); os.rename(strati.new, strati)
```

Gli hardlink rendono la costruzione dell'insieme nuovo quasi gratuita: nessun
byte copiato. I due `rename` non sono atomici *insieme*, ma lo stato intermedio è
inequivocabile — `strati` assente con `.old` e `.new` presenti — e ricade
nell'autoriparazione di §6 del piano principale. L'invariante **costruisci prima
di cancellare** resta intatta, e con lei la `verifica()` di
[immagine.py](../npz_python/lib/immagine.py#L147), che continua a montare e confrontare
prima che qualcosa di vecchio sparisca.

---

## 7. La struttura su disco, e il salto di `FORMATO`

Estende §5 del piano principale. `static/` e `dynamic/` non cambiano nome — sono
`FORMATO`, e rinominarli renderebbe illeggibile ogni store già scritto.

```text
.npz/
├── config                          ← formato: sale di uno
├── lock
├── static/
│   ├── strati/
│   │   ├── node_modules.000.img    ← il freeze iniziale
│   │   ├── node_modules.001.img    ← un delta sigillato
│   │   └── node_modules.002.img
│   └── node_modules.meta
├── dynamic/node_modules/           ← il delta scrivibile, invariato
└── run/node_modules/
    ├── lower.000  lower.001  …     ← un punto per strato: un erofsfuse ciascuno
    ├── work
    └── fusione
```

Tre conseguenze che non sono libere:

- **`run/` cresce con K**, e resta ciò che il montaggio ricrea con un `mkdir` e
  che a riposo non deve esistere. La regola di §5 non cambia: *a riposo `run/`
  non esiste; se esiste e non è vuota, un mount è morto a metà.* Ma ora la
  riparazione deve smontare K punti, non due.
- **Il formato sale, e la lettura all'indietro va decisa.** Uno `.npz` con
  `static/node_modules.img` e nessuna `strati/` è di formato precedente. La via
  più economica non è un convertitore: è **rileggere `package-lock.json` e
  rifare**, perché `node_modules` è derivabile — l'argomento di §1 del piano
  principale — e un percorso di migrazione da mantenere per sempre costa più di
  1,74 s spesi una volta.
- **Il percorso veloce non cambia di una istruzione.** Continua a chiedersi se
  `node_modules` è un mountpoint, e non ha ragione di sapere quanti strati ci
  siano sotto. I 14 ms di N6 non sono in gioco.

---

## 8. `npm ci` smette di essere il caso patologico — ma solo con la via B

N1 lo ha misurato ed è il numero peggiore della fase 0: **3,04–3,51×**, delta di
588 MiB in 35.222 voci, **821 MiB contro i 588 del nativo**. Il piano principale
lo intercetta e lo porta sull'albero nudo, e con quell'interruttore N1 passa.

Con lo store per **identità** l'intercettazione smette di essere un ripiego. Da
`package-lock.json` si conoscono i locator e i loro integrity hash; per ognuno si
chiede allo store se l'immagine c'è già; si costruiscono solo le mancanti; si
scrive l'insieme di strati. Un `npm ci` su un lockfile che non è cambiato
diventa **quasi interamente hit di store**, cioè scende sotto il tempo nativo
invece di stare tre volte sopra.

Sono i benefici della via B, e nella fase 2 **non si materializzano**:
l'intercettazione di §8 resta come è, ed è già sufficiente a far passare N1. Va
scritto qui perché è la ragione più forte per sondare B (N12) invece di
archiviarla.

### L'identità di un pacchetto, quando servirà

L'integrity hash del lockfile è la chiave ovvia e non basta da sola, perché
l'albero installato non è il tarball:

- **gli script di ciclo di vita** e gli addon nativi producono contenuto che
  dipende dalla piattaforma e dall'ABI di node: la chiave di quei pacchetti deve
  portarsi dietro l'ambiente di costruzione, oppure quei pacchetti **non si
  condividono**. Non è un difetto fatale: un pacchetto non condivisibile resta
  una immagine come le altre, solo non riusata;
- **il confine** di un pacchetto è la sua cartella *esclusi i `node_modules`
  annidati*, che appartengono ad altri locator;
- **quel che non è di nessun pacchetto** — i symlink di `.bin/`,
  `.package-lock.json` — sta in uno strato di radice a parte.

---

## 9. La garbage collection torna, e come si tiene piccola

Con K > 1 esistono immagini che nessuno usa più: gli strati assorbiti da una
fusione, quelli di un giro interrotto. È il ritorno di ciò che la voce 5 del
taccuino aveva eliminato, e va tenuto al minimo con tre regole.

- **L'insieme in uso è una directory, non un elenco.** Quel che sta in
  `static/strati/` è vivo, quel che non ci sta è morto. Nessun refcount, nessun
  registro: la stessa proprietà per cui *il percorso è l'indice*.
- **Si spazza durante la fusione, e in nessun altro momento.** `strati.old/`
  viene rimossa dopo che la nuova è in uso — cioè dopo la `verifica()`, non
  prima.
- **La rete di sicurezza è la derivabilità.** Perdere lo store costa 1,74 s di
  ricostruzione, non dei dati. È lo stesso argomento con cui §1 del piano
  principale autorizza `npz` a essere brutale dove `freeze` non poteva.

Nella fase 2 lo store è **per progetto** e sparisce con `npz detach`. Nessun
ciclo di vita condiviso fra progetti: quello arriva con la via B, se arriva, e
si porta dietro una discussione che non è di questa fase.

---

## 10. Il banco — N9…N14

Continua la numerazione della fase 0. Il banco vive accanto a
[fase0.sh](../npz_python/test/fase0.sh); non serve root, tranne dove indicato.

| | Scenario | Perché può cambiare il disegno |
| --- | --- | --- |
| **N9** | un delta con **cancellazioni** sigillato in una immagine EROFS e montato come strato inferiore: le cancellazioni sono ancora onorate? | **è il cardine.** Se no, la via A non esiste e la fase 2 si riduce al sondaggio di N12. Costa un'ora, e va fatto per primo |
| **N10** | **la curva di K**: resolve storm, `vite build`, `tsc --noEmit`, tempo di montaggio con 1, 2, 4, 8, 16, 32, 64 strati | dà il tetto di K. La resolve storm è già a 1,30–1,93× con K=1 ed è la metrica più vicina al criterio di uscita: qui si vede quanto margine c'è. Usa `monta_fusione`, che accetta già una lista |
| **N11** | **il sigillo contro il consolidamento**: sigillare i delta di N2 (5,4 / 15 / 17 MiB) contro i 12–15 s di N4 | è il premio. Se non è almeno un ordine di grandezza, il salto di `FORMATO` non si paga |
| **N12** | **EROFS multi-device**: `mkfs.erofs` produce un'immagine di metadati su blob costruiti a parte? `erofsfuse` la monta? il `::` della voce 7 c'entra davvero? | apre o chiude la via B, cioè la condivisione fra progetti e `npm ci` economico. Sondaggio, non implementazione |
| **N13** | **la distribuzione per pacchetto**: taglie dei 879 pacchetti, e costo totale di 879 immagini EROFS contro una | il costo fisso per immagine è l'unico modo in cui §3 può sbagliarsi. Criterio: lo store per pacchetto entro **1,15×** l'immagine unica |
| **N14** | **dedup per identità sui sette progetti React** della voce 5, a granularità di pacchetto e **con compressione attiva** | è il numero che rovescia o conferma la voce 5. Stessa fixture, per confrontabilità. Serve alla fase 3 |

### Criterio di uscita

- **N9 verde**, o la via A è fuori e con lei il grosso della fase 2.
- **N10 dà un K massimo** che tiene la resolve storm **entro 2×**, che è il
  criterio della fase 0 e non si allarga qui.
- **N11 almeno 10×** sui tredici secondi. Sotto, non si cambia formato.
- **N12, N13, N14 producono numeri, non verdetti**: servono a decidere la fase 3.

Va misurato **a cache fredda**: senza `drop_caches` la fase 0 ha già prodotto una
conclusione falsa una volta (N4, la nota sullo staging), e la page cache lì valeva
sei secondi su dodici. È la stessa avvertenza della voce 9 del taccuino, e qui
pesa di più perché la frammentazione dei metadati si vede *solo* a freddo.

---

## 11. Il resto della fase 2

Le tre voci che il §14 del piano principale aveva già assegnato a questa fase
restano, e non dipendono da niente di quanto sopra:

- **il timer di inattività**, tarato su **N5** — che è ancora l'unico criterio di
  uscita della fase 0 scoperto. Il §2 del piano principale ne ha già ridotto il
  rango: non ricompra i backup e gli indicizzatori, che si escludono da soli al
  confine di filesystem, ma la fascia stretta degli attraversatori senza `-x`;
- **i workspace**, se N1 e N5 hanno dato buone notizie. La struttura di `.npz/`
  li regge senza modifiche, e con `strati/` continua a reggerli;
- **`npz` come binario compilato**, se N6 dice che i 48 ms si sentono. N6 ha
  misurato **10,9–12,9% a riposo e 11,1–12,4% sotto carico**: il rapporto non
  peggiora, quindi non c'è urgenza. Da non confondere con il demone della via C,
  che è un'altra cosa e resta fuori.

---

## 12. L'ordine di lavoro

La fase 0 ha stabilito una disciplina che vale anche qui: **le misure che possono
uccidere l'idea costano ore, implementarla costa settimane.**

1. **N9** — un'ora. Se i whiteout non sopravvivono al sigillo, tutto il resto di
   questo documento è archiviato e la fase 2 torna a essere il §14.
2. **N13** — mezza giornata. Dice se la granularità per pacchetto è sopra il
   costo fisso, cioè se §3 tiene.
3. **N10** — mezza giornata con il codice esistente. Dà il tetto di K, che è il
   parametro da cui dipende ogni scelta successiva.
4. **N12** — un pomeriggio di sondaggio. Non implementa niente: stabilisce se la
   fase 3 ha una strada.
5. Solo allora: il sigillo, la fusione periodica, la migrazione di formato per
   ricostruzione, e **N11** come verifica del premio.
6. **N14** quando la fase 2 è chiusa, perché serve alla successiva.

---

## Rimandi

- [piano di implementazione.md](<piano di implementazione.md>) — la fase 0 e la
  fase 1 di `npz`, e i §§2, 5, 8, 9 che questo documento estende.
- [report-fase0.md](../npz_python/test/report-fase0.md) — i numeri da cui parte tutto.
- [taccuino di viaggio.md](<taccuino di viaggio.md>) — la voce 5, che va letta
  prima di §3 di questo documento, e la voce 7, che va letta prima di §5.
- [claim.md](claim.md) — le invarianti: un solo lock, formato versionato,
  costruisci prima di cancellare. Nessuna delle tre si muove qui.
