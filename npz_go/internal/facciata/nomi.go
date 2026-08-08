// Package facciata e' la politica: sa di package.json, di npm e di `.npz`.
//
// Si appoggia su internal/nucleo — il meccanismo — senza copiarne una riga. La
// separazione e' quella del §4 del piano: `nucleo` sa costruire, montare e
// tenere lo stato; sa *dove* farlo solo chi lo chiama.
//
// Dove `freeze` ha una radice condivisa fra progetti dichiarata con `init`,
// `npz` ha **una radice per progetto**, che nasce da sola accanto al
// package.json e si chiama `.npz`.
package facciata

import (
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"

	"npz/internal/nucleo"
)

const (
	Manifesto = "package.json"
	Cartella  = "node_modules"

	// La cartella di servizio ha due nomi, e il nome *e'* lo stato.
	//
	// Mentre si lavora si chiama `.npz` ed e' nascosta: accanto c'e'
	// `node_modules` montata, e il progetto ha l'aspetto di sempre. Quando
	// invece e' ferma — smontata, con l'albero che non esiste — prende il nome
	// visibile, cosi' che una cartella di progetto dormiente non sembri una
	// cartella a cui manca qualcosa, ma dichiari da sola che cosa e' successo e
	// dove sono finiti i dati.
	//
	// Non e' un segnaposto: e' la stessa cartella, con addosso il nome giusto
	// per lo stato in cui si trova.
	Servizio      = ".npz"
	ServizioFermo = "node_modules.frozen"

	// Sul filesystem sotto il mount: invisibile mentre il mount c'e', unica cosa
	// presente quando e' caduto.
	Sentinella = ".npz_automount_here"

	// Il suffisso delle copie messe da parte (§6 bis). Una sola per volta,
	// ovunque si trovi: l'albero di npm resta nella radice di progetto, dove si
	// vede, l'immagine vecchia e il suo delta dentro la cartella di servizio.
	Superato       = ".superseded"
	AlberoSuperato = Cartella + Superato
)

// PROFILO e' il profilo di npz nella sua forma canonica. Chi opera su un
// progetto usa Profilo(progetto), che sa quale dei due nomi c'e' adesso.
var PROFILO = nucleo.Profilo{Servizio: Servizio, Sentinella: Sentinella}

// ── gli otto stati ───────────────────────────────────────────────────────────
//
// Il valore che portano e' cio' che `npz status` stampa alla lettera, quindi e'
// in inglese e non e' libero.
//
// NOTA DI PORTING (§6.3) — in Rust sarebbero un enum con match esaustivo, e un
// nono stato farebbe fallire la compilazione ovunque non fosse gestito. Go non
// ha somme di tipi: la mitigazione e' un tipo dedicato (non `string` nuda), il
// linter `exhaustive` in CI, e un `default:` che va in panico invece di
// prendere il ramo prudente — che su un progetto che sta per essere montato o
// cancellato non c'e'.

type Stato string

const (
	Estraneo   Stato = "outside"   // nessun package.json qui sopra
	Candidato  Stato = "candidate" // node_modules vero, npz non ne sa niente
	Rifiutato  Stato = "declined"  // l'utente ha detto no, e non glielo si richiede
	Vergine    Stato = "fresh"     // ne' node_modules ne' .npz
	Montato    Stato = "mounted"   // lo stato di lavoro
	Congelato  Stato = "attached"  // immagine presente, cartella assente
	Rotto      Stato = "broken"    // il nostro mountpoint scoperto
	Scavalcato Stato = "bypassed"  // un albero vero che npz non ha costruito
)

// ── le domande sul filesystem ────────────────────────────────────────────────

func eFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

func eDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func esiste(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// eCartellaVera: una cartella in cui scendere. Un symlink a cartella non lo e'.
func eCartellaVera(p string) bool {
	fi, err := os.Lstat(p)
	return err == nil && fi.IsDir()
}

// soloSentinella dice se dentro non c'e' altro che la sentinella.
//
// E' cio' che separa *rotto* da *scavalcato*, e i due non si possono
// confondere: sul primo si rimonta in silenzio, sul secondo montare coprirebbe
// l'albero dell'utente lasciandolo invisibile a occupare disco.
func soloSentinella(dir string) bool {
	d, err := os.Open(dir)
	if err != nil {
		return false
	}
	defer d.Close()
	for {
		nomi, err := d.Readdirnames(32)
		for _, n := range nomi {
			if n != Sentinella {
				return false
			}
		}
		if err == io.EOF {
			return true
		}
		if err != nil {
			return false
		}
		if len(nomi) == 0 {
			return true
		}
	}
}

// NomeServizio dice quale dei due nomi esiste adesso, o "" se nessuno.
func NomeServizio(progetto string) string {
	for _, nome := range [...]string{Servizio, ServizioFermo} {
		if eDir(filepath.Join(progetto, nome)) {
			return nome
		}
	}
	return ""
}

// TrovaProgetto: la prima cartella, risalendo, che contiene un package.json.
//
// E' il criterio con cui npm stesso decide dove sta il progetto: usarne un
// altro produrrebbe divergenze silenziose fra cio' che npz crede di gestire e
// cio' su cui npm opera. Ci si ferma al **confine di filesystem**, perche'
// l'upperdir di overlayfs deve stare sullo stesso filesystem del suo workdir.
func TrovaProgetto(partenza string) string {
	if partenza == "" {
		var err error
		if partenza, err = os.Getwd(); err != nil {
			return ""
		}
	}
	corrente, err := filepath.EvalSymlinks(partenza)
	if err != nil {
		return ""
	}
	dispositivo, ok := dispositivoDi(corrente)
	if !ok {
		return ""
	}
	for {
		if eFile(filepath.Join(corrente, Manifesto)) {
			return corrente
		}
		genitore := filepath.Dir(corrente)
		if genitore == corrente {
			return ""
		}
		d, ok := dispositivoDi(genitore)
		if !ok || d != dispositivo {
			return ""
		}
		corrente = genitore
	}
}

func dispositivoDi(p string) (uint64, bool) {
	fi, err := os.Stat(p)
	if err != nil {
		return 0, false
	}
	s, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return uint64(s.Dev), true
}

// StatoDi dice in quale degli otto stati siamo. Quattro Stat, nel caso normale.
func StatoDi(progetto string) Stato {
	if progetto == "" {
		return Estraneo
	}
	albero := filepath.Join(progetto, Cartella)
	serv := NomeServizio(progetto)
	if serv == "" {
		if eDir(albero) {
			return Candidato
		}
		return Vergine
	}
	if eFile(filepath.Join(progetto, serv, "static", Cartella+".img")) {
		if !eDir(albero) {
			return Congelato
		}
		if nucleo.Montato(albero) {
			return Montato
		}
		if soloSentinella(albero) {
			return Rotto
		}
		return Scavalcato
	}
	if esiste(filepath.Join(progetto, serv, "no")) {
		return Rifiutato
	}
	if eDir(albero) {
		return Candidato
	}
	return Vergine
}

// ── misure sul delta ─────────────────────────────────────────────────────────
//
// `tranne` serve a distinguere le due domande che si fanno al delta, e che non
// hanno la stessa risposta: *quanto occupa* — e allora si conta tutto, perche'
// tutto sta sul disco — contro *quanto ne assorbirebbe un consolidamento*, che
// esclude cio' che nell'immagine non entrerebbe comunque (§9). Senza la
// distinzione, una cache di build da 40 MiB reclamerebbe per sempre un
// consolidamento che non puo' toglierla di li'.

// sotto da' le voci di primo livello del delta da guardare.
func sotto(delta string, tranne []string) []string {
	if !eDir(delta) {
		return nil
	}
	voci, err := os.ReadDir(delta)
	if err != nil {
		return nil
	}
	var scelte []string
	for _, v := range voci {
		if contiene(tranne, v.Name()) {
			continue
		}
		scelte = append(scelte, filepath.Join(delta, v.Name()))
	}
	return scelte
}

func contiene(elenco []string, nome string) bool {
	for _, e := range elenco {
		if e == nome {
			return true
		}
	}
	return false
}

// Somma da' i byte occupati dal delta.
func Somma(delta string, tranne ...string) int64 {
	var totale int64
	for _, voce := range sotto(delta, tranne) {
		if !eCartellaVera(voce) {
			if fi, err := os.Lstat(voce); err == nil {
				totale += fi.Size()
			}
			continue
		}
		_ = filepath.WalkDir(voce, func(p string, d fs.DirEntry, e error) error {
			if e != nil || d.IsDir() {
				return nil
			}
			if fi, err := os.Lstat(p); err == nil {
				totale += fi.Size()
			}
			return nil
		})
	}
	return totale
}

// Quante conta le voci del delta.
func Quante(delta string, tranne ...string) int {
	totale := 0
	for _, voce := range sotto(delta, tranne) {
		totale++
		if !eCartellaVera(voce) {
			continue
		}
		_ = filepath.WalkDir(voce, func(p string, d fs.DirEntry, e error) error {
			if e != nil || p == voce {
				return nil
			}
			totale++
			return nil
		})
	}
	return totale
}
