# npz — piano di implementazione

`npz` è un wrapper di `npm`. Gira ogni parametro a `npm` tale e quale, e si riserva
tre comportamenti propri: chiede una volta se congelare `node_modules`, lo congela e
lo monta, e con `npz bye` rilascia il mount.

Nasce come seconda facciata sul nucleo di [`freeze`](claim.md), e da quando `freeze`
è uscito dal repo è l'unica. Le tre invarianti — un solo lock, formato versionato,
costruisci prima di cancellare — restano scritte in un posto solo (§4).

---

## 1. Perché non è "freeze con un alias"

La fase 3 di `freeze` prevedeva un demone che deve *indovinare* tre cose. Il wrapper
le sa per costruzione:

| Segnale | Il demone | `npz` |
| --- | --- | --- |
| quando l'albero è cambiato | euristiche sul delta, `tc`, soglia | ogni mutazione passa da `install`, `ci`, `update`, … |
| quando serve montato | mai saputo | il comando `npm` sta per partire |
| quanto è ricostruibile | mai: la cartella è unica | `package-lock.json` la ridetermina per intero |

Il terzo è il più sottovalutato: `node_modules` è **derivabile**, e questo autorizza
`npz` a essere molto più brutale di `freeze` — davanti a una situazione confusa può
buttare via e rifare.

**La conseguenza architetturale più grossa: la rotazione del delta non serve.** Serve
a `freeze` perché consolida sotto un mount vivo (voce 4 del
[taccuino](<taccuino di viaggio.md>)); `npz` possiede l'intera finestra — smonta,
ricostruisce, rimonta — quindi l'intervallo in cui l'utente scrive non esiste. La
parte più delicata del progetto sparisce invece di essere ereditata.

---

## 2. Il mount è la superficie di compatibilità

Lo stato stazionario di `npz` è **montato**, non congelato. Da qui la tentazione di
leggere il mount come una rinuncia: da montati gli strumenti riattraversano tutti i
file. È una lettura sbagliata — da montati i file si vedono **perché si devono
vedere**: `node`, `vite`, `tsc`, il language server e i binari in `.bin` non passano
da `npz` e non devono accorgersi di niente. La domanda giusta è un'altra: **le due
popolazioni di lettori sono distinguibili?**

| Popolazione | Esempi | Deve vedere l'albero |
| --- | --- | --- |
| la toolchain | `node`, bundler, language server, test runner | **sì** — è la ragione per cui `npz` esiste |
| gli attraversatori | backup, antivirus, indicizzatori, `du`, `find` | **no** — sono puro costo |

Sono distinguibili, con un meccanismo che `npz` ottiene gratis: **un mount è un
confine di filesystem.** Misurato sullo stesso progetto, stesso istante:

| | attraversa | si ferma al confine |
| --- | --- | --- |
| `find -type f` | 302 file | `-xdev`: **2** |
| `du -sh` | 1,3 M | `-x`: **16 K** |
| `rsync -an` | 308 voci | `-x`: **5** |
| `tar` | tutto | `--one-file-system`: **5 voci** |

Prima di `npz`, escludere `node_modules` richiede che *ogni* strumento abbia una
regola per nome, scritta a mano. Dopo, è un confine di filesystem — la primitiva di
esclusione più universale che Unix offra — e gli attraversatori ci si fermano **senza
sapere nulla di `npz`**. Come mount point la cartella è *più* escludibile di quanto
fosse come directory.

**Il costo che resta.** Gli attraversatori che non usano `-x` non guadagnano nulla, e
vedono gli stessi file più lentamente, attraverso due demoni user space. E `du` sul
progetto riporta la dimensione espansa, perché legge la vista fusa: 1,3 M contro i
16 K occupati — i due numeri divergono di proposito, ed è confondente, quindi
`npz status` deve dirli entrambi. Da cui la politica di smontaggio **scende di
rango**: non ricompra metà del valore, ricompra una fascia stretta. Resta
obbligatorio lo smontaggio *ordinato* di §6, che serve alla correttezza dello stato al
riavvio.

### Cosa cambia quando `node_modules` è un mount point

| | Come cartella | Come mount point |
| --- | --- | --- |
| visibile a `-x` | sì | **no** — la voce per cui vale la pena |
| `mv node_modules node_modules.bak` | funziona | **EBUSY** |
| `rm -rf node_modules` | cancella | **svuota tutto**, poi fallisce sul mountpoint |
| `rename(2)` fra progetto e albero | funziona | **EXDEV** |
| hardlink dal progetto dentro l'albero | funziona | **EXDEV** |

npm nella configurazione predefinita non hardlinka dalla cache e non rinomina
attraverso il confine, quindi nessuna di queste righe lo tocca.

**La terza riga è un pericolo, non una curiosità.** `rm -rf node_modules` cancella
l'intero contenuto della vista fusa — whiteout nel delta per ogni voce — e fallisce
solo sull'ultimo `rmdir`. L'immagine resta intatta, ma l'utente vede una cartella
vuota e un errore che molti script ignorano. È lo stesso meccanismo di `npm ci` (§8):
`npz` riconosce un delta che copre di whiteout l'intero albero e chiede se buttarlo —
tornando all'immagine in un istante — o completare con `bye`.

---

## 3. Le decisioni prese

