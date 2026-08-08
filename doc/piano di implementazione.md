# npz — piano di implementazione

`npz` è un wrapper di `npm`. Gira ogni parametro a `npm` tale e quale, e si
riserva tre comportamenti propri: chiede una volta se congelare `node_modules`,
lo congela e lo monta, e con `npz bye` rilascia il mount.

Non è un progetto nuovo: nasce come **seconda facciata** sul nucleo di
[`freeze`](claim.md), e da quando `freeze` è uscito da questo repo è l'unica. Le
tre invarianti — un solo lock, formato versionato, costruisci prima di cancellare
— restano scritte in un posto solo, `npz_python/lib/` (§4).

---

## 1. Perché non è "freeze con un alias"

La fase 3 di `freeze` prevede un demone che deve *indovinare* tre cose. Il
wrapper le sa per costruzione:

| Segnale | Il demone | `npz` |
| --- | --- | --- |
| quando l'albero è cambiato | euristiche sul delta, `tc`, soglia del 30% | ogni mutazione passa da `install`, `ci`, `update`, `uninstall`, `dedupe`, `prune` |
| quando serve montato | mai saputo | il comando `npm` sta per partire |
| quanto è ricostruibile | mai: la cartella è unica | `package-lock.json` la ridetermina per intero |

Il terzo è il più sottovalutato. `node_modules` è **derivabile**, e questo
autorizza `npz` a essere molto più brutale di `freeze`: davanti a una situazione
confusa può buttare via e rifare, opzione che `freeze` non ha mai.

**La conseguenza architetturale più grossa: la rotazione del delta non serve.**
Serve a `freeze` perché consolida sotto un mount vivo, ed è il punto in cui il
disegno poteva perdere dati (voce 4 del [taccuino](<taccuino di viaggio.md>)).
`npz` possiede l'intera finestra — smonta, ricostruisce, rimonta — quindi non
esiste l'intervallo in cui l'utente scrive. La parte più delicata del progetto
sparisce invece di essere ereditata.

---

## 2. Il mount è la superficie di compatibilità

La tabella di [claim.md](claim.md) — 258.450 file che diventano 7 — descrive lo
stato **congelato**, mentre lo stato stazionario di `npz` è **montato**. Da qui
la tentazione di leggere il mount come una rinuncia: da montati gli strumenti
riattraversano tutti i file, quindi metà del beneficio non si materializza.

È una lettura sbagliata. Da montati i file si vedono **perché si devono
vedere**: `node`, `npx`, `vite`, `tsc`, il language server dell'editor e i binari
in `node_modules/.bin` non passano da `npz` e non devono accorgersi di niente.
La compatibilità piena con npm *è* la visibilità dell'albero — non sono due
obiettivi in tensione, sono la stessa cosa detta due volte.

La domanda giusta non è quando smontare per riprendersi il beneficio. È: **le
due popolazioni di lettori sono distinguibili?**

| Popolazione | Esempi | Deve vedere l'albero |
| --- | --- | --- |
| la toolchain | `node`, bundler, language server, test runner | **sì** — è la ragione per cui `npz` esiste |
| gli attraversatori | backup, antivirus, indicizzatori, `du`, `find`, client di sincronizzazione | **no** — sono puro costo, e sono quelli di cui parla claim.md |

Sono distinguibili, con un meccanismo che `npz` ottiene gratis: **un mount è un
confine di filesystem.** Misurato su uno stack vero, stesso progetto, stesso
istante:

| | attraversa | si ferma al confine |
| --- | --- | --- |
| `find -type f` | 302 file | `-xdev`: **2** |
| `du -sh` | 1,3 M | `-x`: **16 K** |
| `rsync -an` | 308 voci | `-x`: **5** |
| `tar` | tutto | `--one-file-system`: **5 voci** |
| `node -e 'require(...)'` | risolve | — |

Questo rovescia la conclusione. Prima di `npz`, escludere `node_modules` richiede
che *ogni* strumento abbia una regola per nome, scritta a mano, progetto per
progetto. Dopo `npz` è un confine di filesystem, cioè la primitiva di esclusione
più universale e più affidabile che Unix offra, e gli attraversatori che sanno
fermarsi ci si fermano **senza sapere nulla di `npz` né di `node_modules`**. Come
mount point la cartella è *più* escludibile di quanto fosse come directory.

### Il costo che resta, detto per intero

- **Gli attraversatori che non usano `-x` non guadagnano nulla**, e vedono gli
  stessi file più lentamente di prima perché ci passano attraverso due demoni in
  user space. Per loro, e solo da montati, `npz` è leggermente peggio del niente.
- **`du` sul progetto continua a riportare la dimensione espansa**, perché legge
  la vista fusa: 1,3 M contro i 16 K realmente occupati. I due numeri divergono
  di proposito, ed è confondente. `npz status` deve dirli entrambi.

Da cui la politica di smontaggio **scende di rango**: non ricompra metà del
valore, ricompra una fascia stretta — gli attraversatori senza `-x`, mentre la
macchina è accesa. Resta obbligatorio lo smontaggio *ordinato* di §6, che serve
alla correttezza dello stato al riavvio e non al beneficio.

### Cosa cambia quando `node_modules` è un mount point

Compatibilità piena vuol dire elencare anche gli scarti. Misurati:

| | Come cartella | Come mount point |
| --- | --- | --- |
| visibile a `-x` / `--one-file-system` | sì | **no** — la voce per cui vale la pena |
| `mv node_modules node_modules.bak` | funziona | **EBUSY** |
| `rm -rf node_modules` | cancella | **svuota tutto**, poi fallisce sul mountpoint |
| `rename(2)` fra progetto e albero | funziona | **EXDEV** — `mv` da shell ripiega su copia+unlink, `fs.renameSync` no |
| hardlink dal progetto dentro l'albero | funziona | **EXDEV** |

npm nella configurazione predefinita non hardlinka dalla cache dentro l'albero e
non rinomina attraverso il confine, quindi nessuna di queste righe lo tocca. Ma
sono esattamente le righe da verificare in N1 e N3 invece di darle per buone.

**La terza riga è un pericolo, non una curiosità.** `rm -rf node_modules` non
protegge niente: cancella l'intero contenuto della vista fusa — cioè scrive
whiteout nel delta per ogni voce — e fallisce solo sull'ultimo `rmdir` del
mountpoint. L'immagine resta intatta, quindi non si è perso nulla; ma l'utente
vede una cartella vuota e un errore che molti script ignorano. È lo stesso
meccanismo di `npm ci` (§8), e va trattato allo stesso modo: `npz` riconosce un
delta che copre di whiteout l'intero albero e chiede se buttare il delta —
tornando all'immagine in un istante — o completare la cancellazione con `bye`.

---

## 3. Le decisioni prese

| Questione | Decisione | Conseguenza accettata |
| --- | --- | --- |
| che cosa lascia `npz bye` | **lo stato congelato**: smonta, rimuove la cartella, tiene `.npz` | il prossimo comando `npm` rimonta in meno di un decimo di secondo; lo spazio resta occupato dall'immagine |
| dove vivono delta e workdir | **dentro `.npz/`**, accanto al progetto | `npz` **rifiuta** i progetti su filesystem non idoneo, cioè su `/mnt/400GB_FastData` (fuseblk): i progetti devono stare sotto `$HOME` |
| quando si rilascia il mount | unità utente con `ExecStop` + autoriparazione a ogni invocazione | serve alla correttezza dello stato al riavvio, non al beneficio (§2): il timer di inattività è rimandato alla fase 2 e tarato su N5 |
| perimetro | solo `npm`, solo il `node_modules` alla radice del progetto | `pnpm` e `yarn PnP` fuori (vedi §11); i `node_modules` annidati vengono rilevati e segnalati, non gestiti |
| lingua | Python, stesso pacchetto di `freeze`; binario compilato dopo la fase 0 | misurato: **13 ms** di percorso veloce contro **121 ms** di `npm run`, cioè +11% sul comando `npm` più economico. Vale solo con la disciplina sugli import di §7, senza la quale sono 75 ms |

### Node.js valutato e scartato

Sarebbe la scelta ovvia per un wrapper di npm — `npm i -g npz`, stesso pubblico,
stesso ecosistema. Misurato, è il candidato peggiore proprio sull'asse che conta:

| percorso veloce | ms |
| --- | --- |
| Python `-SE` | **13,4** |
| Node, CommonJS | 36,4 |
| Node, ESM | 38,0 |
| *(`node -e ''`, pavimento assoluto)* | *29,9* |

Il **pavimento** di Node — processo vuoto, zero codice — costa più del doppio del
percorso veloce completo di Python. E `npz` sta davanti a ogni comando `npm`.

Sopra i millisecondi ci sono due mancanze strutturali, verificate:

- **`fs.flock` non esiste.** Servirebbe un addon nativo, cioè esattamente la
  gestione delle dipendenze che si voleva evitare, oppure un lock per file dalla
  semantica più debole: non si rilascia da solo alla morte del processo, che è la
  proprietà per cui `freeze` usa `flock`.
- **Nessun `exec` che sostituisca il processo.** Per i comandi neutri — cioè la
  stragrande maggioranza — Python fa `os.execvp` e *sparisce*: `npm` eredita TTY,
  segnali e codice di uscita senza una riga di codice. Node deve sempre generare
  un figlio e restare, con un processo da decine di MB fermo per tutta la durata
  di un `npm run dev`, e con l'inoltro dei segnali da scrivere a mano (§7).

E il vantaggio di distribuzione è apparente: il binario compilato lo dà comunque
e meglio, spedito *come* pacchetto npm con i prebuild per piattaforma — il modo
in cui si distribuiscono esbuild, swc e biome. Node comprerebbe adesso, al prezzo
del budget di avvio, ciò che la fase successiva regala.

---

