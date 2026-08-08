# Taccuino di viaggio

Le decisioni prese durante la fase 1, con i numeri che le hanno prodotte. Serve a
ricordare **perché** il progetto è fatto come è fatto, e soprattutto perché non è
fatto come era stato pensato all'inizio: quasi tutte le voci qui sotto
raccontano di un'idea ragionevole smontata da una misura.

Il disegno risultante è in [claim.md](claim.md). I banchi che hanno prodotto questi
numeri — `test/fase1.sh`, `test/confronto.sh` — erano di `freeze` e sono usciti da
questo repo con lui; le voci qui sotto restano perché `npz` eredita le decisioni,
non solo il codice. Le sue misure stanno in
[report-fase0.md](../npz_python/test/report-fase0.md), e le voci **5**, **6** e
**7** sono quelle che il [piano fase 2](<piano di implementazione fase 2.md>)
rimette in discussione.

---

## 1. Il disco di lavoro non può ospitare il sistema

**La domanda.** Il progetto vive su `/mnt/400GB_FastData`. Ci può girare?

**La misura.** No, ed è un no strutturale. Il disco è NTFS via `ntfs-3g`, cioè
FUSE. `chmod 700` viene riletto come `777`: i permessi non sopravvivono. E
overlayfs non accetta un `upperdir` su FUSE, quindi il delta non può stare lì.

**La decisione.** `freeze init` deve rifiutarsi di creare una radice su un
filesystem che non regge un `upperdir` e non conserva i permessi POSIX. Non è
una preferenza: senza permessi il round-trip byte a byte è impossibile per
costruzione.

**Il seguito.** Ha morso una seconda volta, in modo peggiore. Avendo scelto di
tenere il banco di prova sullo stesso disco, un loop device su file servito da
FUSE ha fatto passare tutta la scrittura attraverso il demone `ntfs-3g`: le
pagine sporche si sono accumulate più in fretta di quanto il demone riuscisse a
scaricarle, e il kernel ha esaurito la memoria portandosi via l'editor. Ora lo
script rifiuta un backing su FUSE invece di limitarsi a sconsigliarlo.

---

## 2. Lo stack di montaggio regge

**La domanda.** Era l'assunzione portante e bloccante: si può impilare un
`upperdir` scrivibile sopra un'immagine di sola lettura, con tutto ciò che ne
segue — copy-up, whiteout, rename, `fsync`?

**La misura.** Sì, su entrambe le vie provate. Tutte le verifiche passano,
compreso il `rename` fra directory diverse, che era il candidato più probabile
alla rottura. E le due invarianti dure tengono: dopo ogni scrittura l'immagine
statica resta bit-identica.

**La decisione.** L'architettura procede senza revisioni. È l'unica voce di
questo taccuino in cui la misura ha confermato l'ipotesi invece di smontarla.

---

## 3. Il merge lo fa il kernel

**La domanda.** Il consolidamento deve leggere whiteout e xattr
`trusted.overlay.opaque` dal delta e riconciliarli a mano? Sarebbe la parte più
delicata da scrivere e da mantenere.

**La misura.** No. Si rimonta lo stack in sola lettura e si dà al costruttore
dell'immagine **la vista già fusa** da overlayfs. Whiteout assorbiti, directory
opache risolte, permessi e symlink conservati, nessun xattr interno che trapela,
e l'immagine risultante coincide byte a byte con ciò che l'utente vedeva prima.

**La decisione.** Il `purge` sono tre righe. Nessuna logica di merge da scrivere.

**Il costo, misurato dopo.** Il consolidamento è O(albero) e non O(delta): il
costruttore rilegge tutto. Ma è il **4%** del costo del primo freeze, costante
fra le scale provate, perché rileggere costa molto meno che costruire. Il timore
era fondato nella forma e irrilevante nella grandezza.

---

## 4. La rotazione del delta, ovvero un bug nel disegno

