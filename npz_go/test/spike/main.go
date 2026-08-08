// npz — spike di fase 0: il percorso veloce, e niente altro.
//
// Non e' codice di prodotto. E' lo script da buttare via del §8 del piano di
// implementazione in Go, sulla falsariga di `fase0.sh`: il suo unico scopo e'
// rispondere alle domande che possono ancora smentire la scelta di Go, prima
// che si scrivano settimane di codice.
//
// Le domande sono tre, e sono tutte e tre misurabili in mezza giornata:
//
//  1. il percorso veloce sta sotto i 3 ms? N6 ha misurato 12,4 ms per Python;
//     se Go non sta molto sotto, il porting non compra quello che promette.
//  2. `syscall.Exec` e' trasparente come `os.execv`? Il runtime di Go e'
//     multi-thread e `Exec` lo attraversa: TTY, ctrl-c e codice di uscita
//     devono passare senza che una riga di codice se ne occupi. E' la
//     proprieta' per cui il §3 del piano ha scartato Node, quindi se cade qui
//     cade tutto.
//  3. la coda della voce viene emessa prima di `Exec`? `Exec` **non esegue i
//     defer** (§6.1), e un `defer chiudi()` in cima a main funzionerebbe
//     sull'uscita normale fallendo sul percorso piu' frequente del programma.
//
// Tutto il resto — montare, congelare, consolidare — non sta qui e non deve.
// Dove il percorso lento comincerebbe, questo binario si ferma e lo dichiara.
//
// Il codice ricalca `veloce.py` e `lanciatore.py` funzione per funzione, e
// deliberatamente non li migliora: uno spike che diverge dall'originale non
// misura l'originale.
package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// ── i nomi, che vengono da veloce.py ─────────────────────────────────────────

const (
	manifesto = "package.json"
	cartella  = "node_modules"

	// La cartella di servizio ha due nomi, e il nome *e'* lo stato. Mentre si
	// lavora si chiama `.npz` ed e' nascosta; quando e' ferma prende il nome
	// visibile, cosi' che un progetto dormiente non sembri un progetto a cui
	// manca qualcosa ma dichiari da solo dove sono finiti i dati.
	servizio      = ".npz"
	servizioFermo = "node_modules.frozen"

	// Sul filesystem sotto il mount: invisibile mentre il mount c'e', unica
	// cosa presente quando e' caduto. E' cio' che separa *rotto* da
	// *scavalcato*.
	sentinella = ".npz_automount_here"
)

// Gli otto stati. Gli identificatori restano italiani come tutto il resto del
// codice, ma il valore che portano e' cio' che `npz status` stampa alla
// lettera, quindi e' in inglese e non e' libero.
const (
	estraneo   = "outside"   // nessun package.json qui sopra
	candidato  = "candidate" // node_modules vero, npz non ne sa niente
	rifiutato  = "declined"  // l'utente ha detto no, e non glielo si richiede
	vergine    = "fresh"     // ne' node_modules ne' .npz
	montato    = "mounted"   // lo stato di lavoro
	congelato  = "attached"  // immagine presente, cartella assente
	rotto      = "broken"    // il nostro mountpoint scoperto
	scavalcato = "bypassed"  // un albero vero che npz non ha costruito
)

// ── la voce di npz ───────────────────────────────────────────────────────────
//
// La sbarra delimita un **turno di parola**: si apre con una testa, ogni riga
// porta il segno, e si chiude esattamente dove npz cede il terminale. Quel che
// sta fra testa e coda l'ha detto npz; tutto il resto e' di npm.

const (
	testa = " ╥"
	segno = " ║  "
	coda  = " ╨"

	tintaVoce = "\033[2;33m" // giallo a meta' intensita'
	spento    = "\033[0m"
)

var turnoAperto bool

