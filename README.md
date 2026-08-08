# npz

`npz` è un wrapper di `npm`. Gira ogni parametro a `npm` tale e quale, e si
riserva tre comportamenti propri: chiede una volta se congelare `node_modules`,
lo congela in una immagine [EROFS] compressa e lo monta, e con `npz bye` rilascia
il mount.

La cartella di dipendenze smette di essere decine di migliaia di inode e diventa
**un file solo**, montato in sola lettura con un delta scrivibile sopra. La
toolchain — `node`, `npx`, i bundler, il language server — continua a vedere
l'albero come prima; gli attraversatori che sanno fermarsi a un confine di
filesystem (`du -x`, `find -xdev`, `rsync -x`, `tar --one-file-system`) smettono
di pagarlo.

Questo file è **l'indice** della cartella. Ogni voce rimanda al documento o al
modulo che la spiega per esteso.

---

## Come si legge

L'ordine sotto non è alfabetico: è quello in cui i documenti si sono prodotti a
vicenda. Chi arriva adesso legga **1 → 2 → 3**; il 4 serve solo a chi deve
scrivere codice della fase successiva.

| # | Documento | Che cosa ci si trova |
| --- | --- | --- |
| 1 | [claim.md](doc/claim.md) | il disegno di `freeze`, il progetto da cui `npz` discende. **Le tre invarianti** — un solo lock, formato versionato, costruisci prima di cancellare — nascono qui, e `npz` le eredita per intero. `freeze` non vive più in questo repo; il documento resta perché le invarianti sono sue |
| 2 | [taccuino di viaggio.md](<doc/taccuino di viaggio.md>) | perché il progetto è fatto come è fatto, e soprattutto perché **non** è fatto come era stato pensato: nove voci, quasi tutte un'idea ragionevole smontata da una misura (la deduplicazione, i privilegi, il costo della compressione, un bug nel disegno trovato rileggendolo) |
| 3 | [piano di implementazione.md](<doc/piano di implementazione.md>) | il piano di `npz`: architettura, struttura su disco, ciclo di vita, i sei comandi intercettati, il consolidamento, e gli **esiti della fase 0** (§12 bis) con il verdetto |
| 4 | [piano di implementazione fase 2.md](<doc/piano di implementazione fase 2.md>) | il seguito: smettere di avere una immagine sola, sigillando ogni delta in uno strato invece di riassorbirlo. Cambia `FORMATO`, e va deciso da sei misure nuove (N9…N14) **prima** di scrivere codice di prodotto |
| 5 | [piano di implementazione go.md](<doc/piano di implementazione go.md>) | il porting in Go, **a formato fermo**: perché Go e non C o Rust, i tre punti dove Go non è Python, l'oracolo differenziale contro l'implementazione attuale, e la distribuzione — che è il vero movente. Non si fa insieme al 4 |
| — | [_v.1.1.md](doc/_v.1.1.md) | tre righe di storia delle versioni: dedup → solo zip → npz |

Le misure vere stanno in [report-fase0.md](npz_python/test/report-fase0.md), che
è output di banco e non prosa: è da lì che partono sia il §12 bis sia tutta la
fase 2.

---

## Il codice

`npz_python/` è la **facciata** — sa di `package.json`, di npm e di `.npz` —
appoggiata su `npz_python/lib/`, il **nucleo**, che sa costruire, montare e
tenere lo stato ma non sa dove. La separazione è quella fra meccanismo e
politica, ed è dove stanno le invarianti
([§4 del piano](<doc/piano di implementazione.md>)).

### La facciata — [npz_python/](npz_python/)

| Modulo | Ruolo |
| --- | --- |
| [lanciatore.py](npz_python/lanciatore.py) | l'eseguibile, `python3 -SE`. Il caso normale sono tre `os.stat` e poi `execv` su npm: il processo **sparisce**, e TTY, segnali e codice di uscita passano senza una riga che se ne occupi |
| [veloce.py](npz_python/veloce.py) | il percorso veloce. Solo `os` e `sys`: niente `pathlib`, `subprocess`, `argparse`, `json`. Misurato **13 ms** contro i 121 di `npm run`; la stessa passata con `pathlib` ne costa 39, importando il pacchetto 49 |
| [comandi.py](npz_python/comandi.py) | che cosa fa un comando npm, e quale è invece nostro. Si sbaglia **per eccesso**: quel che non conosce è MUTANTE |
| [progetto.py](npz_python/progetto.py) | la radice non si dichiara: è il progetto stesso, riconosciuto dal `package.json`. L'opposto della risalita à-la-`git` di `freeze` |
| [cli.py](npz_python/cli.py) | il percorso lento — montaggio, congelamento, scavalcamento, consolidamento, i sei comandi. Qui i millisecondi non contano più, le invarianti sì |
| [`__init__.py`](npz_python/__init__.py) | il `Profilo` di `npz`: `SERVIZIO = ".npz"` e la sentinella, più `IMPLEMENTAZIONE`, che l'aiuto stampa per dire quale dei due gemelli sta rispondendo. `VERSIONE` non è scritta qui: la prende da `lib`, che la legge da [progetto.conf](progetto.conf) — e la prende **pigramente**, perché questo modulo sta sul percorso veloce |

