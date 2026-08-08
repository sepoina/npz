// Il consolidamento — §9 del piano.
//
// E' il `consolida()` di `freeze` **meno la rotazione del delta**, e la
// differenza non e' una semplificazione ma una conseguenza: `freeze` consolida
// sotto un mount vivo, e deve tenere il delta ruotato come strato inferiore
// perche' nessuno perda cio' che scrive durante la costruzione. Qui la cartella
// non esiste dal momento in cui si smonta a quello in cui si rimonta — §6, da
// non montati la cartella non deve esistere — quindi non c'e' nessuno che
// scrive, e non c'e' finestra da chiudere.
//
// Il prezzo e' l'indisponibilita' dell'albero per la durata: N4 l'ha misurata
// in 12–15 s su un node_modules vero, ed e' la voce di costo piu' alta di tutto
// il progetto. Da cui il fatto che sia un comando esplicito e non un
// automatismo: arriva quando l'utente ha deciso di pagarla.

package facciata

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"npz/internal/nucleo"
	"npz/internal/voce"
)

// Escluse: cio' che nell'immagine non deve entrare (§9). Sono cache di build:
// si rigenerano, cambiano a ogni comando, e comprimerle dentro un'immagine e'
// lavoro sprecato che diventa peso permanente — si ricomprimerebbero a ogni
// consolidamento per essere invalidate subito dopo. Restano dove sono, nel
// delta, che e' esattamente il posto per cio' che cambia.
//
// **Escluse dall'immagine non vuol dire perse.** Se una di queste cartelle sta
// gia' dentro l'immagine — perche' c'era quando si e' fatto attach — il
// consolidamento la sposta nel delta invece di lasciarla cadere: la vista fusa
// dopo deve essere identica a quella di prima, ed e' la verifica stessa del
// consolidamento a esigerlo. Costa una copia, una volta sola.
var Escluse = [...]string{".cache", ".vite"}

// EsigiLibera: il consolidamento porta via l'albero, quindi prima ci si
// assicura che non serva.
//
// E' il rifiuto di §10, che per npz e' la norma e non l'eccezione — in un
// ambiente di sviluppo c'e' sempre un language server o un watcher dentro
// node_modules. Si elencano i colpevoli per nome, che e' l'uscita preferita del
// piano, e si lascia `--force` a chi sa cosa sta facendo.
func EsigiLibera(cartella string, forza bool, uscita string) error {
	attivi, err := nucleo.ProcessiAttivi(cartella)
	if err != nil {
		return err
	}
	if len(attivi) > 0 && !forza {
		return &nucleo.Errore{Messaggio: "there are processes using node_modules:\n  " +
			strings.Join(attivi, "\n  ") +
			"\nCompacting takes the tree away for a few seconds. Close them and retry, or `" +
			uscita + "`."}
	}
	return nil
}

// deposito: dove si mette da parte cio' che esce dall'immagine e va nel delta.
// Accanto al delta, cioe' sullo stesso filesystem: il ritorno e' un rename e non
// una seconda copia, ed e' atomico.
func deposito(p nucleo.PercorsiImmagine) string { return p.Delta + ".excluded" }

// deposita copia dalla vista fusa le cartelle che l'immagine nuova non conterra'.
func deposita(fusione, dove string, nomi []string) error {
	_ = os.RemoveAll(dove)
	if err := os.MkdirAll(dove, 0o755); err != nil {
		return &nucleo.Errore{Messaggio: "can't create " + dove + ": " + err.Error()}
	}
	for _, nome := range nomi {
		cmd := exec.Command("cp", "-a", "--",
			filepath.Join(fusione, nome), filepath.Join(dove, nome))
		var fuori, dentro strings.Builder
		cmd.Stdout, cmd.Stderr = &fuori, &dentro
		if err := cmd.Run(); err != nil {
			testo := strings.TrimSpace(dentro.String())
			if testo == "" {
				testo = strings.TrimSpace(fuori.String())
			}
			messaggio := "no message"
			if testo != "" {
				righe := strings.Split(testo, "\n")
				messaggio = righe[len(righe)-1]
			}
			return &nucleo.Errore{Messaggio: "couldn't set aside node_modules/" + nome +
				": " + messaggio}
		}
	}
	return nil
}