## 4. Architettura: il nucleo e la facciata

Il nucleo sta in [`npz_python/lib/`](../npz_python/lib/), la facciata è
`npz_python/` stesso, e ci si appoggia sopra senza copiarne una riga. La
separazione è quella fra **meccanismo** e **politica** — `lib` sa costruire,
montare e tenere lo stato; sa *dove* farlo solo chi lo chiama.

| Modulo | Ereditato dal nucleo di `freeze` |
| --- | --- |
| [immagine.py](../npz_python/lib/immagine.py) | **invariato** — `percorsi()`, `costruisci()`, `verifica()`, `inventario()`, `differenze()` |
| [mount.py](../npz_python/lib/mount.py) | **invariato** — le due implementazioni dietro la stessa interfaccia |
| [stato.py](../npz_python/lib/stato.py) | **invariato** — lock, config, meta |
| [perimetro.py](../npz_python/lib/perimetro.py) | **invariato** — usato però in modo diverso (§9) |
| [filesystem.py](../npz_python/lib/filesystem.py) | **invariato** — `idoneita()` è il controllo che rende sicura la scelta di tenere tutto in `.npz/` |

Quel che **non** si è ereditato era politica di `freeze`, e con `freeze` è uscito
da questo repo: `radice.py` — la risalita à-la-`git` verso una radice dichiarata
a mano con `init` — `segnaposto.py` e la sua CLI. Il disegno che li descrive resta
in [claim.md](claim.md), perché è da lì che vengono le tre invarianti.

### La separazione sopravvive alla ragione che l'aveva prodotta

Il nucleo era stato estratto per servire **due** facciate. Ora ne serve una sola,
e la domanda va posta invece di essere evitata: una linea di taglio che non separa
più due consumatori si guadagna ancora il posto?

Sì, e per un motivo diverso da quello che l'ha prodotta. `lib` è **dove stanno le
invarianti** — un solo lock, formato versionato, costruisci prima di cancellare —
e tenerle in un modulo che non sa niente di `.npz`, di `package.json` e di npm è
ciò che permette di leggerle senza leggere la politica che le usa. La fase 2 lo
mette alla prova nel modo più diretto: il salto di `FORMATO`
([il suo piano](<piano di implementazione fase 2.md>)) cambia `percorsi()` e fa
nascere la catena degli strati **dentro `lib`**, e la facciata non deve
accorgersene.

### Il refactoring che abilita tutto ✔

*Fatto.* `SERVIZIO`, `SUFFISSO_SEGNAPOSTO` e `SENTINELLA` erano costanti di
modulo in `lib/__init__.py` e portavano i nomi di `freeze` — `.freeze-blobs`,
`.freeze.txt` — non quelli del nucleo. Finché stavano lì, `lib` era condiviso
nella struttura ma non nel comportamento: `npz` non poteva ottenere `.npz` senza
modificarlo.

Sono diventati un [`Profilo`](../npz_python/lib/__init__.py) che la facciata
costruisce e passa al nucleo:

```python
PROFILO = Profilo(servizio=SERVIZIO, sentinella=SENTINELLA)     # ".npz"
```

Le firme toccate sono state nove, di cui cinque in `lib`:
`immagine.percorsi()` ed `elenca()`, `stato.lock()`, `scrivi_config()`,
`leggi_config()` — le altre stavano nella facciata di `freeze`. **Verificato che
`Profilo(servizio=".npz")` produce esattamente la struttura del §5** —
`.npz/static/node_modules.img`, `.npz/dynamic/`, `.npz/run/node_modules/` — con
zero righe nuove in `lib`.

