// Il governo del percorso lento: quando c'e' davvero qualcosa da fare.
//
// Qui si sta per pagare un mount o un mkfs.erofs: i millisecondi non contano
// piu'. Valgono invece le tre invarianti del nucleo — un solo lock, formato
// versionato, **costruisci prima di cancellare**.

package facciata

import (
	"errors"
	"os"

	"npz/internal/nucleo"
	"npz/internal/voce"
)

// Governa e' l'ingresso del percorso lento. Trasforma un *Errore in una riga e
// un codice di uscita; qualunque altro errore e' un difetto di npz e si mostra
// per intero.
func Governa(argv []string, radice string, stato Stato) int {
	err := governa(argv, radice, stato)
	if err == nil {
		return 0
	}
	var uscita *uscitaCon
	if errors.As(err, &uscita) {
		return uscita.codice
	}
	var previsto *nucleo.Errore
	if errors.As(err, &previsto) {
		voce.Sbaglia("%s", previsto.Messaggio)
		return 1
	}
	voce.Sbaglia("npz: %v", err)
	return 1
}

// uscitaCon porta un codice di uscita che non e' un errore: il codice di npm,
// che va restituito com'e'.
type uscitaCon struct{ codice int }

func (u *uscitaCon) Error() string { return "uscita" }

