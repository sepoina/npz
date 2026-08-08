// Il progetto: l'opposto della risalita di `freeze`.
//
// `freeze` cerca una cartella di servizio dichiarata a mano con `init`, e si
// rifiuta di annidarne due. Qui la radice **non si dichiara**: e' il progetto
// stesso, e la si riconosce dal package.json. Ne segue che due progetti annidati
// — un workspace dentro un monorepo — sono legittimi, e ognuno ha il proprio
// `.npz`.

package facciata

import (
	"os"
	"path/filepath"
	"strings"

	"fmt"
	"npz/internal/nucleo"
	"strconv"
	"unicode/utf8"
)

// Richiedi da' il progetto o un errore leggibile.
func Richiedi(partenza string) (string, error) {
	progetto := TrovaProgetto(partenza)
	if progetto == "" {
		return "", &nucleo.Errore{Messaggio: "you're not inside a project: no " +
			Manifesto + " above here.\nnpz works wherever npm works."}
	}
	return progetto, nil
}

// ServizioDi da' la cartella di servizio, con il nome che ha *adesso*.
func ServizioDi(progetto string) string {
	nome := NomeServizio(progetto)
	if nome == "" {
		nome = Servizio
	}
	return filepath.Join(progetto, nome)
}

// ProfiloDi da' il profilo da dare al nucleo, intonato al nome corrente.
//
// E' esattamente cio' che il Profilo ha reso possibile: il nucleo non sa come
// si chiami la cartella di servizio, e non deve saperlo.
func ProfiloDi(progetto string) nucleo.Profilo {
	return nucleo.Profilo{
		Servizio:   filepath.Base(ServizioDi(progetto)),
		Sentinella: PROFILO.Sentinella,
	}
}

// CartellaDi e' il node_modules del progetto.
func CartellaDi(progetto string) string {
	return filepath.Join(progetto, Cartella)
}

// effimere: le sottocartelle che esistono solo mentre si e' montati. Dentro
// `run/` ci sta tutto lo stato di esercizio — `lower` con l'immagine montata,
// `work` con lo scratch di overlayfs, `merged` durante un consolidamento — e
// nessuna delle tre significa piu' niente a mount spento. Il montaggio le
// ricrea tutte con un mkdir, quindi tenerle da fermi e' solo rumore dentro una
// cartella che deve spiegarsi da sola. Che siano una sola voce e non due sparse
// e' cio' che rende questa riga una regola invece di un elenco da aggiornare.
var effimere = [...]string{"run"}

// Addormenta va da `.npz` al nome visibile: la cartella e' ferma e lo dichiara.
//
// La rinomina va fatta **fuori dal lock**: il file di lock vive dentro la
// cartella che si rinomina, e un secondo processo che avesse gia' risolto il
// vecchio nome lo troverebbe sparito fra NomeServizio() e l'apertura. flock sta
// sull'inode e sopravvive alla rinomina, quindi l'esclusione regge; e' la
// finestra di risoluzione del nome che va tenuta stretta.
func Addormenta(progetto string) {
	corrente := filepath.Join(progetto, Servizio)
	fermo := filepath.Join(progetto, ServizioFermo)
	if !eDir(corrente) || esiste(fermo) {
		return
	}
	for _, e := range effimere {
		os.RemoveAll(filepath.Join(corrente, e))
	}
	_ = os.Rename(corrente, fermo)
}

// Sveglia va dal nome visibile a `.npz`: si torna a lavorare, e la cartella si
// nasconde.
func Sveglia(progetto string) {
	fermo := filepath.Join(progetto, ServizioFermo)
	corrente := filepath.Join(progetto, Servizio)
	if eDir(fermo) && !esiste(corrente) {
		_ = os.Rename(fermo, corrente)
	}
}

