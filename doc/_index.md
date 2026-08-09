# npz — indice

`npz` è un wrapper di `npm`. Gira ogni parametro a `npm` tale e quale, e si riserva
tre comportamenti propri: chiede una volta se congelare `node_modules`, lo congela in
una immagine [EROFS] compressa e lo monta, e con `npz bye` rilascia il mount.

La cartella di dipendenze smette di essere decine di migliaia di inode e diventa **un
file solo**, montato in sola lettura con un delta scrivibile sopra. La toolchain
continua a vedere l'albero come prima; gli attraversatori che sanno fermarsi a un
confine di filesystem (`du -x`, `find -xdev`, `rsync -x`) smettono di pagarlo.

---

## I documenti

L'ordine non è alfabetico: è quello in cui si sono prodotti a vicenda. Chi arriva
adesso legga **1 → 2 → 3**.

| # | Documento | Che cosa ci si trova |
| --- | --- | --- |
| 1 | [claim.md](claim.md) | il disegno di `freeze`, il progetto da cui `npz` discende. **Le tre invarianti** — un solo lock, formato versionato, costruisci prima di cancellare — nascono qui, e `npz` le eredita per intero |
| 2 | [taccuino di viaggio.md](<taccuino di viaggio.md>) | perché il progetto **non** è fatto come era stato pensato: nove voci, quasi tutte un'idea ragionevole smontata da una misura — la deduplicazione, i privilegi, il costo della compressione, un bug nel disegno trovato rileggendolo |
| 3 | [piano di implementazione.md](<piano di implementazione.md>) | il piano di `npz`: architettura, struttura su disco, ciclo di vita, i sei comandi, il consolidamento, e gli **esiti della fase 0** (§12 bis) col verdetto |
| 4 | [piano di implementazione go.md](<piano di implementazione go.md>) | il porting in Go, **a formato fermo**: perché Go, i tre punti dove Go non è Python, l'oracolo differenziale, e la distribuzione — che è il vero movente |
| 5 | [piano di implementazione fase 2.md](<piano di implementazione fase 2.md>) | il seguito, **da decidere**: smettere di avere una immagine sola. Cambia `FORMATO` e vuole sei misure nuove prima di scrivere codice |
| — | [_history.md](_history.md) | quattro righe di storia: dedup → solo zip → npz → versione go |

Le misure vere stanno in [report-fase0.md](../npz_python/test/report-fase0.md), che è
output di banco e non prosa.

---

## Il codice

`npz_python/` è la **facciata** — sa di `package.json`, di npm e di `.npz` —
appoggiata su `npz_python/lib/`, il **nucleo**, che sa costruire, montare e tenere lo
stato ma non sa dove. È la separazione fra meccanismo e politica, ed è dove stanno le
invarianti ([§4 del piano](<piano di implementazione.md>)).

### La facciata — [npz_python/](../npz_python/)

| Modulo | Ruolo |
| --- | --- |
| [lanciatore.py](../npz_python/lanciatore.py) | l'eseguibile, `python3 -SE`. Il caso normale sono tre `os.stat` e poi `execv` su npm: il processo **sparisce**, e TTY, segnali e codice di uscita passano senza una riga che se ne occupi |
| [veloce.py](../npz_python/veloce.py) | il percorso veloce. Solo `os` e `sys`: misurato **13 ms** contro i 121 di `npm run`; la stessa passata con `pathlib` ne costa 39 |
| [comandi.py](../npz_python/comandi.py) | che cosa fa un comando npm, e quale è invece nostro. Si sbaglia **per eccesso**: quel che non conosce è MUTANTE |
| [progetto.py](../npz_python/progetto.py) | la radice non si dichiara: è il progetto stesso, riconosciuto dal `package.json` |
| [cli.py](../npz_python/cli.py) | il percorso lento — montaggio, congelamento, scavalcamento, consolidamento. Qui i millisecondi non contano più, le invarianti sì |
| [`__init__.py`](../npz_python/__init__.py) | il `Profilo` di `npz`: `SERVIZIO = ".npz"`, la sentinella, e `IMPLEMENTAZIONE`, che l'aiuto stampa per dire quale dei due gemelli risponde |

**Come si esegue.** `lanciatore.py` è già l'eseguibile, quindi basta un symlink, e si
chiama **`pnpz`** per non scontrarsi col binario Go installato come `npz`:

