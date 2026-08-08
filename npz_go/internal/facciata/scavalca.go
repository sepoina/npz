// Lo scavalcamento — §6 bis del piano.
//
// Qualcuno ha battuto `npm` al posto di `npz`, e da fermi npm ha ricostruito
// node_modules: adesso ci sono due alberi, e nessuno dei due e' sbagliato.
// **Non si fondono** — non sono due rami della stessa cosa, sono due soluzioni
// distinte dello stesso problema di vincoli, e meta' dell'una piu' meta'
// dell'altra non e' una soluzione. Si sceglie un albero intero.
//
// Chi perde non si cancella: si rinomina. E' MettiDaParte() applicata al
// conflitto — li' non si distrugge lo stato congelato prima di sapere se npm
// riuscira', qui non lo si distrugge prima di sapere se l'utente ha scelto bene.

package facciata

import (
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"npz/internal/nucleo"
	"npz/internal/voce"
)

// La grazia prima di chiedere se togliere una copia messa da parte. Si guarda
// l'mtime, che sta gia' sul filesystem: contare le invocazioni vorrebbe dire
// tenere un contatore, ed e' il pezzo di stato che il §5 ha deciso di non
// scrivere da nessuna parte. Misura anche la cosa giusta — non "cinque
// comandi", ma *aver avuto il tempo di accorgersi se serviva ancora*.
const (
	graziaImmagine = 86400     // un file solo, superato da una immagine verificata
	graziaAlbero   = 7 * 86400 // l'annullamento dell'utente: una settimana
)

// Peso dice quanto occupa, che sia un file solo o un albero intero.
func Peso(percorso string) int64 {
	if eCartellaVera(percorso) {
		var totale int64
		_ = filepath.WalkDir(percorso, func(p string, d fs.DirEntry, e error) error {
			if e != nil || d.IsDir() {
				return nil
			}
			if fi, err := os.Lstat(p); err == nil {
				totale += fi.Size()
			}
			return nil
		})
		return totale
	}
	if fi, err := os.Lstat(percorso); err == nil {
		return fi.Size()
	}
	return 0
}

// Superata e' una copia messa da parte che esiste adesso.
type Superata struct {
	Che    string   // come si chiama, per l'utente
	Dove   []string // i percorsi che la compongono
	Grazia int64    // per quanti secondi non se ne chiede la rimozione
	Quando int64    // l'mtime piu' vecchio fra i suoi pezzi
}

// Superate da' le copie messe da parte che esistono adesso.
//
// Si **cercano per nome** invece di tenerne un elenco: il filesystem e' la
// fonte di verita' (§5), e un registro scritto a mano potrebbe contraddirlo.
// Non si pesano qui: pesare un albero e' una passata su decine di migliaia di
// file, e chi chiama spesso vuole solo sapere se ce n'e' una.
func Superate(radice string) []Superata {
	p := Percorsi(radice)
	candidate := []Superata{
		{Che: "the folder npm built",
			Dove:   []string{filepath.Join(radice, AlberoSuperato)},
			Grazia: graziaAlbero},
		{Che: "the previous image and its delta",
			Dove:   []string{p.Immagine + Superato, p.Delta + Superato},
			Grazia: graziaImmagine},
		// L'orfano di un `npm ci` ucciso a meta': MettiDaParte() lo crea e solo
		// il giro completo lo toglie, quindi finora restava li' per sempre
		// mentre StatoDi() dichiarava il progetto *candidato*. La grazia di un
		// giorno garantisce anche che un `npm ci` **vivo**, che dura minuti, non
		// venga mai scambiato per un residuo.
		{Che: "an image left behind by an interrupted `npm ci`",
			Dove:   []string{p.Immagine + ".aside"},
			Grazia: graziaImmagine},
	}

	var presenti []Superata
	for _, v := range candidate {
		var esistono []string
		var piuVecchio int64
		for _, d := range v.Dove {
			fi, err := os.Lstat(d)
			if err != nil {
				continue
			}
			esistono = append(esistono, d)
			if m := fi.ModTime().Unix(); piuVecchio == 0 || m < piuVecchio {
				piuVecchio = m
			}
		}
		if len(esistono) == 0 {
			continue
		}
		v.Dove, v.Quando = esistono, piuVecchio
		presenti = append(presenti, v)
	}
	return presenti
}

func data(quando int64) string {
	return time.Unix(quando, 0).Format("2006-01-02")
}

func buttaVia(percorso string) {
	if eCartellaVera(percorso) {
		_ = os.RemoveAll(percorso)
		return
	}
	_ = os.Remove(percorso)
}

