# Fase 2 del porting in Go — la facciata

- data: 2026-08-09 00:52:28
- go: `go1.26.5-X:nodwarf5` · python: `3.14.6`
- banco: `/var/tmp/npz-banco-fase2`

Sono i quattro test del §13 del piano — mai scritti in Python, e il
porting e' l'occasione di scriverli una volta sola — piu' l'oracolo
del §7, che alla fase 2 e' ancora acceso.

## Esiti

| Esito | Verifica | Dettaglio |
| --- | --- | --- |
| PASS | npz e il driver compilano | 2,6MiB |
| PASS | npz_python in posizione | l'oracolo della fase 1, ancora acceso |
| PASS | attach riesce |  |
| PASS | l'albero montato coincide con l'originale |  |
| PASS | compact riesce |  |
| PASS | il consolidamento non cambia la vista |  |
| PASS | detach riesce |  |
| PASS | l'albero finale coincide con quello montato |  |
| PASS | di npz non resta niente |  |
| PASS | node_modules e' una cartella vera |  |
| PASS | compact converge sopra i residui di un giro interrotto |  |
| PASS | il rilancio dopo un SIGKILL riporta lo stesso albero |  |
| PASS | e lo stato torna 'mounted' |  |
| PASS | il comando passa a npm |  |
| PASS | in CI npz non congela niente di sua iniziativa |  |
| PASS | e non registra nemmeno un rifiuto |  |
| PASS | il codice di uscita di npm arriva intatto | 17 |
| PASS | in CI un progetto attaccato si rimonta da solo |  |
| PASS | node risolve un modulo dall'albero montato |  |
| PASS | un binario in node_modules/.bin si esegue |  |
| PASS | il mount e' un confine di filesystem | 5 file dentro, 0 visti da find -xdev |
| PASS | il Python attacca |  |
| PASS | Go legge lo stato scritto dal Python |  |
| PASS | Go smonta e rimonta l'immagine del Python |  |
| PASS | Go consolida l'immagine del Python |  |
| PASS | Go stacca il progetto del Python |  |
| PASS | Go attacca |  |
| PASS | il Python legge lo stato scritto da Go |  |
| PASS | il Python smonta e rimonta l'immagine di Go |  |
| PASS | il Python consolida l'immagine di Go |  |
| PASS | il Python stacca il progetto di Go |  |
| PASS | stato candidate: Go ≡ Python |  |
| PASS | stato mounted: Go ≡ Python |  |
| PASS | stato attached: Go ≡ Python |  |
| PASS | stato bypassed: Go ≡ Python |  |
| PASS | lo scavalcamento si riconosce |  |
| PASS | senza TTY npz non si mette in mezzo | l'albero di npm resta |
| PASS | stato broken: Go ≡ Python |  |
| PASS | il mount caduto si riconosce |  |
| PASS | e si ripara da solo |  |
| PASS | il comando `npm ci` passa |  |
| PASS | dopo `npm ci` il progetto torna montato |  |
| PASS | l'albero ricostruito e' equivalente all'originale |  |
| PASS | l'immagine messa da parte e' stata tolta |  |

## Verdetto

La facciata Go regge il giro completo, converge dopo un'uccisione, tace
in CI, non si fa notare dagli script di package.json, e si scambia i
progetti col Python in tutte e due le direzioni.

La fase 3 — una settimana d'uso, poi il taglio — puo' cominciare.