**Come si esegue.** `lanciatore.py` è già l'eseguibile — ha lo shebang e si
localizza da sé — quindi basta un symlink, e si chiama **`pnpz`** per non
scontrarsi col binario Go installato come `npz`:

```bash
ln -sfn "$PWD/npz_python/lanciatore.py" ~/.local/bin/pnpz
```

I due convivono di proposito: `npz` è quel che si spedisce, `pnpz` è quel che si
sta scrivendo, e averli entrambi in PATH è ciò che rende l'oracolo differenziale
una cosa che si può lanciare invece che una cerimonia. L'aiuto di ciascuno
dichiara chi è.

### Il nucleo — [npz_python/lib/](npz_python/lib/)

Ereditato **invariato** dal nucleo di `freeze`.

| Modulo | Ruolo |
| --- | --- |
| [immagine.py](npz_python/lib/immagine.py) | `percorsi()`, `costruisci()`, `verifica()`, `inventario()`, `differenze()`. `mkfs.erofs` senza opzioni oltre alla compressione: mode, mtime, uid, gid, xattr, symlink e hardlink si conservano |
| [mount.py](npz_python/lib/mount.py) | due implementazioni dietro la stessa interfaccia. **FUSE è quella normale** e non serve alcun privilegio; il kernel è l'ottimizzazione per quando root c'è |
| [stato.py](npz_python/lib/stato.py) | lock, config, meta. Il `.meta` accanto all'immagine è la fonte di verità: tutto il resto se ne deriva |
| [perimetro.py](npz_python/lib/perimetro.py) | cosa si può congelare. Corto, perché EROFS regge quasi tutto: restano i processi attivi e l'ownership che richiede privilegi |
| [filesystem.py](npz_python/lib/filesystem.py) | `sonda()` — non si fida del tipo dichiarato, prova, e restituisce **fatti**: chi possiede i file, se la `chmod` riesce, se attecchisce (due domande diverse), tipo, sorgente, opzioni, UUID. `idoneita()` è la prima politica costruita sopra, ed è il controllo che rende sicura la scelta di tenere tutto in `.npz/` |
| [`__init__.py`](npz_python/lib/__init__.py) | `FORMATO`, `COMPRESSIONE`, `Errore`, e il `Profilo` che è l'unica differenza fra le facciate. Più `VERSIONE`, letta da [progetto.conf](progetto.conf) risalendo l'albero — è il nucleo che scrive il `creata_da` di uno store, quindi è il nucleo che non deve poter mentire sul numero |

### Il porting — [npz_go/](npz_go/)

Segue il [piano Go](<doc/piano di implementazione go.md>), **a formato fermo**:
`FORMATO` resta 1, e finché il Python è ancora qui le due implementazioni si
verificano a vicenda.

> **Regola permanente sul disallineamento.** Due implementazioni che si
> verificano a vicenda valgono finché coprono la stessa superficie: una funzione
> che esiste da una parte sola non è metà lavoro, è un buco nell'oracolo — e un
> buco che non si vede, perché quel che manca non viene confrontato con niente.
>
> Quindi: **chi trova una funzione presente in una implementazione e assente
> nell'altra la porta, o apre una voce che dice perché no.** Vale nei due sensi,
> Python→Go come Go→Python, e vale anche quando il porting è «a valle»: allora
> il debito si scrive, con nome della funzione e data, invece di restare nella
> testa di chi l'ha visto.
>
> Il confronto poi si fa **sui fatti, non sulla prosa**. Un oracolo che paragona
> messaggi si rompe al primo ritocco di una frase e non si accorge di una
> semantica cambiata; uno che paragona campi strutturati fa l'opposto. Dove una
> funzione restituisce una diagnosi per un umano, il banco confronti i dati da
> cui la diagnosi nasce, e lasci il testo libero di essere scritto bene in un
> posto solo.