```bash
ln -sfn "$PWD/npz_python/lanciatore.py" ~/.local/bin/pnpz
```

I due convivono di proposito: `npz` è quel che si spedisce, `pnpz` quel che si sta
scrivendo, e averli entrambi in PATH è ciò che rende l'oracolo differenziale una cosa
che si lancia invece che una cerimonia.

### Il nucleo — [npz_python/lib/](../npz_python/lib/)

Ereditato **invariato** dal nucleo di `freeze`.

| Modulo | Ruolo |
| --- | --- |
| [immagine.py](../npz_python/lib/immagine.py) | `percorsi()`, `costruisci()`, `verifica()`, `inventario()`, `differenze()`. `mkfs.erofs` senza opzioni oltre alla compressione: mode, mtime, uid, gid, xattr, symlink e hardlink si conservano |
| [mount.py](../npz_python/lib/mount.py) | due implementazioni dietro la stessa interfaccia. **FUSE è quella normale** e non serve alcun privilegio; il kernel è l'ottimizzazione per quando root c'è |
| [stato.py](../npz_python/lib/stato.py) | lock, config, meta. Il `.meta` accanto all'immagine è la fonte di verità |
| [perimetro.py](../npz_python/lib/perimetro.py) | cosa si può congelare. Corto, perché EROFS regge quasi tutto |
| [filesystem.py](../npz_python/lib/filesystem.py) | `sonda()` — non si fida del tipo dichiarato, prova, e restituisce **fatti**. `idoneita()` è la prima politica costruita sopra |
| [`__init__.py`](../npz_python/lib/__init__.py) | `FORMATO`, `COMPRESSIONE`, `Errore`, il `Profilo`, e `VERSIONE` letta da [progetto.conf](../progetto.conf) — è il nucleo che scrive il `creata_da` di uno store, quindi è il nucleo che non deve poter mentire sul numero |

### Il porting — [npz_go/](../npz_go/)

Segue il [piano Go](<piano di implementazione go.md>), **a formato fermo**: `FORMATO`
resta 1, e finché il Python è ancora qui le due implementazioni si verificano a
vicenda.

> **Regola permanente sul disallineamento.** Due implementazioni che si verificano a
> vicenda valgono finché coprono la stessa superficie: una funzione che esiste da una
> parte sola non è metà lavoro, è **un buco nell'oracolo** — e un buco che non si
> vede, perché quel che manca non viene confrontato con niente. Quindi: chi trova una
> funzione presente in una implementazione e assente nell'altra **la porta, o apre una
> voce che dice perché no**, nei due sensi.
>
> Il confronto si fa **sui fatti, non sulla prosa**. Un oracolo che paragona messaggi
> si rompe al primo ritocco di una frase e non si accorge di una semantica cambiata;
> uno che paragona campi strutturati fa l'opposto.

**Debito allineato — 2026-08-08.** Le due implementazioni coprono di nuovo la stessa
superficie. E l'oracolo confronta i fatti: `banco-fase1.sh` chiede a entrambi
`fs-sonda` e paragona gli undici campi uno per uno. È stato quel confronto a trovare
l'ultima divergenza vera — un symlink a directory che il Python non contava né fra i
file né fra le cartelle — e a farla correggere **nel Python**, che era quello
sbagliato.

**Una divergenza deliberata, e misurata.** `inventario` fa la stessa cosa per due
strade diverse, perché il collo di bottiglia — su un albero servito da FUSE una
`lstat` è **latenza**, non calcolo — si aggira in modi che i due linguaggi non
condividono:

| | come | su 10.400 voci dietro `erofsfuse` |
| --- | --- | --- |
| Go | `lstat` per percorso, ma **16 in parallelo** | 0,45 s → **0,04 s** |
| Python | `os.scandir`, che chiede gli attributi alla **voce** e non al percorso | 0,415 s → **0,093 s** |

