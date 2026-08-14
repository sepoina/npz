# npz — piano di implementazione, il porting in Go

> **Nota del 14-08-2026.** Il §11 descrive come futuro il taglio del Python; **ora è
> avvenuto**. `npz_python/` non vive più nel repo: la versione 0.2.7 è archiviata in
> [archive/npz_python-0.2.7.tar.gz](../archive/npz_python-0.2.7.tar.gz), e l'oracolo
> differenziale di cui parla il §7 è spento. Il testo resta — è la storia del porting.

Il §3 del [piano](<piano di implementazione.md>) aveva condizionato il binario
compilato a N6. **N6 è passato a 11,8%**: sull'asse della velocità il wrapper in
Python regge, e non c'è niente da comprare. Questo porting nasce quindi da un movente
diverso — la **distribuzione** — ed è il movente a scegliere il linguaggio: se si
trattasse di millisecondi vincerebbe il C.

---

## 1. Che cosa è, e che cosa non è

**È una reimplementazione a formato invariato.** `FORMATO` resta **1**, la struttura
di `.npz/` non si muove di una voce, lo schema dei `.meta` neppure. Un binario Go deve
leggere e scrivere store creati dal Python di oggi, e viceversa, per tutta la durata
del porting: è questo che rende possibile l'oracolo del §7.

**Non è l'occasione per correggere il disegno.** Ogni cosa che il codice fa oggi la fa
per una ragione scritta da qualche parte — le invarianti da [claim.md](claim.md), gli
stati dal §6 del piano, la classificazione per eccesso da N2. Il porting le trasporta,
non le rinegozia.

**E non si fa insieme alla fase 2**, che cambia `FORMATO` e riscrive `percorsi()`.
Farla nello stesso movimento del cambio di linguaggio significa avere due variabili in
volo e nessun modo di sapere quale delle due ha rotto cosa. Prima il porting a formato
fermo, poi la fase 2 sul codice Go — o l'inverso, ma in nessun caso insieme.

---

## 2. Perché Go, e il fatto che decide

| | C | Rust | Go |
| --- | --- | --- | --- |
| avvio | ~0,5 ms | ~1 ms | ~1–2 ms |
| binario statico | 300–600 KB | 1,5–2,5 MB | **3–5 MB** |
| toolchain | **0** (gcc già presente) | 306 MiB, **un solo target** | 215 MiB, **tutti i target** |
| cross-compile aarch64 | la parte dolorosa del C | +150 MiB per target | `GOARCH=arm64` |
| dipendenza da glibc | sì, se dinamico | sì, se target `gnu` | **nessuna**, con `CGO_ENABLED=0` |

L'ultima riga decide. Questa macchina ha **glibc 2.44**; Debian 12 ne ha 2.36, Ubuntu
22.04 la 2.35, RHEL 9 la 2.34. Un binario linkato dinamicamente qui sopra non parte su
nessuna delle tre, e l'utente lo scopre dopo aver eseguito lo script di installazione,
quando ormai si è fidato. Con `CGO_ENABLED=0` un binario Go **non linka libc affatto**:
fa syscall dirette, non c'è versione da far combaciare, ed è il comportamento
predefinito. I caveat noti — DNS, NSS — non toccano `npz`, che non fa rete.

L'avvio, che nel §3 era **la** variabile dominante, qui non discrimina: tutti e tre
stanno dieci volte sotto i 13 ms di Python.

**Quello che si paga: niente somme di tipi.** Gli otto stati e le quattro classi di
comando sono, in Rust, `enum` con `match` esaustivo — un nono stato farebbe fallire la
compilazione ovunque non sia gestito. In Go sono costanti e uno `switch` senza
controllo. Il progetto ha già aggiunto uno stato a disegno fatto (*scavalcato*): non è
un rischio teorico. La mitigazione è in §6.3.

---

## 3. Quello che il compilato cancella

`veloce.py` non esiste per una ragione di disegno: esiste perché importare `pathlib`
costa 26 ms e `npz` sta davanti a ogni comando `npm`. **Compilato, quel costo è zero**,
e con la ragione sparisce il modulo — il suo contenuto si scioglie dentro i moduli
normali, dove ognuna delle sue funzioni sarebbe stata scritta se non ci fosse stato un
budget da rispettare.

Attenzione a non cancellare troppo: **la divisione fast/slow sparisce come
organizzazione del codice, non come logica.** Resta intatta la cosa che conta:
`consegna()` — quando dopo npm non c'è niente da fare — **sostituisce il processo** e
non torna; `accompagna()` genera un figlio, inoltra i segnali e aspetta. Non è
un'ottimizzazione di Python: è il motivo per cui `npm run dev` non si trascina dietro
un processo `npz` fermo per ore, ed è la ragione principale per cui il §3 aveva
scartato Node. Va portata identica.

