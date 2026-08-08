// Il montaggio e lo smontaggio, e l'automontaggio che ripara.

package facciata

import (
	"os"
	"path/filepath"
	"strings"

	"npz/internal/nucleo"
	"npz/internal/voce"
)

// Relativo: "node_modules", l'unico albero che npz gestisce.
const Relativo = Cartella

func Percorsi(radice string) nucleo.PercorsiImmagine {
	return nucleo.Percorsi(ProfiloDi(radice), radice, Relativo)
}

// Monta ricrea la cartella e ci sovrappone lo stack. Il contrario di Smonta.
func Monta(radice string) error {
	Sveglia(radice)
	l, err := nucleo.Lock(ProfiloDi(radice), radice)
	if err != nil {
		return err
	}
	defer l.Rilascia()
	backend, err := nucleo.Scegli("", radice)
	if err != nil {
		return err
	}
	return montaSenzaLock(Percorsi(radice), CartellaDi(radice), backend)
}

// montaSenzaLock e' il montaggio vero, **senza prendere il lock**: lo ha gia'
// preso chi chiama.
//
// Sta separato da Monta() per il consolidamento, che smonta e rimonta dentro un
// lock solo. Non e' una preferenza di stile: flock sta sulla descrizione del
// file aperto, quindi due aperture dello stesso lock nello stesso processo non
// si annidano — la seconda trova la prima e fallisce.
func montaSenzaLock(p nucleo.PercorsiImmagine, cartella string, backend nucleo.Backend) error {
	// Se qualcosa e' sopravvissuto a un ciclo precedente — un `bye` interrotto,
	// l'overlay caduto da solo, uno smontaggio riuscito a meta' — montarne un
	// altro sopra ne impila due sullo stesso punto, e da li' in poi ogni
	// smontaggio ne lascia indietro uno. Si toglie di mezzo prima, su entrambi.
	for nucleo.Montato(cartella) {
		if err := backend.Smonta(cartella, false); err != nil {
			return err
		}
	}
	for nucleo.Montato(p.Basso) {
		if err := backend.Smonta(p.Basso, false); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(cartella, 0o755); err != nil {
		return &nucleo.Errore{Messaggio: "can't create " + cartella + ": " + err.Error()}
	}
	// La sentinella vive sul filesystem sottostante: coperta dall'overlay
	// mentre il mount c'e', unica cosa presente quando e' caduto.
	_ = os.WriteFile(filepath.Join(cartella, PROFILO.Sentinella), []byte(
		"This folder's mount isn't active, but the data is safe in the\n"+
			"image inside .npz/. Run any npm command from here: npz will\n"+
			"remount it on its own.\n"), 0o644)

	if err := backend.MontaRO(p.Immagine, p.Basso); err != nil {
		return err
	}
	if err := backend.MontaStack(p.Basso, p.Delta, p.Lavoro, cartella); err != nil {
		_ = backend.Smonta(p.Basso, false)
		return err
	}
	return nil
}

// Smonta smonta e **rimuove la cartella**, che e' la differenza con `freeze`.
//
// Da smontati la cartella non deve esistere: se restasse li' vuota, un builder
// non direbbe "manca node_modules" ma `cannot find module 'react'`, che e' un
// errore molto peggiore da diagnosticare — e lo direbbe a strumenti che non
// passano da npz. Lo stato *assente* e' invece indistinguibile da "mai
// installato", l'unico errore che tutto l'ecosistema JavaScript sa raccontare.
func Smonta(radice string, forza bool) error {
	p := Percorsi(radice)
	cartella := CartellaDi(radice)
	backend, err := nucleo.Scegli("", radice)
	if err != nil {
		return err
	}

	attivi, err := nucleo.ProcessiAttivi(cartella)
	if err != nil {
		return err
	}
	if len(attivi) > 0 && !forza {
		return &nucleo.Errore{Messaggio: "there are processes using node_modules:\n  " +
			strings.Join(attivi, "\n  ") +
			"\nClose them and retry, or `npz bye --force` to unmount anyway."}
	}

	l, err := nucleo.Lock(ProfiloDi(radice), radice)
	if err != nil {
		return err
	}
	errSmonta := smontaSenzaLock(p, cartella, backend, forza)
	l.Rilascia()
	if errSmonta != nil {
		return errSmonta
	}
	// Fuori dal lock, e per ultima: da qui in poi la cartella e' ferma e lo dice.
	Addormenta(radice)
	return nil
}

// smontaSenzaLock e' lo smontaggio vero, senza lock e senza addormentare.
//
// `pigro` e' cio' che `--force` promette: senza di esso un mount tenuto da un
// watcher non si stacca, e la promessa resterebbe una parola (§10).
func smontaSenzaLock(p nucleo.PercorsiImmagine, cartella string,
	backend nucleo.Backend, pigro bool) error {
	// `for` e non `if`: se per qualsiasi ragione i mount si sono impilati, uno
	// solo non basta, e quel che resta e' invisibile finche' non si prova a
	// cancellare la cartella.
	for nucleo.Montato(cartella) {
		if err := backend.Smonta(cartella, pigro); err != nil {
			return err
		}
	}
	for nucleo.Montato(p.Basso) {
		if err := backend.Smonta(p.Basso, pigro); err != nil {
			return err
		}
	}
	_ = os.Remove(filepath.Join(cartella, PROFILO.Sentinella))
	if eDir(cartella) {
		if voci, err := os.ReadDir(cartella); err == nil && len(voci) == 0 {
			_ = os.Remove(cartella)
		}
	}
	return nil
}

// AssicuraMontato e' l'automontaggio: il segnale che il demone di `freeze` non
// ha mai avuto.
//
// Ogni comando npm passa da qui, quindi npz sa quando serve montato senza
// doverlo indovinare. Ripara anche lo stato *rotto*, che e' quel che resta dopo
// uno spegnimento o un OOM.
func AssicuraMontato(radice string, stato Stato) error {
	if stato == Montato {
		return nil
	}
	cartella := CartellaDi(radice)
	if stato == Scavalcato {
		// Due alberi, e montare coprirebbe quello dell'utente lasciandolo
		// invisibile a occupare disco. Si sceglie, e chi sceglie monta da se'.
		tornato, err := Conflitto(radice)
		if err != nil {
			return err
		}
		if !tornato {
			// Breve di proposito: chi arriva qui ha appena letto il quadro
			// intero, o la riga di avvisaScavalcato. Questa porta solo il codice
			// di uscita, che il comando non ha fatto quel che chiedeva.
			return &nucleo.Errore{Messaggio: "nothing mounted: node_modules is still " +
				"the folder npm built."}
		}
		return nil
	}
	if stato == Rotto {
		// Adesso *rotto* vuol dire esattamente questo — il nostro mountpoint
		// scoperto, con dentro solo la sentinella — perche' a distinguerlo da
		// *scavalcato* ci pensa StatoDi(). Si rimonta in silenzio.
		_ = os.Remove(filepath.Join(cartella, PROFILO.Sentinella))
		_ = os.Remove(cartella)
	}
	return Monta(radice)
}

// AvvisaDelta e' la soglia di §9, tarata su N2: si guarda il delta, non il
// comando.
//
// Si guarda pero' solo il delta *consolidabile*: proporre un consolidamento per
// una cache di build sarebbe proporre un lavoro che non la toglierebbe di li',
// e lo si riproporrebbe identico subito dopo.
func AvvisaDelta(radice string) {
	p := Percorsi(radice)
	if !esiste(p.Meta) {
		return
	}
	voci := Quante(p.Delta, Escluse[:]...)
	if voci == 0 {
		return // N2: capita spesso
	}
	meta, err := nucleo.LeggiMeta(p.Meta)
	if err != nil {
		return
	}
	totali := interoDa(meta["file"])
	if totali < 1 {
		totali = 1
	}
	if voci*100/totali >= 10 {
		voce.Dici("the delta is at %d%% of the image's entries (%d); "+
			"a `npz compact` is worth it.", voci*100/totali, voci)
	}
}

// interoDa estrae un intero da un valore JSON, che arriva sempre come float64.
func interoDa(v any) int {
	if f, ok := v.(float64); ok {
		return int(f)
	}
	return 0
}