// eTty senza dipendenze esterne. `golang.org/x/term` farebbe un ioctl vero;
// qui basta il tipo del file, e lo spike non deve tirarsi dietro un modulo per
// una riga. Nel codice di prodotto si riconsidera.
func eTty(f *os.File) bool {
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

// Il colore sta sul segno, mai sul testo: il testo resta copiabile.
func tinge(glifo string) string {
	if !eTty(os.Stderr) {
		return glifo
	}
	return tintaVoce + glifo + spento
}

func dice(righe ...string) {
	if !turnoAperto {
		fmt.Fprintln(os.Stderr, tinge(testa))
		turnoAperto = true
	}
	for _, r := range righe {
		fmt.Fprintln(os.Stderr, tinge(segno)+r)
	}
}

// chiudi va chiamata **esplicitamente** prima di ogni Exec e di ogni Start.
// Non con un defer: vedi il commento in consegna().
func chiudi() {
	if turnoAperto {
		fmt.Fprintln(os.Stderr, tinge(coda))
		turnoAperto = false
	}
}

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
	_, err := os.Stat(p)
	return err == nil
}

// eMount ricalca os.path.ismount di Python: la libreria standard di Go non ha
// un equivalente. Si confronta il device con quello del genitore, e in caso di
// parita' l'inode — che e' come si riconosce la radice, e come si riconoscono i
// bind mount sullo stesso device.
func eMount(percorso string) bool {
	fi, err := os.Lstat(percorso)
	if err != nil || fi.Mode()&os.ModeSymlink != 0 {
		return false
	}
	s1, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	genitore, err := filepath.EvalSymlinks(filepath.Join(percorso, ".."))
	if err != nil {
		return false
	}
	fi2, err := os.Lstat(genitore)
	if err != nil {
		return false
	}
	s2, ok := fi2.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	if s1.Dev != s2.Dev {
		return true
	}
	return s1.Ino == s2.Ino
}