| Questione | Decisione | Conseguenza accettata |
| --- | --- | --- |
| che cosa lascia `npz bye` | **lo stato congelato**: smonta, rimuove la cartella, tiene `.npz` | il prossimo comando rimonta in <0,1 s; lo spazio resta occupato |
| dove vivono delta e workdir | **dentro `.npz/`**, accanto al progetto | `npz` rifiuta i progetti su filesystem non idoneo |
| quando si rilascia il mount | unità utente con `ExecStop` + autoriparazione a ogni invocazione | serve alla correttezza al riavvio, non al beneficio |
| perimetro | solo `npm`, solo il `node_modules` alla radice | `pnpm` e `yarn PnP` fuori (§11); gli annidati si segnalano |
| lingua | Python in fase 0/1, binario compilato dopo | **13 ms** contro i **121 ms** di `npm run`. Vale solo con la disciplina sugli import di §7 |

**Node.js valutato e scartato.** Sarebbe la scelta ovvia per un wrapper di npm, ed è
il candidato peggiore sull'asse che conta: percorso veloce **13,4 ms** in Python
contro 36,4 (CommonJS) e 38,0 (ESM) — e il **pavimento** di Node, processo vuoto e
zero codice, costa **29,9 ms**, più del doppio del percorso veloce completo di Python.
Sopra i millisecondi, due mancanze strutturali: **`fs.flock` non esiste** (servirebbe
un addon nativo, o un lock che non si rilascia alla morte del processo), e **nessun
`exec` che sostituisca il processo** — Node deve sempre generare un figlio e restare,
con decine di MB fermi per tutta la durata di un `npm run dev`.

---

## 4. Architettura: il nucleo e la facciata

Il nucleo è [`npz_python/lib/`](../npz_python/lib/), la facciata è `npz_python/`
stesso. La separazione è quella fra **meccanismo** e **politica** — `lib` sa
costruire, montare e tenere lo stato; sa *dove* farlo solo chi lo chiama. Tutti i
moduli del nucleo sono ereditati **invariati** da `freeze`: `immagine.py`, `mount.py`,
`stato.py`, `perimetro.py`, `filesystem.py`. Quel che non si è ereditato era politica
di `freeze` ed è uscito dal repo con lui: `radice.py`, `segnaposto.py` e la sua CLI.

**La separazione sopravvive alla ragione che l'aveva prodotta.** Il nucleo era stato
estratto per servire due facciate; ora ne serve una sola, e si guadagna ancora il
posto per un motivo diverso: `lib` è **dove stanno le invarianti**, e tenerle in un
modulo che non sa niente di `.npz`, di `package.json` e di npm è ciò che permette di
leggerle senza leggere la politica che le usa.

**Il refactoring che abilita tutto ✔** — *fatto.* `SERVIZIO` e `SENTINELLA` erano
costanti di modulo e portavano i nomi di `freeze`: finché stavano lì, `lib` era
condiviso nella struttura ma non nel comportamento. Sono diventati un `Profilo` che la
facciata costruisce e passa al nucleo, con nove firme toccate e **zero righe nuove in
`lib`**. E qui c'è la conferma che la parametrizzazione non era un lusso per due
gemelli: con una facciata sola i profili in gioco restano **due**, perché la cartella
di servizio si chiama `.npz` da montati e `node_modules.frozen` da fermi (§5) — se
`SERVIZIO` fosse ancora una costante, quella sezione non si potrebbe implementare. Il
**segnaposto** invece non è entrato nel profilo: è uscito da `lib`, perché `npz` ha
deciso di non averne.

**Una radice per progetto.** `freeze` risaliva fino a una radice dichiarata a mano con
`init`, e rifiutava di annidarne una dentro un'altra: due regole giuste per una radice
condivisa e sbagliate qui. `npz` usa la prima cartella che, risalendo, contiene un
`package.json` — lo stesso criterio con cui npm decide dove sta il progetto, perché
usarne un altro produrrebbe divergenze silenziose. Va invece riusata **integralmente**
`filesystem.idoneita()`, che sta in `lib` proprio perché è **un fatto sul supporto e
non una scelta**: è la riga di confine più netta fra nucleo e facciata.

**Il nucleo non sa che esiste la facciata**: le dipendenze vanno in una direzione
sola, e la condivisione avviene per import, mai per copia. E **il nome `npz_python`
non è una goffaggine: è una data di scadenza.** Chiamare la cartella `npz` avrebbe
fatto del passaggio al compilato una sostituzione in cui la vecchia implementazione
non ha più un posto dove stare; così è un'aggiunta, e le due possono convivere per il
tempo in cui la nuova va confrontata con la vecchia — che è l'unico modo di
sostituirla senza fidarsi.

---

## 5. La struttura su disco

```text
progetto/                            ← qui sta package.json
├── package.json · package-lock.json
├── node_modules/                    ← mountpoint. Esiste SOLO da montati.
│   └── .npz_mount_caduto_…          ← sentinella, coperta dall'overlay
└── .npz/                            ← da fermo si chiama `node_modules.frozen`
    ├── config · lock
    ├── static/node_modules.img · .meta   ← l'immagine EROFS lz4hc
    ├── dynamic/node_modules/        ← il delta scrivibile
    └── run/node_modules/            ← esiste SOLO col mount: lower · work · fusione
```

**Le due famiglie non si mescolano, e il livello superiore lo dice.** `static/` e
`dynamic/` sono i dati, e i loro nomi appartengono a `FORMATO`; `run/` è lo stato di
esercizio, che il montaggio ricrea con un `mkdir`. Da cui una regola sola: *a riposo
`run/` non esiste; se esiste e non è vuota, un mount è morto a metà.*

`work` sta lì perché overlayfs lo esige **sullo stesso filesystem dell'upperdir**: il
copy-up di un file grosso viene materializzato lì e poi spostato nel delta con un
`rename(2)`, che è ciò che rende impossibile trovare nel delta un file a metà.
Misurato: con workdir su tmpfs e delta su ext4 il mount riesce e il primo copy-up
fallisce con **EXDEV**. È lo stesso vincolo che obbliga `.npz/` a stare accanto al
progetto e fa esistere `filesystem.idoneita()`.

