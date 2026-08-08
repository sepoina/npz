# Fase 0 di npz — esiti

- data: 2026-08-02 10:53:27
- kernel: `6.12.96-1-MANJARO`
- npm: `11.16.0` · node: `v24.18.0`
- banco: `/var/tmp/npz-banco` (ext4)
- scenari: check fixture n1 n2 n3 n4 n6 n7

## Esiti

| Esito | Scenario | Verifica | Dettaglio |
| --- | --- | --- | --- |
| PASS | CHECK | mkfs.erofs presente |  |
| PASS | CHECK | erofsfuse presente |  |
| PASS | CHECK | fuse-overlayfs presente |  |
| PASS | CHECK | fusermount3 presente |  |
| PASS | CHECK | npm presente |  |
| PASS | CHECK | node presente |  |
| PASS | CHECK | bc presente |  |
| PASS | CHECK | numfmt presente |  |
| PASS | CHECK | findmnt presente |  |
| PASS | CHECK | mountpoint presente |  |
| PASS | CHECK | il banco vive su un filesystem POSIX | ext4 |
| PASS | CHECK | i permessi POSIX si conservano |  |
| PASS | CHECK | spazio sufficiente | 37 GiB liberi |
| PASS | CHECK | registry npm raggiungibile |  |
| PASS | FIXTURE | fixture costruita |  |
| PASS | N1 | install idempotente entro 2× | 1.72× |
| PASS | N1 | npm ci peggiora il bilancio: va intercettato | 821MiB contro 588MiB del nativo |
| PASS | N2 | dieci install restano sotto il 30% | 7.0% — la soglia va abbassata o affiancata |
| PASS | N3 | resolve storm entro 2× | 1.45× |
| PASS | N3 | tsc entro 2× | 1.12× |
| PASS | N3 | vite build entro 2× | 1.16× |
| PASS | N4 | la vista fusa coincide con quella pre-consolidamento |  |
| PASS | N4 | l'albero e' identico dopo il consolidamento |  |
| PASS | N4 | il delta e' stato assorbito |  |
| SKIP | N4 | quale delle due vie convenga | il vincitore cambia con l'ordine: e' page cache, non metodo. Serve drop_caches (root) |
| PASS | N6 | il wrapper resta sotto il 25% di npm anche sotto carico | 11.8% |
| PASS | N7 | gli eventi di fs.watch attraversano l'overlay |  |
| SKIP | N7 | inotifywait | inotify-tools non installato |

## Misure

| Scenario | Metrica | Valore |
| --- | --- | --- |
| CHECK | npm | 11.16.0 |
| CHECK | node | v24.18.0 |
| CHECK | kernel | 6.12.96-1-MANJARO |
| CHECK | banco | /var/tmp/npz-banco (ext4) |
| FIXTURE | fixture: voci (file + directory) | 31667 |
| FIXTURE | fixture: occupazione su disco | 588MiB |
| N1 | install idempotente: nativo | 1.27 s |
| N1 | install idempotente: sullo stack | 2.19 s |
| N1 | install idempotente: rapporto | 1.72× |
| N1 | install idempotente: delta prodotto | 460KiB in 1 voci |
| N1 | npm ci: nativo | 9.12 s |
| N1 | npm ci: sullo stack | 32.62 s |
| N1 | npm ci: rapporto | 3.57× |
| N1 | npm ci: delta prodotto | 588MiB in 35222 voci |
| N1 | npm ci: immagine + delta contro albero nativo | 821MiB contro 588MiB |
| N2 | delta dopo 10 install | 17MiB in 2970 voci |
| N2 | immagine | 234MiB |
| N2 | delta / immagine | 7.0% |
| N2 | crescita media per install | 1.7MiB |
| N3 | campione della resolve storm | 3000 file |
| N3 | resolve storm: nativo | 4.47 s |
| N3 | resolve storm: sullo stack | 6.51 s |
| N3 | resolve storm: rapporto | 1.45× |
| N3 | tsc --noEmit: nativo / stack | 1.13 s / 1.27 s |
| N3 | tsc --noEmit: rapporto | 1.12× |
| N3 | vite build: nativo / stack | .89 s / 1.04 s |
| N3 | vite build: rapporto | 1.16× |
| N3 | vite build: delta lasciato | 4.0KiB in 0 voci |
| N4 | delta da assorbire | 14MiB in 2371 voci |
| N4 | consolidamento completo (smonta→ricostruisci→rimonta) | 15.15 s |
| N4 | immagine dopo il consolidamento | 237MiB |
| N4 | delta dopo il consolidamento | 4.0KiB |
| N4 | delta del confronto | 464KiB in 1 voci |
| N4 | vista fusa: prima / seconda a girare | 15.38 s / 7.29 s |
| N4 | staging su ext4: seconda / prima a girare | 13.96 s / 11.93 s |
| N6 | percorso veloce, a riposo | 12.4 ms |
| N6 | npm run <vuoto>, a riposo | 121.4 ms |
| N6 | sovraccarico, a riposo | 10.2% |
| N6 | percorso veloce, sotto carico | 15.4 ms |
| N6 | npm run <vuoto>, sotto carico | 130.1 ms |
| N6 | sovraccarico, sotto carico | 11.8% |
| N7 | fs.watch: nativo | SI |
| N7 | fs.watch: sullo stack | SI |