**La domanda.** Nessuno l'aveva posta. È emersa rileggendo i tre tempi
*costruisci → applica → cancella*.

**Il problema.** Fra la lettura del delta (primo tempo) e il suo svuotamento
(terzo tempo) passa tutto il tempo di costruzione dell'immagine. In
quell'intervallo l'utente può scrivere, e quelle scritture verrebbero cancellate
senza essere mai entrate nell'immagine. Una perdita silenziosa dentro
l'operazione che dovrebbe mettere i dati al sicuro.

**La decisione.** Al primo tempo il delta viene **ruotato**: rinominato in un
nome di lavoro, e al suo posto ne nasce uno vuoto. Le scritture successive
atterrano nel nuovo e sopravvivono. Il terzo tempo cancella il ruotato, non il
corrente.

**La misura, arrivata dopo.** Ruotare sotto il mount attivo non funziona:
overlayfs non tollera che i propri layer cambino sotto di sé. Va fatto fra uno
smontaggio e un rimontaggio, che costano **17 millisecondi**. Verificato poi il
caso che conta: scrivendo nella cartella *mentre* il consolidamento è in corso,
la scrittura si ritrova al suo posto a operazione conclusa.

---

## 5. La deduplicazione non paga

È la voce più importante, perché smonta la premessa da cui il progetto era nato.

**L'idea di partenza.** Il valore di `freeze` sta nella deduplicazione
content-addressed fra decine di cartelle che condividono centinaia di copie
degli stessi file. Da cui: un object store condiviso per radice, e nessun
beneficio per una cartella isolata.

**Prima misura, su copie.** Tre copie identiche di un `node_modules` reale:
−66,4% in byte, −75,6% in inode, contro un massimo teorico del −66,7%. La
deduplicazione è quasi perfetta. Sembrava una conferma.

**Seconda misura, su progetti veri.** Quattro progetti React reali e distinti,
95.952 file: **−1,1% in byte**. Gli inode calavano del 38,8%, i byte di niente.

**La scomposizione.** La dedup pura valeva −12,6%, i metadati delle immagini
+11,4%, e — il numero che spiega tutto — lo spazio davvero occupato dagli oggetti
era per il **54% arrotondamento al blocco**. Centocinquantotto MiB logici ne
occupavano trecentoquarantatré reali, perché ogni oggetto è un file e la taglia
media era 2.816 byte. Metà dello store era aria.

**La variabile decisiva** non è quanta duplicazione ci sia, ma **quanto sono
grandi i file**. In un `node_modules` vero il 97% dei file sta sotto i 5 KB e
contiene il 26% dei byte. Sotto la dimensione del blocco, un object store che
tiene un file per oggetto non può vincere.

**Il tentativo di salvataggio.** Un ibrido: file piccoli impacchettati dentro
l'immagine, file grandi nell'object store deduplicato. Tecnicamente fattibile —
il dump testuale di composefs distingue esplicitamente il contenuto inline dal
riferimento allo store, `--from-file` lo riaccetta senza perdite, verificato su
tutti i 256 valori di byte, e il limite per l'inline è 5000 byte, cioè
esattamente la fascia che soffre.

**La misura finale.** Sette progetti React reali, 258.450 file, ibrido contro
semplice immagine compressa, misurando la curva a ogni cartella aggiunta:

| cartelle | ibrido | compresso | chi vince |
| --- | --- | --- | --- |
| 1 | 54,8 MiB | 26,4 MiB | compresso |
| 3 | 88,9 MiB | 44,1 MiB | compresso |
| 5 | 225,8 MiB | 125,3 MiB | compresso |
| 7 | 1,1 GiB | 736,3 MiB | compresso |

La deduplicazione **stava funzionando**: il rapporto cumulato scendeva da 2,08 a
1,53 man mano che lo store si popolava. Ma il costo marginale — quanto costa
aggiungere la cartella successiva — non è mai sceso sotto **1,29**. Perché ci sia
un incrocio dovrebbe scendere sotto 1, cioè una nuova cartella dovrebbe essere
quasi interamente già presente nello store: la definizione di copia.