### Il nome è lo stato

Da montati `ls` mostra `node_modules` · `.npz` · `package.json` e il progetto ha
l'aspetto di sempre; da fermo mostra `node_modules.frozen` · `package.json`. Nasce da
un'osservazione semplice: da fermo, un progetto con un `.npz` nascosto e nessun
`node_modules` **sembra un progetto a cui manca qualcosa**, e col nome visibile smette
di sembrarlo e comincia a dirlo. Non è un segnaposto — è la stessa cartella col nome
giusto, e **un nome non può disallinearsi da sé**: è per questo che il segnaposto di
`freeze` qui non serve.

**Ferma vuol dire anche più magra**: `run/` cade all'addormentamento. Per la stessa
ragione il congelamento **sveglia prima di cominciare** — costruire dentro il nome
fermo lascerebbe, se qualcosa andasse storto, una cartella che si dichiara a riposo
mentre contiene un'immagine incompleta. Tre dettagli che non sono liberi:

- **la rinomina avviene fuori dal lock**: `flock` sta sull'inode e sopravvive, ma la
  finestra fra `nome_servizio()` e `open()` va tenuta stretta;
- **entrambi i nomi vanno in `.git/info/exclude`** — non nel `.gitignore` del
  progetto, che è un file versionato dell'utente;
- **il percorso veloce paga un `os.stat` in più** per sapere quale dei due c'è. Sotto
  la soglia di misurabilità: i 14 ms sono dominati dall'avvio di Python.

---

## 6. Il ciclo di vita

Ogni invocazione comincia riconoscendo lo stato in cui si trova.

| Stato | cartella di servizio | `node_modules/` | Come ci si arriva |
| --- | --- | --- | --- |
| **vergine** | assente | assente | progetto appena clonato |
| **candidato** | assente | cartella vera | dopo `npm install` senza `npz` |
| **rifiutato** | `.npz/no` | cartella vera | l'utente ha detto no |
| **congelato** | `node_modules.frozen/` | **assente** | dopo `npz bye`, o spegnimento pulito |
| **montato** | `.npz/` | mountpoint | lo stato di lavoro |
| **rotto** | `.npz/` | solo la sentinella | crash, OOM, spegnimento sporco |
| **scavalcato** | l'una o l'altra | albero vero, non montato | `npm` battuto al posto di `npz` (§6 bis) |

*(L'implementazione ne espone otto, coi nomi che `npz status` stampa alla lettera:
`outside`, `candidate`, `declined`, `fresh`, `mounted`, `attached`, `broken`,
`bypassed`.)*

**La regola che li governa: da non montati la cartella non deve esistere.** Se resta
lì vuota, un builder non dice "manca `node_modules`" — dice `cannot find module
'react'`, che è molto peggio da diagnosticare, e lo dice a strumenti che non passano
da `npz`. Lo stato *assente* è invece indistinguibile da "mai installato", l'unico
errore che tutto l'ecosistema JavaScript già sa raccontare. Quindi: montare è
`mkdir` + `mount`, smontare è `umount` + `rmdir`.

**Lo smontaggio deliberato.** Misurato: `KillUserProcesses=no`, quindi al logout i
demoni FUSE sopravvivono; allo spegnimento vengono uccisi e i mount staccati, ma per
uccisione, non per smontaggio — il `rmdir` non avviene mai, e al riavvio ogni progetto
è **rotto**. L'uptime sugli ultimi otto avvii va da 1h47 a 17h57: i mount non si
accumulano nel tempo lungo, si accumulano dentro la giornata. Da cui:

- **fase 1, obbligatoria** — unità systemd utente con solo `ExecStop`, che smonta
  ordinatamente tutti i progetti registrati;
- **fase 1, rete di sicurezza** — autoriparazione a ogni invocazione: immagine
  presente, cartella esistente, mount assente, sentinella presente → rimonta in
  silenzio. Copre crash e OOM, che l'`ExecStop` non copre;
- **fase 2, da misurare** — timer di inattività, che compra poco (§2). Lo decide N5.

---

## 6 bis. Lo scavalcamento

Prima o poi qualcuno batterà `npm`, e `node_modules` tornerà a esistere alle spalle di
npz — da un IDE, da uno script, o da un'abitudine di dieci anni. I due sotto-casi si
comportano in modo opposto.

**Da montati non succede niente di male.** npm scrive nell'overlay, tutto finisce nel
delta, la vista fusa resta corretta. È una **degradazione silenziosa**, non un guasto:
il delta cresce e nessuno lo dice. Il rimedio esiste già ed è `npz compact`.

**Da fermi è un vicolo cieco.** Con `node_modules.frozen/` in giro, `npm install`
ricostruisce un albero vero e il progetto ne ha due. Misurato: `npz status` dice
*broken* mentre nulla è rotto, e `hey`, `attach`, `compact` **e persino `ls`**
rifiutano. **npz smette di essere trasparente e diventa un ostacolo**: blocca comandi
che npm da solo eseguirebbe benissimo, mentre il disco paga due volte.

**Il settimo stato.** La causa è che *rotto* confonde due situazioni senza niente in
comune: il **nostro** mountpoint scoperto dopo uno spegnimento — dentro c'è solo la
sentinella, e l'autoriparazione è giusta — e un albero **estraneo**, che npz non ha
costruito e su cui non deve montare niente. La discriminazione è uno `scandir` che
esce alla prima voce che non è la sentinella, e si paga solo nel ramo non montato.