func governa(argv []string, radice string, stato Stato) error {
	classe := Classifica(argv)
	comando, _ := Separa(argv)

	// La raccolta dei residui sta in cima al percorso lento: il giro che crea
	// una copia da parte non la vede — non esisteva ancora — quindi la domanda
	// arriva dal giro dopo, che e' il punto in cui l'utente ha gia' avuto una
	// sessione per accorgersi di aver scelto male. Non davanti a `status`, che
	// e' il comando che si batte *per guardare*, e che le elenca da se'.
	if radice != "" && comando != "status" {
		Raccogli(radice)
	}

	if classe == Nostro {
		if radice != "" {
			stato = StatoDi(radice)
		}
		switch comando {
		case "status":
			return &uscitaCon{CmdStatus(radice, stato)}
		case "attach":
			return CmdAttach(radice, stato)
		case "detach":
			return CmdDetach(radice, stato, argv)
		case "hey":
			return CmdHey(radice, stato)
		case "bye":
			return CmdBye(radice, argv)
		case "compact":
			return CmdCompact(radice, stato, argv)
		default:
			return &nucleo.Errore{Messaggio: "`npz " + comando +
				"` isn't implemented yet in this phase."}
		}
	}

	npm := TrovaNpm(IoStesso())
	if npm == "" {
		return &uscitaCon{MancaNpm()}
	}

	if stato == Scavalcato {
		// npz **non si mette in mezzo**: l'albero e' reale e completo, e npm ci
		// lavora meglio di quanto npz possa fare adesso. Bloccare qui
		// significherebbe far fallire anche un `npz ls`, cioe' rendere npz un
		// ostacolo davanti a comandi che npm esegue benissimo.
		//
		// I neutri se ne vanno subito, con una riga; dopo un mutante riuscito si
		// propone di scegliere, e li' un codice di uscita di npm c'e' — che e'
		// esattamente cio' che manca a npz per fidarsi di un albero (§8).
		if classe == Neutro {
			avvisaScavalcato()
			Consegna(npm, argv) // non torna
		}
		esito := Accompagna(npm, argv)
		if esito == 0 {
			if _, err := Conflitto(radice); err != nil {
				return err
			}
		}
		return &uscitaCon{esito}
	}

	// Il progetto e' candidato: si chiede, una volta sola, e *prima* che npm
	// parta. Quando si agisce dipende invece da che comando e': subito se e'
	// neutro, alla fine se puo' toccare l'albero. Vedi AttaccaSubito().
	congelareDopo := false
	daParte := ""

	switch {
	case stato == Candidato:
		// L'idoneita' del filesystem si controlla PRIMA di chiedere. Chiederlo
		// dopo significherebbe far dire di si' all'utente, fargli aspettare npm,
		// e solo allora dirgli che qui non si puo' fare: una domanda che non si
		// e' in grado di onorare non va posta.
		if err := VerificaIdoneita(radice); err != nil {
			var previsto *nucleo.Errore
			if errors.As(err, &previsto) {
				voce.Dici("%s", primaRiga(previsto.Messaggio))
			}
			SegnaRifiuto(radice)
			Consegna(npm, argv) // non torna
		}
		if !Proponi(radice) {
			Consegna(npm, argv) // non torna
		}
		if classe == Neutro {
			// Il si' si onora adesso, e poi npz sparisce dentro npm.
			if !AttaccaSubito(radice) {
				return &uscitaCon{1}
			}
			Consegna(npm, argv) // non torna
		}
		congelareDopo = true

	case classe == Distruttivo:
		// `npm ci` cancella node_modules: sull'overlay sono 35.000 whiteout e
		// poi l'albero intero riestratto nel delta. Misurato in fase 0: 3,0–3,5x
		// piu' lento, e 821 MiB contro i 588 del nativo. Si porta sull'albero
		// nudo.
		if stato == Montato || stato == Rotto || stato == Congelato {
			voce.Dici("`npm %s` rebuilds node_modules from scratch: running it "+
				"on the bare tree, then re-attaching.", comando)
			var err error
			if daParte, err = MettiDaParte(radice); err != nil {
				return err
			}
			congelareDopo = true
		}

	case stato == Congelato || stato == Rotto:
		if err := AssicuraMontato(radice, stato); err != nil {
			return err
		}
	}

	esito := Accompagna(npm, argv)

	if !congelareDopo {
		if (classe == Mutante || classe == Distruttivo) && radice != "" {
			AvvisaDelta(radice)
		}
		return &uscitaCon{esito}
	}

	albero := eDir(CartellaDi(radice))

	if esito != 0 {
		// npm ha fallito per ragioni sue, e qui il comando era di quelli che
		// l'albero lo compongono: cio' che sta in node_modules non e' l'albero
		// che l'utente voleva, ma uno a meta'. Non si congela — e lo si
		// **dice**, perche' un si' che non produce niente e non spiega perche' e'
		// peggio di un no. (Per i neutri non si arriva mai qui: hanno gia'
		// attaccato prima, e il loro codice di uscita dell'albero non dice nulla.)
		if daParte != "" {
			voce.Dici("`npm %s` failed (exit code %d): restoring the previous image.",
				comando, esito)
			if err := Riprendi(radice, daParte); err != nil {
				return err
			}
		} else {
			voce.Dici("`npm %s` failed (exit code %d): npz isn't touching "+
				"node_modules. Run `npz attach` when it's settled.", comando, esito)
		}
		return &uscitaCon{esito}
	}

	if !albero {
		// npm e' riuscito e non ha prodotto node_modules: il progetto non ha
		// dipendenze. Rimettere l'immagine vecchia resusciterebbe un albero che
		// npm ha appena deciso non dover esistere — npz si fa da parte.
		if daParte != "" {
			_ = os.Remove(daParte)
			voce.Dici("no dependencies to manage: npz steps aside.")
		}
		return &uscitaCon{esito}
	}

	if err := ripiegaSuErrore(radice, daParte, func() error {
		if err := VerificaIdoneita(radice); err != nil {
			return err
		}
		if err := Congela(radice); err != nil {
			return err
		}
		return Monta(radice)
	}); err != nil {
		return err
	}
	if daParte != "" {
		_ = os.Remove(daParte) // solo ora la vecchia si butta
	}
	return &uscitaCon{esito}
}

// ripiegaSuErrore esegue il lavoro e, se fallisce con una copia messa da parte,
// la rimette al suo posto prima di propagare.
func ripiegaSuErrore(radice, daParte string, lavoro func() error) error {
	err := lavoro()
	if err == nil {
		return nil
	}
	var previsto *nucleo.Errore
	if errors.As(err, &previsto) && daParte != "" {
		voce.Dici("attaching failed: restoring the previous image.")
		_ = Riprendi(radice, daParte)
	}
	return err
}

func primaRiga(testo string) string {
	for i := 0; i < len(testo); i++ {
		if testo[i] == '\n' {
			return testo[:i]
		}
	}
	return testo
}