**Debito allineato — 2026-08-08.** Le due implementazioni coprono di nuovo la
stessa superficie. Portate in Go nello stesso giro: `Sonda`/`Supporto` con i
suoi fatti, la politica nuova di `Idoneita` (proprietà e bit `x`, non più il
tipo di filesystem), `ReggeUpperdirKernel`, `DriverDiMount`, `Mountinfo`,
`PuntoDiMount`, `UuidDi`, `Scegli(preferito, percorso)`, `Censisci` con la
passata unica, `Conta` e `Misura` a tre valori, `Battito` e `EseguiContando`,
`voce.Avanzamento` col girello, il rimedio di `fstab` nella facciata, la chiave
`cartelle` nel `.meta`, il `detach` che non riconta, e `Implementazione = "go"`
nell'aiuto — con il rientro corretto, che `len()` sull'em dash sbagliava di 2
colonne.

**E l'oracolo ora confronta i fatti, non la prosa**, come la regola qui sopra
prescrive: `banco-fase1.sh` chiede a entrambi `fs-sonda` e paragona gli undici
campi uno per uno, invece della frase che ne nasce. È stato quel confronto a
trovare l'ultima divergenza vera — un symlink a directory che il Python non
contava né fra i file né fra le cartelle, mentre `cp` e `mkfs.erofs` lo nominano
— e a farla correggere **nel Python**, che era quello sbagliato.

**Una divergenza deliberata, e misurata.** `inventario` fa la stessa cosa nei
due gemelli per due strade diverse, perché il collo di bottiglia — su un albero
servito da FUSE una `lstat` è **latenza**, non calcolo — si aggira in modi che i
due linguaggi non condividono:

| | come | misurato su 10.400 voci dietro `erofsfuse` |
| --- | --- | --- |
| Go | `lstat` per percorso, ma **16 in parallelo** | 0,45 s → **0,04 s** |
| Python | `os.scandir`, che chiede gli attributi alla **voce** e non al percorso | 0,415 s → **0,093 s** |