// VerificaIdoneita rifiuta i supporti su cui npz non potrebbe funzionare, e dice
// come fare.
//
// Il giudizio e' di nucleo.Idoneita(); qui si aggiunge il **rimedio**, che nel
// nucleo non puo' stare: nomina convenzioni di distribuzione, un driver e un
// file di configurazione, e sono tutte cose che il nucleo non sa e non deve
// sapere.
//
// Il rimedio si compone solo quando c'e' davvero, ed e' misurato invece che
// indovinato: device e UUID da mountinfo e da /dev/disk/by-uuid, il nome del
// driver dalla riga di comando del demone. Dove uno di questi manca — un mount
// di rete, un tmpfs, una immagine dentro un file — non si propone niente,
// perche' un fstab per UUID li' non esiste.
func VerificaIdoneita(progetto string) error {
	motivo := nucleo.Idoneita(progetto)
	if motivo == "" {
		return nil
	}
	righe := []string{"npz can't work here: " + motivo + "."}
	if rimedio := rimedio(nucleo.Sonda(progetto)); len(rimedio) > 0 {
		righe = append(righe, rimedio...)
	} else {
		tipo := nucleo.TipoFilesystem(progetto)
		if tipo == "" {
			tipo = "unknown"
		}
		righe = append(righe, "The filesystem is "+tipo+
			". Move the project to a local POSIX filesystem.")
	}
	return &nucleo.Errore{Messaggio: strings.Join(righe, "\n")}
}

// I driver NTFS in user space. Il rimedio si scrive solo per questi: e' l'unico
// caso in cui sappiamo davvero quale riga di fstab funzionerebbe.
var driverNtfs = map[string]bool{
	"mount.ntfs": true, "ntfs-3g": true, "mount.ntfs-3g": true,
	"lowntfs-3g": true, "mount.lowntfs-3g": true,
}

// rimedio dice come rimontare il disco perche' i file siano nostri, o nil.
func rimedio(s nucleo.Supporto) []string {
	if !s.ProprietarioEstraneo || !s.Device() {
		return nil
	}
	punto := nucleo.PuntoDiMount(s.Percorso)
	driver := nucleo.DriverDiMount(s.Sorgente, punto)
	if punto == "" || !driverNtfs[driver] {
		return nil
	}
	// In fstab va il **tipo**, non l'aiutante: mount cerca `mount.<tipo>`, e
	// scriverci `mount.ntfs` gli farebbe cercare `mount.mount.ntfs`. Il tipo si
	// ricava togliendo il prefisso, ed e' giusto per costruzione: l'aiutante lo
	// abbiamo trovato perche' e' lui a servire questo mount.
	tipo := strings.TrimPrefix(driver, "mount.")
	uid, gid := os.Geteuid(), os.Getegid()
	C, Z := accento()
	return []string{
		"",
		avvolgi(fmt.Sprintf(
			"%s is elastic about permissions: it takes any chmod and quietly "+
				"drops it. The overlay npz puts on top is not — only an owner may "+
				"change a mode — so npm's chmod on the shims it installs comes back "+
				"EPERM and the install stops.", tipo)),
		"",
		"Remount it as yours, as root:",
		fmt.Sprintf("  %sumount %s%s", C, punto, Z),
		fmt.Sprintf("  %s%s -o uid=%d,gid=%d,allow_other %s %s%s",
			C, driver, uid, gid, s.Sorgente, punto, Z),
		"",
		"To keep it, in /etc/fstab:",
		fmt.Sprintf("  %sUUID=%s %s %s uid=%d,gid=%d,allow_other,nofail 0 0%s",
			C, s.Uuid, punto, tipo, uid, gid, Z),
		"",
		avvolgi(fmt.Sprintf(
			"allow_other needs user_allow_other in /etc/fuse.conf, or "+
				"node_modules can't be mounted inside a path on %s.", s.Tipo)),
	}
}

// accento da' ciano e spegnimento per i comandi, o due stringhe vuote se non
// c'e' un terminale.
//
// Gli errori escono su **stderr**: e' li' che si guarda se c'e' un terminale, e
// non su stdout, che potrebbe essere in una pipe mentre il terminale c'e' lo
// stesso. E' lo stesso ciano che l'aiuto mette sui nomi dei comandi — qui come
// la' colora *quel che si digita*, che e' l'unica cosa in un messaggio d'errore
// a cui serva saltare all'occhio.
func accento() (string, string) {
	fi, err := os.Stderr.Stat()
	if err != nil || fi.Mode()&os.ModeCharDevice == 0 {
		return "", ""
	}
	return "\033[36m", "\033[0m"
}