// riporta rimette nel delta cio' che era stato messo da parte, e sparisce.
func riporta(dove, delta string) {
	if !eDir(dove) {
		return
	}
	voci, err := os.ReadDir(dove)
	if err != nil {
		return
	}
	for _, v := range voci {
		bersaglio := filepath.Join(delta, v.Name())
		_ = os.RemoveAll(bersaglio)
		_ = os.Rename(filepath.Join(dove, v.Name()), bersaglio)
	}
	_ = os.Remove(dove)
}

// svuota il delta, lasciando i nomi che l'immagine non ha assorbito.
func svuota(delta string, tenere []string) {
	if !eDir(delta) {
		return
	}
	voci, err := os.ReadDir(delta)
	if err != nil {
		return
	}
	for _, v := range voci {
		if contiene(tenere, v.Name()) {
			continue
		}
		percorso := filepath.Join(delta, v.Name())
		if eCartellaVera(percorso) {
			_ = os.RemoveAll(percorso)
			continue
		}
		_ = os.Remove(percorso) // anche i whiteout: sono nodi di device
	}
}

// Compatta applica i passi di §9, con i tre tempi di sempre.
func Compatta(radice string, stato Stato, forza bool) error {
	// Chi era montato torna montato, chi era fermo torna fermo: il
	// consolidamento cambia l'immagine, non lo stato del progetto. E si sveglia
	// prima di cominciare, per la stessa ragione del congelamento: dentro il
	// nome fermo non si costruisce mai.
	rimontare := stato == Montato
	cartella := CartellaDi(radice)
	// Il controllo sui processi viene **prima** della sveglia: e' il rifiuto
	// piu' probabile di tutti (§10), e fermarsi dopo aver rinominato la cartella
	// lascerebbe un progetto fermo con addosso il nome di uno al lavoro.
	if err := EsigiLibera(cartella, forza, "npz compact --force"); err != nil {
		return err
	}

	Sveglia(radice)
	p := Percorsi(radice)
	backend, err := nucleo.Scegli("", radice)
	if err != nil {
		return err
	}
	config, err := nucleo.LeggiConfig(ProfiloDi(radice), radice)
	if err != nil {
		return err
	}
	meta, err := nucleo.LeggiMeta(p.Meta)
	if err != nil {
		return err
	}
	// Accanto a `lower` e `work`, che sono i suoi fratelli dentro `run/`: quel
	// che si vede su disco parla inglese, gli identificatori qui sopra no.
	fusione := filepath.Join(filepath.Dir(p.Basso), "merged")

	voce.Dici("compacting: %d entries (%s) in the delta …",
		Quante(p.Delta), nucleo.Leggibile(Somma(p.Delta)))

	l, err := nucleo.Lock(ProfiloDi(radice), radice)
	if err != nil {
		return err
	}

	var file int
	var byte int64
	errLavoro := func() error {
		defer l.Rilascia()
		// Lo smontaggio sta dentro il recupero perche' puo' riuscire a meta' —
		// la vista staccata e il lower no — e anche allora l'albero deve
		// tornare: e' montaSenzaLock che sa rimettere in ordine i due strati.
		var escluse []string
		errInterno := func() error {
			if err := smontaSenzaLock(p, cartella, backend, forza); err != nil {
				return err
			}
			_ = os.RemoveAll(deposito(p)) // residuo di un giro interrotto
			var err error
			file, byte, escluse, err = Ricostruisci(p, fusione, config, meta, backend)
			if err != nil {
				return err
			}
			// tempo 3 — solo adesso si cancella, e si cancella il delta che e'
			// appena stato assorbito. Un'uccisione fra il rename e questo punto
			// lascia un delta che verrebbe riapplicato sopra un'immagine che lo
			// contiene gia': identico, quindi innocuo. Il consolidamento
			// converge anche se lo si interrompe.
			svuota(p.Delta, escluse)
			riporta(deposito(p), p.Delta)
			_ = os.RemoveAll(p.Lavoro)
			return nil
		}()

		if errInterno != nil {
			// L'albero torna comunque: che il consolidamento sia fallito non e'
			// una ragione per lasciare il progetto senza node_modules. Se anche
			// il rimontaggio fallisce, l'errore da riportare resta il primo — e
			// lo stato *congelato* che ne risulta si ripara al prossimo comando.
			if rimontare {
				_ = montaSenzaLock(p, cartella, backend)
			}
			return errInterno
		}
		if rimontare {
			return montaSenzaLock(p, cartella, backend)
		}
		return nil
	}()
	if errLavoro != nil {
		return errLavoro
	}

	// I due numeri si leggono adesso, finche' i percorsi valgono: Addormenta
	// rinomina la cartella di servizio, e dopo di lei `p` non punta piu' a nulla.
	var guadagno int64
	if fi, err := os.Stat(p.Immagine); err == nil {
		guadagno = fi.Size()
	}
	rimasto := Somma(p.Delta)
	if !rimontare {
		// Fuori dal lock, che la rinomina lo esige. Se invece il consolidamento
		// fosse fallito non si arriva qui, e la cartella resta col nome da
		// sveglia: lo stato non cambia — StatoDi guarda tutti e due i nomi — e
		// il primo montaggio che capita la rimette a posto.
		Addormenta(radice)
	}

	coda := "the delta is empty again."
	if rimasto > 0 {
		coda = nucleo.Leggibile(rimasto) + " of build cache stays in the delta."
	}
	voce.Dici("compacted: %d files (%s) → one file (%s); %s",
		file, nucleo.Leggibile(byte), nucleo.Leggibile(guadagno), coda)
	return nil
}

