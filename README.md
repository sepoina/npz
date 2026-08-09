# npz

> node_modules without the node_modules

`npz` è un wrapper di `npm`. Gira ogni parametro a `npm` tale e quale, e si riserva
tre comportamenti propri: chiede una volta se congelare `node_modules`, lo congela
in una immagine [EROFS] compressa e lo monta al suo posto, e con `npz bye` rilascia
il mount.

La cartella di dipendenze smette di essere decine di migliaia di inode e diventa
**un file solo**, in sola lettura, con un delta scrivibile sopra. Sulla fixture di
riferimento: **31.667 voci e 588 MiB** diventano una immagine da **234 MiB**, in
1,74 secondi, e il montaggio costa 0,07 s.

La toolchain — `node`, `npx`, i bundler, il language server — continua a vedere
l'albero esattamente come prima. Gli attraversatori che sanno fermarsi a un confine
di filesystem (`du -x`, `find -xdev`, `rsync -x`, `tar --one-file-system`) smettono
di pagarlo, **senza sapere nulla di `npz`**: come mount point la cartella è *più*
escludibile di quanto fosse come directory.

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

## Requisiti

`mkfs.erofs`, `erofsfuse`, `fuse-overlayfs`, `fusermount3`, più `npm` e `node`.
Su Arch e Manjaro: `erofs-utils`, `erofsfuse`, `fuse-overlayfs`, `fuse3` —
`erofsfuse` è un pacchetto separato.

**Nessun privilegio**: lo stack si monta interamente in user space. La via del
kernel (`mount -t erofs` + `overlay`) è un'ottimizzazione per quando root c'è, non
un requisito.

Il progetto deve stare su un supporto su cui si possa scrivere, i cui file siano
dell'utente e che regga il bit di esecuzione — `npz` lo verifica prima di toccare
qualsiasi cosa, e quando rifiuta stampa la riga di `fstab` che lo rimedia.

## Come si costruisce

```bash
cd npz_go/build && ./build.sh        # npz per questa macchina, in build/lavoro/
./build.sh tutti                     # anche linux/amd64 e linux/arm64
```

Versione, descrizioni, manutentore, licenza e dipendenze stanno tutte in
[progetto.conf](progetto.conf) e **da nessun'altra parte**: chi rilascia tocca quel
file e nient'altro.

## La documentazione

Sta in **[doc/](doc/)**, e l'indice è **[doc/_index.md](doc/_index.md)**: i
documenti, la mappa del codice, i banchi e lo stato di avanzamento.

Chi ha fretta legga [il taccuino di viaggio](<doc/taccuino di viaggio.md>) — le
misure che hanno smontato una dopo l'altra le idee da cui il progetto era nato.

[EROFS]: https://docs.kernel.org/filesystems/erofs.html