**Non si fonde.** La tentazione, davanti a due alberi, è unirli, e non è questione di
sforzo: non sono due rami della stessa cosa, sono due soluzioni distinte dello stesso
problema di vincoli, calcolate da npm in momenti diversi. Non c'è antenato comune né
provenienza per file, e un'unione darebbe `react` da un albero e `react-dom`
dall'altro, a versioni mai risolte insieme. Il guasto che ne uscirebbe è del tipo
peggiore: **l'albero funziona.** Node risolve quel che trova, il build passa, e il
difetto salta fuori a runtime in un punto che con npz non c'entra niente. Si sceglie
**un albero intero**, e quello che perde non si cancella.

**Dove si aggancia.** Tutto ciò che richiede l'espansione dell'immagine passa da
`assicura_montato()`: un imbuto solo, e la procedura sta lì e da nessun'altra parte.
Fuori dall'imbuto npz **non si mette in mezzo**, perché l'albero è reale e completo:
un comando neutro riceve una riga di avviso, un mutante lavora sull'albero vero e a
esito zero si propone l'adozione. **Senza TTY non si chiede e non si tocca niente** —
meglio un npz che sparisce di un npz che blocca `npm run build` in pipeline — e ne
segue, e va accettato, che **in CI un progetto scavalcato resta scavalcato**. Con un
TTY, tre uscite e nessuna è la fusione: tenere la cartella che npm ha costruito,
tenere l'immagine, o non fare niente.

**Si mette da parte, non si cancella.** Il precedente è `metti_da_parte()`, che prima
di un `npm ci` rinomina l'immagine invece di cancellarla, *perché cancellare
distruggerebbe lo stato congelato prima di sapere se npm riuscirà*.

| Vince | Copia ridondante | Dove finisce |
| --- | --- | --- |
| l'immagine | l'albero che npm ha ricreato | `node_modules.superseded/` nella radice |
| la cartella di npm | l'immagine vecchia e il suo delta | `*.superseded` dentro la cartella di servizio |

L'albero messo da parte sta **in vista**: è la copia grossa — 588 MiB contro 234 — e
nasconderla dentro `.npz/` significherebbe seppellire il costo che npz esiste per
togliere. **`npz detach` la nomina prima di sparire**: dichiarare che di npz non resta
niente lasciando lì una `node_modules.superseded/` sarebbe falso. E **una sola copia
per volta, per costruzione**: se la procedura scatta di nuovo si chiede il permesso di
togliere la prima, senza accostarne una seconda — altrimenti il failsafe diventa
`.superseded.2`, `.superseded.3`, cioè la perdita di spazio che doveva evitare.

**La raccolta va a orologio, non a contatore.** Le copie non restano appese: npz torna
a chiedere se toglierle. Ma contare le invocazioni vorrebbe dire tenere un contatore,
ed è il pezzo di stato che §5 ha deciso di non scrivere; l'`mtime` della copia è già
sul filesystem, dentro lo stesso `stat` che serve ad accorgersi che la copia esiste, e
misura la cosa giusta — non "cinque comandi", ma *aver avuto il tempo di accorgersi se
serviva ancora*. La grazia è di **1 giorno** per l'immagine vecchia (è un file solo,
superata da una immagine verificata) e **7 giorni** per l'albero di npm (è
l'annullamento dell'utente, la scelta più sospetta). Rispondere **no non registra un
rifiuto: rimette l'orologio a zero** con un `utime` — *l'`mtime` è la memoria*, quindi
il meccanismo non si può inchiodare e non nagga. Senza TTY non si cancella mai niente;
`npz status` elenca comunque le copie con quanto occupano.

---

## 7. Il percorso veloce e il percorso lento

`npz` sta davanti a ogni `npm run` di ogni ciclo di sviluppo. Il caso normale — già
montato, comando neutro — deve costare **tre `stat`**: l'immagine esiste?
`node_modules` è un mountpoint? il comando è fra i mutanti? Poi `exec` di npm. Niente
lock, nessuna scansione di `/proc` — che costa decine di millisecondi su una macchina
carica e serve solo prima di uno smontaggio. Il lock va preso solo per montare,
congelare e consolidare, altrimenti due `npm run` in parallelo si serializzerebbero.

### La disciplina sugli import è il vero costo, non la lingua

| | ms |
| --- | --- |
| `python3 -SE`, solo `os` e `sys`, tre `stat`, `execvp` | **13** |
| `import os, sys, pathlib, subprocess` | 39 |
| il pacchetto intero | 49 |
| giro vero, via naturale | 75 |
| `npm run <script vuoto>` | 121 |

Fra i 13 ms disciplinati e i 75 della via naturale ci sono **62 ms**; fra Python e un
binario compilato ce ne sono dieci. **La lingua non è la variabile dominante**: lo è la
scelta di non importare nulla sul percorso veloce. Da cui tre regole vincolanti:
shebang `-SE`; niente `pathlib`, `subprocess`, `argparse` sul percorso veloce; tutto il
resto dietro un import ritardato dentro le funzioni che lo usano.

**Il lanciatore** è un file Python, non uno script di shell: risparmia il fork di bash,
ed è il posto dove il percorso veloce deve vivere. Tre dettagli non stilistici:
**`env -S`** è ciò che permette due flag nello shebang; **`-E` ignora `PYTHONPATH`**,
quindi il lanciatore si localizza da solo con `realpath(__file__)` — un comando globale
non deve dipendere dall'ambiente di chi lo invoca, e `realpath` è anche ciò che lo
rende **collegabile**, perché attraverso un symlink `__file__` è il link e non il
bersaglio; **`NPM` va risolto a un percorso assoluto** e confrontato col lanciatore
stesso, perché un wrapper che esegue `npm` per nome, su una macchina dove qualcuno ha
messo un `npm` che punta a `npz`, entra in ricorsione infinita.