// avvolgi manda a capo alla larghezza utile del terminale, entro 120 colonne.
//
// Utile e' quella che resta tolta la sbarra, che voce.Su antepone a ogni riga:
// mandare a capo a 120 e poi vederne stampate 124 vanificherebbe il lavoro. Il
// tetto a 120 c'e' perche' una riga di prosa larga quanto un terminale a schermo
// intero non si legge — l'occhio perde il capo.
//
// I comandi non passano di qui: si spezzano dove capita, e uno spezzato non si
// puo' copiare. Meglio che sia il terminale a mandarlo a capo come vuole.
func avvolgi(testo string) string {
	larghezza := colonne() - 4 // la sbarra: " ║  "
	if larghezza < 40 {
		larghezza = 40
	}
	var righe []string
	corrente := ""
	for _, parola := range strings.Fields(testo) {
		if corrente == "" {
			corrente = parola
			continue
		}
		if utf8.RuneCountInString(corrente)+1+utf8.RuneCountInString(parola) > larghezza {
			righe = append(righe, corrente)
			corrente = parola
			continue
		}
		corrente += " " + parola
	}
	if corrente != "" {
		righe = append(righe, corrente)
	}
	return strings.Join(righe, "\n")
}

// colonne e' la larghezza del terminale, entro 120. Si legge da COLUMNS, che e'
// quel che la shell esporta; senza, si assume 80, che e' il minimo storico e non
// sfigura da nessuna parte.
func colonne() int {
	larghezza := 80
	if v := os.Getenv("COLUMNS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			larghezza = n
		}
	}
	if larghezza > 120 {
		larghezza = 120
	}
	return larghezza
}

// PreparaServizio crea `.npz/` e la esclude da git, senza toccare il .gitignore
// dell'utente.
//
// `.git/info/exclude` e' il posto giusto: non e' versionato, quindi non compare
// nei diff di nessuno, e non si sovrappone a scelte che l'utente ha gia' fatto
// nel proprio .gitignore.
func PreparaServizio(progetto string) (string, error) {
	dove := ServizioDi(progetto)
	// Solo le due che contengono dati: `run/` la fa nascere il montaggio, ed e'
	// giusto che una cartella di servizio appena creata non ce l'abbia — non
	// c'e' ancora niente in esercizio.
	for _, sotto := range [...]string{"static", "dynamic"} {
		if err := os.MkdirAll(filepath.Join(dove, sotto), 0o755); err != nil {
			return "", &nucleo.Errore{Messaggio: "can't create " + dove + ": " + err.Error()}
		}
	}

	esclusioni := filepath.Join(progetto, ".git", "info", "exclude")
	if eDir(filepath.Dir(esclusioni)) {
		// Non poter escludere non e' un motivo per fermarsi: ogni errore qui
		// sotto si ignora di proposito.
		var righe []string
		if grezzo, err := os.ReadFile(esclusioni); err == nil {
			righe = strings.Split(string(grezzo), "\n")
		}
		// Tutti e tre i nomi: la cartella di servizio ne cambia uno a seconda
		// dello stato, ed escluderne uno solo la farebbe ricomparire fra gli
		// untracked appena il progetto va a riposo. Il terzo e' l'albero messo
		// da parte dopo uno scavalcamento (§6 bis): sta nella radice di
		// progetto, in vista, e non e' roba da committare.
		var mancanti []string
		for _, n := range [...]string{Servizio, ServizioFermo, AlberoSuperato} {
			if !contiene(righe, n+"/") {
				mancanti = append(mancanti, n+"/")
			}
		}
		if len(mancanti) > 0 {
			if fh, err := os.OpenFile(esclusioni, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
				_, _ = fh.WriteString("\n# added by npz\n" + strings.Join(mancanti, "\n") + "\n")
				fh.Close()
			}
		}
	}
	return dove, nil
}

// SegnaRifiuto ricorda che l'utente ha detto no.
//
// Un file vuoto e non una chiave in una configurazione: il percorso veloce lo
// legge con uno Stat, senza aprire ne' analizzare niente. E ricordare il "no" e'
// importante quanto ricordare il "si'" — senza, si richiederebbe a ogni
// comando, per sempre.
func SegnaRifiuto(progetto string) {
	dove := ServizioDi(progetto)
	if err := os.MkdirAll(dove, 0o755); err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(dove, "no"),
		[]byte("npz isn't managing this project: the user answered no.\n"+
			"Delete this file to be asked again.\n"), 0o644)
}