// FaiPosto tiene una sola copia messa da parte per volta, e dice se si puo'
// andare avanti.
//
// Senza questa regola il failsafe diventa `.superseded.2`, `.superseded.3`,
// cioe' esattamente la perdita di spazio che doveva evitare. Con, il costo
// massimo e' **una generazione**, sempre, per costruzione.
//
// Senza TTY si sovrascrive dicendolo — che e' gia' cio' che fa MettiDaParte()
// con la rimozione prima del rename.
func FaiPosto(radice string) bool {
	presenti := Superate(radice)
	if len(presenti) == 0 {
		return true
	}
	var totale int64
	var righe []string
	for _, v := range presenti {
		for _, d := range v.Dove {
			totale += Peso(d)
		}
		righe = append(righe, "there's already a copy set aside: "+v.Che+
			" ("+data(v.Quando)+").")
	}
	quanto := nucleo.Leggibile(totale)
	righe = append(righe, "That's "+quanto+". npz keeps one at a time, so making "+
		"room means removing it.")

	scelta := Chiedi(righe, "Remove it and go on? [y/N] ", "yn", "n",
		map[string]string{"n": "nothing was touched."})
	if scelta == "n" {
		return false
	}
	if scelta == "" {
		voce.Dici("overwriting the copy already set aside (%s): npz keeps one at a time.",
			quanto)
	}
	for _, v := range presenti {
		for _, d := range v.Dove {
			buttaVia(d)
		}
	}
	return true
}

// Raccogli chiede se togliere le copie a cui la grazia e' scaduta.
//
// Sta in cima al percorso lento: il giro che crea una copia non la vede — non
// esisteva ancora — quindi la domanda arriva dal giro dopo, che e' il punto in
// cui l'utente ha gia' avuto una sessione per accorgersi di aver scelto male.
//
// Rispondere no **non registra un rifiuto**: rimette l'orologio a zero, e la
// domanda torna fra un'altra grazia. L'mtime e' la memoria — non c'e' niente da
// mantenere, non si puo' inchiodare, e non nagga.
func Raccogli(radice string) {
	if !SiPuoChiedere() {
		return // senza TTY non si cancella mai niente
	}
	adesso := time.Now().Unix()
	for _, v := range Superate(radice) {
		if adesso-v.Quando < v.Grazia {
			continue
		}
		giorni := v.Grazia / 86400
		if giorni < 1 {
			giorni = 1
		}
		var totale int64
		for _, d := range v.Dove {
			totale += Peso(d)
		}
		quanto := nucleo.Leggibile(totale)
		durata := "day"
		if giorni > 1 {
			durata = "week"
		}
		// Il suggerimento sta **prima** della domanda: dopo `[y/N]` ci va solo
		// il cursore, altrimenti chi risponde scrive in fondo a una frase.
		//
		// La descrizione sta dopo i due punti e non come soggetto: cosi' non
		// deve concordare col verbo, e "the previous image and its delta" non
		// chiede un plurale che le altre voci non vogliono.
		scelta := Chiedi([]string{
			"still set aside: " + v.Che + ", from " + data(v.Quando) +
				". Nothing has read it since, and it's taking " + quanto + ".",
			"Saying no keeps it another " + durata + ".",
		}, "Remove it? [y/N] ", "yn", "n", nil)

		if scelta == "y" {
			for _, d := range v.Dove {
				buttaVia(d)
			}
			voce.Dici("removed: %s (%s freed).", v.Che, quanto)
			continue
		}
		adessoT := time.Now()
		for _, d := range v.Dove {
			_ = os.Chtimes(d, adessoT, adessoT)
		}
	}
}

// avvisaScavalcato e' la riga che si dice quando non si puo' — o non si deve —
// chiedere.
//
// Non porta numeri: contarli vorrebbe dire una passata su tutto l'albero, e
// questa riga esce anche davanti a un `npm run` che deve solo partire. E' neutra
// rispetto a chi la dice: esce sia davanti a un comando che sta per passare a
// npm, sia da dentro `npz hey`, e nominare un comando andrebbe bene solo per il
// primo dei due.
func avvisaScavalcato() {
	voce.Dici("npz was bypassed here: npm rebuilt node_modules on its own, and " +
		"the image is still in the service folder.\nBoth are on disk — run npz " +
		"from a terminal to pick one.")
}