**Il conto di fondo.** Su questi alberi la compressione toglie il **48%** dei
byte, la deduplicazione ne toglie circa il **20%**. E deduplicare, con gli
strumenti disponibili, significa rinunciare a comprimere. Due contro uno e un
quarto.

**La decisione.** Niente object store. Una immagine compressa autosufficiente per
cartella. Cadono con lui la garbage collection, gli oggetti orfani, il refcount,
il ciclo di vita condiviso — cioè la parte più delicata del progetto — e il
requisito di root.

**La conseguenza sulla premessa.** Il beneficio non viene dal condividere ma dal
comprimere e dall'impacchettare, quindi **una cartella isolata ci guadagna**,
esattamente il caso che il documento originale dichiarava privo di senso. E il
beneficio principale sono gli inode: 258.450 file diventano sette.

**Cosa resterebbe da provare, se un giorno servisse.** L'handicap dell'ibrido è
la compressione mancante, non la deduplicazione: il costruttore di composefs non
espone alcuna opzione di compressione. Su un filesystem con compressione
trasparente — btrfs `compress=zstd` — lo store si comprimerebbe mentre le
immagini già compresse non guadagnerebbero nulla, e l'esito potrebbe rovesciarsi.
Non misurato.

---

## 6. La compressione non costa: accelera

**La domanda.** Comprimere l'immagine fa risparmiare spazio, ma quanto penalizza
la lettura? Il carico che conta è quello di un bundler che risolve moduli: accessi
sparsi, in ordine non prevedibile, su una frazione dell'albero. È il caso peggiore
per un formato compresso, perché l'ordine casuale annulla il readahead.

**La misura**, a cache fredda, campione di 5.000 file estratto una volta sola e
riusato identico:

| | grezzo | lz4hc | zstd |
| --- | --- | --- | --- |
| file al secondo | 7.874 | **8.591** | 7.974 |
| latenza mediana | 122,6 µs | **108,9 µs** | 122,2 µs |
| p99 | 491,4 µs | **486,7 µs** | 516,2 µs |
| spazio | 191,4 MiB | 113,8 MiB | 112,5 MiB |

A parità di struttura, **`lz4hc` è più veloce del non compresso** e occupa il 40%
in meno. Comprimere significa leggere meno byte dal supporto, e `lz4` decomprime
più in fretta di quanto il supporto consegni: il risparmio di I/O paga la
decompressione con l'avanzo. `zstd` comprime uguale ma decomprime più lentamente
e torna ai tempi del grezzo.

**La decisione.** `lz4hc`, e la compressione non è più una voce da valutare in
futuro: è il meccanismo principale del risparmio di spazio. Sul disco meccanico
il vantaggio sarebbe ancora maggiore, perché il rapporto fra costo dell'I/O e
costo della CPU peggiora.

---

## 7. I privilegi: da obbligatori a non necessari

**La prima conclusione.** `erofsfuse` monta senza problemi, ma `fuse-overlayfs`
(1.17) **non implementa i layer data-only** — la sintassi `lowerdir=a::b`. E il
doppio due punti è proprio il meccanismo con cui un'immagine composefs rimanda
al suo object store. Verdetto: il montaggio richiede root, senza alternative.

**Il ribaltamento.** Quel verdetto valeva per l'object store, non per lo stack.
Senza store il `::` non serve, e allora `erofsfuse` più `fuse-overlayfs`
funzionano per intero da utente non privilegiato: lettura, scrittura nel delta,
copy-up, whiteout, rotazione e consolidamento, tutti provati senza `sudo`.

**La decisione.** Nessun helper privilegiato, nessuna unità systemd con
privilegi, nessun `sudo` chiesto all'utente. La via del kernel resta disponibile
dove root c'è, come ottimizzazione, dietro la stessa interfaccia.