Le due strade non sono intercambiabili: in Python i thread **peggiorano** la
stessa passata (0,9×, il GIL costa più dell'attesa che eviterebbe), e in Go
`os.Lstat` resta per percorso perché `fstatat` con un descrittore di directory
la libreria standard non lo espone. Il perché di `scandir` è che
`lstat("a/b/c/d")` fa risolvere al kernel **ogni componente**, e su FUSE ogni
componente è un giro verso il demone.

Ad armi pari, su 15.600 voci: Go 0,087 s, Python 0,144 s. L'oracolo verifica che
i due inventari coincidano, che è la cosa che deve restare vera.

Lo stesso vale per `censisci`: Python 0,247 → **0,127 s** con `scandir`, Go
**0,027 s** leggendo le directory in parallelo, un livello alla volta.

**E il congelamento attraversa l'albero originale una volta sola.** Prima lo
leggeva due volte — `censisci` per contare, e di nuovo `inventario` dentro
`verifica` per fotografarlo — mentre la fotografia contiene già tutto quel che
il conteggio cercava: `misura()` ne ricava file, byte e cartelle, `uid_visti()`
gli uid per l'avviso sull'ownership. Verificato che i due diano gli stessi
numeri. Ne segue che l'aiuto mostra **una** fase di verifica invece di due, e
che l'attraversata risparmiata è quella sul disco lento, la più cara delle due.

La sola conseguenza di sostanza è **quando** si scatta la fotografia: prima
della costruzione invece che dopo. L'immagine finisce così per essere
confrontata con quel che c'era quando si è deciso di congelare, invece che con
lo stato in cui l'albero si trova alla fine — che è la domanda più sensata delle
due, e chi scrivesse nell'albero nel frattempo lo intercetta comunque
`processi_attivi()`.

Per arrivarci è stata allineata una classificazione che divergeva in silenzio: un
**symlink a directory** contava fra le cartelle per `censisci` e fra i file per
`misura`. I totali tornavano, la ripartizione no, e il `file` scritto nel `.meta`
dipendeva da quale delle due l'aveva prodotto. Adesso è un file per entrambe —
per `lstat` è un link — e sull'albero difficile i tre modi di contare danno tutti
`(7, 9, 6)`, con 7+6 = 13 = le voci che `mkfs.erofs` nomina. E la classificazione regge dove è più facile
sbagliarla — su un albero con symlink a directory, symlink rotto e una fifo,
`file + cartelle` fa **13**, che sono esattamente le voci che `mkfs.erofs`
nomina.

| banco | esito |
| --- | --- |
| [banco-fase0.sh](npz_go/test/banco-fase0.sh) — il pavimento | **30 pass, 0 fail** |
| [banco-fase1.sh](npz_go/test/banco-fase1.sh) — l'oracolo differenziale | **47 pass, 0 fail** |
| [banco-fase2.sh](npz_go/test/banco-fase2.sh) — i giri completi incrociati | **44 pass, 0 fail** |

```text
progetto.conf                                    ← i metadati, in un posto solo,
                                                   nella radice: lo leggono in due
npz_go/
├── main.go · internal/{voce,nucleo,facciata}/   ← il prodotto
├── build/                                       ← si costruisce
│   ├── build.sh                                     l'entrata
│   ├── bin/                                     ← le utilità, versionate
│   │   ├── pacchetto.sh
│   │   └── PKGBUILD
│   └── lavoro/                                  ← i binari per provare
├── dist/                                        ← e si spedisce da qui
└── test/                                        ← si prova
```

Quattro cartelle che dicono quattro cose: il prodotto, come si costruisce, come
si prova, e cosa si spedisce. Le utilità stanno in `build/bin/` e sono
versionate; `build/lavoro/` e `dist/` no, perché contengono roba che si rifà in
pochi secondi e che committata sarebbe subito più vecchia del codice.

**`build/lavoro/` e `dist/` sono due cartelle e non una** perché sono due cose:
in `lavoro/` c'è il binario con cui provi quel che hai appena scritto, in `dist/`
c'è quel che pubblichi. Confonderle è il modo più rapido per spedire il binario
di ieri. `dist/` si svuota all'inizio di ogni pacchettazione, così il suo
contenuto è sempre di **una versione sola** — e il suo contenuto *è* l'elenco
degli allegati di un rilascio, senza niente da scegliere a mano.

**[progetto.conf](progetto.conf) è la fonte di verità.** Versione, descrizioni,
manutentore, URL, licenza e dipendenze stanno lì e **da nessun'altra parte**:
`grep -rn 0.2.1` sul progetto restituisce una riga sola. Chi rilascia tocca quel
file e nient'altro.

**Sta nella radice e non in `npz_go/`** perché le implementazioni sono due e la
versione del progetto è una. Finché stava dentro il modulo Go, il Python non
poteva nominarlo senza uscire dal proprio albero, e infatti non lo nominava: si
teneva un `VERSIONE = "0.1.0"` scritto a mano in due moduli, che ha fatto quel
che fa ogni copia — è rimasto a 0.1.0 mentre il Go arrivava a 0.2.2, e gli store
creati dal Python dichiaravano nel `creata_da` un numero che non era di nessun
rilascio. Un file nella radice non appartiene a nessuna delle due, ed è la sola
posizione da cui entrambe lo raggiungono senza salire.

Il formato è `chiave=valore` di shell perché tre dei quattro consumatori —
`build.sh`, `pacchetto.sh` e il `PKGBUILD` — sono bash e lo leggono con un
punto, senza una riga di parsing.

**I due gemelli lo leggono in due modi, e la differenza è nel loro ciclo di
vita.** Il codice Go non lo legge affatto: riceve la versione a tempo di
collegamento via `-ldflags -X`, e un binario costruito senza passare da
`build.sh` si presenta come **`sviluppo`** invece che con un numero — che è
l'unico modo di distinguere a occhio un binario di rilascio da uno fatto al
volo. Il Python non ha un tempo di collegamento in cui farsi marchiare, quindi
lo legge a runtime, ma **pigramente**: il file si apre alla prima volta che
qualcuno chiede `VERSIONE`, mai a import. Sul percorso veloce — quello davanti a
ogni comando npm — resta chiuso, perché lì la versione non serve a nessuno, e
aprirlo sarebbe una syscall per ogni `npm run` in un loop. Se non lo trova dice
`sviluppo`, la stessa parola del Go per lo stesso caso.

I simboli di versione sono **due per implementazione** — `facciata.Versione` e
`nucleo.Versione` in Go, `npz.VERSIONE` e `lib.VERSIONE` in Python — ma la fonte
è una: in Go si marchiano insieme, in Python la facciata prende quella del
nucleo. La versione che `npz` stampa e quella che finisce nel `creata_da` di uno
store non possono contraddirsi.

**Compilare** — [build/build.sh](npz_go/build/build.sh):

| | |
| --- | --- |
| `./build.sh` | `npz` per questa macchina, in `build/lavoro/` |
| `./build.sh tutti` | anche `linux/amd64` e `linux/arm64` — 5 secondi, nessuna toolchain in più |
| `./build.sh attrezzi` | anche lo spike e il guscio del banco |
| `./build.sh pulisci` | svuota `build/lavoro/` e `dist/` |

Lo script esiste per non affidare alla memoria le tre opzioni che non sono
preferenze: `CGO_ENABLED=0` (nessuna dipendenza da glibc, che è tutta la ragione
per cui il §2 ha scelto Go), `-trimpath` (via i percorsi della macchina che
compila) e `-s -w`. E verifica quel che ne esce: se un binario non risultasse
**statico** lo dichiara guasto, perché non girerebbe sulle distro più vecchie e
il ragionamento sulla distribuzione cadrebbe.

I banchi in `test/` non usano questo script: ricompilano da soli, perché una
prova che dipende da un binario costruito prima proverebbe quel binario e non il
codice di adesso.

**E impacchetta da sé quando serve.** Se la versione in `progetto.conf` non è
quella dell'ultimo rilascio, `build.sh` chiama `bin/pacchetto.sh` da solo. La
ragione è che bumpare la versione e ricordarsi di impacchettare sono due momenti,
e fra i due si perde un rilascio: resti con un binario nuovo e dei pacchetti che
dichiarano il numero di ieri. Per costruire senza rilasciare:
`SALTA_PACCHETTO=1 ./build.sh`.

Il sentinella è **`dist/SHA256SUMS`**, e non un file di stato scritto per
l'occasione: `pacchetto.sh` lo scrive per ultimo e solo a zero guasti, quindi
esiste se e solo se un rilascio è andato a buon fine, e nomina i file, quindi
porta scritta dentro la versione che copre. Un giro interrotto a metà non lo
lascia, e il prossimo `build.sh` riprova — che è il comportamento che si vuole.
Un `.ultima-versione` nascosto avrebbe detto la stessa cosa potendo mentire:
esisterebbe anche dopo un giro fallito.

**Impacchettare** — [build/bin/pacchetto.sh](npz_go/build/bin/pacchetto.sh) e
[build/bin/PKGBUILD](npz_go/build/bin/PKGBUILD):

| | |
| --- | --- |
| `./pacchetto.sh` | il rilascio intero, in `dist/` |
| `./pacchetto.sh arch` | solo `.pkg.tar.zst`, via `makepkg`, più `PKGBUILD-aur` |
| `./pacchetto.sh rpm` | i `.rpm` x86_64/aarch64, via `rpmbuild`, più `npz.spec` |
| `./pacchetto.sh tarball` | i `.tar.gz` per chi non passa da un gestore di pacchetti |
| `./pacchetto.sh ispeziona` | riapre i `.deb` e verifica quel che il formato prescrive |
| `./pacchetto.sh oracolo` | confronta il `.deb` con quello che produrrebbe `nfpm` |

Solo il primo è un rilascio: svuota `dist/`, costruisce tutto e chiude con un
`SHA256SUMS` **verificato con `sha256sum -c`**, cioè con lo stesso comando che
eseguirà chi scarica. Gli altri servono a provare un pezzo alla volta e lasciano
`dist/` a metà di proposito — un `SHA256SUMS` che copre mezzo rilascio direbbe a
`build.sh` che la versione è fatta.

Gli intermedi non si accumulano perché non arrivano mai in una cartella
permanente: ogni funzione lavora in un `mktemp -d` che cancella prima di tornare,
compresi i percorsi d'errore. `dist/` è l'unica uscita, e si svuota a ogni giro.

`.deb` e tarball sono **riproducibili** — `--sort=name`, `--mtime=@0`, `--owner=0`
— e non per eleganza: due giri sulla stessa sorgente danno lo stesso archivio,
altrimenti una somma pubblicata non dice niente.

Il `.deb` si costruisce **senza `dpkg`**, che su questa macchina non c'è: è un
archivio `ar` con tre membri in ordine fisso — `debian-binary`,
`control.tar.gz`, `data.tar.gz` — e `ar` sta in binutils. Il pacchetto non
dipende quindi da nessuna toolchain in più, come il binario non dipende da
glibc.

Il `.rpm` **no**, e la differenza è nel formato, non nella voglia. Un `.rpm` è un
lead binario, una sezione di firma, un header di voci indicizzate e tipizzate in
big-endian e un `cpio` compresso, con dei digest calcolati su regioni
dell'header stesso. Scriverlo a mano si può fare, e darebbe un file che **su
questa macchina nessuno può leggere**: senza `rpm` non ci sarebbe né lo strumento
vero né l'oracolo, cioè nessuno dei due modi con cui qui si distingue un
pacchetto da un archivio che gli somiglia. `rpm-tools` invece sta nei repo di
Manjaro e porta entrambi — `sudo pacman -S rpm-tools`. Una dipendenza in più per
chi rilascia, in cambio del secondo canale su cui la struttura non sia un'ipotesi.

**I tre pacchetti non sono verificati allo stesso modo, e conviene saperlo.**

| | Debian | Arch | Fedora |
| --- | --- | --- | --- |
| costruito con | `ar` + `tar` a mano | `makepkg`, lo strumento vero | `rpmbuild`, lo strumento vero |
| struttura | verificata voce per voce, e coincide con quella di `nfpm` | verificata da `pacman -Qip`/`-Qlp` | verificata da `rpm -qp`/`-qpl`/`-qpR` |
| installazione | **non provata** — niente `dpkg` qui | provata: il pacchetto si legge, il binario si estrae e parte | **non provata** — nessuna Fedora qui |
| dipendenze | **non verificate** — i nomi Debian sono un'ipotesi | **lette da questa macchina** con `pacman -Qo` | **non verificate** — i nomi Fedora sono un'ipotesi |

Anche lo `.spec` **si genera** da `progetto.conf`, come il `PKGBUILD-aur` e per la
stessa ragione, e finisce in `dist/npz.spec` **solo dopo** che `rpmbuild` lo
ha accettato: il file che si pubblica su COPR è quello che ha funzionato, non
quello che spero funzioni. Non ha `%prep` né `%build` — il binario è costruito
fuori, una volta sola e nello stesso modo per ogni canale, ed è anche ciò che
permette di produrre l'`aarch64` da questa macchina x86 con `--target`.

Su rpm `npm` sta fra i **`Suggests`** e non fra i `Recommends`, che è la
distinzione che conta: `dnf` installa le raccomandate per difetto, e
installerebbe quindi l'`npm` della distro proprio a chi ne ha già uno da
nvm/fnm — cioè al pubblico di npz.

Il `PKGBUILD` del repo **non contiene metadati**: legge `progetto.conf`. Su AUR
quel file non ci sarebbe, quindi la versione pubblicabile si *genera* —
`dist/PKGBUILD-aur`, con i valori sostituiti alla lettera. Generare invece
di duplicare, perché una copia che localmente nessuno esercita è una copia di
cui nessuno si accorge quando invecchia.

Il tarball dei sorgenti che `makepkg` costruisce **conserva la geometria del
repo** — `progetto.conf` in cima, il modulo Go in `npz_go/` — e non è
pignoleria: è ciò che rende `build/build.sh` eseguibile dentro il tarball
esattamente come qui, perché il conf sta allo stesso posto relativo.
Appiattirlo costerebbe una seconda regola di ricerca negli script, cioè un modo
in più di leggere la versione, cioè un modo in più di sbagliarla.

Su Arch `erofsfuse` è un pacchetto separato da `erofs-utils`: è la prova che
quella riga non si scrive a memoria, ed è la ragione per cui nel `.deb` è
dichiarata **per difetto** — un `Depends` sbagliato non lascia installare,
mentre un binario mancante npz lo segnala al primo uso nominando il pacchetto.

`npm` sta fra le dipendenze **opzionali** e non fra le obbligatorie: su questa
stessa macchina `pacman -Qo $(command -v npm)` non trova alcun proprietario,
perché npm era stato installato fuori da pacman — come fanno nvm, fnm e volta.

| Fase 0 — il pavimento | |
| --- | --- |
| [test/spike/main.go](npz_go/test/spike/main.go) | il percorso veloce e niente altro, per rispondere alle domande che potevano ancora smentire la scelta di Go |
| [banco-fase0.sh](npz_go/test/banco-fase0.sh) | stati, trasparenza di `syscall.Exec`, tempi contro il Python |
| [report-fase0-go.md](npz_go/test/report-fase0-go.md) | **30 pass, 0 fail** · percorso veloce **2,72 ms** contro 14,45 · binario 1,7 MiB statico |

| Fase 1 — il nucleo | |
| --- | --- |
| [internal/nucleo/](npz_go/internal/nucleo/) | il meccanismo, portato da [npz_python/lib/](npz_python/lib/): `nucleo.go`, `filesystem.go`, `mount.go`, `immagine.go`, `stato.go`, `perimetro.go` |
| [test/nucleo/](npz_go/test/nucleo/) | un guscio sottile sul nucleo — non è la CLI di npz, è l'attrezzo con cui il banco accende l'oracolo differenziale |
| [banco-fase1.sh](npz_go/test/banco-fase1.sh) | Go contro Python su ogni funzione, e sulle combinazioni incrociate |
| [report-fase1-go.md](npz_go/test/report-fase1-go.md) | **46 pass, 0 fail** · immagini con lo stesso contenuto, `flock` che si esclude nei due sensi |

| Fase 2 — la facciata | |
| --- | --- |
| [main.go](npz_go/main.go) | il lanciatore: quattro `Stat` e poi `Exec`, o il percorso lento |
| [internal/voce/](npz_go/internal/voce/) | la sbarra — testa, segno, coda — e la regola che la coda si chiude **prima** di ogni `Exec`, che i `defer` non eseguirebbe |
| [internal/facciata/](npz_go/internal/facciata/) | la politica: gli otto stati, le quattro classi di comando, montaggio, congelamento, scavalcamento, consolidamento, i sei comandi |
| [banco-fase2.sh](npz_go/test/banco-fase2.sh) | i quattro test del §13, mai scritti prima, più l'oracolo incrociato |
| [report-fase2-go.md](npz_go/test/report-fase2-go.md) | **44 pass, 0 fail** · giro completo, convergenza dopo `SIGKILL`, CI muto, progetti scambiati col Python nei due sensi |

### Il banco — [npz_python/test/](npz_python/test/)

| File | |
| --- | --- |
| [fase0.sh](npz_python/test/fase0.sh) | gli scenari N1…N8. Non è codice di prodotto: è uno script da buttare via, il cui scopo è produrre sì/no e una tabella di numeri **prima** che si scriva una riga di `npz` |
| [report-fase0.md](npz_python/test/report-fase0.md) | il suo output: esiti e misure, 2026-08-02 |
| [banco-sonda.py](npz_python/test/banco-sonda.py) | `sonda()` misurata su **tutto il montato** più i filesystem che si possono fabbricare senza privilegi (NTFS in un file, EROFS, overlay). Prova la diagnosi anche dove non serve: un consiglio sbagliato è peggio di nessun consiglio |
| [report-sonda.md](npz_python/test/report-sonda.md) | il suo output, 2026-08-08, più le **letture** — fra cui il falso negativo di `idoneita()` sullo stack di npz stesso |
| [mounter.sh](npz_python/mounter.sh) | un ext4 in loopback su cui provare, perché il disco che ospita il progetto è NTFS via ntfs-3g e verrebbe rifiutato |

---

## I comandi

Tutto il resto va a `npm` invariato — e vale l'inverso: `npz -- attach` passa
`attach` a npm.

| Comando | Effetto |
| --- | --- |
| `npz attach` | attiva npz su questo progetto adesso, senza chiedere niente |
| `npz hey` | monta ciò che `attach` ha già costruito; non costruisce mai |
| `npz bye` | smonta, rimuove la cartella, tiene `.npz`: torna allo stato congelato |
| `npz status` | in quale stato siamo, quanto è grande l'immagine, quanto il delta |
| `npz compact` | forza il consolidamento adesso, invece di aspettare la soglia |
| `npz detach` | materializza `node_modules` come cartella vera e cancella `.npz` |

`npz detach` è la via d'uscita, e senza di essa il sistema non si adotta: in un
sistema in cui si può solo entrare non entra nessuno.

`npz` senza argomenti stampa il proprio aiuto e a seguire quello di npm.

---

## La struttura su disco

```text
progetto/
├── package.json
├── node_modules/          ← mountpoint. Esiste SOLO da montati.
└── .npz/                  ← da fermo si chiama `node_modules.frozen`
    ├── config · lock
    ├── static/            ← l'immagine EROFS lz4hc + il .meta.  I dati.
    ├── dynamic/           ← il delta scrivibile
    └── run/               ← stato di esercizio: esiste SOLO col mount
```

**Il nome è lo stato.** La cartella di servizio ne ha due, e cambiarlo è tutto
ciò che distingue un progetto al lavoro da uno fermo: da montati si nasconde in
`.npz` e il progetto ha l'aspetto di sempre; da fermo diventa
`node_modules.frozen`, visibile, e dichiara dove sono finiti i dati. Non è un
segnaposto — è la stessa cartella con addosso il nome giusto, e un nome non può
disallinearsi da sé.

**Da non montati la cartella `node_modules` non deve esistere.** Se restasse lì
vuota, un builder non direbbe "manca `node_modules`" ma `cannot find module
'react'`, che è un errore molto peggiore da diagnosticare. Montare è `mkdir` +
`mount`, smontare è `umount` + `rmdir`.

---

## Requisiti

`mkfs.erofs`, `erofsfuse`, `fuse-overlayfs`, `fusermount3`, più `npm` e `node`.
**Nessun privilegio**: lo stack si monta interamente in user space; la via del
kernel (`mount -t erofs` + `overlay`) è un'ottimizzazione per quando root c'è,
non un requisito.

**Dove può stare un progetto.** `.npz/` vive accanto al progetto, quindi delta e
immagine condividono il supporto, ed è `filesystem.idoneita()` a dire se quel
supporto regge. Chiede tre cose e non di più, tutte misurate in
[report-sonda.md](npz_python/test/report-sonda.md):

| | |
| --- | --- |
| si deve poter **scrivere** | ovvio |
| i file devono essere **nostri** | npm mette il bit di esecuzione sugli shim che installa. Un disco montato con `uid=0` accetta quella `chmod` e non fa niente, così sembra a posto; attraverso l'overlay la stessa chiamata viene **rifiutata**, e `npm install` muore con `EPERM` |
| il **bit `x`** si deve poter mettere | su `fuse.rclone`, misurato, i modi si appiattiscono a `644` e gli shim di `.bin/` non partono |

**Non** chiede che i permessi POSIX si conservino, ed è la differenza con
`freeze`, da cui il controllo era ereditato. `freeze` conserva alberi arbitrari
e deve ripristinarli fedeli; npz congela `node_modules`, che sta sullo stesso
supporto del delta — qualunque cosa quel supporto faccia ai modi l'ha già fatta
all'albero prima che npz lo vedesse, e i due lati coincidono per costruzione.
Su NTFS l'albero è uniformemente `777` e non c'è niente da perdere: giro
completo misurato, consolidamento incluso, un solo regime di modi prima e dopo.
Il requisito **tornerebbe** se un giorno `dynamic/` finisse su un filesystem
diverso dall'immagine.

Ne segue che **NTFS non è escluso**: lo è un NTFS montato da root, che è come
udisks lo monta per difetto. Quando `idoneita()` rifiuta per quel motivo, npz
stampa la riga di `fstab` che lo rimedia — device, UUID e nome del driver letti
dalla macchina, non indovinati. E non è vero il contrario: `$HOME` non basta
come regola, perché sotto `$HOME` può esserci un mount di rete che il bit di
esecuzione non lo regge.

Serve inoltre `user_allow_other` in `/etc/fuse.conf` per i progetti che stanno
su un filesystem FUSE: senza, `fusermount3` non può montare `node_modules`
dentro un percorso servito da un altro FUSE.

La voce 1 del [taccuino](<doc/taccuino di viaggio.md>) racconta il vincolo come
era stato capito all'inizio, ed è ancora buona sulla parte che non è cambiata:
la contropressione di un loop device servito da FUSE.

---

## Stato

| | |
| --- | --- |
| **fase 0** — il banco | **chiusa**. Criterio di uscita superato; gli esiti nel [§12 bis](<doc/piano di implementazione.md>), i numeri in [report-fase0.md](npz_python/test/report-fase0.md) |
| **fase 1** — la CLI | i sei comandi, il percorso veloce, il consolidamento senza rotazione e il lanciatore sono scritti. Restano l'unità utente `npz-smonta.service` (non ancora in repo) e i quattro test di giro completo elencati nel [§13](<doc/piano di implementazione.md>) |
| **fase 2** — una immagine per strato | **da decidere, non da scrivere**: nessun codice di prodotto prima delle misure N9…N14. L'ordine di lavoro è nel [§12 del piano fase 2](<doc/piano di implementazione fase 2.md>) |

I tredici secondi del consolidamento (N4) sono il numero che regge tutta la fase
2: è l'unico che la fase 0 ha misurato e che nessuno aveva stimato.

[EROFS]: https://docs.kernel.org/filesystems/erofs.html