---

## 4. La mappa

```text
npz_go/
├── go.mod · main.go             ← l'entrata: classifica, decide, consegna
├── internal/
│   ├── nucleo/                  ← il meccanismo. Non sa niente di npm né di .npz
│   │   └── nucleo · immagine · mount · stato · perimetro · filesystem
│   ├── facciata/                ← la politica: package.json, npm, .npz
│   │   └── progetto · nomi · comandi · npm · monta · congela · compatta ·
│   │       scavalca · comandi_npz
│   └── voce/                    ← la sbarra: testa, segno, coda
├── build/ · test/
```

`internal/` è il modo in cui Go impedisce che qualcuno importi il nucleo dall'esterno —
la stessa cosa che in Python è una convenzione, resa un errore di compilazione. **È
l'unico nome di cartella a cui il compilatore dà un significato**, e per questo non si
rinomina per gusto: chiamarla `src/` la ridurrebbe a una cartella qualsiasi, e la
separazione tornerebbe a essere una promessa invece di un vincolo.

| Python | righe | Go |
| --- | --- | --- |
| `lanciatore.py` | 71 | `main.go` |
| `veloce.py` | 340 | si scioglie in `facciata/` e `voce/` |
| `comandi.py` | 87 | `facciata/comandi.go` — quasi 1:1 |
| `progetto.py` | 162 | `facciata/progetto.go` |
| `cli.py` | 1416 | `facciata/`, spezzato per operazione |
| `lib/*.py` | 673 | `nucleo/*.go` — 1:1, file per file |

`lib/` si trasporta quasi meccanicamente: non ha stato globale e la sua interfaccia è
già quella giusta. `cli.py` è dove sta il lavoro vero.

---

## 5. Le decisioni di linguaggio

| Questione | Decisione | Perché |
| --- | --- | --- |
| CGO | **`CGO_ENABLED=0`**, sempre | è tutta la ragione per cui si è scelto Go |
| sostituire il processo | `syscall.Exec`, percorso assoluto | `os/exec` non ha un exec-replace |
| eseguire e aspettare | `os/exec` + `Start()`/`Wait()` | **in Go non si fa `fork()`**: il runtime è multi-thread |
| lock | `unix.Flock`, `*os.File` tenuto vivo | la proprietà che serve è del kernel, e sopravvive |
| errori attesi | `*Errore` + `errors.As` | è il `class Errore(Exception)` di oggi: si stampa senza traceback |
| config e `.meta` | **`encoding/json`** | scriverne uno a mano risparmia ~700 KB e introduce bug in un formato versionato |
| sottoprocessi | `exec.Command`, **mai una shell** | i percorsi contengono spazi |
| esaustività | linter `exhaustive`, obbligatorio in CI | è il surrogato delle somme di tipi |
| dipendenze | solo `golang.org/x/sys` | meno superficie da impacchettare |

---

## 6. I tre punti dove Go non è Python

Il resto è trasporto. Questi tre no, e sono quelli su cui un porting distratto si rompe
in modi silenziosi.

**6.1 — `syscall.Exec` non esegue i `defer`.** La tentazione di scrivere
`defer voce.Chiudi()` in cima a `main` è forte e sarebbe un bug: sull'uscita normale
funziona, ma su ogni `Exec` — cioè sul percorso più frequente — la coda non verrebbe
mai stampata, e l'output di `npm` apparirebbe dentro il turno di `npz`. **La coda si
chiude esplicitamente prima di ogni `Exec` e di ogni `Start`**, mai per `defer`.

**6.2 — Niente `fork()`, e qui Go è migliore del Python.** `accompagna()` oggi fa
`os.fork()`, `execv` nel figlio, quattro gestori di segnale, `waitpid` in un ciclo che
ritenta su `InterruptedError`, ripristino dei gestori, e decodifica di `WIFSIGNALED`:
quaranta righe di cui trenta sono meccanica POSIX. In Go `fork()` senza exec immediato
non è supportato, ma non serve — `os/exec` fa fork+exec internamente, i segnali
diventano `signal.Notify` su un canale, l'attesa `cmd.Wait()`, l'uscita
`cmd.ProcessState`. Comportamento identico, righe dimezzate. È l'unico punto in cui il
codice Go sarà più leggibile dell'originale.