// soloSentinella dice se dentro non c'e' altro che la sentinella.
//
// E' cio' che separa *rotto* da *scavalcato*, e i due non si possono
// confondere: sul primo si rimonta in silenzio, sul secondo montare coprirebbe
// l'albero dell'utente lasciandolo invisibile a occupare disco. Si legge a
// blocchi e si esce alla prima voce che non sia la sentinella, quindi su un
// node_modules vero e' una lettura sola.
func soloSentinella(dir string) bool {
	d, err := os.Open(dir)
	if err != nil {
		return false
	}
	defer d.Close()
	for {
		nomi, err := d.Readdirnames(32)
		for _, n := range nomi {
			if n != sentinella {
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

// ── dove siamo, e in che stato ───────────────────────────────────────────────

func dev(p string) (uint64, bool) {
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

// trovaProgetto: la prima cartella, risalendo, che contiene un package.json.
//
// E' il criterio con cui npm stesso decide dove sta il progetto: usarne un
// altro produrrebbe divergenze silenziose fra cio' che npz crede di gestire e
// cio' su cui npm opera. Ci si ferma al **confine di filesystem**, perche'
// l'upperdir di overlayfs deve stare sullo stesso filesystem del suo workdir.
func trovaProgetto(partenza string) string {
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
	dispositivo, ok := dev(corrente)
	if !ok {
		return ""
	}
	for {
		if eFile(filepath.Join(corrente, manifesto)) {
			return corrente
		}
		genitore := filepath.Dir(corrente)
		if genitore == corrente {
			return ""
		}
		d, ok := dev(genitore)
		if !ok || d != dispositivo {
			return ""
		}
		corrente = genitore
	}
}

// nomeServizio: quale dei due nomi esiste adesso, o "" se non ce n'e' nessuno.
func nomeServizio(progetto string) string {
	for _, nome := range [...]string{servizio, servizioFermo} {
		if eDir(filepath.Join(progetto, nome)) {
			return nome
		}
	}
	return ""
}

// statoDi: in quale degli otto stati siamo. Quattro Stat, nel caso normale.
func statoDi(progetto string) string {
	if progetto == "" {
		return estraneo
	}
	albero := filepath.Join(progetto, cartella)
	serv := nomeServizio(progetto)
	if serv == "" {
		if eDir(albero) {
			return candidato
		}
		return vergine
	}
	if eFile(filepath.Join(progetto, serv, "static", cartella+".img")) {
		if !eDir(albero) {
			return congelato
		}
		if eMount(albero) {
			return montato
		}
		if soloSentinella(albero) {
			return rotto
		}
		return scavalcato
	}
	if esiste(filepath.Join(progetto, serv, "no")) {
		return rifiutato
	}
	if eDir(albero) {
		return candidato
	}
	return vergine
}

// ── la classificazione dei comandi ───────────────────────────────────────────

const (
	neutro      = "neutro"
	mutante     = "mutante"
	distruttivo = "distruttivo"
	nostro      = "nostro"
)

func insieme(nomi ...string) map[string]bool {
	m := make(map[string]bool, len(nomi))
	for _, n := range nomi {
		m[n] = true
	}
	return m
}

var propri = insieme("attach", "detach", "hey", "bye", "status", "compact")

// `npm ci` comincia cancellando node_modules: sull'overlay un whiteout per ogni
// voce e poi l'albero intero riestratto nel delta. N1 l'ha misurato 3,57x piu'
// lento, 821 MiB contro 588.
var distruttivi = insieme("ci", "clean-install", "install-clean", "ic", "isntall-clean")

// Gli alias sono quelli veri di npm: chi scrive `npm i` non deve ottenere un
// comportamento diverso da chi scrive `npm install`.
var mutanti = insieme(
	"install", "i", "in", "ins", "inst", "insta", "instal", "isnt", "isnta",
	"isntal", "isntall", "add",
	"uninstall", "unlink", "remove", "rm", "r", "un",
	"update", "up", "upgrade", "udpate",
	"dedupe", "ddp", "find-dupes",
	"prune",
	"link", "ln",
	"rebuild", "rb",
	"install-test", "it", "install-ci-test", "cit",
)

var neutri = insieme(
	"run", "run-script", "rum", "urn", "test", "t", "tst", "start", "stop",
	"restart", "ls", "list", "la", "ll", "explain", "why", "outdated", "audit",
	"publish", "pack", "view", "v", "info", "show", "search", "s", "se", "find",
	"help", "help-search", "config", "c", "get", "set", "whoami", "login",
	"logout", "adduser", "token", "team", "org", "owner", "author", "access",
	"dist-tag", "deprecate", "undeprecate", "star", "unstar", "stars", "ping",
	"doctor", "root", "prefix", "bin", "repo", "docs", "home", "bugs", "issues",
	"version", "exec", "x", "create", "init", "query", "sbom", "diff", "hook",
	"profile", "edit", "fund", "completion", "shrinkwrap", "pkg", "cache",
	"approve-scripts", "deny-scripts", "stage", "trust", "unpublish",
)

// separa: il primo argomento che non e' un'opzione, e se c'era un `--`.
// Dopo `--` non si guarda piu': `npz -- bye` deve arrivare a npm come `bye`.
func separa(argv []string) (string, bool) {
	for i, a := range argv {
		if a == "--" {
			if i+1 < len(argv) {
				return argv[i+1], true
			}
			return "", true
		}
		if !strings.HasPrefix(a, "-") {
			return a, false
		}
	}
	return "", false
}

// classifica risponde MUTANTE anche a cio' che non conosce: si sbaglia per
// eccesso. Un comando classificato mutante per errore costa uno Stat sul delta
// che non trova niente; un mutante non classificato lascia crescere il delta
// senza che nessuno se ne accorga.
func classifica(argv []string) string {
	comando, passante := separa(argv)
	if comando == "" {
		return neutro // `npz` nudo: npm stampa l'aiuto
	}
	if !passante && propri[comando] {
		return nostro
	}
	switch {
	case distruttivi[comando]:
		return distruttivo
	case neutri[comando]:
		return neutro
	default:
		return mutante
	}
}

// ── consegnare il comando a npm ──────────────────────────────────────────────

// ioStesso: il nostro eseguibile a percorso reale, per non rincorrerci.
func ioStesso() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if reale, err := filepath.EvalSymlinks(exe); err == nil {
		return reale
	}
	return exe
}

// trovaNpm: npm risolto a percorso assoluto, saltando noi stessi.
//
// Un wrapper che esegue `npm` per nome, su una macchina dove qualcuno ha messo
// in PATH un `npm` che punta a `npz`, entra in ricorsione infinita. Le alias di
// shell non si ereditano e non fanno danno; un symlink si'.
func trovaNpm(io string) string {
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		if dir == "" {
			continue
		}
		candidato := filepath.Join(dir, "npm")
		if syscall.Access(candidato, 0x01 /* X_OK */) != nil {
			continue
		}
		if eDir(candidato) {
			continue
		}
		if io != "" {
			if reale, err := filepath.EvalSymlinks(candidato); err == nil && reale == io {
				continue // siamo noi travestiti: si tira dritto
			}
		}
		return candidato
	}
	return ""
}

// consegna sostituisce il processo con npm. Non torna.
//
// E' il motivo per cui il percorso veloce e' davvero veloce: il processo npz
// sparisce, e npm eredita TTY, segnali e codice di uscita senza una riga di
// codice che se ne occupi.
//
// La chiamata a chiudi() qui sopra **non e' un defer**, e non e' una svista.
// syscall.Exec non esegue le funzioni differite: il processo viene sostituito e
// tutto cio' che era in coda a un defer semplicemente non succede. Un
// `defer chiudi()` in cima a main funzionerebbe sull'uscita normale e fallirebbe
// proprio sul percorso piu' frequente del programma, lasciando l'output di npm
// dentro il turno di parola di npz. E' il §6.1 del piano.
func consegna(npm string, argv []string) {
	chiudi()
	err := syscall.Exec(npm, append([]string{npm}, argv...), os.Environ())
	// Si arriva qui solo se exec fallisce.
	fmt.Fprintln(os.Stderr, "npz: exec di npm non riuscito:", err)
	os.Exit(127)
}

// ── dove il percorso lento comincerebbe ──────────────────────────────────────

// Lo spike si ferma qui e lo dichiara. Nel prodotto, questa e' la chiamata a
// cli.governa() — dove si e' gia' pagato tutto e i millisecondi non contano.
func lento(argv []string, progetto, stato string) {
	dice("percorso lento — qui lo spike di fase 0 si ferma.")
	if progetto == "" {
		dice("  progetto: (nessuno)")
	} else {
		dice("  progetto: " + progetto)
	}
	dice("  stato:    "+stato, "  classe:   "+classifica(argv))
	chiudi()
	os.Exit(0)
}

// ── main: il percorso veloce, riga per riga come lanciatore.py ───────────────

func main() {
	argv := os.Args[1:]

	// Sonda di servizio per il banco: stampa lo stato e esce. Non esiste nel
	// prodotto — serve a provare la macchina a stati senza montare niente.
	if os.Getenv("NPZ_SPIKE_STATO") != "" {
		fmt.Println(statoDi(trovaProgetto("")))
		return
	}

	if len(argv) == 0 {
		lento(argv, trovaProgetto(""), "")
	}

	classe := classifica(argv)
	if classe == nostro {
		lento(argv, trovaProgetto(""), "")
	}

	npm := trovaNpm(ioStesso())
	if npm == "" {
		dice("npm non si trova nel PATH.")
		chiudi()
		os.Exit(127)
	}

	// Prova del §6.1: apre un turno di parola prima di consegnare, cosi' il
	// banco puo' verificare che la coda esca *prima* dell'output di npm.
	if os.Getenv("NPZ_SPIKE_PARLA") != "" {
		dice("turno aperto prima di Exec: la coda deve uscire qui sotto.")
	}

	progetto := trovaProgetto("")
	stato := statoDi(progetto)

	// Fuori da un progetto, o in un progetto che non ci riguarda, npz non
	// esiste: si consegna il comando e si sparisce.
	if stato == estraneo || stato == rifiutato || stato == vergine {
		consegna(npm, argv)
	}

	// Il caso caldo: montato, e il comando non tocca l'albero.
	if stato == montato && classe == neutro {
		consegna(npm, argv)
	}

	lento(argv, progetto, stato)
}