Il montaggio ha una corsa: due `npz` che trovano entrambi "non montato" e montano
entrambi. Si prende il lock e si **ricontrolla sotto il lock**.

**Trasparenza del wrapper.** Dove dopo `npm` c'è lavoro da fare non si può fare `exec`:
serve `fork` + `wait`, e da lì quattro obblighi — il codice di uscita di `npm` è quello
di `npz`, sempre; `stdin`/`stdout`/`stderr` passano invariati, **compresa la loro
natura di TTY**; `SIGINT` e `SIGTERM` vengono inoltrati; ogni messaggio va su
**stderr** e ogni domanda su `/dev/tty`, perché `npm view react --json | jq` non deve
trovare parole di `npz` nella pipe.

### La voce di `npz`

Sullo stesso terminale parlano in due, a turno. Ogni riga di `npz` porta una **sbarra
verticale** tinta, che si apre con una testa e si chiude con una coda:

```text
 ╥
 ║  in questo progetto c'è un node_modules da 31.667 file (588 MiB).
 ║  Posso comprimerlo in una immagine sola e montarlo al suo posto:
 ║    · lo spazio scende di circa due terzi, gli inode a uno
 ║  Procedo? [s/N] s
 ╨
```

Testa e coda **delimitano il turno di parola, non il messaggio.** Quel che sta dentro è
di `npz`, quel che sta sotto la coda è di `npm` — l'unica cosa da sapere leggendo lo
scroll di un `npm install` andato storto. Da cui:

- **si chiude prima di ogni consegna a `npm`**, cioè prima dell'`execv` e prima del
  `fork`. Non è cortesia tipografica: `execv` non fa girare gli `atexit`, e il `fork`
  duplicherebbe i buffer non svuotati, facendo comparire le righe due volte;
- **il colore sta sul segno, mai sul testo**, così il testo resta copiabile. Giallo
  `faint` quando `npz` racconta, che si compone col fondo vero invece di richiedere un
  giallo scelto sapendo se il tema è chiaro o scuro; rosso pieno quando si ferma,
  perché un errore non sussurra, e detto a metà turno tinge anche la coda;
- **niente colore se il flusso non è un terminale**: il segno resta, l'escape no;
- **il segno sta su ogni riga**: una riga nuda in mezzo a un blocco di `npz` sembra
  output di `npm`.

Sul percorso veloce non costa niente: se `npz` non dice nulla non stampa nulla.
Misurato dopo l'aggiunta: **13,9 ms**.

**La conferma** si chiede una volta sola, e la risposta si ricorda in `.npz/config` —
**anche il "no"**, altrimenti si richiede per sempre. Non si chiede se `stdin` non è un
TTY, se `CI` è valorizzata, o se c'è `--yes`. Si chiede **prima** che `npm` parta, così
l'utente non viene sorpreso alla fine, ma si agisce **dopo** (§8).

---

## 8. I comandi

Sei intercettati, coi nomi in inglese come tutta la superficie di npm: la CLI parla la
lingua di chi la usa, il codice sotto resta in italiano.

| Comando | Effetto | |
| --- | --- | --- |
| `npz attach` | attiva npz su questo progetto adesso, senza chiedere niente | ✔ |
| `npz detach` | materializza `node_modules` come cartella vera e cancella `.npz` | ✔ |
| `npz hey` | monta ciò che `attach` ha già costruito; non costruisce mai | ✔ |
| `npz bye` | smonta, rimuove la cartella, tiene `.npz` | ✔ |
| `npz status` | in quale stato siamo, quanto è grande l'immagine, quanto il delta | ✔ |
| `npz compact` | forza il consolidamento adesso | ✔ |

**`npz attach` scavalca la domanda**, e anche un no già dato: chi lo scrive ha già
deciso. **`npz hey` è il contrario esplicito di `bye`**, per chi vuole vedere l'albero
senza lanciare npm; su un progetto mai attaccato rifiuta e lo dice. **`npz detach` è la
via d'uscita, e senza di essa il sistema non si adotta**: in un sistema in cui si può
solo entrare non entra nessuno. Rispetta i tre tempi — l'albero vero nasce accanto a
quello montato, viene confrontato con la vista da cui proviene (**attributi, non
nomi**, con lo stesso `img.differenze()` che il congelamento usa al contrario), e solo
allora prende il suo posto.

Tutto il resto va a `npm` invariato, e vale l'inverso: `npz -- attach` passa `attach` a
npm. `npz` **senza argomenti** stampa il proprio aiuto e a seguire quello di npm:
l'ordine è il messaggio.

### La classificazione

| Classe | Comandi | Cosa fa `npz` |
| --- | --- | --- |
| **neutri** | `run`, `test`, `view`, `ls`, `outdated`, … | assicura il mount, esegue, esce |
| **mutanti** | `install`, `uninstall`, `update`, `dedupe`, `prune`, `link` | assicura il mount, esegue, **poi** valuta il consolidamento |
| **distruttivi** | `ci` | vedi sotto |

Va sbagliata **per eccesso**: un comando classificato mutante per errore costa un
controllo del delta che trova zero; un mutante non classificato lascia crescere il
delta senza che nessuno se ne accorga.

**`npm ci` è il caso patologico.** Cancella `node_modules` prima di installare, e
sull'overlay significa whiteout per 45.000 voci, poi 45.000 file veri riestratti nel
delta: l'immagine diventa peso morto e il risultato ha **più inode di prima di usare
`npz`**. Va intercettato prima di eseguirlo — `smonta → cancella immagine e delta →
npm ci sull'albero nudo → congela` — così i whiteout non vengono mai scritti e `npm ci`
gira alla velocità nativa. Il gemello non intercettabile è `rm -rf node_modules`
battuto a mano: si riconosce solo **dopo**, dal delta che copre di whiteout l'intero
albero (§2).