Le due strade non sono intercambiabili: in Python i thread **peggiorano** la stessa
passata (il GIL costa più dell'attesa che eviterebbe), e in Go `os.Lstat` resta per
percorso perché `fstatat` con un descrittore di directory la libreria standard non lo
espone. Ad armi pari, su 15.600 voci: Go 0,087 s, Python 0,144 s. L'oracolo verifica
che i due inventari coincidano, che è la cosa che deve restare vera.

**E il congelamento attraversa l'albero originale una volta sola**, perché la
fotografia che serve alla verifica contiene già tutto quel che il conteggio cercava.
L'attraversata risparmiata è quella sul disco lento. La sola conseguenza di sostanza è
**quando** si scatta la fotografia: prima della costruzione invece che dopo, cioè
l'immagine viene confrontata con quel che c'era quando si è deciso di congelare — la
domanda più sensata delle due.

| banco | esito |
| --- | --- |
| [banco-fase0.sh](../npz_go/test/banco-fase0.sh) — il pavimento | **30 pass, 0 fail** · percorso veloce **2,72 ms** contro 14,45 |
| [banco-fase1.sh](../npz_go/test/banco-fase1.sh) — l'oracolo differenziale | **47 pass, 0 fail** |
| [banco-fase2.sh](../npz_go/test/banco-fase2.sh) — i giri completi incrociati | **44 pass, 0 fail** |

### Come si costruisce e si spedisce

```text
progetto.conf              ← i metadati, in un posto solo: lo leggono in due
npz_go/
├── main.go · internal/    ← il prodotto
├── build/build.sh         ← l'entrata; bin/ le utilità, versionate
│         lavoro/          ← i binari per provare
├── dist/                  ← e si spedisce da qui
└── test/                  ← si prova
```

**`build/lavoro/` e `dist/` sono due cartelle e non una** perché sono due cose: in
`lavoro/` c'è il binario con cui provi quel che hai appena scritto, in `dist/` quel
che pubblichi. Confonderle è il modo più rapido per spedire il binario di ieri.
`dist/` si svuota all'inizio di ogni pacchettazione, così il suo contenuto è sempre di
**una versione sola** — e *è* l'elenco degli allegati di un rilascio.

**[progetto.conf](../progetto.conf) è la fonte di verità**: versione, descrizioni,
manutentore, URL, licenza e dipendenze stanno lì e **da nessun'altra parte**. Sta nella
radice e non in `npz_go/` perché le implementazioni sono due e la versione del progetto
è una: finché stava dentro il modulo Go, il Python teneva un `VERSIONE = "0.1.0"`
scritto a mano che è rimasto a 0.1.0 mentre il Go arrivava a 0.2.2. Il formato è
`chiave=valore` di shell perché tre dei quattro consumatori sono bash.

**I due gemelli lo leggono in due modi.** Il Go non lo legge affatto: riceve la
versione a tempo di collegamento via `-ldflags -X`, e un binario costruito senza
passare da `build.sh` si presenta come **`sviluppo`** — l'unico modo di distinguere a
occhio un binario di rilascio da uno fatto al volo. Il Python lo legge a runtime ma
**pigramente**: sul percorso veloce resta chiuso, perché lì la versione non serve a
nessuno e aprirlo sarebbe una syscall per ogni `npm run` in un loop.

`build.sh` costruisce in `build/lavoro/`, con `tutti` anche per `linux/amd64` e
`linux/arm64`. Esiste per non affidare alla memoria le tre opzioni che non sono
preferenze — `CGO_ENABLED=0`, `-trimpath`, `-s -w` — e verifica quel che ne esce: se un
binario non risultasse **statico** lo dichiara guasto. **E impacchetta da sé quando
serve**: se la versione non è quella dell'ultimo rilascio chiama `pacchetto.sh`, perché
bumpare la versione e ricordarsi di impacchettare sono due momenti, e fra i due si
perde un rilascio. Il sentinella è **`dist/SHA256SUMS`**, scritto per ultimo e solo a
zero guasti: esiste se e solo se un rilascio è andato a buon fine, e nomina i file,
quindi porta scritta dentro la versione che copre.

**I tre pacchetti non sono verificati allo stesso modo, e conviene saperlo.**

| | Debian | Arch | Fedora |
| --- | --- | --- | --- |
| costruito con | `ar` + `tar` a mano | `makepkg`, lo strumento vero | `rpmbuild`, lo strumento vero |
| struttura | verificata voce per voce, coincide con `nfpm` | verificata da `pacman -Qip` | verificata da `rpm -qp` |
| installazione | **non provata** — niente `dpkg` qui | provata | **non provata** |
| dipendenze | **non verificate** — i nomi Debian sono un'ipotesi | **lette da questa macchina** | **non verificate** |

`.deb` e tarball sono **riproducibili**: due giri sulla stessa sorgente danno lo stesso
archivio, altrimenti una somma pubblicata non dice niente. Anche `npz.spec` e
`PKGBUILD-aur` **si generano** da `progetto.conf`, e lo `.spec` finisce in `dist/`
**solo dopo** che `rpmbuild` lo ha accettato: il file che si pubblica è quello che ha
funzionato, non quello che spero funzioni.

---

## I comandi

Tutto il resto va a `npm` invariato — e vale l'inverso: `npz -- attach` passa `attach`
a npm.

| Comando | Effetto |
| --- | --- |
| `npz attach` | attiva npz su questo progetto adesso, senza chiedere niente |
| `npz hey` | monta ciò che `attach` ha già costruito; non costruisce mai |
| `npz bye` | smonta, rimuove la cartella, tiene `.npz`: torna allo stato congelato |
| `npz status` | in quale stato siamo, quanto è grande l'immagine, quanto il delta |
| `npz compact` | forza il consolidamento adesso, invece di aspettare la soglia |
| `npz detach` | materializza `node_modules` come cartella vera e cancella `.npz` |

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

**Il nome è lo stato**: da montati la cartella di servizio si nasconde in `.npz`, da
fermo diventa `node_modules.frozen`, visibile, e dichiara dove sono finiti i dati. Non
è un segnaposto — è la stessa cartella col nome giusto, e **un nome non può
disallinearsi da sé**. E **da non montati `node_modules` non deve esistere**: se
restasse lì vuota, un builder non direbbe "manca `node_modules`" ma `cannot find
module 'react'`, che è molto peggio da diagnosticare.

## Requisiti

`mkfs.erofs`, `erofsfuse`, `fuse-overlayfs`, `fusermount3`, più `npm` e `node`.
**Nessun privilegio**: lo stack si monta interamente in user space.

`.npz/` vive accanto al progetto, quindi delta e immagine condividono il supporto, ed è
`filesystem.idoneita()` a dire se quel supporto regge. Chiede tre cose, tutte misurate
in [report-sonda.md](../npz_python/test/report-sonda.md): che si possa **scrivere**;
che i file siano **nostri**, perché un disco montato con `uid=0` accetta la `chmod`
degli shim e non fa niente, così sembra a posto, mentre attraverso l'overlay la stessa
chiamata viene **rifiutata** e `npm install` muore con `EPERM`; e che il **bit `x`** si
possa mettere, perché su `fuse.rclone` i modi si appiattiscono a `644` e gli shim di
`.bin/` non partono.

**Non** chiede che i permessi POSIX si conservino, ed è la differenza con `freeze`, da
cui il controllo era ereditato: `freeze` conserva alberi arbitrari e deve ripristinarli
fedeli, mentre npz congela `node_modules`, che sta sullo stesso supporto del delta —
qualunque cosa quel supporto faccia ai modi l'ha già fatta all'albero prima che npz lo
vedesse. Il requisito **tornerebbe** se `dynamic/` finisse su un filesystem diverso
dall'immagine.

Ne segue che **NTFS non è escluso**: lo è un NTFS montato da root, che è come udisks lo
monta per difetto — e quando `idoneita()` rifiuta per quel motivo, npz stampa la riga di
`fstab` che lo rimedia, con device, UUID e driver letti dalla macchina. E non vale il
contrario: `$HOME` non basta come regola, perché sotto `$HOME` può esserci un mount di
rete che il bit di esecuzione non lo regge. Serve inoltre `user_allow_other` in
`/etc/fuse.conf` per i progetti su filesystem FUSE.

---

## Stato

| | |
| --- | --- |
| **fase 0** — il banco | **chiusa**. Criterio di uscita superato; gli esiti nel [§12 bis](<piano di implementazione.md>) |
| **fase 1** — la CLI | i sei comandi, il percorso veloce, il consolidamento e il lanciatore sono scritti. Resta l'unità utente `npz-smonta.service` |
| **il porting in Go** | fasi 0, 1 e 2 **chiuse** (30 + 47 + 44 pass). Restano la settimana d'uso e il taglio del Python |
| **fase 2** — una immagine per strato | **da decidere, non da scrivere**: nessun codice di prodotto prima delle misure nuove |

I tredici secondi del consolidamento (N4) sono il numero che regge tutta la fase 2: è
l'unico che la fase 0 ha misurato e che nessuno aveva stimato.

[EROFS]: https://docs.kernel.org/filesystems/erofs.html
