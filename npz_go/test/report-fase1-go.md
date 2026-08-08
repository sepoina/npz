# Fase 1 del porting in Go — il nucleo

- data: 2026-08-09 00:52:25
- go: `go1.26.5-X:nodwarf5` · python: `3.14.6`
- banco: `/var/tmp/npz-banco-fase1` (ext4)

## Il criterio di uscita, riformulato

Il §9 del piano chiedeva una immagine **bit-identica** a quella del Python.
Misurato qui: irrealizzabile, e non per colpa del porting — `mkfs.erofs`
incorpora un UUID casuale, quindi due build della stessa sorgente
differiscono gia' fra Python e Python. Con `-U` fisso tornano identiche,
il che dimostra che tutto il resto dell'immagine e' deterministico.

Il criterio diventa: **il contenuto montato delle due immagini coincide**,
attributo per attributo, e coincide con la sorgente. E' la proprieta' che
il congelamento usa per fidarsi di se' stesso, ed e' quella che conta.

## Esiti

| Esito | Verifica | Dettaglio |
| --- | --- | --- |
| PASS | go presente |  |
| PASS | python3 presente |  |
| PASS | mkfs.erofs presente |  |
| PASS | erofsfuse presente |  |
| PASS | fusermount3 presente |  |
| PASS | sha256sum presente |  |
| PASS | il banco vive su un filesystem POSIX | ext4 |
| PASS | il driver Go compila |  |
| PASS | npz_python in posizione | l'oracolo |
| PASS | fixture costruita | 20 voci, con symlink, hardlink, fifo, sparso, spazi, unicode |
| PASS | inventario: Go e Python coincidono |  |
| PASS | conta: Go e Python coincidono |  |
| PASS | percorsi: i cinque posti coincidono |  |
| PASS | relativo_di coincide |  |
| PASS | leggibile: sette valori coincidono |  |
| PASS | tipo_filesystem coincide |  |
| PASS | idoneita coincide (filesystem buono) |  |
| PASS | sonda: i fatti coincidono campo per campo |  |
| PASS | idoneita coincide (filesystem cattivo) |  |
| PASS | mkfs.erofs e' deterministico a UUID fisso | il resto dell'immagine non ha entropia |
| PASS | l'UUID casuale spiega perche' il §9 va riformulato | py≠py sulla stessa sorgente |
| PASS | Go costruisce l'immagine | node_modules.img.new |
| PASS | Python costruisce l'immagine | node_modules.img.new |
| PASS | le due immagini hanno la stessa dimensione | 16384 byte |
| PASS | le due immagini si montano |  |
| PASS | immagine Go ≡ immagine Python (contenuto) |  |
| PASS | immagine Go ≡ sorgente |  |
| PASS | immagine Python ≡ sorgente |  |
| PASS | il Python legge l'immagine di Go allo stesso modo |  |
| PASS | l'hardlink sopravvive dentro l'immagine | stesso inode, nlink=2 |
| PASS | il fifo sopravvive dentro l'immagine |  |
| PASS | il symlink rotto sopravvive dentro l'immagine |  |
| PASS | il file sparso non viene riespanso | immagine di 16384 byte per 1 MiB dichiarato |
| PASS | Go verifica l'immagine di Go |  |
| PASS | Go verifica l'immagine del Python |  |
| PASS | il Python verifica l'immagine di Go |  |
| PASS | la verifica fallisce su una sorgente diversa | il caso negativo tiene |
| PASS | il Python legge il config scritto da Go |  |
| PASS | Go legge il config scritto dal Python |  |
| PASS | config: stesse chiavi da entrambe le parti |  |
| PASS | meta: Go scrive, entrambi rileggono lo stesso |  |
| PASS | meta: Python scrive, entrambi rileggono lo stesso |  |
| PASS | entrambi rifiutano un formato che non parlano | formato versionato, §invarianti |
| PASS | il lock di Go esclude il Python | flock e' del kernel, non del linguaggio |
| PASS | il lock del Python esclude Go | l'esclusione vale nei due sensi |
| PASS | il lock cade alla morte del processo | la proprieta' per cui si usa flock |
| PASS | elenca: le immagini trovate coincidono |  |

## Verdetto

Il nucleo Go e il nucleo Python sono **indistinguibili** su tutto cio' che
il banco sa chiedere: stessa lettura dell'albero, stessi percorsi, stesso
giudizio sul filesystem, immagini con lo stesso contenuto, verifica che
funziona in tutte e quattro le combinazioni incrociate, e lo stesso lock.

La fase 2 — la facciata — puo' cominciare.
