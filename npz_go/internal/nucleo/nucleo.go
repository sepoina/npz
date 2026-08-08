// Package nucleo e' il nucleo condiviso: congelare una cartella in una immagine
// EROFS compressa.
//
// Qui sta il *meccanismo* — costruire l'immagine, montarla, tenere lo stato,
// dire che cosa si puo' congelare — e non la *politica*, che appartiene alla
// facciata. Il nucleo non sa se sta servendo `npz` o altro, e non deve saperlo:
// sa leggere un Profilo.
//
// Il disegno sta in doc/claim.md, le misure che l'hanno prodotto in
// "doc/taccuino di viaggio.md". Le tre invarianti che vincolano ogni operazione
// che scrive — un solo lock, formato versionato, costruisci prima di cancellare
// — sono implementate qui dentro fin dalla prima riga: aggiungerle dopo costa
// molto.
//
// Porting dal Python di `npz_python/lib/`, a **formato fermo**: FORMATO non si
// muove, e un binario Go deve leggere gli store scritti dal Python e viceversa.
// E' cio' che rende possibile l'oracolo differenziale del §7 del piano.
package nucleo

import "fmt"

// Versione del nucleo, scritta a tempo di collegamento come quella della
// facciata: `build.sh` marchia entrambe da `progetto.conf`.
//
// Sono due simboli e non uno perche' il Python da cui questo nasce ne aveva
// due — `lib.VERSIONE` e `npz.VERSIONE` — e il porting non rinegozia il
// disegno. Ma la fonte e' una sola, quindi non possono divergere.
//
// Questa finisce nel campo `creata_da` del config, cioe' resta scritta su
// disco: e' la versione che ha prodotto quello store.
var Versione = "sviluppo"

// Formato e' la versione del formato su disco. Cambia solo quando cambia la
// struttura della cartella di servizio o dei .meta, non a ogni rilascio: e'
// cio' che permettera' di leggere store creati da versioni precedenti invece di
// dichiararli illeggibili.
//
// Il porting in Go **non lo tocca**. Lo tocchera' la fase 2 del progetto, che
// per questo non si fa insieme al porting.
const Formato = 1

// Compressione: lz4hc perche' misurato piu' veloce del non compresso e il 40%
// piu' piccolo — comprimere significa leggere meno byte, e lz4 decomprime piu'
// in fretta di quanto il supporto consegni.
const Compressione = "lz4hc"

// Errore e' un errore previsto, da mostrare all'utente senza traceback.
//
// E' il `class Errore(Exception)` del Python. In cima al percorso lento si
// distingue con errors.As: un *Errore si stampa e basta, qualunque altro errore
// e' un difetto di npz e va mostrato per intero.
type Errore struct {
	Messaggio string
}

func (e *Errore) Error() string { return e.Messaggio }

// errf costruisce un *Errore con la stessa comodita' di fmt.Errorf.
func errf(formato string, argomenti ...any) *Errore {
	return &Errore{Messaggio: fmt.Sprintf(formato, argomenti...)}
}

// Profilo dice come si chiamano le cose su disco. E' l'unica differenza fra le
// facciate.
//
// Il nucleo non sa se sta servendo `freeze` o `npz`, e non deve saperlo: sa
// leggere questo. Finche' i nomi erano costanti di modulo, il nucleo era
// condiviso nella struttura ma non nel comportamento.
type Profilo struct {
	// Servizio e' il nome della cartella di servizio nella radice di lavoro.
	Servizio string
	// Sentinella e' il file nascosto dentro il mountpoint, sul filesystem
	// sottostante: invisibile quando il mount c'e', unica cosa presente quando
	// e' caduto.
	Sentinella string
}

func (p Profilo) String() string { return "Profilo(" + p.Servizio + ")" }