### Quando si congela: dipende dal comando

Se l'utente scrive `npz install lodash` su un progetto candidato, la sequenza giusta è:
chiedi → esegui `npm install` sull'albero vero → congela l'assestato → monta. Congelare
prima significherebbe costruire un'immagine e subito duplicarne un pezzo.

**Ma questa regola vale per i mutanti soltanto.** Applicata ai neutri produce un
difetto silenzioso, osservato sul campo con `npz run dev` su un progetto candidato: npz
chiede, l'utente dice sì, `vite` gira per ore, ctrl-c, npm esce 130, e **npz non crea
niente e tace**. Due errori: per un comando neutro **il codice di uscita di npm non
dice niente dell'albero** (`npm test` esce 1 se un test è rosso, `outdated` esce 1 di
routine); e **una domanda che ferma chi lavora deve avere una conseguenza che si vede
subito** — se il sì produce l'effetto ore dopo, non era una domanda, era un disturbo.

| classe | quando si attacca | perché |
| --- | --- | --- |
| **neutri** | **prima**, e poi `execv` verso npm | l'albero non lo toccano: il delta nasce vuoto e il comando parte già montato |
| **mutanti** e **distruttivi** | dopo, sull'albero assestato | lo sta componendo npm; congelarlo prima duplicherebbe l'installazione nel delta |

Per i neutri l'attacco è anche più economico: finito il congelamento npz **sparisce
dentro npm** con `execv`. E se attaccare non riesce, il comando dell'utente non è
ostaggio: se ha fallito il *congelamento* — e allora `node_modules` non è stata
toccata, per invariante — si spiega e si consegna comunque a npm; se ha fallito il
*montaggio* ci si ferma, perché un build che non trova `node_modules` produrrebbe un
errore peggiore del nostro.

---

## 9. Il consolidamento, senza rotazione

```text
  1. lock                                    7. smonta fusione e lower
  2. controlla i processi attivi (§10)       8. os.replace(temp, immagine)  ← tempo 2
  3. smonta la vista, smonta il lower        9. rmtree(delta); rmtree(work) ← tempo 3
  4. rimonta il lower ro, monta la fusione  10. rimonta
  5. mkfs.erofs dalla vista fusa → temp     11. unlock
  6. verifica: inventario(fusione) == inventario(temp montata)
```

È il `consolida()` di `freeze` **meno la rotazione**: fra il passo 3 e il 10 la
cartella non esiste, quindi nessuno può scrivere, quindi non c'è la finestra di perdita
dati. Il merge continua a farlo il kernel. Tre conseguenze che il disegno non aveva
scritto:

- **il passo 3 sta dentro il `try` del passo 10**: che una costruzione sia andata male
  non è una ragione per lasciare il progetto senza `node_modules`;
- **il lock non si annida.** `flock` sta sulla descrizione del file aperto: riusare
  `monta()` e `smonta()`, che il lock se lo prendono da soli, lo farebbe fallire contro
  sé stesso. Da cui `_monta`/`_smonta` senza lock;
- **lo stato non cambia.** Chi era montato torna montato, chi era fermo torna fermo: il
  consolidamento cambia l'immagine, non lo stato del progetto.

**Quando.** Dopo un comando mutante, se il delta supera una soglia. Le soglie di
partenza — 30% dei byte, 5% dei file — **N2 le ha smentite entrambe**: si passa al
**10% delle voci** dell'immagine (≈ dieci installazioni fra un consolidamento e
l'altro), tenendo il **30% dei byte** come rete per il caso che i byte crescano senza i
file. E una regola che N2 ha reso evidente: **si guarda il delta, non il comando** —
tre installazioni su dieci non hanno prodotto delta perché il pacchetto c'era già come
dipendenza transitiva.

*Allo stato attuale la soglia non fa scattare il consolidamento: lo **consiglia**, e a
pagare i tredici secondi è l'utente che scrive `npz compact`. Con N4 misurato, far
scattare l'automatismo è una decisione che vuole N5, non un'omissione da colmare.*

**Cosa non deve entrare nell'immagine.** `node_modules/.cache` e `.vite` sono cache di
build: consolidarle è lavoro sprecato che diventa peso permanente, e vanno escluse con
una lista di diniego corta ed esplicita. Ma **escluse non vuol dire perse**: se una di
quelle cartelle sta *già* dentro l'immagine, tenerla fuori dalla nuova la farebbe
sparire a metà, quindi il consolidamento la **sposta** — la copia dalla vista fusa
mentre è ancora montata, e la rimette nel delta dopo il rename. Costa una copia una
volta sola, e tiene l'invariante che conta: *la vista fusa dopo è identica a quella
prima*. Ne segue che **il delta ha due misure** — quanto occupa e quanto ne
assorbirebbe un consolidamento — e la soglia guarda la seconda, altrimenti una cache da
40 MiB reclamerebbe per sempre un consolidamento che non può toglierla di lì.

**Il delta che cancella tutto non si consolida**: consolidare una vista fusa vuota
scriverebbe un'immagine vuota, cioè obbedirebbe a una cancellazione che l'utente
potrebbe non aver voluto. Il comando si ferma e nomina le due uscite di §2.

**`metacopy=on` non va usato.** Rende il copy-up dei soli metadati economico, ma lascia
nel delta riferimenti al lower — e il passo 8 sostituisce il lower. Sarebbe consistente
per via dell'ordine di due righe, e non vale il rischio.

---

## 10. I rifiuti, e il problema che li rende ingestibili