**E qui c'è la conferma che la parametrizzazione non era un lusso per due
gemelli.** Con una facciata sola i profili in gioco restano **due**, e li produce
`npz` da sé: [`progetto.profilo()`](../npz_python/progetto.py#L46) ne costruisce
uno intonato al nome che la cartella di servizio ha *adesso*, perché quel nome è
`.npz` da montati e `node_modules.frozen` da fermi. È il §5, «il nome è lo
stato»: se `SERVIZIO` fosse ancora una costante di modulo, quella sezione non si
potrebbe implementare. Il refactoring è sopravvissuto al motivo per cui è stato
fatto, e serve a una cosa che allora non era in programma.

Il **segnaposto** invece non è entrato nel profilo: è uscito da `lib`. Era un'idea
di `freeze` — `npz` ha deciso di non averne (§5) — e `lib/stato.py` non sa più che
i segnaposto esistano.

### `progetto.py` — una radice per progetto

`freeze` risaliva l'albero come `git` fino a una radice dichiarata a mano con
`init`, e rifiutava di annidarne una dentro un'altra: due regole giuste per una
radice condivisa fra progetti e sbagliate qui. `npz` vuole **una radice per
progetto**, che nasce senza `init` esplicito.

```python
def trova(partenza=None) -> Path | None:
    """La cartella del progetto: la prima, risalendo, che contiene package.json.

    Si ferma al confine di filesystem come radice.risali(), e non oltrepassa
    un package.json: e' lo stesso criterio con cui npm decide dove sta il
    progetto, e usarne un altro produrrebbe divergenze silenziose.
    """
```

Va invece riusata **integralmente** [`filesystem.idoneita()`](../npz_python/lib/filesystem.py):
è il controllo che rifiuta i filesystem che non conservano i permessi POSIX o
non reggono un `upperdir`. Con la decisione di tenere tutto in `.npz/`, quel
controllo è ciò che impedisce a `npz` di produrre un ripristino silenziosamente
sbagliato. Sta in `lib` proprio perché è **un fatto sul supporto e non una
scelta**: è la riga di confine più netta fra nucleo e facciata, e resta dov'è con
una facciata come con due.

### Dove stanno le cose

Due cartelle e una regola: **il nucleo non sa che esiste la facciata.** Le
dipendenze vanno in una direzione sola — `lib` non importa niente da sopra di sé —
e la condivisione avviene per import, mai per copia.

```text
<radice del repo>/
├── doc/                        ← il disegno e le misure
│   ├── claim.md                          il disegno di `freeze`: le invarianti
│   ├── taccuino di viaggio.md            le misure che l'hanno prodotto
│   ├── piano di implementazione.md       ← questo documento
│   └── piano di implementazione fase 2.md   il salto di FORMATO
│
└── npz_python/                 ← LA FACCIATA: politica, e nient'altro
    ├── lanciatore.py           il percorso veloce, da ~/.local/bin/npz
    ├── __init__.py             il PROFILO, e nient'altro di costoso
    ├── veloce.py               i tre `stat`, lo stato, la consegna a npm
    ├── progetto.py             la risalita a package.json
    ├── comandi.py              la classificazione di §8
    ├── cli.py                  i comandi intercettati
    ├── mounter.sh              il testbed ext4
    │
    ├── lib/                    ← IL NUCLEO: meccanismo, nessuna politica
    │   ├── __init__.py         costanti, Errore, e il Profilo
    │   ├── immagine.py         mkfs.erofs, la catena dei percorsi, la verifica
    │   ├── mount.py            FUSE e kernel dietro la stessa interfaccia
    │   ├── stato.py            lock, config, meta
    │   ├── perimetro.py        chi tiene la cartella, di chi sono i file
    │   └── filesystem.py       che cosa il supporto sotto di noi puo' reggere
    │
    └── test/                   i banchi N1…N8 della fase 0, e il loro report
```

**Il nome `npz_python` non è una goffaggine: è una data di scadenza.** Il §3 ha
deciso Python per la fase 0/1 e un binario compilato per la fase 2, e la fase 2 lo
tiene fra le sue voci se N6 dirà che i millisecondi si sentono. Chiamare la
cartella `npz` avrebbe fatto di quel passaggio una sostituzione in cui la vecchia
implementazione non ha più un posto dove stare; chiamarla `npz_python` lo rende
un'aggiunta, e permette alle due di convivere per il tempo in cui la nuova va
confrontata con la vecchia — che è l'unico modo di sostituirla senza fidarsi.

Il lanciatore mette la radice del repo in `sys.path` risolvendo il proprio
symlink (§7), così `import npz_python` risolve e il nucleo si raggiunge come
`npz_python.lib`. È un artificio del prototipo e sparisce quando la facciata
diventa un pacchetto installato o un binario.

---

## 5. La struttura su disco

```text
progetto/                            ← qui sta package.json
│
├── package.json
├── package-lock.json
├── node_modules/                    ← mountpoint. Esiste SOLO da montati.
│   └── .npz_mount_caduto_...        ← sentinella, coperta dall'overlay
│
└── .npz/                            ← da fermo si chiama `node_modules.frozen`
    ├── config                       ← formato, compressione, risposta alla conferma
    ├── lock
    ├── static/
    │   ├── node_modules.img         ← l'immagine EROFS lz4hc
    │   └── node_modules.meta
    ├── dynamic/node_modules/        ← il delta scrivibile
    └── run/node_modules/            ← esiste SOLO mentre il mount c'è
        ├── lower                    ← dove erofsfuse monta l'immagine
        ├── work                     ← il workdir di overlayfs
        └── fusione                  ← solo durante un `npz compact`
```

**Le due famiglie non si mescolano, e il livello superiore lo dice.** `static/` e
`dynamic/` sono i dati — sopravvivono a tutto, e i loro nomi appartengono a
`FORMATO`, perché rinominarli renderebbe illeggibile ogni store già scritto.
`run/` è lo stato di esercizio: le sue tre voci le ricrea il montaggio con un
`mkdir`, e a mount spento non significano più niente. Da cui una regola sola,
invece di un elenco da tenere aggiornato: *a riposo `run/` non esiste; se esiste
e non è vuota, un mount è morto a metà.*

`work` sta lì e non altrove per una ragione che non è di gusto: overlayfs lo
esige **sullo stesso filesystem dell'upperdir**, perché il copy-up di un file
grosso viene materializzato lì dentro e poi spostato nel delta con un
`rename(2)` — che è ciò che rende impossibile trovare nel delta un file a metà.
Misurato: con il workdir su tmpfs e il delta su ext4 `fuse-overlayfs` monta
senza protestare, e poi il primo copy-up fallisce con **EXDEV**. È lo stesso
vincolo che, un livello più su, obbliga `.npz/` a stare accanto al progetto (§3)
e fa esistere `filesystem.idoneita()`.

È esattamente ciò che restituisce `immagine.percorsi(progetto, "node_modules")`
con `SERVIZIO = ".npz"`. La catena inversa di `freeze` qui è banale — un
progetto, una immagine — ma la struttura resta la stessa, e i `node_modules`
annidati dei workspace ci entrerebbero senza modifiche il giorno in cui si
decidesse di gestirli.

### Il nome è lo stato

La cartella di servizio ha **due nomi**, e cambiarlo è tutto ciò che distingue
un progetto al lavoro da uno fermo:

| | `ls` mostra | |
| --- | --- | --- |
| **montato** | `node_modules` · `.npz` · `package.json` | si lavora: la cartella di servizio si nasconde e il progetto ha l'aspetto di sempre |
| **congelato** | `node_modules.frozen` · `package.json` | è ferma, e lo dichiara: una cartella sola, visibile, che dice dove sono finiti i dati |

Nasce da un'osservazione semplice: da fermo, un progetto con un `.npz` nascosto e
nessun `node_modules` **sembra un progetto a cui manca qualcosa**. Con il nome
visibile smette di sembrarlo e comincia a dirlo.

Non è un segnaposto — è la stessa cartella, con addosso il nome giusto per lo
stato in cui si trova. Ed è per questo che qui il segnaposto di `freeze` non
serve: `node_modules.freeze.txt` è un file *in più* da mantenere allineato alla
verità, mentre un nome non può disallinearsi da sé.

**Ferma vuol dire anche più magra.** Delle tre sottocartelle, una non contiene
mai nulla a mount spento: `run/`, con dentro tutto lo stato di esercizio.
Il montaggio la ricrea — `monta_ro` e `monta_stack` fanno già `mkdir` — quindi
tenerla da fermi sarebbe solo rumore dentro una cartella che deve spiegarsi da
sola. All'addormentamento cade, e resta esattamente ciò che ha un contenuto:

```text
node_modules.frozen/
├── config
├── lock
├── static/node_modules.img      ← i dati, compressi
├── static/node_modules.meta
└── dynamic/node_modules/        ← il delta, se ce n'è
```

Per la stessa ragione il congelamento **sveglia prima di cominciare**: costruire
dentro il nome fermo e rinominare dopo lascerebbe, se qualcosa andasse storto a
metà, una cartella che si dichiara a riposo mentre contiene un'immagine
incompleta.

Tre dettagli di implementazione che non sono liberi:

- **La rinomina avviene fuori dal lock.** Il file di lock vive dentro la cartella
  che si rinomina; `flock` sta sull'inode e sopravvive, quindi l'esclusione fra
  processi regge — ma è la finestra fra `nome_servizio()` e `open()` che va
  tenuta stretta.
- **Entrambi i nomi vanno in `.git/info/exclude`**, altrimenti la cartella
  ricompare fra gli untracked appena il progetto va a riposo.
- **Il percorso veloce paga un `os.stat` in più** (quattro invece di tre) per
  sapere quale dei due nomi c'è. Sotto la soglia di misurabilità: i 14 ms sono
  dominati dall'avvio di Python, non dalle `stat`.

Il refactoring del [`Profilo`](../npz_python/lib/__init__.py) è ciò che rende tutto questo
quasi gratuito: il nucleo riceve già il nome della cartella di servizio dalla
facciata e non ha idea di come si chiami, quindi renderlo variabile è un
parametro e non una modifica.

`npz` aggiunge `.npz/` a `.git/info/exclude` alla prima inizializzazione: non
tocca il `.gitignore` del progetto, che è un file versionato dell'utente.

---

## 6. Il ciclo di vita

Cinque stati, e ogni invocazione di `npz` comincia riconoscendo in quale si trova.

| Stato | cartella di servizio | `node_modules/` | Come ci si arriva |
| --- | --- | --- | --- |
| **vergine** | assente | assente | progetto appena clonato |
| **candidato** | assente | cartella vera | dopo `npm install` senza `npz` |
| **rifiutato** | `.npz/no` | cartella vera | l'utente ha detto no, e non glielo si richiede |
| **congelato** | `node_modules.frozen/` | **assente** | dopo `npz bye`, o dopo uno spegnimento pulito |
| **montato** | `.npz/` | mountpoint | lo stato di lavoro |
| **rotto** | `.npz/` | cartella vuota, non montata | crash, OOM, spegnimento sporco |

Ce n'è un settimo, che nasce quando qualcuno batte `npm` al posto di `npz`:
**scavalcato**. Sta nel §6 bis, perché non è uno stato del ciclo di vita ma una
sua interruzione dall'esterno.

```text
   vergine ──(npm install)──> reale ──(conferma)──> montato
                                                     │  ▲
                                          npz bye ───┘  │
                                                     ▼  │
                                                congelato┘
                                             (qualsiasi comando npm)

   rotto ──(autoriparazione, silenziosa)──> montato
```

**La regola che chiude P6: da non montati la cartella non deve esistere.** Se
resta lì vuota, un builder non dice "manca `node_modules`" — dice
`cannot find module 'react'`, che è un errore molto peggiore da diagnosticare, e
lo dice a strumenti che non passano da `npz` (l'editor, `node`, `npx`, i binari
già nel PATH). Lo stato *assente* è invece indistinguibile da "mai installato",
l'unico errore che tutto l'ecosistema JavaScript già sa raccontare.

Quindi: montare è `mkdir` + `mount`, smontare è `umount` + `rmdir`. La sentinella
di `freeze` resta, e serve a distinguere lo stato **rotto** da una cartella vuota
creata dall'utente.

### Lo smontaggio deliberato

Misurato su questa macchina: `KillUserProcesses=no`, quindi al **logout** i
demoni FUSE sopravvivono; allo **spegnimento** vengono uccisi e i mount staccati
da `systemd-shutdown`. Il mount se ne va da solo — ma per uccisione, non per
smontaggio, e il `rmdir` non avviene mai. Risultato: al riavvio ogni progetto
congelato è nello stato **rotto**.

L'uptime misurato sugli ultimi otto avvii va da 1h47 a 17h57, sempre con
spegnimento notturno: i mount **non si accumulano nel tempo lungo**, si
accumulano dentro la giornata. Da cui:

- **fase 1, obbligatoria** — unità systemd utente con solo `ExecStop`, che smonta
  ordinatamente tutti i progetti registrati. Gira sia al logout sia allo
  spegnimento. Al riavvio lo stato è *congelato*, non *rotto*.
- **fase 1, rete di sicurezza** — autoriparazione a ogni invocazione: immagine
  presente, cartella esistente, mount assente, sentinella presente → rimonta in
  silenzio. Copre crash e OOM, che l'`ExecStop` non copre.
- **fase 2, da misurare** — timer di inattività. Vale la pena ricordare quanto
  poco compra, dopo il §2: non i backup e gli indicizzatori, che si escludono da
  soli al confine di filesystem, ma solo gli attraversatori che non usano `-x`,
  e solo mentre la macchina è accesa. Con questo uptime servirebbe a tenere
  montato il progetto su cui si lavora adesso invece di tutti quelli toccati
  oggi. Lo decide N5.

---

## 6 bis. Lo scavalcamento

Il §6 assume che chi lavora batta `npz`. Prima o poi qualcuno batterà `npm`, e
`node_modules` tornerà a esistere alle spalle di npz. Non è un caso di bordo: è
il modo normale in cui uno strumento che si sostituisce a un altro viene
dimenticato — da un IDE che lancia `npm` per conto suo, da uno script, da una
pipeline, o semplicemente da un'abitudine di dieci anni.

I due sotto-casi si comportano in modo opposto, ed è la cosa più importante da
tenere ferma.

**Da montati non succede niente di male.** npm scrive nell'overlay, tutto
finisce nel delta, la vista fusa resta corretta. Provato: `npm install` e
`npm ci` diretti su un mount attivo lasciano il progetto coerente. È una
**degradazione silenziosa**, non un guasto — il delta cresce e nessuno lo dice,
perché `avvisa_delta()` parla solo quando npz viene invocato. Il rimedio esiste
già ed è `npz compact`. Non serve altro.

**Da fermi è un vicolo cieco.** Con `node_modules.frozen/` in giro, `npm
install` ricostruisce un `node_modules` vero, e il progetto si ritrova con due
alberi. Misurato prima di scrivere questa sezione, ed è peggio di quanto
sembri:

```text
npz status  →  status  broken       ← nulla è rotto: npm è riuscito, l'albero è completo
npz hey     →  … exists, isn't mounted, and isn't empty. npz won't touch it
npz attach  →  idem      npz compact →  idem
npz ls      →  idem      ← e questo è il punto grave
```

`npz ls` è in sola lettura, con un `node_modules` completo davanti, e fallisce
lo stesso. **npz smette di essere trasparente e diventa un ostacolo**: blocca
comandi che npm da solo eseguirebbe benissimo, mentre il disco paga due volte e
nessuno lo dice.

### Il settimo stato

La causa è che *rotto* confonde due situazioni che non hanno niente in comune:
il **nostro** mountpoint scoperto dopo uno spegnimento — dentro c'è solo la
sentinella, e l'autoriparazione del §6 è giusta — e un albero **estraneo**, che
npz non ha costruito e su cui non deve montare niente. Vanno separate.

| Stato | cartella di servizio | `node_modules/` | Come ci si arriva |
| --- | --- | --- | --- |
| **rotto** | `.npz/` | solo la sentinella | crash, OOM, spegnimento sporco |
| **scavalcato** | `node_modules.frozen/` o `.npz/` | albero vero, non montato | `npm` battuto al posto di `npz` |

La discriminazione è uno `scandir` che esce alla prima voce che non è la
sentinella, e si paga solo nel ramo non montato — che va comunque al percorso
lento, quindi il §7 non ne risente di un'istruzione.

### Non si fonde

La tentazione, davanti a due alberi, è unirli. **Non si fa**, e non è una
questione di sforzo: non sono due rami della stessa cosa, sono due soluzioni
distinte dello stesso problema di vincoli, calcolate da npm in momenti diversi.
Non c'è antenato comune registrato da nessuna parte e non c'è provenienza per
file. Un'unione al livello dei percorsi darebbe `react` da un albero e
`react-dom` dall'altro, a versioni mai risolte insieme, con `package-lock.json`
a descrivere una terza cosa ancora.

Il guasto che ne uscirebbe è del tipo peggiore: **l'albero funziona**. Node
risolve quel che trova su disco, il build passa, e il difetto salta fuori a
runtime in un punto che con npz non c'entra niente. Metà di una soluzione più
metà di un'altra non è una soluzione.

Si sceglie quindi **un albero intero**, e quello che perde non si cancella.

### La procedura, e dove si aggancia

Tutto ciò che richiede l'espansione dell'immagine passa da `assicura_montato()`:
un imbuto solo, cinque chiamanti. La procedura si aggancia lì, e da nessun'altra
parte.

Fuori dall'imbuto npz **non si mette in mezzo**, perché non ha ragione di farlo:
l'albero è reale e completo.

- comando **neutro** → una riga di avviso, e il comando va a npm come sempre;
- comando **mutante** → npm lavora sull'albero vero, e a esito zero si propone
  l'adozione. Qui un codice di uscita c'è, quindi ci si può fidare.

**Senza TTY non si chiede e non si tocca niente**: una riga di avviso e il
comando passa. Vale la regola di `proponi()` — una domanda che non si può porre
non si pone — e nel merito è la cosa giusta: meglio un npz che sparisce di un
npz che blocca `npm run build` in pipeline. Ne segue, e va accettato
esplicitamente, che **in CI un progetto scavalcato resta scavalcato**: si ripara
alla prima sessione interattiva.

Con un TTY, tre uscite e nessuna di esse è la fusione:

```text
  [f] keep the folder npm built — it becomes the new image, the old one is set aside
  [i] keep the image — the folder is set aside as node_modules.superseded/
  [x] do nothing now
```

### Si mette da parte, non si cancella

Il precedente è `metti_da_parte()`, che prima di un `npm ci` rinomina l'immagine
invece di cancellarla, *perché cancellare significherebbe distruggere lo stato
congelato prima di sapere se npm riuscirà*. Qui non si sa nemmeno se l'utente ha
scelto bene, e la risposta è la stessa.

| Vince | Copia ridondante | Dove finisce |
| --- | --- | --- |
| l'immagine | l'albero che npm ha ricreato | `node_modules.superseded/` nella radice |
| la cartella di npm | l'immagine vecchia e il suo delta | `*.superseded` dentro la cartella di servizio |

L'albero messo da parte sta **in vista**, accanto a `node_modules.frozen`, con
un nome che si spiega da solo. È la copia grossa — 588 MiB contro 234 sulla
misura di riferimento — e nasconderla dentro `.npz/` significherebbe seppellire
il costo che npz esiste per togliere. Va aggiunta alle righe che
`prepara_servizio()` scrive in `.git/info/exclude`, che da due diventano tre.

**`npz detach` nomina l'albero messo da parte prima di sparire.** La cartella di
servizio se ne va, e con lei la scadenza che avrebbe raccolto la copia: da lì in
poi non c'è più nessuno che possa tornare a chiederne conto. Dichiarare che *di
npz non resta niente* lasciando lì una `node_modules.superseded/` sarebbe falso, e
la riga che la nomina costa uno `stat`.

**Una sola copia per volta, per costruzione.** Se la procedura scatta di nuovo e
ce n'è già una, non se ne accosta una seconda: si chiede il permesso di togliere
la prima, e senza TTY la si sovrascrive dicendolo — che è già quel che fa
`metti_da_parte()` con `unlink(missing_ok=True)` prima del rename. Senza questa
regola il failsafe diventa `.superseded.2`, `.superseded.3`, cioè esattamente la
perdita di spazio che doveva evitare. Con, il costo massimo è **una
generazione**, sempre.

### La raccolta va a orologio, non a contatore

Le copie messe da parte non restano appese: npz torna a chiedere se toglierle.
Ma **contare le invocazioni vorrebbe dire tenere un contatore**, ed è il pezzo di
stato che il §5 ha deciso di non scrivere da nessuna parte.

L'`mtime` della copia è già sul filesystem, dentro lo stesso `stat` che serve ad
accorgersi che la copia esiste. Nessun file nuovo, fonte di verità invariata. E
misura la cosa giusta: quel che serve non è "cinque comandi", è *aver avuto il
tempo di accorgersi se serviva ancora*.

| Copia | Grazia | Perché |
| --- | --- | --- |
| immagine vecchia | 1 giorno | è un file solo, ed è superata da una immagine **verificata** contro l'albero che l'utente ha scelto |
| albero di npm | 7 giorni | è l'annullamento dell'utente, ed è la scelta più sospetta: chi tiene l'immagine butta ciò che npm aveva appena installato |

Rispondere **no non registra un rifiuto: rimette l'orologio a zero** con un
`utime`. La domanda torna dopo un'altra grazia. Il meccanismo non ha memoria da
mantenere — *l'`mtime` è la memoria* — non si può inchiodare, non nagga, e non
aggiunge un byte fuori dal filesystem. Il messaggio lo dice, perché un no che
costa poco rende il sì onesto invece che estorto:

```text
Remove it? [y/N]   — saying no keeps it another week.
```

La grazia paga anche un debito che non era suo. L'orfano `.aside` —
l'immagine messa da parte prima di un `npm ci`, se npz muore in mezzo — oggi
resta e **nessuno lo cerca più**: `veloce.stato()` non trova l'immagine, dichiara
il progetto *candidato*, e ripropone l'attach mentre centinaia di MiB stanno lì.
Confronta con `.excluded`, che ha il suo "residuo di un giro interrotto" e viene
ripulito. Cercando i residui per nome dentro `static/` si copre anche quello con
la stessa `glob`; e la grazia di un giorno garantisce che un `npm ci` **vivo**,
che dura minuti, non venga mai scambiato per un orfano.

Senza TTY non si cancella mai niente. `npz status` elenca comunque le copie con
quanto occupano: visibili sempre, tolte solo su risposta.

---

## 7. Il percorso veloce e il percorso lento

`npz` sta davanti a ogni `npm run` di ogni ciclo di sviluppo. Il caso normale —
già montato, comando neutro — deve costare **tre `stat`**:

```text
percorso veloce   .npz/static/node_modules.img esiste?
                  node_modules è un mountpoint?
                  il comando è nella lista dei mutanti?
                  ─────────────────────────────────────
                  no lock, nessuna scansione di /proc, exec di npm
```

La scansione di `/proc` di [perimetro.py:17](../npz_python/lib/perimetro.py#L17) costa
decine di millisecondi su una macchina carica e **non deve mai** stare sul
percorso veloce: serve solo prima di uno smontaggio. Stessa cosa per il lock di
`stato.py`, che va preso solo per montare, congelare e consolidare — altrimenti
due `npm run` in parallelo si serializzerebbero.

### La disciplina sugli import è il vero costo, non la lingua

Misurato su questa macchina, trenta ripetizioni:

| | ms |
| --- | --- |
| `python3 -SE`, solo `os` e `sys`, tre `stat`, `execvp` | **13** |
| `import os, sys, pathlib, subprocess` | 39 |
| `import freeze, freeze.cli` (il pacchetto intero) | 49 |
| `./freeze.sh --version`, giro vero | 75 |
| — | |
| `npm run <script vuoto>` | 121 |
| `npm ls --depth=0` | 276 |

Fra i 13 ms disciplinati e i 75 ms della via naturale ci sono **62 ms**; fra
Python e un binario compilato ce ne sono dieci. La lingua non è la variabile
dominante: lo è la scelta di non importare nulla sul percorso veloce.

Da cui tre regole vincolanti, non stilistiche:

- shebang con **`-SE`**, che toglie `site` e le variabili d'ambiente;
- sul percorso veloce **niente `pathlib`, `subprocess`, `argparse`**, e nessun
  import del pacchetto `freeze`: `os.stat` e `os.execvp` bastano;
- tutto il resto — mount, congelamento, consolidamento — vive dietro un import
  ritardato, dentro le funzioni che lo usano, dove i millisecondi non contano
  perché la si sta già pagando in secondi.

### Il lanciatore, e il comando globale

`npz` deve stare **in PATH fin dalla fase 0**: si lavora dentro il testbed ext4
di [mounter.sh](../npz_python/mounter.sh), e battere un percorso assoluto a ogni comando
falsifica proprio l'ergonomia che si sta provando.

In fase 0/1 il modo giusto è un **symlink** da `~/.local/bin` al lanciatore
nell'albero di lavoro — già in PATH su questa macchina, in seconda posizione. Le
modifiche al codice sono vive: nessun passo di installazione fra una modifica e
la prova, che è il punto dello sviluppo prototipale.

Il lanciatore è un **file Python, non uno script di shell**: risparmia il fork di
bash, e soprattutto è il posto dove il percorso veloce deve vivere.

```python
#!/usr/bin/env -S python3 -SE
"""npz — lanciatore. Il percorso veloce sta qui, prima di qualsiasi import."""
import os, sys

# ── percorso veloce ──────────────────────────────────────────────────────────
# Niente oltre os e sys, e nessun accesso al pacchetto: sono i 13 ms.
progetto = risali_a_package_json()          # solo os.stat
if progetto and neutro(sys.argv[1:]) and montato(progetto):
    os.execvp(NPM, [NPM, *sys.argv[1:]])    # il processo sparisce qui

# ── percorso lento ───────────────────────────────────────────────────────────
# Solo adesso si paga il pacchetto: siamo gia' in un'operazione da secondi.
QUI = os.path.dirname(os.path.realpath(__file__))    # …/npz
sys.path.insert(0, os.path.dirname(QUI))             # la radice del repo
from npz.cli import main                             # e da li', anche `lib`
sys.exit(main())
```

Tre dettagli che non sono stilistici:

- **`env -S`** è ciò che permette due flag nello shebang; verificato su questa
  macchina (coreutils 9.11, `no_site` e `ignore_environment` entrambi attivi).
- **`-E` ignora `PYTHONPATH`**, quindi il trucco con cui il lanciatore di `freeze`
  esportava la radice del repo non è disponibile: il lanciatore si localizza da
  solo con `realpath(__file__)`. È un miglioramento, non un ripiego — un comando
  globale non deve dipendere dall'ambiente di chi lo invoca. `realpath` è anche
  ciò che lo rende **collegabile**: attraverso un symlink `__file__` è il link,
  non il bersaglio, e senza risolverlo la radice del repo finirebbe su
  `~/.local`. Vale per qualunque involucro che si faccia collegare, ed è il primo
  errore da cercare quando un comando globale non trova il proprio pacchetto.
- **`NPM` va risolto a un percorso assoluto** e confrontato con il lanciatore
  stesso. Un wrapper che esegue `npm` per nome, su una macchina dove qualcuno ha
  messo un `npm` che punta a `npz`, entra in ricorsione infinita. Le alias di
  shell non si ereditano e non fanno danno; un symlink sì.

In fase 2 il binario si installa in `/usr/local/bin`, o come pacchetto npm con i
prebuild per piattaforma. Nota per allora: `~/.local/bin` non è nel `secure_path`
di `sudo`, quindi il backend kernel di [mount.py](../npz_python/lib/mount.py) va invocato
con `sudo -E env PATH="$PATH" npz` finché il comando vive lì. Il disegno non
chiede privilegi, ma il testbed di `mounter.sh` sì.

Il montaggio ha una corsa: due `npz` che trovano entrambi "non montato" e montano
entrambi. Si prende il lock e si **ricontrolla sotto il lock**.

### Trasparenza del wrapper

Siccome dopo `npm` c'è lavoro da fare, non si può fare `exec`: serve `fork` +
`wait`. Da cui quattro obblighi:

- il codice di uscita di `npm` è il codice di uscita di `npz`, sempre;
- `stdin`, `stdout` e `stderr` passano invariati, **compresa la loro natura di
  TTY**: `npm` cambia comportamento se `stdout` non è un terminale (colori,
  barre di avanzamento), e un wrapper che interpone una pipe lo altera;
- `SIGINT` e `SIGTERM` vengono inoltrati al figlio, e `npz` aspetta che esca;
- ogni messaggio di `npz` va su **stderr**, e ogni domanda su `/dev/tty`.
  `npm view react --json | jq` non deve trovare parole di `npz` nella pipe.

### La voce di `npz`

Wrapper vuol dire che sullo stesso terminale parlano in due, a turno: `npz`
annuncia, `npm` lavora, `npz` conclude. Senza un marcatore le due voci si
confondono, e la riga che porta l'errore diventa di nessuno. Ogni riga di `npz`
porta quindi una **sbarra verticale in box drawing**, tinta, che si apre con una
testa e si chiude con una coda:

```text
 ╥
 ║  in questo progetto c'è un node_modules da 31.667 file (588 MiB).
 ║  Posso comprimerlo in una immagine sola e montarlo al suo posto:
 ║    · lo spazio scende di circa due terzi, gli inode a uno
 ║  Procedo? [s/N] s
 ╨
```

Testa e coda non sono decorazione: **delimitano il turno di parola, non il
messaggio.** La sbarra si apre alla prima riga che `npz` dice, resta aperta per
tutte quelle che seguono, e si chiude dove `npz` cede il terminale. Quel che sta
dentro è suo, quel che sta sotto la coda è di `npm` — che è l'unica cosa da
sapere leggendo lo scroll di un `npm install` andato storto.

Da cui quattro regole, tutte conseguenza di quella:

- **si chiude prima di ogni consegna a `npm`**, cioè prima dell'`execv` e prima
  del `fork` di `accompagna()`. Non è cortesia tipografica: `execv` non fa girare
  gli `atexit`, e il `fork` duplicherebbe nel figlio i buffer non svuotati,
  facendo comparire le stesse righe due volte;
- **il colore sta sul segno, mai sul testo** — giallo a metà intensità quando
  `npz` racconta, rosso pieno quando si ferma — così il testo resta copiabile
  senza portarsi dietro le sequenze di escape. Un terminale non ha un'opacità: ha
  l'attributo `faint`, che è il modo giusto per ottenere quel mezzo tono, perché
  si compone col fondo vero invece di richiedere un giallo scelto sapendo se il
  tema è chiaro o scuro. Il segno deve stare **sotto** il testo, non accanto: è un
  margine, non un contenuto. Il rosso invece resta pieno — un errore non
  sussurra — e detto a metà turno tinge anche la coda, così com'è andata si legge
  dalla chiusura senza rileggere il blocco;
- **niente colore se il flusso non è un terminale.** Il segno resta e l'escape
  no: in una pipe la voce va distinta lo stesso, ma senza sporcarla;
- **il segno sta su ogni riga**, comprese quelle degli elenchi e quella della
  domanda. Una riga nuda in mezzo a un blocco di `npz` sembra output di `npm`.

Sul percorso veloce non costa niente: se `npz` non dice nulla non stampa nulla, e
`atexit` — l'unico import che serve a garantire la coda anche quando si esce per
un'altra strada — si carica alla prima parola, non all'importazione del modulo.
Misurato dopo l'aggiunta: **13,9 ms**, gli stessi di N6.

### La conferma

Una volta sola, e la risposta si ricorda in `.npz/config` — anche il "no",
altrimenti si richiede a ogni comando per sempre. Non si chiede se `stdin` non è
un TTY, se `CI` è valorizzata, o se c'è `--yes`. Si chiede **prima** che `npm`
parta, così l'utente non viene sorpreso alla fine, ma si agisce **dopo** (§8).

---

## 8. I comandi

### Quelli intercettati

Sei, con i nomi in inglese come tutta la superficie di npm: la CLI parla la
lingua di chi la usa, il codice sotto resta in italiano — e da questa fase in
inglese sono anche i messaggi e l'aiuto che quella CLI stampa, non solo i nomi
dei comandi.

| Comando | Effetto | |
| --- | --- | --- |
| `npz attach` | attiva npz su questo progetto adesso, senza chiedere niente | ✔ |
| `npz detach` | materializza `node_modules` come cartella vera e cancella `.npz` | ✔ |
| `npz hey` | monta ciò che `attach` ha già costruito; non costruisce mai | ✔ |
| `npz bye` | smonta, rimuove la cartella, tiene `.npz`: torna allo stato *attached* | ✔ |
| `npz status` | in quale stato siamo, quanto è grande l'immagine, quanto il delta | ✔ |
| `npz compact` | forza il consolidamento adesso, invece di aspettare la soglia | ✔ |

**`npz attach` scavalca la domanda**, e anche un no già dato: chi lo scrive ha
già deciso, e chiedergli conferma di ciò che ha appena chiesto non ha senso. Per
la stessa ragione toglie di mezzo il `.npz/no` registrato in precedenza — è
l'utente stesso a smentirlo. Su un progetto già gestito è idempotente: assicura
il mount e riferisce.

**`npz hey` è il contrario esplicito di `bye`.** Dove il montaggio automatico
del percorso lento (§7) monta perché sta per partire un comando `npm`, `hey`
lo fa a comando, per chi vuole vedere l'albero senza lanciare npm — un editor
da riaprire, un `ls` da fare. Monta solo quel che `attach` ha già costruito: su
un progetto mai attaccato rifiuta e lo dice, invece di attaccare npz senza che
nessuno l'abbia chiesto.

**`npz detach` è la via d'uscita, e senza di essa il sistema non si adotta.**
Con `bye` che porta allo stato attached, nulla riporterebbe il progetto a essere
un progetto normale, e in un sistema in cui si può solo entrare non entra
nessuno. Rispetta i tre tempi come tutto il resto: l'albero vero nasce accanto a
quello montato con un nome di lavoro, viene confrontato con la vista da cui
proviene — **attributi, non nomi**: tipo, permessi, dimensione, destinazione dei
symlink, uid e gid, con lo stesso `img.differenze()` che il congelamento usa al
contrario — e solo allora prende il suo posto. `.npz/` sparisce per ultima. Se
qualcosa va storto a metà, l'immagine è ancora lì e non si è perso niente.

Tutto il resto va a `npm` invariato. E vale la regola inversa: `npz -- attach`
passa `attach` a `npm`, per il giorno in cui `npm` avesse un comando con uno di
questi nomi.

`npz` **senza argomenti** stampa il proprio aiuto e a seguire quello di npm.
L'ordine è il messaggio: npz non è un comando che assomiglia a npm, è npm con
tre comportamenti in più, e mostrarne l'aiuto dopo il proprio lo dice meglio di
qualunque frase. Il codice di uscita resta quello di npm. Qui la sbarra di §7 fa
un lavoro che nessuna frase farebbe altrettanto bene: l'aiuto di `npz` sta tutto
dentro il segno, la coda cade, e da lì in giù parla npm.

### La classificazione

| Classe | Comandi | Cosa fa `npz` |
| --- | --- | --- |
| **neutri** | `run`, `test`, `view`, `ls`, `outdated`, `publish`, … | assicura il mount, esegue, esce |
| **mutanti** | `install`, `uninstall`, `update`, `dedupe`, `prune`, `link` | assicura il mount, esegue, **poi** valuta il consolidamento |
| **distruttivi** | `ci` | vedi sotto |

La lista dei mutanti è un elenco chiuso e va sbagliata **per eccesso**: un
comando classificato mutante per errore costa un controllo del delta che trova
zero; un mutante non classificato lascia crescere il delta senza che nessuno se
ne accorga.

### `npm ci` è il caso patologico

`npm ci` cancella `node_modules` prima di installare. Sull'overlay significa
whiteout per 45.000 voci, poi 45.000 file veri riestratti nel delta: l'immagine
diventa peso morto, il delta una copia piena, e il risultato ha **più inode di
prima di usare `npz`**.

Va intercettato prima di eseguirlo:

```text
   smonta → cancella immagine e delta → npm ci sull'albero nudo → congela
```

Così i 45.000 whiteout non vengono mai scritti, e `npm ci` gira alla velocità
nativa su una cartella vera — che è esattamente ciò che quel comando si aspetta.

Il gemello non intercettabile è `rm -rf node_modules` battuto a mano o da uno
script: non passa da `npz`, quindi si può solo riconoscere **dopo**, dal delta
che copre di whiteout l'intero albero (§2). Stessa diagnosi, due uscite: buttare
il delta e tornare all'immagine, oppure completare con `bye`.

### Quando si congela: dipende dal comando, e la classificazione lo dice già

Se l'utente scrive `npz install lodash` in un progetto nello stato *reale*, la
sequenza giusta è: chiedi conferma → esegui `npm install` sull'albero vero →
congela l'albero assestato → monta. Congelare prima significherebbe far scrivere
l'installazione dentro il delta, cioè costruire un'immagine e subito
duplicarne un pezzo.

**Ma questa regola vale per i mutanti, e per quelli soltanto.** Applicata anche
ai neutri produce un difetto, e uno silenzioso — osservato sul campo, con `npz
run dev` su un progetto candidato:

```text
  npz chiede  →  l'utente dice sì  →  vite parte e gira per ore
              →  ctrl-c  →  npm esce 130  →  npz non crea niente, e tace
```

Due errori in fila. Il primo è che **per un comando neutro il codice di uscita
di npm non dice niente dell'albero**: `npm test` esce 1 se un test è rosso, `npm
outdated` esce 1 di routine, e un `run` interrotto esce 130 — in tutti e tre i
casi `node_modules` è esattamente quello che l'utente aveva davanti quando ha
detto di sì. Il secondo è di forma, e conta quanto l'altro: **una domanda che
ferma chi lavora deve avere una conseguenza che si vede subito.** Se il sì
produce l'effetto ore dopo, o non lo produce affatto, quella domanda non era una
domanda: era un disturbo.

Da cui la regola in due righe, che si appoggia alla classificazione che c'è già:

| classe | quando si attacca | perché |
| --- | --- | --- |
| **neutri** | **prima**, e poi `execv` verso npm | l'albero non lo toccano: il delta nasce vuoto e resta vuoto, e il comando parte già sul montato, cioè nella configurazione in cui vivrà |
| **mutanti** e **distruttivi** | dopo, sull'albero assestato | l'albero lo sta componendo npm; congelarlo prima duplicherebbe l'installazione dentro il delta |

Per i neutri l'attacco è anche più economico di prima: finito il congelamento
npz **sparisce dentro npm** con `execv`, invece di restare in attesa con
`fork`/`wait` per un lavoro che non ha più. E se attaccare non riesce, il comando
dell'utente non è ostaggio: se ha fallito il congelamento — e allora `node_modules`
non è stata toccata, per invariante — si spiega e si consegna comunque a npm; se
ha fallito il *montaggio*, ci si ferma, perché far partire un build che non
troverà `node_modules` produrrebbe un errore peggiore da leggere del nostro.

Resta un caso che deve parlare e prima taceva: **mutante che fallisce su un
progetto candidato.** Lì non si congela — giustamente, l'albero è a metà — ma va
detto, perché un sì che non produce niente e non spiega perché è peggio di un no.

---

## 9. Il consolidamento, senza rotazione

```text
  1. lock
  2. controlla i processi attivi (§10)
  3. smonta la vista, smonta il lower
  4. rimonta il lower ro, monta la fusione [delta, lower] ro
  5. mkfs.erofs dalla vista fusa            → temporanea
  6. verifica: inventario(fusione) == inventario(temporanea montata)
  7. smonta fusione e lower
  8. os.replace(temporanea, immagine)       ← tempo 2, atomico
  9. rmtree(delta); rmtree(work)            ← tempo 3
 10. rimonta
 11. unlock
```

È il `consolida()` di `freeze` — il ciclo di [claim.md](claim.md), «come evolve
l'immagine statica» — **meno la rotazione**: fra il passo 3 e
il passo 10 la cartella non esiste, quindi nessuno può scrivere, quindi non c'è
la finestra di perdita dati che la rotazione chiude. Il merge continua a farlo il
kernel, e non c'è logica di whiteout da scrivere.

Implementato in [`cli.compatta()`](../npz_python/cli.py), con tre conseguenze che il disegno
non aveva scritto e che l'implementazione ha dovuto risolvere:

- **il passo 3 sta dentro il `try` del passo 10.** Se il consolidamento fallisce,
  a qualunque altezza, l'albero torna comunque: che una costruzione sia andata
  male non è una ragione per lasciare il progetto senza `node_modules`. Se
  fallisce anche il rimontaggio, lo stato che resta è *congelato*, che è quello
  che la rete di sicurezza di §6 ripara al comando successivo.
- **il lock non si annida.** `flock` sta sulla descrizione del file aperto, non
  sul processo: riusare `monta()` e `smonta()`, che il lock se lo prendono da
  soli, lo farebbe fallire contro sé stesso. Da cui `_monta`/`_smonta`, che sono
  il montaggio senza il lock, e le due funzioni pubbliche che restano il
  montaggio *con* il lock.
- **lo stato non cambia.** Chi era montato torna montato, chi era fermo torna
  fermo — e da fermo il consolidamento non paga né smontaggio né rimontaggio,
  perché l'albero non c'è già. Il consolidamento cambia l'immagine, non lo stato
  del progetto.

Il costo è l'indisponibilità dell'albero per la durata: 17 ms di
smontaggio/rimontaggio più il tempo di costruzione. Su un `node_modules` vero è
la misura N4. Arriva subito dopo un `npm install`, cioè nel momento in cui
l'utente sta già aspettando.

**Quando.** Dopo un comando mutante, se il delta supera una delle due soglie.
Le soglie di partenza erano il 30% dei byte dell'immagine — quella di
[claim.md](claim.md) — e il 5% dei file, aggiunta perché qui il bene scarso
sono gli inode. **N2 le ha smentite entrambe** (§12 bis): sui byte servirebbero
oltre quaranta installazioni per arrivare al 30%, e il 5% sui file scatterebbe
alla seconda. I numeri misurati portano a:

| soglia | valore | perché |
| --- | --- | --- |
| voci nel delta | **10% delle voci dell'immagine** | ≈ dieci installazioni fra un consolidamento e l'altro, con 13 s di costo |
| byte nel delta | **30% dei byte** | resta come rete per il caso che i byte crescano senza i file — un `chmod -R`, un file grosso riscritto |

E una regola che N2 ha reso evidente: **si guarda il delta, non il comando.**
Tre installazioni su dieci non hanno prodotto delta perché il pacchetto c'era
già come dipendenza transitiva. Un consolidamento innescato dal nome del comando
sarebbe lavoro a vuoto.

*Allo stato attuale la soglia delle voci non fa scattare il consolidamento: lo
**consiglia**, con la riga di `cli.avvisa_delta()`, e a pagare i tredici secondi
è l'utente che scrive `npz compact`. Con N4 misurato — tredici secondi in mezzo
alla strada di chi sta aspettando un `npm install` finito — far scattare
l'automatismo è una decisione che vuole N5, non un'omissione da colmare.*

**Cosa non deve entrare nell'immagine.** `node_modules/.cache` e
`node_modules/.vite` sono cache di build: si rigenerano, cambiano in
continuazione, e consolidarle dentro un'immagine compressa è lavoro sprecato che
diventa peso permanente. Vanno escluse dal consolidamento con una lista di
diniego corta ed esplicita — `cli.ESCLUSE`, passata a `mkfs.erofs` come
`--exclude-path`.

**Escluse dall'immagine non vuol dire perse**, ed è la sola parte del disegno che
l'implementazione ha dovuto precisare. Se una di quelle cartelle sta *già* dentro
l'immagine — perché c'era al momento dell'`attach` — tenerla fuori dalla nuova la
farebbe sparire a metà: quel che stava nel delta resterebbe, quel che stava
nell'immagine no. Il consolidamento la **sposta** invece: la copia dalla vista
fusa mentre è ancora montata, e la rimette nel delta dopo il rename. Costa una
copia una volta sola — dalla passata seguente nell'immagine non c'è più — e in
cambio tiene l'invariante che conta, *la vista fusa dopo è identica a quella
prima*, che è poi quello che la verifica del passo 6 dimostra. Ciò che invece sta
solo nel delta ci resta senza copiare un byte: basta non cancellarlo al passo 9.

Ne segue una distinzione che il resto della CLI deve rispettare: **il delta ha
due misure**, quanto occupa e quanto ne assorbirebbe un consolidamento. La soglia
di §9 e `npz status` guardano la seconda, altrimenti una cache di build da 40 MiB
reclamerebbe per sempre un consolidamento che non può toglierla di lì.

**Il delta che cancella tutto non si consolida.** È il caso di §2 — `rm -rf
node_modules` battuto a mano, o uno script che lo fa — e vi si arriva con la
vista fusa vuota: consolidarla scriverebbe un'immagine vuota, cioè obbedirebbe a
una cancellazione che l'utente potrebbe non aver voluto. Il comando si ferma e
nomina le due uscite di §2: `npz compact --discard`, che butta il delta e
restituisce l'albero in un istante, oppure `npz bye`, che tiene la cancellazione.

**`metacopy=on` non va usato.** Rende il copy-up dei soli metadati economico, ma
lascia nel delta riferimenti al lower — e il passo 8 sostituisce il lower. Il
passo 9 svuota il delta subito dopo, quindi sarebbe consistente; ma è una
consistenza che dipende dall'ordine di due righe, e non vale il rischio.

---

## 10. I rifiuti, e il problema che li rende ingestibili

`perimetro.processi_attivi()` rifiuta l'operazione se qualcuno ha una cwd o un
descrittore dentro la cartella. Per `freeze` è un rifiuto raro. Per `npz` è la
norma: in un ambiente di sviluppo c'è **sempre** qualcosa — il server TypeScript
dell'editor, un dev server, un watcher, un `jest --watch`.

Se non si fa niente, `npz bye` e ogni consolidamento falliscono quasi sempre.
Le uscite possibili, in ordine di preferenza:

1. **elencare i colpevoli per nome** e fermarsi. È il comportamento di `freeze`,
   ed è corretto: `perimetro` restituisce già `pid` e `comm`. ✔
2. **`--force`** con smontaggio pigro (`fusermount3 -uz`), documentato come
   rischioso: le scritture in volo finiscono in un delta che nessuno rileggerà. ✔
3. **riprovare dopo N secondi** una volta sola, perché molti dei detentori sono
   processi effimeri di npm stesso appena usciti.

Le prime due sono in `Backend.smonta(punto, pigro)`. Il `--force` di `bye`, di
`detach` e di `compact` saltava il controllo ma poi si arenava sull'`umount`, che
con un watcher dentro l'albero risponde EBUSY: era una promessa che il codice non
manteneva, e la manteneva solo là dove nessuno la stava usando.

Quale serva lo dice **N5**, che è la misura più importante della fase 0 insieme a
N1: se in una giornata normale la cartella è tenuta il 90% del tempo, il rifiuto
educato non è una politica, è un muro.

---

## 11. Fuori perimetro, e perché

- **`pnpm`.** Il suo `node_modules` è una selva di symlink verso `.pnpm/`, che a
  sua volta usa **hardlink verso uno store globale**. Congelarlo spezzerebbe gli
  hardlink: `mkfs.erofs` li conserva *dentro* l'immagine, ma il legame con lo
  store esterno si perde, e la deduplicazione globale di pnpm si trasforma in
  copie. Sarebbe un peggioramento, e silenzioso.
- **`yarn PnP`.** Non ha `node_modules`. Non c'è niente da congelare.
- **Monorepo e workspace.** `npm` isserebbe alla radice, ma non sempre e non
  tutto. La struttura di `.npz/` li reggerebbe senza modifiche (§5); la
  classificazione dei comandi e la scelta di *quale* albero congelare no. In v1
  i `node_modules` annidati vengono **rilevati e segnalati**, non gestiti.
- **Il timer di inattività.** Fase 2, tarato su N5.
- **Cancellare `.npz` da solo.** Lo fa `npz detach`, che è l'unica via
  supportata: cancellare `.npz` a mano con il mount attivo lascia due demoni FUSE
  appesi su strati che non esistono più.

---

## 12. Fase 0 — il banco

`freeze` è nato da una fase 1 di script buttati via che ha riscritto
l'architettura due volte. `npz` ha due domande che possono ucciderlo, e costano
giorni misurarle contro settimane implementarle. **Nessun codice di prodotto
prima di questi otto numeri.**

Il banco è [test/fase0.sh](../npz_python/test/fase0.sh), gli esiti in
[test/report-fase0.md](../npz_python/test/report-fase0.md). Non serve root: tutto lo stack è
`erofsfuse` più `fuse-overlayfs` in user space. Sei scenari su otto sono stati
eseguiti; i risultati stanno in §12 bis.

| | Scenario | Perché può cambiare il disegno |
| --- | --- | --- |
| **N1** | `npm ci` e `npm install` su un progetto vero: sullo stack contro nativo. Tempo, byte del delta, inode del delta | è il numero che decide se il progetto è utilizzabile. La fase 1 di `freeze` ha misurato **letture** (S6: 8.591 file/s, più veloce del grezzo) e scritture su alberi giocattolo (S1). Il carico di `npm` è l'opposto: centinaia di migliaia di `lstat`, `mkdir`, `rename`, `unlink`, ognuno attraverso due demoni user space, più il copy-up di ogni file toccato |
| **N2** | `npm install <pacchetto>` incrementale, dieci volte di fila: quanto cresce il delta a ogni giro | tara le due soglie di §9. Senza, sono numeri inventati |
| **N3** | `vite build`, `tsc --noEmit`, `jest` sullo stack contro nativo | atteso pari o meglio per S6, ma su un albero vero e non su un campione di 5.000 file |
| **N4** | consolidamento su un `node_modules` da 45.000 file | il taccuino dichiara **aperto** il costo del `purge` oltre i 12.000 file. Qui è in mezzo alla strada dell'utente |
| **N5** | scansione di `/proc` ogni minuto per una giornata di lavoro: quante volte `processi_attivi()` sarebbe non vuoto | decide §10 e il timer di §6. Se la risposta è "quasi sempre", il rifiuto educato non basta |
| **N6** | costo del percorso veloce dentro un `npm run` in loop, a freddo e sotto carico | **già misurato a riposo** (13 ms contro 121, §7): resta da vedere se regge a cache fredda e con la macchina occupata. È la misura che decide se `npz` va portato su un binario compilato |
| **N7** | `vite dev` con HMR e `jest --watch` attraverso `fuse-overlayfs` | gli eventi inotify attraversano l'overlay in user space? È il modo più probabile in cui `npz` rompe il ciclo di sviluppo senza dare errori |
| **N8** | riavvio con un mount attivo; poi con l'unità `ExecStop` installata | verifica sperimentale di §6: cosa resta davvero, e l'autoriparazione lo risolve |

### Quel che è già misurato

Fatto durante l'analisi, e già acquisito:

| Verifica | Esito |
| --- | --- |
| `fuse-overlayfs`, `lowerdir` con **spazi**, percorsi assoluti | **funziona**. La nota in [mounter.sh:26-29](../npz_python/mounter.sh#L26-L29) è più severa del vero |
| `fuse-overlayfs`, `lowerdir` con **due punti**, percorsi assoluti | **fallisce**: `cannot resolve path .../con` |
| gli stessi due casi con percorsi **relativi** dopo `chdir` | **funzionano entrambi** |
| il mount è un confine di filesystem vero | sì: `st_dev` distinto, `find -xdev` 2 file contro 302, `du -x` 16 K contro 1,3 M, `rsync -ax` 5 voci contro 308 |
| `require()` attraverso lo stack | risolve normalmente |
| `mv` e `rm -rf` sul mountpoint | **EBUSY**, ma `rm -rf` svuota prima di fallire |
| `rename` e hardlink attraverso il confine | **EXDEV** |
| filesystem di `/mnt/400GB_FastData` | `fuseblk` — `idoneita()` lo rifiuta, e ha ragione |
| filesystem di `$HOME` e `/var/tmp` | `ext4` |
| `KillUserProcesses` | `no`: al logout i demoni FUSE sopravvivono |
| uptime fra riavvii, ultimi otto | 1h47 – 17h57, sempre con spegnimento notturno |

**Da cui una regola di implementazione:** `npz` fa `chdir` in `.npz/` e passa a
`fuse-overlayfs` percorsi **relativi**. Costa una riga, e rende il montaggio
immune a qualunque percorso di progetto l'utente abbia — che è una garanzia che
`freeze`, girando su un testbed scelto, non ha mai dovuto dare.

### Criterio di uscita

- **N1 entro 2×** rispetto al nativo. Oltre, il disegno cambia: si scongela prima
  di ogni comando mutante e si ricongela dopo, e `npz` diventa un altro
  strumento.
- **N5 dà una risposta netta** su quale delle tre uscite di §10 implementare.
- **N7 verde**, o una via d'uscita documentata: un ciclo di sviluppo senza HMR
  non è un ciclo di sviluppo.
- N2 e N4 producono numeri, non verdetti: servono a tarare, non a decidere.

---

## 12 bis. Fase 0 — esiti

Fixture: `next` + `react` + toolchain reale (eslint, jest, webpack, babel,
storybook, vite, tailwind, sass, prettier, typescript) — **879 pacchetti,
31.667 voci, 588 MiB**. Non i 45.000 del piano, ma lo stesso ordine di
grandezza; le conclusioni al di sopra di questa scala vanno riverificate.

Primo freeze: **1,74 s**, immagine di **234 MiB** da 588 (−60%). Montaggio dello
stack completo: **0,07 s**.

Tutti i rapporti qui sotto sono **intervalli su tre corse**, non valori singoli:
la varianza fra una corsa e l'altra è reale e in un caso conta (N3).

### N1 — il criterio di uscita è superato, ma solo perché il caso patologico si intercetta

| | nativo | sullo stack | rapporto |
| --- | --- | --- | --- |
| `npm install` idempotente | 1,3 s | 1,9–2,1 s | **1,47–1,56×** ✔ |
| `npm ci` | 9,2 s | 28–32 s | **3,04–3,51×** ✘ |

Il caso normale — l'utente lancia `npm install` e non cambia niente — costa il
56% in più e lascia **460 KiB di delta in una sola voce**. È il caso che si
ripete dieci volte al giorno, ed è dentro il criterio.

`npm ci` è fuori di tre volte, e la misura conferma la tesi di §8 in ogni sua
parte: **il delta diventa 588 MiB in 35.222 voci**, cioè una copia intera
dell'albero. Immagine più delta fanno **821 MiB contro i 588 MiB del nativo** —
il 40% di spazio in più, e tutti gli inode tornati indietro. Non è una
penalizzazione di velocità: è la negazione del prodotto. `npm ci` va intercettato
e portato sull'albero nudo, come già scritto in §8. Con quell'interruttore, N1
passa.

### N2 — la soglia sui byte è lo strumento sbagliato

Dieci `npm install <pacchetto>` in fila, dal delta vuoto:

| dopo | delta | voci | vale sull'immagine |
| --- | --- | --- | --- |
| 1 install | 5,4 MiB | 1.056 | 2,3% |
| 5 install | 15 MiB | 2.488 | 6,4% |
| 10 install | **17 MiB** | **2.970** | **7,0%** |

La soglia del 30% dei byte proposta in §9 **non viene sfiorata**: servirebbero
oltre quaranta installazioni. Quella sui file invece sì — 2.970 voci sono il
**9,4%** dell'albero, quindi il 5% che avevo proposto scatterebbe già alla
seconda installazione, e con un consolidamento da tredici secondi sarebbe una
tassa. **Le due soglie vanno riscritte: il 30% sui byte è inerte, e quella sui
file va portata attorno al 10%**, che su questi numeri corrisponde a
consolidare ogni dieci installazioni circa.

Tre installazioni su dieci (`ms`, `picocolors`, `debug`) hanno prodotto **delta
zero**: erano già presenti come dipendenze transitive. Il wrapper deve
controllare il delta, non fidarsi del fatto che un comando mutante sia stato
lanciato.

### N3 — i carichi veri non soffrono, il sintetico sì

| | rapporto sullo stack |
| --- | --- |
| `vite build` | **1,03–1,08×** |
| `tsc --noEmit` | **1,04–1,20×** |
| resolve storm (3.000 file, ordine sparso) | **1,30–1,93×** |

I carichi veri sono quelli che soffrono meno — `vite build` è a un ventesimo di
scarto — e lascia **4 KiB di delta in zero voci**: non sporca.

**La resolve storm è però l'unica metrica di tutta la fase 0 che si avvicina al
criterio di uscita**, e oscilla molto: 1,30× in una corsa, 1,93× in un'altra,
sullo stesso campione. Va tenuta d'occhio, con due avvertenze che ne
ridimensionano la gravità: è un caso peggiore sintetico — 3.000 `cat` in ordine
casuale, senza alcuna località — e nessuno strumento reale legge così. Quando a
leggere è un bundler vero, il rapporto crolla a 1,05.

### N4 — il consolidamento costa tredici secondi, ed è il numero da tenere d'occhio

Ciclo completo (smonta → ricostruisci dalla vista fusa → rimonta) su un delta
da 14 MiB: **12–15 s** su cinque misure, contro **1,74 s** del primo freeze. Non è il 4% del primo
freeze che la fase 1 di `freeze` aveva misurato su alberi da 12.000 file: qui è
**sette volte tanto**, perché il consolidamento rilegge l'intero albero
attraverso due strati FUSE mentre il primo freeze lo legge da ext4. Il taccuino
dichiarava aperto il costo del `purge` alla scala vera: questa è la risposta, ed
è la voce di costo più alta di tutto il progetto.

Correttezza verificata: la vista fusa coincide con quella pre-consolidamento,
l'albero è identico dopo, il delta è assorbito.

**Un'alternativa provata e non dimostrata.** Se il collo di bottiglia è la
lettura via FUSE, copiare prima l'albero su ext4 e costruire da lì dovrebbe
convenire. Misurato nei due ordini di esecuzione:

| | gira per prima | gira per seconda |
| --- | --- | --- |
| dalla vista fusa | 12,97 s | **7,03 s** |
| con staging su ext4 | 11,51 s | 12,32 s |

L'effetto della **page cache vale sei secondi**; la differenza fra i due metodi
ne vale uno o due, e il vincitore cambia con l'ordine. **Non si conclude
niente**, e senza `drop_caches` — cioè senza root — non si può concludere. Il
disegno di §9 resta: leggere dalla vista fusa non ha alcuno svantaggio
dimostrato, e lo staging aggiunge una copia intera e un requisito di spazio
temporaneo in cambio di niente di misurabile.

*(La prima versione di questa misura dava un verdetto netto a favore dello
staging. Era falsa: il banco creava il delta a mount smontato, scrivendo
l'albero vero dentro il mountpoint e nascondendolo poi sotto il mount.)*

### N6 — il wrapper in Python regge

| | percorso veloce | `npm run` vuoto | sovraccarico |
| --- | --- | --- | --- |
| a riposo | 14,1–14,3 ms | 127–129 ms | **10,9–12,9%** |
| sotto carico (4 scansioni parallele) | 15,7–16,7 ms | 131–134 ms | **11,1–12,4%** |

Sotto carico il wrapper cresce di un paio di millisecondi e npm di tre: il
rapporto **non peggiora**. La decisione di §3 — Python in fase 0/1, binario in
fase 2 — non ha urgenza di essere anticipata.

### N7 — i watcher funzionano

`fs.watch` di node — cioè quello che usano chokidar, vite e jest sotto il
cofano — riceve gli eventi attraverso `fuse-overlayfs` esattamente come sul
nativo. È un criterio di uscita, ed è verde. *(`inotifywait` non verificato:
inotify-tools non è installato.)*

### Quel che resta da misurare

- **N5** — richiede una giornata di lavoro vera con l'editor aperto sulla
  cartella. Il campionatore c'è: `./fase0.sh n5 --for 28800 --intervallo 60`.
  È il numero che decide §10, ed è l'unico criterio di uscita ancora scoperto.
- **N8** — richiede un riavvio: `./fase0.sh n8 --arm`, si riavvia, poi
  `./fase0.sh n8`.

### Verdetto

Il progetto **non è stato ucciso da nessuna delle due domande che potevano
ucciderlo.** Il carico di scrittura di npm sta dentro il criterio nel caso
normale, e il caso patologico ha un interruttore già previsto dal disegno. Restano
due cose da correggere nel piano — le soglie di §9 (N2) — e una da tenere sotto
osservazione: i tredici secondi del consolidamento, che sono il prezzo vero di
`npz` e che nessuno aveva stimato.

---

## 13. Fase 1 — la CLI

Quel che si costruisce, dopo la fase 0:

- ~~il refactoring di `SERVIZIO` da costante a parametro~~ — **fatto** (§4);
- `progetto.py` — `trova()`, e il riuso di `filesystem.idoneita()`;
- `comandi.py`, `veloce.py`, `cli.py` — classificazione, percorso veloce,
  `fork`/`wait` trasparente, i sei comandi intercettati;
- ~~`consolida_npz()` — §9, cioè il `consolida()` di `freeze` senza rotazione~~ —
  **fatto**: `cli.compatta()`, con `npz compact` e la sua uscita `--discard` (§2);
- l'unità utente `npz-smonta.service` con solo `ExecStop`;
- l'eseguibile `npz` — il `lanciatore.py` di §7, collegato da `~/.local/bin/npz`,
  che si localizza da sé invece di ereditare `PYTHONPATH`.

I test che servono davvero:

- **giro completo con confronto byte a byte**: `npm install` nativo → attach →
  monta → `npm install <altro>` → consolida → `detach` → l'albero finale
  coincide con quello che si otterrebbe da un `npm install` nativo delle stesse
  dipendenze;
- **uccisione fra i passi 3 e 10** del consolidamento: rilanciare `npz` deve
  convergere, e la cartella non deve restare nello stato *rotto* senza che
  l'autoriparazione la veda;
- **`npz` in CI**: `CI=1`, niente TTY, `stdin` chiuso. Nessuna domanda, nessun
  congelamento non richiesto, codice di uscita di `npm`;
- **`npz` dentro uno script di `package.json`**: gli script chiamano `npm`, non
  `npz`, e devono continuare a funzionare sull'albero montato.

## 14. Fase 2

Ha un piano proprio: [piano di implementazione fase 2.md](<piano di implementazione fase 2.md>).
Il suo centro è l'unico numero della fase 0 che nessuno aveva stimato — i tredici
secondi del consolidamento (N4) — e l'idea con cui lo attacca: **smettere di
avere una immagine sola**, sigillando ogni delta in uno strato invece di
riassorbirlo nell'immagine intera. Cambia `FORMATO`, e va deciso da sei misure
nuove (N9…N14) prima di scrivere codice di prodotto.

Le tre voci già assegnate a questa fase restano, e non dipendono da quella:

- il timer di inattività, tarato su N5;
- i workspace, se N1 e N5 hanno dato buone notizie;
- `npz` come binario compilato, se N6 dice che i 48 ms si sentono.

---

## Rimandi

- [claim.md](claim.md) — il disegno di `freeze`, di cui questo documento eredita
  le invarianti.
- [taccuino di viaggio.md](<taccuino di viaggio.md>) — le misure che l'hanno
  prodotto, e le idee che hanno smontato.
- [piano di implementazione fase 2.md](<piano di implementazione fase 2.md>) — il
  seguito: una immagine per strato invece di una sola.

`freeze` non vive più in questo repo. I due documenti che restano ne parlano al
presente perché sono suoi, ed è deliberato: le misure che hanno prodotto questo
disegno sono le sue, e riscriverle al passato vorrebbe dire riscriverle.