// Conflitto: due alberi, se ne sceglie uno intero. Dice se npz e' tornato in
// mano.
//
// Falso vuol dire che npz si e' fatto da parte: la cartella che npm ha
// costruito resta al suo posto e funziona, ed e' esattamente il motivo per cui
// non chiedere e' una via legittima invece di un guasto.
func Conflitto(radice string) (bool, error) {
	if !SiPuoChiedere() {
		avvisaScavalcato()
		return false, nil
	}

	cartella := CartellaDi(radice)
	p := Percorsi(radice)
	file, byte, _, err := nucleo.Conta(cartella, nil)
	if err != nil {
		return false, err
	}
	meta := map[string]any{}
	if esiste(p.Meta) {
		if letto, err := nucleo.LeggiMeta(p.Meta); err == nil {
			meta = letto
		}
	}
	var pesoImmagine int64
	if fi, err := os.Stat(p.Immagine); err == nil {
		pesoImmagine = fi.Size()
	}

	quadro := []string{
		"npz was bypassed here: npm rebuilt node_modules on its own.",
		"  · the folder has " + strconv.Itoa(file) + " files (" + nucleo.Leggibile(byte) + ")",
		"  · the image from " + testoDa(meta["creata"]) + " has " +
			testoDa(meta["file"]) + " files (" + nucleo.Leggibile(pesoImmagine) + " on disk)",
		"You're paying for both, and npz won't mount over a folder it didn't build.",
		// Va detto, perche' e' la prima cosa che viene in mente guardando due
		// alberi, ed e' quella che romperebbe tutto in silenzio.
		"They can't be merged: they're two different dependency trees, and half " +
			"of one plus half of the other isn't a working tree.",
		"  [f] keep the folder npm built — it becomes the new image",
		"  [i] keep the image — the folder is set aside, nothing is deleted",
		"  [x] do nothing now",
	}
	// La risposta al "non fare niente" sta dentro `dopo`, cioe' sullo stesso
	// terminale e nella stessa sbarra della domanda: e' la risposta a quel che
	// e' appena stato chiesto, non un messaggio nuovo.
	scelta := Chiedi(quadro, "Which one? [f/i/X] ", "fix", "x",
		map[string]string{"x": "nothing was touched. node_modules stays as npm " +
			"left it, and the image stays where it is."})

	switch scelta {
	case "f":
		return Adotta(radice)
	case "i":
		return Ripudia(radice)
	}
	return false, nil
}

// testoDa rende un valore JSON in forma leggibile, con "?" se manca.
func testoDa(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return strconv.FormatInt(int64(t), 10)
	case nil:
		return "?"
	default:
		return "?"
	}
}

// Adotta: l'albero di npm diventa l'immagine nuova; la vecchia si mette da parte.
//
// L'immagine si parcheggia **prima** di costruire. Rinominare non e' cancellare,
// quindi l'invariante regge — e se la costruzione fallisce restano sul disco sia
// l'albero vero sia l'immagine di prima, cioe' tutto.
func Adotta(radice string) (bool, error) {
	cartella := CartellaDi(radice)
	// Prima di toccare qualsiasi cosa: al tempo 3 quell'albero sparisce, e
	// fermarsi dopo aver parcheggiato l'immagine sarebbe il momento peggiore.
	attivi, err := nucleo.ProcessiAttivi(cartella)
	if err != nil {
		return false, err
	}
	if len(attivi) > 0 {
		return false, &nucleo.Errore{Messaggio: "there are processes using node_modules:\n  " +
			joinRighe(attivi) + "\nClose them and retry."}
	}
	if err := VerificaIdoneita(radice); err != nil {
		return false, err
	}
	if !FaiPosto(radice) {
		return false, nil
	}

	Sveglia(radice)
	p := Percorsi(radice)
	for _, percorso := range []string{p.Immagine, p.Delta} {
		if esiste(percorso) {
			_ = os.Rename(percorso, percorso+Superato)
		}
	}
	voce.Dici("the previous image is set aside, not deleted.")
	if err := Congela(radice); err != nil {
		return false, err
	}
	if err := Monta(radice); err != nil {
		return false, err
	}
	return true, nil
}

// Ripudia: l'immagine vince, e l'albero che npm ha costruito si mette da parte,
// intero.
//
// Va detto forte che cosi' si perde di vista quel che npm aveva appena
// installato — chi ha battuto `npm install lodash` e sceglie qui l'immagine si
// ritrova senza lodash. E' la scelta piu' sospetta delle due, e per questo la
// copia da parte le sopravvive una settimana invece di un giorno.
func Ripudia(radice string) (bool, error) {
	if !FaiPosto(radice) {
		return false, nil
	}
	// Idempotente, e serve a chi e' stato attaccato da una versione che il nome
	// `node_modules.superseded` non lo conosceva: senza, l'albero messo da parte
	// comparirebbe fra gli untracked del progetto.
	if _, err := PreparaServizio(radice); err != nil {
		return false, err
	}
	cartella := CartellaDi(radice)
	daParte := filepath.Join(radice, AlberoSuperato)
	// Un rename e non una copia: e' atomico, istantaneo, e non serve il doppio
	// dello spazio per una cartella che stiamo mettendo via.
	if err := os.Rename(cartella, daParte); err != nil {
		return false, &nucleo.Errore{Messaggio: "can't set the folder aside: " + err.Error()}
	}
	if err := Monta(radice); err != nil {
		return false, err
	}
	voce.Dici("node_modules is the image again. What npm built is set aside in "+
		"%s/ — anything it installed is not in the mounted tree.", AlberoSuperato)
	return true, nil
}

func joinRighe(righe []string) string {
	out := ""
	for i, r := range righe {
		if i > 0 {
			out += "\n  "
		}
		out += r
	}
	return out
}