`perimetro.processi_attivi()` rifiuta se qualcuno ha una cwd o un descrittore dentro la
cartella. Per `freeze` è raro; per `npz` è la norma — in un ambiente di sviluppo c'è
**sempre** qualcosa: il server TypeScript, un dev server, un watcher. Senza rimedio,
`npz bye` e ogni consolidamento falliscono quasi sempre. Le uscite, in ordine di
preferenza: **elencare i colpevoli per nome** e fermarsi ✔; **`--force`** con
smontaggio pigro, documentato come rischioso perché le scritture in volo finiscono in
un delta che nessuno rileggerà ✔; **riprovare dopo N secondi** una volta sola, perché
molti detentori sono processi effimeri di npm appena usciti.

Il `--force` saltava il controllo ma poi si arenava sull'`umount`, che con un watcher
risponde EBUSY: era una promessa che il codice non manteneva. Quale serva lo dice
**N5**: se in una giornata la cartella è tenuta il 90% del tempo, il rifiuto educato non
è una politica, è un muro.

---

## 11. Fuori perimetro, e perché

- **`pnpm`.** Il suo `node_modules` è una selva di symlink verso `.pnpm/`, che usa
  **hardlink verso uno store globale**. `mkfs.erofs` li conserva *dentro* l'immagine,
  ma il legame con lo store esterno si perde e la dedup globale di pnpm diventa copie:
  sarebbe un peggioramento, e silenzioso.
- **`yarn PnP`.** Non ha `node_modules`. Niente da congelare.
- **Monorepo e workspace.** La struttura di `.npz/` li reggerebbe senza modifiche; la
  classificazione dei comandi e la scelta di *quale* albero congelare no. In v1 gli
  annidati vengono **rilevati e segnalati**.
- **Cancellare `.npz` a mano.** Lo fa `npz detach`: cancellarla col mount attivo lascia
  due demoni FUSE appesi su strati che non esistono più.

---

## 12. Fase 0 — il banco

`npz` ha due domande che possono ucciderlo, e costano giorni misurarle contro settimane
implementarle. **Nessun codice di prodotto prima di questi otto numeri.** Il banco è
[fase0.sh](../npz_python/test/fase0.sh), gli esiti in
[report-fase0.md](../npz_python/test/report-fase0.md). Non serve root.

| | Scenario | Perché può cambiare il disegno |
| --- | --- | --- |
| **N1** | `npm ci` e `npm install` sullo stack contro nativo | decide se il progetto è utilizzabile: il carico di npm è centinaia di migliaia di `lstat`, `mkdir`, `rename` attraverso due demoni user space |
| **N2** | dieci `npm install` incrementali di fila | tara le soglie di §9. Senza, sono numeri inventati |
| **N3** | `vite build`, `tsc --noEmit`, `jest` contro nativo | atteso pari o meglio, ma su un albero vero |
| **N4** | consolidamento su un `node_modules` da 45.000 file | il taccuino dichiara aperto il costo del `purge` oltre i 12.000 file |
| **N5** | `/proc` ogni minuto per una giornata | decide §10 e il timer di §6 |
| **N6** | percorso veloce a freddo e sotto carico | decide se `npz` va portato su un binario compilato |
| **N7** | `vite dev` con HMR e `jest --watch` attraverso `fuse-overlayfs` | gli eventi inotify attraversano l'overlay? È il modo più probabile in cui `npz` rompe il ciclo di sviluppo senza dare errori |
| **N8** | riavvio con un mount attivo, poi con l'unità `ExecStop` | verifica sperimentale di §6 |

**Già acquisito durante l'analisi:** `fuse-overlayfs` regge i `lowerdir` con **spazi**
ma non con **due punti**, e con percorsi **relativi** funzionano entrambi — da cui la
regola di implementazione: `npz` fa `chdir` in `.npz/` e passa percorsi relativi. Costa
una riga e rende il montaggio immune a qualunque percorso l'utente abbia.

**Criterio di uscita.** N1 entro **2×** rispetto al nativo, oltre il quale il disegno
cambia; **N5** deve dare una risposta netta su quale delle tre uscite di §10
implementare; **N7 verde**, o una via d'uscita documentata, perché un ciclo di sviluppo
senza HMR non è un ciclo di sviluppo. N2 e N4 producono numeri, non verdetti.

---

## 12 bis. Fase 0 — esiti

Fixture: `next` + `react` + toolchain reale — **879 pacchetti, 31.667 voci, 588 MiB**.
Primo freeze **1,74 s**, immagine di **234 MiB** (−60%), montaggio **0,07 s**. Tutti i
rapporti sono **intervalli su tre corse**.

**N1 — superato, ma solo perché il caso patologico si intercetta.**

| | nativo | sullo stack | rapporto |
| --- | --- | --- | --- |
| `npm install` idempotente | 1,3 s | 1,9–2,1 s | **1,47–1,56×** ✔ |
| `npm ci` | 9,2 s | 28–32 s | **3,04–3,51×** ✘ |

Il caso normale costa il 56% in più e lascia **460 KiB di delta in una sola voce**: è
dentro il criterio. `npm ci` è fuori di tre volte, e conferma la tesi di §8 in ogni sua
parte — **il delta diventa 588 MiB in 35.222 voci**, cioè una copia intera dell'albero,
e immagine più delta fanno **821 MiB contro i 588 del nativo**. Non è una penalizzazione
di velocità: è la negazione del prodotto. Con l'interruttore di §8, N1 passa.

**N2 — la soglia sui byte è lo strumento sbagliato.**

| dopo | delta | voci | vale sull'immagine |
| --- | --- | --- | --- |
| 1 install | 5,4 MiB | 1.056 | 2,3% |
| 5 install | 15 MiB | 2.488 | 6,4% |
| 10 install | **17 MiB** | **2.970** | **7,0%** |