// Ricostruisci va dalla vista fusa alla nuova immagine, verificata e applicata.
//
// Il merge lo fa il kernel — o fuse-overlayfs: whiteout e directory opache
// arrivano gia' risolti nella vista che ci consegna, e non c'e' una riga di
// logica dei whiteout da scrivere ne' da sbagliare.
func Ricostruisci(p nucleo.PercorsiImmagine, fusione string, config, meta map[string]any,
	backend nucleo.Backend) (int, int64, []string, error) {

	compressione, _ := config["compressione"].(string)
	var temporanea string
	var escluse []string
	atteso := map[string]nucleo.Voce{}

	if err := backend.MontaRO(p.Immagine, p.Basso); err != nil {
		return 0, 0, nil, err
	}
	errFusa := func() error {
		defer backend.Smonta(p.Basso, false)

		if err := backend.MontaFusione([]string{p.Delta, p.Basso}, fusione); err != nil {
			return err
		}
		defer backend.Smonta(fusione, false)

		// Lstat e non Stat: un symlink rotto e' comunque una voce da tenere
		// fuori, e Stat risponderebbe di no.
		for _, n := range Escluse {
			if esiste(filepath.Join(fusione, n)) {
				escluse = append(escluse, n)
			}
		}
		// Quelle che stanno anche nell'immagine vecchia vanno portate via da li'
		// prima che l'immagine venga sostituita. Le altre stanno gia' tutte nel
		// delta, e restarci non costa niente.
		var emigranti []string
		for _, n := range escluse {
			if esiste(filepath.Join(p.Basso, n)) {
				emigranti = append(emigranti, n)
			}
		}
		for _, nome := range emigranti {
			voce.Dici("moving node_modules/%s out of the image: it's a build cache, "+
				"and from now on it lives in the delta.", nome)
		}

		// Un delta che cancella tutto e' il caso di §2: `rm -rf node_modules`
		// battuto a mano, o uno script che lo fa, riempie il delta di whiteout
		// invece che di file. Consolidarlo scriverebbe un'immagine vuota, cioe'
		// butterebbe l'albero per obbedire a una cancellazione che l'utente
		// potrebbe non aver voluto. Non si indovina: si chiede.
		if voci, err := os.ReadDir(fusione); err == nil && len(voci) == 0 {
			return &nucleo.Errore{Messaggio: "the delta deletes the whole tree: " +
				"compacting now would write an empty image.\nNothing was touched — " +
				"the image still has everything. Two ways out:\n" +
				"  · `npz compact --discard` throws the delta away and brings the tree back\n" +
				"  · `npz bye` keeps the deletion, and node_modules stays away until you ask for it"}
		}

		// tempo 1 — si costruisce, e non si tocca niente di esistente.
		var err error
		temporanea, err = nucleo.Costruisci(fusione, p.Immagine, compressione, escluse,
			func(n int, _ int64) {
				voce.Avanzamento("compacting … %s%s", Quanto(n, 0),
					cresciuta(p.Immagine+".new"))
			})
		if err != nil {
			return err
		}
		fotografia, err := nucleo.Inventario(fusione, nil)
		if err != nil {
			return err
		}
		for rel, v := range fotografia {
			primo := rel
			if i := strings.IndexByte(rel, filepath.Separator); i >= 0 {
				primo = rel[:i]
			}
			if !contiene(escluse, primo) {
				atteso[rel] = v
			}
		}
		// La copia si fa qui, mentre la vista fusa c'e' ancora: e' l'unico posto
		// in cui quelle cartelle si vedono intere, delta e immagine insieme.
		return deposita(fusione, deposito(p), emigranti)
	}()
	if errFusa != nil {
		return 0, 0, nil, errFusa
	}

	// …e si verifica prima di crederci, con la stessa prova del congelamento
	// fatta al contrario: qui l'originale e' la vista fusa e la copia e'
	// l'immagine. Attributi, non nomi.
	if err := backend.MontaRO(temporanea, p.Basso); err != nil {
		return 0, 0, nil, err
	}
	ottenuto, errInv := nucleo.Inventario(p.Basso, nil)
	_ = backend.Smonta(p.Basso, false)
	if errInv != nil {
		return 0, 0, nil, errInv
	}
	if scarto := nucleo.Differenze(atteso, ottenuto, 5); len(scarto) > 0 {
		os.Remove(temporanea)
		return 0, 0, nil, &nucleo.Errore{Messaggio: "the compacted image doesn't match " +
			"the merged view:\n  " + strings.Join(scarto, "\n  ") + "\nNothing was applied."}
	}

	// tempo 2 — si applica, con un rename atomico. I tre numeri escono
	// dall'inventario appena fatto: ripercorrere l'albero attraverso FUSE per
	// ricontarlo costerebbe quanto un pezzo della costruzione.
	file, byte, cartelle := nucleo.Misura(ottenuto)
	if err := os.Rename(temporanea, p.Immagine); err != nil {
		return 0, 0, nil, &nucleo.Errore{Messaggio: "can't apply the image: " + err.Error()}
	}
	meta["incardinata"] = nucleo.Adesso()
	meta["file"], meta["byte"], meta["cartelle"] = file, byte, cartelle
	if err := nucleo.ScriviMeta(p.Meta, meta); err != nil {
		return 0, 0, nil, err
	}
	return file, byte, escluse, nil
}