Vale la pena notare l'ordine: **è stata la rinuncia alla deduplicazione a
regalare l'esecuzione non privilegiata.** Non era un obiettivo, è arrivata come
conseguenza.

---

## 8. Il perimetro si è svuotato

**Le regole di partenza.** Rifiutare hardlink, socket, fifo, device node; e, dopo
una misura, anche i file sparsi, che nello store venivano riespansi con
un'amplificazione di quattro ordini di grandezza.

**La misura sul formato.** Tutti quei divieti erano imposti dall'object store, non
da EROFS. Costruendo l'immagine direttamente: hardlink conservati con lo stesso
inode e `nlink` corretto, fifo, socket, symlink rotti, xattr utente e permessi
tutti preservati. E un file sparso da 64 MiB sta dentro un'immagine da 319 KiB,
perché la compressione riduce gli zeri a nulla.

**La decisione.** Il perimetro si riduce a due voci: processi attivi nella
cartella, e ownership che richiede privilegi. Tutto il resto si congela.

**La nota di metodo.** Il rifiuto degli hardlink era comunque giustificato quando
è stato scritto: nello store la struttura si perdeva **in silenzio**, con i due
nomi che tornavano come file indipendenti. Era una regola giusta per un
meccanismo che poi è stato abbandonato.

---

## 9. Errori di misura che hanno rischiato di sviare

Vale la pena tenerne memoria, perché ognuno ha prodotto per un po' una
conclusione sbagliata che sembrava solida.

**`du -sb` misura la dimensione apparente**, non l'occupazione: `-b` implica
`--apparent-size`. Con quello i file sparsi risultavano innocui. Serve
`du -s --block-size=1`.

**`du -s` con più argomenti stampa una riga per argomento.** Un `tail -1`
prendeva solo l'ultima, e per un giro intero il sorgente è risultato di 17 MiB
invece di 181, e una strategia ha riportato 4 KiB di occupazione.

**`printf '%.3f'` rifiuta il punto decimale sotto locale italiano.** Tutti i
tempi di un giro completo sono usciti come `0,000`. Serve `LC_NUMERIC=C`.

**Una funzione dentro `$(...)` o `< <(...)` gira in un subshell**, e ogni
variabile globale che tocca viene persa. È capitato due volte: la prima faceva
scambiare un messaggio d'errore per un percorso di mount, la seconda ha
cancellato tutte le misure di tempo.

**`mount -o loop` marca il device `AUTOCLEAR`**, che si stacca in modo asincrono
all'ultimo close. Il device successivo riprende lo stesso numero mentre la page
cache conserva ancora i blocchi del filesystem precedente, e il mount trova un
superblocco che non è il suo. Serve `losetup --find --show` più
`blockdev --flushbufs`.

**Un banco di prova su btrfs non dice cosa succede su ext4.** I file sparsi
risultavano preservati perché il reflink clona anche i buchi; su ext4, dove il
reflink non c'è, venivano riespansi. La conclusione era giusta per il testbed e
sbagliata per l'utente.

**Il conteggio dei file va in timeout in silenzio.** Un albero da 155.298 file è
stato misurato a 57.811 perché il `find` era sotto `timeout` e il troncamento non
produceva errore.

---

## Quel che resta aperto

- **Il linguaggio della CLI.** Python parte in 48 ms con gli import tipici,
  un binario compilato in 2–3 ms. In assoluto 48 ms su un comando lanciato a mano
  non si notano; diventano fastidiosi solo se `freeze list` finisce dentro un
  prompt di shell.
- **Il costo del `purge` su alberi molto grandi.** Misurato fino a 12.000 file e
  costante al 4% del primo freeze; da riverificare sulle centinaia di migliaia.
- **La taratura di `tc` e della soglia del 30%.** Nessun test la può dare: serve
  la crescita giornaliera del delta sull'uso reale.
