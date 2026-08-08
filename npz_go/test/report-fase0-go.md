# Fase 0 del porting in Go — esiti

- data: 2026-08-08 22:51:54
- kernel: `6.12.101-1-MANJARO`
- go: `go1.26.5-X:nodwarf5` · npm: `11.16.0` · python: `3.14.6`
- banco: `/var/tmp/npz-banco-go` (ext4)

## Esiti

| Esito | Verifica | Dettaglio |
| --- | --- | --- |
| PASS | go presente |  |
| PASS | python3 presente |  |
| PASS | npm presente |  |
| PASS | mkfs.erofs presente |  |
| PASS | erofsfuse presente |  |
| PASS | fusermount3 presente |  |
| PASS | bc presente |  |
| PASS | numfmt presente |  |
| PASS | il banco vive su un filesystem POSIX | ext4 |
| PASS | il binario Go compila |  |
| PASS | il binario sta sotto i 5 MB | 1,7MiB |
| PASS | il binario e' statico: nessuna dipendenza da glibc |  |
| PASS | npz_python copiato sul banco | confronto fra pari |
| PASS | immagine EROFS costruita | lz4hc |
| PASS | immagine montata con erofsfuse (senza privilegi) |  |
| PASS | npm finto in posizione | misura il wrapper, non npm |
| PASS | stato: mounted |  |
| PASS | stato: outside |  |
| PASS | stato: fresh |  |
| PASS | stato: candidate |  |
| PASS | stato: declined |  |
| PASS | stato: attached |  |
| PASS | stato: broken |  |
| PASS | stato: bypassed |  |
| PASS | Go e Python concordano sullo stato |  |
| PASS | il codice di uscita passa | 42 |
| PASS | la morte per segnale passa | 143 = 128+SIGTERM |
| PASS | il TTY passa a npm |  |
| PASS | la coda della voce esce prima di Exec | §6.1 |
| PASS | il percorso veloce sta sotto i 3 ms | 2.73 ms |

## Misure

| Metrica | Valore |
| --- | --- |
| binario Go (CGO_ENABLED=0, -s -w) | 1,7MiB |
| npm run <vuoto>, a riposo | 125.84 ms |
| pavimento (/bin/true nudo) | .99 ms |
| simulazione N6 (Python, 3 stat + execvp) | 13.59 ms |
| lanciatore.py reale (Python) | 13.91 ms |
| spike Go | 2.73 ms |
| costo proprio di npz: Python | 12.92 ms |
| costo proprio di npz: Go | 1.74 ms |
| sovraccarico Python su npm | 11.0% |
| sovraccarico Go su npm | 2.1% |
| Go contro lanciatore.py | 5.0× piu' veloce |
| spike Go, sotto carico | 3.32 ms |
| npm run <vuoto>, sotto carico | 144.37 ms |
| sovraccarico Go, sotto carico | 2.2% |

Riferimento storico, da `report-fase0.md`: percorso veloce 12,4 ms,
`npm run` a vuoto 121,4 ms, sovraccarico 10,2%.

## Quel che resta da verificare

- **il binario gira su una glibc vecchia.** Non verificato: su questa
  macchina non c'è né podman né docker. Il meccanismo che lo rende vero
  è provato — `file` dice `statically linked` e il binario non ha
  interprete dinamico — ma la prova diretta su Debian 12 (glibc 2.36)
  manca, e va rifatta prima di pubblicare qualsiasi pacchetto.

## Verdetto

Criterio di uscita **superato**. Le tre domande del §8 hanno risposta:
il percorso veloce sta sotto la soglia, `syscall.Exec` è trasparente su
codice di uscita, segnali e TTY, e la coda della voce esce prima di
`Exec` senza affidarsi a un `defer` che non verrebbe eseguito.

La fase 1 — il nucleo — può cominciare.