**6.3 — Gli otto stati, senza somme di tipi.** Sono `outside`, `candidate`,
`declined`, `fresh`, `mounted`, `attached`, `broken`, `bypassed`, e i loro valori sono
ciò che `npz status` stampa alla lettera, quindi non sono liberi. La mitigazione è in
tre parti, e vanno prese tutte: **`type Stato string`** e non `string` nuda, che rende
impossibile passare uno stato dove serve un percorso; il **linter `exhaustive`** in CI,
che è il 90% di quel che darebbe Rust spostato a un attrezzo esterno; e un
**`default:` che va in panico**, non che tira dritto — perché il ramo prudente, su un
progetto che sta per essere montato o cancellato, non c'è.

---

## 7. L'oracolo: il differenziale contro il Python

È la parte del piano che vale più di tutte le altre, ed è disponibile solo adesso:
**durante il porting esistono due implementazioni dello stesso formato**, e quella
vecchia funziona. Da cui una strategia di prova che non richiede di scrivere
aspettative a mano — stessa fixture, due copie, confronto **per attributi e non per
nomi**, con lo stesso `img.differenze()` che `detach` usa per lo stesso scopo.

E una prova più forte, che il formato fermo rende possibile: **incrociare le due
implementazioni.** Congela col Python, monta col Go; compatta col Go, `detach` col
Python. Se `FORMATO` è davvero fermo devono funzionare tutte e quattro le
combinazioni, e ognuna che fallisce indica quale funzione ha deviato. Quando la fase 3
spegne il Python questo oracolo sparisce: è il motivo per cui va usato tutto adesso.

---

## 8. Fase 0 — il pavimento ✔

Mezza giornata, uno spike da buttare via: ~150 righe che fanno il percorso veloce e
niente altro. Esiste perché la scelta di Go era stata fatta su numeri **stimati**, non
misurati su questa macchina — e il metodo di questo progetto è l'inverso.

| | soglia | esito |
| --- | --- | --- |
| percorso veloce a riposo | **< 3 ms** (Python: 13) | **2,72 ms** ✔ |
| `syscall.Exec` trasparente | TTY, ctrl-c, uscita identici al Python | ✔ |
| la coda della voce prima di `Exec` | emessa | ✔ |
| binario, `CGO_ENABLED=0`, `-s -w` | **< 5 MB** | 1,7 MiB ✔ |

Il secondo punto poteva davvero fermare tutto, ed è per questo che sta in fase 0: il
runtime di Go è multi-thread, `Exec` lo attraversa, e la trasparenza del wrapper è il
requisito da cui dipende ogni altra cosa.
[report-fase0-go.md](../npz_go/test/report-fase0-go.md): **30 pass, 0 fail**.

## 9. Fase 1 — il nucleo ✔

~673 righe, sei file, nessuna dipendenza dalla CLI. Si trasporta nell'ordine in cui i
moduli dipendono l'uno dall'altro — `nucleo` → `filesystem` → `mount` → `immagine` →
`stato` → `perimetro` — con la prova differenziale a ogni file.

**Criterio di uscita superato, ma non nella forma in cui era scritto.** Chiedeva
un'immagine **bit-identica**: è irrealizzabile, e non per colpa del porting.
`mkfs.erofs` incorpora un **UUID casuale**, quindi due build della stessa sorgente
differiscono già fra Python e Python; con `-U` fisso tornano identiche, il che dimostra
che tutto il resto è deterministico e che la richiesta era sbagliata solo nel chiedere
più di quanto serva. Riformulato:

> **il contenuto montato delle due immagini coincide**, attributo per attributo, e
> coincide con la sorgente.

È la proprietà che il congelamento usa per fidarsi di sé stesso.
[report-fase1-go.md](../npz_go/test/report-fase1-go.md): **47 pass, 0 fail**.

**Una lacuna emersa strada facendo:** `inventario()` confronta tipo, permessi,
dimensione, destinazione dei symlink, uid e gid, ma **non nlink né inode**. La promessa
di claim.md — *EROFS conserva hardlink con il loro `nlink` e lo stesso inode* — non è
quindi verificata da nessuno dei due nuclei. È una lacuna dell'originale, portata
identica per non rompere l'oracolo e chiusa nel banco; se un giorno la si vuole in
`inventario()`, va aggiunta **in tutte e due le implementazioni insieme**.

**Il commento va con la funzione.** I docstring di `lib/` non sono commenti di
servizio: contengono le misure e le ragioni. Un porting che li lascia indietro butta via
l'unica documentazione che sta accanto al codice che descrive.

## 10. Fase 2 — la facciata ✔