Il 30% sui byte **non viene sfiorato**: servirebbero oltre quaranta installazioni. Il
5% sui file scatterebbe già alla seconda, e con un consolidamento da tredici secondi
sarebbe una tassa. Le due soglie vanno riscritte (§9).

**N3 — i carichi veri non soffrono, il sintetico sì.** `vite build` sta a
**1,03–1,08×**, `tsc --noEmit` a **1,04–1,20×**, la resolve storm a **1,30–1,93×**.
Quest'ultima è **l'unica metrica della fase 0 che si avvicina al criterio di uscita**, e
oscilla molto sullo stesso campione — ma è un caso peggiore sintetico senza alcuna
località, e nessuno strumento reale legge così: quando a leggere è un bundler vero il
rapporto crolla a 1,05.

**N4 — tredici secondi, ed è il numero da tenere d'occhio.** Ciclo completo su un delta
da 14 MiB: **12–15 s** su cinque misure, contro **1,74 s** del primo freeze. Non è il
4% che `freeze` aveva misurato su alberi da 12.000 file: qui è **sette volte tanto**,
perché il consolidamento rilegge l'intero albero attraverso due strati FUSE mentre il
primo freeze lo legge da ext4. È la voce di costo più alta di tutto il progetto.
Correttezza verificata: la vista fusa coincide con quella pre-consolidamento.

*Un'alternativa provata e non dimostrata:* se il collo di bottiglia è la lettura via
FUSE, copiare prima su ext4 dovrebbe convenire. Dalla vista fusa si misurano 12,97 s
girando per prima e 7,03 s per seconda; con staging su ext4, 11,51 e 12,32. **L'effetto
della page cache vale sei secondi**, la differenza fra i metodi uno o due, e il
vincitore cambia con l'ordine: **non si conclude niente**, e senza `drop_caches` non si
può. Il disegno di §9 resta, perché lo staging aggiunge una copia intera in cambio di
niente di misurabile. *(La prima versione di questa misura dava un verdetto netto a
favore dello staging. Era falsa: il banco creava il delta a mount smontato.)*

**N6 — il wrapper in Python regge.** A riposo il percorso veloce costa 14,1–14,3 ms
contro i 127–129 di `npm run` vuoto, cioè un sovraccarico del **10,9–12,9%**; sotto
carico, 15,7–16,7 contro 131–134, cioè **11,1–12,4%**. Il rapporto **non peggiora**, e
la decisione di §3 non ha urgenza di essere anticipata.

**N7 — i watcher funzionano.** `fs.watch` di node — quello che usano chokidar, vite e
jest — riceve gli eventi attraverso `fuse-overlayfs` esattamente come sul nativo. È un
criterio di uscita, ed è verde.

**Resta da misurare N5**, che richiede una giornata di lavoro vera ed è l'unico criterio
di uscita ancora scoperto, e **N8**, che richiede un riavvio.

**Verdetto.** Il progetto **non è stato ucciso da nessuna delle due domande che
potevano ucciderlo.** Il carico di scrittura di npm sta dentro il criterio nel caso
normale, e il caso patologico ha un interruttore già previsto. Resta da tenere sotto
osservazione i tredici secondi del consolidamento, che sono il prezzo vero di `npz` e
che nessuno aveva stimato.

---

## 13. Fase 1 — la CLI

- ~~il refactoring di `SERVIZIO` da costante a parametro~~ — **fatto** (§4);
- `progetto.py`, `comandi.py`, `veloce.py`, `cli.py` — classificazione, percorso
  veloce, `fork`/`wait` trasparente, i sei comandi;
- ~~`consolida_npz()`~~ — **fatto**: `cli.compatta()`, con `--discard` (§2);
- l'unità utente `npz-smonta.service` con solo `ExecStop` — **non ancora scritta**;
- l'eseguibile `npz`, collegato da `~/.local/bin`, che si localizza da sé.

I test che servono davvero — tutti e quattro scritti poi durante il porting Go: **giro
completo** con confronto dell'albero finale contro un `npm install` nativo;
**uccisione fra i passi 3 e 10** del consolidamento, dove rilanciare deve convergere;
**`npz` in CI**, senza domande né congelamenti non richiesti e col codice di uscita di
npm intatto; e **`npz` dentro uno script di `package.json`**, perché gli script
chiamano `npm`, non `npz`, e devono continuare a funzionare sull'albero montato.

## 14. Fase 2

Ha un piano proprio:
[piano di implementazione fase 2.md](<piano di implementazione fase 2.md>). Il suo
centro è N4 — i tredici secondi — e l'idea con cui lo attacca: **smettere di avere una
immagine sola**, sigillando ogni delta in uno strato invece di riassorbirlo. Cambia
`FORMATO`, e va deciso da sei misure nuove prima di scrivere codice.

Le tre voci già assegnate a questa fase non dipendono da quella: il timer di inattività
(tarato su N5), i workspace, e `npz` come binario compilato — quest'ultimo poi
affrontato dal [piano Go](<piano di implementazione go.md>) per un movente diverso, la
distribuzione.

---

## Rimandi

- [claim.md](claim.md) — il disegno di `freeze`, di cui questo documento eredita le
  invarianti.
- [taccuino di viaggio.md](<taccuino di viaggio.md>) — le misure che l'hanno prodotto.
- [piano di implementazione go.md](<piano di implementazione go.md>) — il porting a
  formato fermo.
- [piano di implementazione fase 2.md](<piano di implementazione fase 2.md>) — una
  immagine per strato invece di una sola.

`freeze` non vive più in questo repo. I documenti che restano ne parlano al presente
perché sono suoi, ed è deliberato: riscriverle al passato vorrebbe dire riscriverle.