// Butta e' l'altra uscita di §2: il delta si butta, e l'albero torna l'immagine.
//
// Serve quando il delta non e' lavoro ma una cancellazione — `rm -rf
// node_modules` da shell, o uno script che lo fa — e consolidarlo scriverebbe il
// vuoto. Cio' che era stato scritto a mano dentro node_modules se ne va con
// esso: e' cio' che la parola *discard* dichiara, e per questo e' un flag che si
// scrive e non una cosa che accade da sola.
func Butta(radice string, stato Stato, forza bool) error {
	p := Percorsi(radice)
	voci, peso := Quante(p.Delta), Somma(p.Delta)
	if voci == 0 {
		voce.Dici("the delta is already empty: nothing to discard.")
		return nil
	}

	rimontare := stato == Montato
	cartella := CartellaDi(radice)
	if err := EsigiLibera(cartella, forza, "npz compact --discard --force"); err != nil {
		return err
	}

	Sveglia(radice)
	p = Percorsi(radice) // la cartella di servizio si e' rinominata
	backend, err := nucleo.Scegli("", radice)
	if err != nil {
		return err
	}

	l, err := nucleo.Lock(ProfiloDi(radice), radice)
	if err != nil {
		return err
	}
	errLavoro := func() error {
		defer l.Rilascia()
		err := smontaSenzaLock(p, cartella, backend, forza)
		if err == nil {
			svuota(p.Delta, nil)
			_ = os.RemoveAll(p.Lavoro)
		}
		if rimontare {
			if errMonta := montaSenzaLock(p, cartella, backend); err == nil {
				err = errMonta
			}
		}
		return err
	}()
	if errLavoro != nil {
		return errLavoro
	}
	if !rimontare {
		Addormenta(radice)
	}

	voce.Dici("delta discarded: %d entries (%s) thrown away. "+
		"node_modules is the image again.", voci, nucleo.Leggibile(peso))
	return nil
}