Nell'ordine, perché ogni passo rende provabile il successivo: `voce/` per prima, perché
tutto il resto parla attraverso di lei; `comandi.go`, il file più meccanico e il più
facile da provare; `nomi.go` e `progetto.go`, provabili su alberi fabbricati a mano, uno
per stato; `npm.go` promosso dallo spike; `monta.go` e `congela.go`, e qui si può già
usare `npz` per lavorare; `compatta.go` e `scavalca.go`; infine i sei comandi, con
`status` per ultimo perché legge tutto il resto.

**Criterio di uscita superato**: i quattro test del §13 del piano, che non erano mai
stati scritti e che questo porting è stata l'occasione di scrivere una volta sola.
[report-fase2-go.md](../npz_go/test/report-fase2-go.md): **44 pass, 0 fail** — giro
completo, `SIGKILL` a metà consolidamento con rilancio che converge, CI muto, e `node`
che risolve dall'albero montato con `find -xdev` che vede **0** dei 5 file dentro
l'albero. E l'oracolo regge anche qui, che era la prova meno scontata: le due
implementazioni **si scambiano i progetti in corsa**.

Il percorso veloce non è regredito: il binario completo costa **2,78 ms** contro i 2,72
dello spike, benché sia passato da 1,7 a 2,6 MB. Il codice che non si attraversa non si
paga.

## 11. Fase 3 — la parità, e il taglio

Il porting non è finito quando il Go funziona: è finito quando il Python esce dal repo.
Finché stanno entrambi, ogni correzione va fatta due volte o divergono in silenzio. Una
settimana di uso vero col binario collegato da `~/.local/bin/npz`; l'incrocio del §7 su
tutte e quattro le combinazioni un'ultima volta; poi `npz_python/` esce dal repo, come
ne è uscito `freeze`. `mounter.sh` e `fase0.sh` restano: sono banchi, non prodotto.

## 12. Fase 4 — la distribuzione

È il movente di tutto, e viene per ultima perché non c'è niente da spedire prima.

| Canale | Copertura | Costo |
| --- | --- | --- |
| **`npm i -g npz`** | il **100%** del pubblico: chi userebbe npz ha già npm | `optionalDependencies` per piattaforma |
| **script di installazione** | chi non passa da npm; installa anche l'unità systemd | `~/.local/bin`, **nessun sudo**, checksum verificato |
| **AUR** (`PKGBUILD`) | Arch e Manjaro | un file, dipendenze dichiarate |
| **`.deb` / `.rpm`** | Debian, Ubuntu, Fedora | `build/bin/pacchetto.sh` |

Qui va anche **`npz-smonta.service`**, l'unità utente del §13 mai scritta.

**Le dipendenze, che nessun linguaggio risolve.** Il binario è autosufficiente; `npz`
no. Servono `mkfs.erofs`, `erofsfuse`, `fuse-overlayfs` e `fusermount3`, e la loro
ripartizione in pacchetti cambia da distro a distro: su Arch stanno in `erofs-utils`,
**`erofsfuse`** (pacchetto separato), `fuse-overlayfs` e `fuse3`. Che `erofsfuse` non
stia dentro `erofs-utils` è la prova che questa tabella non si scrive a memoria: le
righe Debian e Fedora **vanno verificate sui repo reali** prima di pubblicare.

Lo script di installazione **verifica e istruisce, non installa**: uno script scaricato
da internet che invoca `pacman -S` o `apt install` con sudo è un'escalation che non si
chiede a nessuno.

---

## 13. L'ordine di lavoro

Fase 0 ✔, fase 1 ✔, fase 2 ✔; restano la settimana d'uso col taglio del Python
(fase 3) e la distribuzione (fase 4), che può andare in parallelo. E la regola del §1,
che vale sopra tutte: **la fase 2 del progetto non entra in questa lista.** Un cambio di
linguaggio a formato fermo si può verificare contro un oracolo; un cambio di linguaggio
insieme a un cambio di formato no.

## Rimandi

- [piano di implementazione.md](<piano di implementazione.md>) — il disegno che questo
  porting trasporta senza rinegoziarlo.
- [piano di implementazione fase 2.md](<piano di implementazione fase 2.md>) — che non
  si fa insieme a questo, e perché.
- [claim.md](claim.md) — le tre invarianti. Nessuna si muove qui: cambiano le righe che
  le implementano, non quelle che le descrivono.
- [report-fase0.md](../archive/npz_python-0.2.7.tar.gz) — N6, il numero che dice che
  questo porting **non** serviva alla velocità (nell'archivio Python).
