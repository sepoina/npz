# npz — piano di implementazione, il porting in Go

Il §3 del [piano](<piano di implementazione.md>) aveva rimandato il binario
compilato alla fase successiva, condizionandolo a N6. **N6 è passato a 11,8%**,
cioè la condizione non si è avverata: sull'asse della velocità il wrapper in
Python regge, e non c'è niente da comprare.

Questo porting nasce quindi da un movente diverso — la **distribuzione** — ed è
importante dirlo subito, perché è il movente a scegliere il linguaggio. Se si
fosse trattato di millisecondi vincerebbe il C; trattandosi di impacchettare e
spedire, vince Go, e per una ragione sola che vale tutte le altre messe insieme.

---

## 1. Che cosa è questo porting, e che cosa non è

**È una reimplementazione a formato invariato.** `FORMATO` resta **1**. La
struttura di `.npz/` non si muove di una voce, lo schema dei `.meta` neppure, i
due nomi della cartella di servizio restano quelli. Un binario Go deve leggere e
scrivere store creati dal Python di oggi, e viceversa, per tutta la durata del
porting — è questo che rende possibile la strategia di prova del §7.

**Non è l'occasione per correggere il disegno.** Ogni cosa che il codice fa oggi
la fa per una ragione scritta da qualche parte: le tre invarianti vengono da
[claim.md](claim.md), gli otto stati dal §6 e dal §6 bis, la classificazione per
eccesso da N2. Il porting le trasporta, non le rinegozia.

**E soprattutto: il porting e la fase 2 non si fanno insieme.** La
[fase 2](<piano di implementazione fase 2.md>) cambia `FORMATO`, fa nascere la
catena degli strati dentro `lib` e riscrive `percorsi()`. Farla nello stesso
movimento del cambio di linguaggio significa avere due variabili in volo e
nessun modo di sapere quale delle due ha rotto cosa. **Prima il porting a
formato fermo, poi la fase 2 sul codice Go** — o, se la fase 2 è più urgente,
prima la fase 2 in Python e il porting dopo. In nessun caso insieme.

---

## 2. Perché Go, e il fatto che decide

Tre candidati — C, Rust, Go — e un asse su cui il confronto si chiude:

| | C | Rust | Go |
| --- | --- | --- | --- |
| avvio | ~0,5 ms | ~1 ms | ~1–2 ms |
| binario statico, `npz` | 300–600 KB | 1,5–2,5 MB | **3–5 MB** |
| toolchain da installare | **0** (gcc già presente, 220 MiB) | 306 MiB, **un solo target** | 215 MiB, **tutti i target** |
| cross-compile aarch64 | la parte dolorosa del C | `rustup`, +150 MiB per target | `GOARCH=arm64` |
| dipendenza da glibc | sì, se dinamico | sì, se target `gnu` | **nessuna**, con `CGO_ENABLED=0` |

L'ultima riga è quella che decide. Questa macchina ha **glibc 2.44**; Debian 12
ne ha 2.36, Ubuntu 22.04 la 2.35, RHEL 9 la 2.34. Un binario linkato
dinamicamente qui sopra non parte su nessuna delle tre, e l'utente lo scopre
dopo aver eseguito lo script di installazione, quando ormai si è fidato.

Con `CGO_ENABLED=0` un binario Go **non linka libc affatto**: fa syscall dirette.
Non c'è versione da far combaciare. È il comportamento predefinito, non una
configurazione da ricordarsi — e i caveat noti di quella scelta (risoluzione DNS,
NSS) non toccano `npz`, che non fa rete e non guarda utenti remoti.

L'avvio, che nel §3 era **la** variabile dominante, qui non discrimina: tutti e
tre stanno dieci volte sotto i 13 ms di Python, e la differenza fra loro è rumore
contro i 121 ms di `npm run`.

### Quello che si paga scegliendo Go

Una cosa sola, e concreta: **niente somme di tipi**. Gli otto stati del §6 e le
quattro classi di comando sono, in Rust, `enum` con `match` esaustivo — un nono
stato farebbe fallire la compilazione in ogni punto che non lo gestisce. In Go
sono costanti e uno `switch` senza controllo. Il progetto ha già aggiunto uno
stato a disegno fatto (*scavalcato*, §6 bis) e ne prevede altri: non è un rischio
teorico. La mitigazione sta nel §6.3.

---

## 3. Quello che il compilato cancella