// AttaccaSubito onora adesso il si' dell'utente, prima di consegnare a npm.
//
// Vale per i **neutri**, che l'albero non lo toccano: congelare prima non
// duplica niente — il delta nasce vuoto e resta vuoto — e il comando parte gia'
// sul montato, cioe' nella configurazione in cui vivra' da li' in avanti.
//
// Aspettare la fine e' invece giusto per i **mutanti**, ed e' quello che il §8
// prescrive: li' l'albero lo sta componendo npm, e congelarlo prima vorrebbe
// dire far scrivere l'installazione dentro il delta appena creato. Applicata
// anche ai neutri, la stessa regola diventa un difetto — e uno grave, perche'
// silenzioso: `npm run dev` dura ore, la conseguenza del si' arriverebbe al
// ctrl-c, e un comando interrotto esce con un codice diverso da zero che di
// quell'albero non dice niente.
//
// Una domanda che ferma chi lavora deve avere una conseguenza che si vede
// subito. Se la conseguenza non arriva, il si' non era una domanda: era un
// disturbo.
//
// Restituisce se il comando dell'utente puo' partire.
func AttaccaSubito(radice string) bool {
	if err := Congela(radice); err != nil {
		// L'invariante tiene: se il congelamento fallisce, node_modules non e'
		// stata toccata. Il comando dell'utente non e' ostaggio del nostro
		// lavoro, quindi si spiega e si tira dritto.
		voce.Sbaglia("%v", err)
		voce.Dici("npz isn't attaching now; running your command as usual.")
		return true
	}
	if err := Monta(radice); err != nil {
		// Qui invece l'albero e' dentro l'immagine e la cartella non c'e': far
		// partire adesso un build che non trovera' node_modules produrrebbe un
		// errore peggiore da leggere del nostro. Ci si ferma e si dice dov'e'
		// finita la roba.
		voce.Sbaglia("%v", err)
		voce.Dici("your files are safe inside the image, but mounting it failed, " +
			"so node_modules isn't there right now.\nRun `npz hey` to retry, or " +
			"`npz detach` to get the plain folder back.")
		return false
	}
	return true
}

// MettiDaParte smonta e sposta l'immagine di lato. **Non la cancella.**
//
// E' l'invariante del progetto applicata al caso di `npm ci`: si costruisce
// prima di cancellare. Cancellare qui significherebbe distruggere lo stato
// congelato *prima* di sapere se npm riuscira' — e npm fallisce per ragioni
// ordinarie, un lockfile che manca o la rete che non c'e'. L'immagine vecchia si
// butta solo quando la nuova esiste ed e' stata verificata.
func MettiDaParte(radice string) (string, error) {
	p := Percorsi(radice)
	// Senza condizioni: lo strato inferiore puo' essere montato anche quando
	// l'overlay sopra non lo e', e saltare lo smontaggio lo lascerebbe li'.
	if err := Smonta(radice, true); err != nil {
		return "", err
	}
	if !esiste(p.Immagine) {
		return "", nil
	}
	daParte := p.Immagine + ".aside"
	l, err := nucleo.Lock(ProfiloDi(radice), radice)
	if err != nil {
		return "", err
	}
	defer l.Rilascia()
	_ = os.Remove(daParte)
	if err := os.Rename(p.Immagine, daParte); err != nil {
		return "", &nucleo.Errore{Messaggio: "can't set the image aside: " + err.Error()}
	}
	_ = os.Remove(p.Meta)
	_ = os.RemoveAll(p.Delta)
	_ = os.RemoveAll(p.Lavoro)
	if err := os.MkdirAll(p.Delta, 0o755); err != nil {
		return "", &nucleo.Errore{Messaggio: "can't recreate the delta: " + err.Error()}
	}
	return daParte, nil
}

// Riprendi rimette al suo posto l'immagine messa da parte, e rimonta.
//
// Quel che npm ha lasciato a meta' nella cartella e' spazzatura derivabile e va
// tolta: se restasse, il mount la coprirebbe e resterebbe li' invisibile a
// occupare spazio.
func Riprendi(radice, daParte string) error {
	p := Percorsi(radice)
	cartella := CartellaDi(radice)
	if eDir(cartella) {
		_ = os.RemoveAll(cartella)
	}
	if err := os.Rename(daParte, p.Immagine); err != nil {
		return &nucleo.Errore{Messaggio: "can't restore the image: " + err.Error()}
	}
	return Monta(radice)
}