`veloce.py` non esiste per una ragione di disegno. Esiste perché importare
`pathlib` costa 26 ms e importare il pacchetto ne costa 36, e `npz` sta davanti a
ogni comando `npm`. Da qui la disciplina del §7 — *niente `pathlib`, niente
`subprocess`, niente `argparse`, niente `json`* — e i 340 righe di un modulo che
riscrive a mano cose che la libreria standard già fa.

**Compilato, quel costo è zero.** La disciplina sugli import sparisce con la
ragione che l'aveva prodotta, e con lei sparisce `veloce.py` come modulo: il suo
contenuto si scioglie dentro i moduli normali, dove ognuna delle sue funzioni
sarebbe stata scritta se non ci fosse stato un budget da rispettare.

Attenzione a non cancellare troppo, però. **La divisione fast/slow sparisce come
organizzazione del codice, non come logica.** Resta intatta la cosa che conta
davvero, ed è un'altra:

| | quando | come |
| --- | --- | --- |
| `consegna()` | dopo npm non c'è niente da fare | **sostituisce il processo** e non torna |
| `accompagna()` | dopo npm c'è da guardare il delta | genera un figlio, inoltra i segnali, aspetta |

Questa distinzione non è un'ottimizzazione di Python: è il motivo per cui `npm
run dev` non si trascina dietro un processo `npz` fermo per ore, ed è la ragione
principale per cui il §3 aveva scartato Node. Va portata identica.

---

## 4. La mappa

```text
npz_go/
├── go.mod
├── main.go                      ← l'entrata: classifica, decide, consegna
├── internal/
│   ├── nucleo/                  ← il meccanismo. Non sa niente di npm né di .npz
│   │   ├── nucleo.go            ← FORMATO, COMPRESSIONE, Errore, Profilo
│   │   ├── immagine.go
│   │   ├── mount.go
│   │   ├── stato.go
│   │   ├── perimetro.go
│   │   └── filesystem.go
│   ├── facciata/                ← la politica: package.json, npm, .npz
│   │   ├── progetto.go          ← risalita, idoneità
│   │   ├── nomi.go              ← gli otto stati
│   │   ├── comandi.go           ← le quattro classi
│   │   ├── npm.go               ← trova, consegna, accompagna
│   │   ├── monta.go · congela.go · compatta.go · scavalca.go
│   │   └── comandi_npz.go       ← i sei comandi
│   └── voce/                    ← la sbarra: testa, segno, coda
├── build/                       ← si costruisce: build.sh e bin/
└── test/                        ← si prova: banchi, report, attrezzi
```

I nomi `nucleo` e `facciata` sono quelli del §4 del piano, che descrive
esattamente questa separazione. `internal/` è il modo in cui Go impedisce che
qualcuno importi il nucleo dall'esterno — la stessa cosa che in Python è una
convenzione, resa un errore di compilazione.

**È l'unico nome di cartella a cui il compilatore Go dà un significato**, e per
questo non si rinomina per gusto: chiamarla `src/` — che è un'abitudine di Java
e di JavaScript, dove serve a separare i sorgenti dal build — la ridurrebbe a
una cartella qualsiasi, e la separazione tornerebbe a essere una promessa
invece di un vincolo. In Go la radice del modulo *è* la radice dei sorgenti, e
`go.mod` con `main.go` ci stanno accanto.

| Python | righe | Go |
| --- | --- | --- |
| `lanciatore.py` | 71 | `main.go` |
| `veloce.py` | 340 | si scioglie in `facciata/` e `voce/` |
| `comandi.py` | 87 | `facciata/comandi.go` — quasi 1:1 |
| `progetto.py` | 162 | `facciata/progetto.go` — assorbe la risalita da `veloce` |
| `cli.py` | 1416 | `facciata/`, spezzato per operazione |
| `lib/*.py` | 673 | `nucleo/*.go` — 1:1, file per file |

`lib/` si trasporta quasi meccanicamente: non ha stato globale, non tocca la CLI,
e la sua interfaccia è già quella giusta. `cli.py` è dove sta il lavoro vero, ed è
l'unico file che vale la pena spezzare invece di trasportare intero.

---

## 5. Le decisioni di linguaggio

Prese una volta qui, così non si ridiscutono file per file.

| Questione | Decisione | Perché |
| --- | --- | --- |
| CGO | **`CGO_ENABLED=0`**, sempre | è tutta la ragione per cui si è scelto Go (§2) |
| sostituire il processo | `syscall.Exec` con percorso assoluto risolto | `os/exec` non ha un exec-replace |
| eseguire e aspettare | `os/exec` + `cmd.Start()`/`Wait()` | **in Go non si fa `fork()`**: il runtime è multi-thread. Vedi §6.2 |
| lock | `unix.Flock(fd, LOCK_EX)`, `*os.File` tenuto vivo | la proprietà che serve — si rilascia alla morte del processo — è del kernel, e sopravvive |
| errori attesi | un tipo `*Errore` + `errors.As` in cima | è il `class Errore(Exception)` di oggi: si stampa senza traceback |
| config e `.meta` | **`encoding/json`**, per adesso | scriverne uno a mano risparmia ~700 KB di binario e introduce bug in un formato versionato. Se ne riparla se il peso dà fastidio, e per §2 non lo darà |
| sottoprocessi | `exec.Command` con slice di argomenti, **mai una shell** | i percorsi contengono spazi, e `fuse-overlayfs` ha già i suoi problemi con quelli (§6 bis dei rischi) |
| esaustività | linter `exhaustive` in `golangci-lint`, obbligatorio in CI | è il surrogato delle somme di tipi (§6.3) |
| dipendenze esterne | solo `golang.org/x/sys` | tutto il resto è libreria standard; meno dipendenze, meno superficie da impacchettare |

---

## 6. I tre punti dove Go non è Python

Il resto del porting è trasporto. Questi tre no, e sono quelli su cui un porting
distratto si rompe in modi silenziosi.

### 6.1 `syscall.Exec` non esegue i `defer`

Quando il processo si sostituisce, **tutto quello che era in coda a un `defer`
non succede**. In Python è la stessa cosa e il codice lo sa già: `consegna()`
chiama `chiudi()` *prima* di `os.execv`, e non per pulizia — perché la sbarra
della voce (`TESTA`/`SEGNO`/`CODA`) delimita un **turno di parola**, e la coda va
emessa esattamente dove `npz` cede il terminale.

In Go la tentazione di scrivere `defer voce.Chiudi()` in cima a `main` è forte, e
sarebbe un bug: sull'uscita normale funziona, su ogni `syscall.Exec` — cioè sul
percorso più frequente del programma — la coda non verrebbe mai stampata, e
l'output di `npm` apparirebbe dentro il turno di `npz`.

La regola da scrivere nel codice, in Go come in Python: **la coda si chiude
esplicitamente prima di ogni `Exec` e prima di ogni `Start`**, mai per `defer`.

### 6.2 Niente `fork()` — e qui Go è migliore del Python

`accompagna()` oggi fa `os.fork()`, poi `os.execv` nel figlio, poi installa
quattro gestori di segnale, poi `waitpid` in un ciclo che ritenta su
`InterruptedError`, poi ripristina i gestori precedenti, poi decodifica
`WIFSIGNALED` per rendere `128 + segnale`. Sono quaranta righe di cui trenta sono
la meccanica POSIX.

In Go `fork()` senza exec immediato **non è supportato** — il runtime ha già
avviato thread e scheduler. Ma non serve: `os/exec` fa fork+exec internamente e
in modo sicuro, e il resto diventa

- segnali → `signal.Notify` su un canale, rilanciati con `cmd.Process.Signal()`;
- attesa → `cmd.Wait()`, che ritenta da sé;
- codice di uscita → `cmd.ProcessState`, con `syscall.WaitStatus` per il caso del
  segnale.

Il comportamento osservabile è identico e le righe sono la metà. È l'unico punto
del porting in cui il codice Go sarà più leggibile dell'originale, e vale la pena
segnarlo perché ovunque altrove il rapporto sarà l'inverso.

### 6.3 Gli otto stati, senza somme di tipi

Gli stati sono otto — `outside`, `candidate`, `declined`, `fresh`, `mounted`,
`attached`, `broken`, `bypassed` — e i loro valori sono ciò che `npz status`
stampa alla lettera, quindi non sono liberi. Le classi di comando sono quattro.
Il codice ci si dirama sopra continuamente.

Senza `enum` esaustivi, la mitigazione è in tre parti e vanno prese tutte e tre:

1. **`type Stato string`**, non `string` nuda: rende impossibile passare uno stato
   dove serve un percorso, che è l'errore banale.
2. **Linter `exhaustive`**, obbligatorio in CI: segnala ogni `switch` su `Stato`
   che non copre tutti i casi. È il 90% di quello che darebbe Rust, spostato dal
   compilatore a un attrezzo esterno.
3. **`default:` che va in panico**, non che tira dritto. Uno stato non gestito
   deve fermare il programma con il proprio nome nel messaggio, non prendere il
   ramo prudente — perché il ramo prudente, su un progetto che sta per essere
   montato o cancellato, non c'è.

---

## 7. L'oracolo: il differenziale contro il Python

Questa è la parte del piano che vale più di tutte le altre, ed è disponibile solo
adesso: **durante il porting esistono due implementazioni dello stesso formato**,
e quella vecchia funziona.

Da cui una strategia di prova che non richiede di scrivere aspettative a mano:

```text
per ogni operazione:
   stessa fixture, due copie
   ├── npz Python  →  albero A + immagine A
   └── npz Go      →  albero B + immagine B
   confronto: A ≡ B  per attributi, non per nomi
```

Il confronto lo fa `img.differenze()`, che il progetto ha già scritto e che
`detach` usa per lo stesso identico scopo — tipo, permessi, dimensione,
destinazione dei symlink, uid, gid. Non c'è codice di prova nuovo da inventare:
c'è da riusare la funzione che il progetto ha costruito per fidarsi di sé stesso.

E una prova più forte, che il formato fermo rende possibile: **incrociare le due
implementazioni**. Congela con il Python, monta con il Go. Compatta con il Go,
fai `detach` con il Python. Se `FORMATO` è davvero fermo devono funzionare tutte
e quattro le combinazioni, e ognuna che fallisce indica esattamente quale funzione
ha deviato.

Quando la fase 3 spegne il Python, questo oracolo sparisce. È il motivo per cui
va usato tutto adesso, e per cui la fase 1 e la fase 2 del porting non devono
avere fretta di arrivare alla fine.

---

## 8. Fase 0 — il pavimento

**Mezza giornata.** Uno spike da buttare via, sulla falsariga di
[fase0.sh](../npz_python/test/fase0.sh): ~150 righe di Go che fanno il percorso
veloce e niente altro — risalita al `package.json`, i quattro `os.Stat` dello
stato, `trova_npm` che salta sé stesso, `syscall.Exec`.

La ragione per cui esiste è che la scelta di Go è stata fatta su numeri **stimati
da me**, non misurati su questa macchina — e il metodo di questo progetto è
l'inverso. *Le misure che possono uccidere l'idea costano ore, implementarla
costa settimane.*

### Criterio di uscita

| | soglia | se fallisce |
| --- | --- | --- |
| percorso veloce a riposo | **< 3 ms** (Python: 13) | Go non è la risposta: si riapre il confronto a tre |
| `syscall.Exec` trasparente | TTY, ctrl-c, codice di uscita **identici** al Python | idem — è la proprietà per cui si è scartato Node |
| la coda della voce prima di `Exec` | emessa | è §6.1: si corregge, non uccide |
| binario, `CGO_ENABLED=0`, `-s -w` | **< 5 MB** | si guarda `encoding/json` |
| gira su una glibc vecchia | sì | verifica in container Debian 12 |

Il secondo punto è quello che può davvero fermare tutto, ed è per questo che sta
in fase 0 e non altrove: il runtime di Go è multi-thread, `Exec` lo attraversa, e
la trasparenza del wrapper è il requisito da cui dipende ogni altra cosa.

---

## 9. Fase 1 — il nucleo

**~673 righe di Python, sei file, nessuna dipendenza dalla CLI.** Si trasporta
file per file, nell'ordine in cui i moduli dipendono l'uno dall'altro:

`nucleo.go` → `filesystem.go` → `mount.go` → `immagine.go` → `stato.go` → `perimetro.go`

Alla fine di ognuno, la prova differenziale del §7 su quella funzione sola.

**Criterio di uscita ✔** — *superato, ma non nella forma in cui era scritto.*

Diceva: un'immagine **bit-identica** a quella prodotta dal Python sulla stessa
fixture. Misurato: è irrealizzabile, e non per colpa del porting. `mkfs.erofs`
incorpora un **UUID casuale**, quindi due build della stessa sorgente
differiscono già fra Python e Python. Con `-U` fisso tornano identiche — il che
dimostra che tutto il resto dell'immagine è deterministico, e che la richiesta
era sbagliata solo nella misura in cui chiedeva più di quanto serva.

Il criterio riformulato, e verificato in
[report-fase1-go.md](../npz_go/test/report-fase1-go.md):

> **il contenuto montato delle due immagini coincide**, attributo per attributo,
> e coincide con la sorgente.

È la proprietà che il congelamento usa per fidarsi di sé stesso — lo stesso
`inventario()` di `verifica()` — quindi è quella che conta. Nessuna CLI, nessuno
stato, nessun npm.

Una lacuna emersa strada facendo: `inventario()` confronta tipo, permessi,
dimensione, destinazione dei symlink, uid e gid, ma **non nlink né inode**.
La promessa di [claim.md](claim.md) — *EROFS conserva hardlink con il loro
`nlink` e lo stesso inode* — non è quindi verificata da nessuno dei due nuclei.
È una lacuna dell'originale, portata identica per non rompere l'oracolo, e
chiusa nel banco: l'hardlink dentro l'immagine risulta con inode condiviso e
`nlink=2`. Se un giorno si vuole in `inventario()`, va aggiunta **in tutte e due
le implementazioni insieme**.

Il commento va con la funzione. I docstring di `lib/` non sono commenti di
servizio: contengono le misure e le ragioni (*"lz4hc perché misurato più veloce
del non compresso"*, *"`-T0` e `--all-time` romperebbero la fedeltà"*). Un porting
che li lascia indietro butta via l'unica documentazione che sta accanto al codice
che descrive.

---

## 10. Fase 2 — la facciata

Il grosso. Nell'ordine, perché ogni passo rende provabile il successivo:

1. `voce/` — la sbarra, con la regola del §6.1. Prima di tutto, perché tutto il
   resto parla attraverso di lei;
2. `comandi.go` — le quattro classi. È il file più meccanico e il più facile da
   provare: stessa `argv`, stessa classe del Python, su tutta la tabella;
3. `stati.go` + `progetto.go` — gli otto stati e la risalita. Provabili contro il
   Python su alberi fabbricati a mano, uno per stato;
4. `npm.go` — `consegna` e `accompagna` (§6.2), promossi dallo spike di fase 0;
5. `monta.go`, `congela.go` — e qui si può già usare `npz` per lavorare;
6. `compatta.go`, `scavalca.go` — il consolidamento e il §6 bis;
7. i sei comandi, `status` per ultimo perché legge tutto il resto.

**Criterio di uscita ✔** — *superato.* I quattro test del §13 del piano, che non
erano mai stati scritti e che questo porting è stata l'occasione di scrivere una
volta sola. Gli esiti in [report-fase2-go.md](../npz_go/test/report-fase2-go.md):
**44 pass, 0 fail**.

| Test del §13 | |
| --- | --- |
| giro completo | albero → `attach` → scrittura nel delta → `compact` → `detach`, e l'albero finale coincide attributo per attributo. Del confronto *byte a byte* vale quanto detto in fase 1: si confrontano gli attributi, che è ciò che l'immagine promette di conservare |
| uccisione a metà | in due forme — residui fabbricati (un `.img.new`, una `run/` popolata) e un `SIGKILL` vero durante il consolidamento. In entrambe il rilancio riporta lo stesso albero e lo stato torna `mounted` |
| `npz` in CI | niente TTY, `stdin` chiuso, `CI=1`: nessuna domanda, nessun congelamento non richiesto, **nemmeno un rifiuto registrato**, e il codice di uscita di npm intatto |
| dentro `package.json` | `node` risolve i moduli dall'albero montato, i binari in `node_modules/.bin` si eseguono, e il mount è un confine di filesystem — `find -xdev` vede **0** dei 5 file dentro l'albero |

E l'oracolo del §7 regge anche qui, che era la prova meno scontata: il Python
attacca e Go smonta, rimonta, consolida e stacca — e nell'altro verso identico.
Le due implementazioni si scambiano i progetti in corsa.

Il percorso veloce non è regredito: il binario completo costa **2,78 ms**
contro i 2,72 dello spike, benché sia passato da 1,7 a 2,6 MB. Il codice che
non si attraversa non si paga.

---

## 11. Fase 3 — la parità, e il taglio

Il porting non è finito quando il Go funziona: è finito quando il Python esce dal
repo. Finché stanno entrambi, ogni correzione va fatta due volte o divergono in
silenzio — che è esattamente quello che il §4 dice del `Profilo` e dei nomi
tenuti in due posti.

1. una settimana di uso vero, con il binario Go collegato da `~/.local/bin/npz`;
2. l'incrocio del §7 su tutte e quattro le combinazioni, un'ultima volta;
3. `npz_python/` esce dal repo, come ne è uscito `freeze`;
4. i documenti restano al presente, come è già stato deciso per `claim.md`.

`mounter.sh` e `fase0.sh` restano: sono banchi, non prodotto, e il secondo serve
ancora alla fase 2 vera.

---

## 12. Fase 4 — la distribuzione

È il movente di tutto (§2), e viene per ultima perché non c'è niente da spedire
prima.

| Canale | Copertura | Costo |
| --- | --- | --- |
| **`npm i -g npz`** | il **100%** del pubblico: `npz` è un wrapper di npm, chi lo userebbe ha già npm | `optionalDependencies` per piattaforma, modello esbuild |
| **script di installazione** | chi non passa da npm; installa anche l'unità systemd | `~/.local/bin`, **nessun sudo**, checksum verificato |
| **AUR** (`PKGBUILD`) | Arch e Manjaro | un file, `git push`, dipendenze dichiarate |
| **`.deb` / `.rpm`** | Debian, Ubuntu, Fedora | escono già da GoReleaser via nfpm |

Tutto da **un `.goreleaser.yaml`**: `linux/amd64` e `linux/arm64`, tarball,
`.deb`, `.rpm`, checksum. E — verificato su questa macchina, che non ha né `dpkg`
né `rpmbuild` — nfpm li produce con implementazioni in Go, senza toolchain Debian
o Fedora installata.

Qui va anche **`npz-smonta.service`**, l'unità utente del §13 che non è mai stata
scritta. La sessione utente di systemd su questa macchina è attiva, quindi è
provabile subito.

### Le dipendenze, che nessun linguaggio risolve

Il binario è autosufficiente; `npz` no. Servono quattro eseguibili esterni, e la
loro ripartizione in pacchetti **cambia da distro a distro**:

| binario | Arch / Manjaro *(verificato)* |
| --- | --- |
| `mkfs.erofs`, `dump.erofs`, `fsck.erofs` | `erofs-utils` |
| `erofsfuse` | **`erofsfuse`** — pacchetto separato |
| `fuse-overlayfs` | `fuse-overlayfs` |
| `fusermount3` | `fuse3` |

Che su Arch `erofsfuse` non stia dentro `erofs-utils` è la prova che questa
tabella non si scrive a memoria: le righe Debian e Fedora **vanno verificate sui
repo reali** prima di pubblicare, insieme alle versioni minime che reggono.

Lo script di installazione **verifica e istruisce, non installa**: uno script
scaricato da internet che invoca `pacman -S` o `apt install` con sudo è
un'escalation che non si chiede a nessuno. La logica esiste già — è il `check` di
`fase0.sh`, con gli stessi quattro nomi.

---

## 13. L'ordine di lavoro

1. **Fase 0**, mezza giornata. Può ancora uccidere la scelta di Go, ed è l'unico
   punto in cui costa poco farlo.
2. **Fase 1**, il nucleo, con l'oracolo acceso a ogni file.
3. **Fase 2**, la facciata, nei sette passi del §10.
4. **Fase 3**, una settimana d'uso, poi il taglio.
5. **Fase 4**, la distribuzione — o anche prima, in parallelo alla 2: il
   `.goreleaser.yaml` non dipende da quanto è finito il codice.

E la regola del §1, che vale sopra tutte: **la fase 2 del progetto non entra in
questa lista.** Un cambio di linguaggio a formato fermo si può verificare contro
un oracolo; un cambio di linguaggio insieme a un cambio di formato no.

---

## Rimandi

- [piano di implementazione.md](<piano di implementazione.md>) — il disegno che
  questo porting trasporta senza rinegoziarlo: gli stati (§6), lo scavalcamento
  (§6 bis), i due percorsi (§7), i comandi (§8), il consolidamento (§9).
- [piano di implementazione fase 2.md](<piano di implementazione fase 2.md>) — che
  non si fa insieme a questo, e perché.
- [claim.md](claim.md) — le tre invarianti. Nessuna si muove qui: cambiano le
  righe che le implementano, non le righe che le descrivono.
- [taccuino di viaggio.md](<taccuino di viaggio.md>) — il metodo che la fase 0 di
  questo piano applica a sé stessa.
- [report-fase0.md](../npz_python/test/report-fase0.md) — N6, cioè il numero che
  dice che questo porting **non** serviva alla velocità.
