// Il montaggio, dietro una sola interfaccia.
//
// Due implementazioni fin da subito. **FUSE e' quella normale**: `erofsfuse`
// per lo strato di sola lettura, `fuse-overlayfs` per il delta, e non serve
// alcun privilegio. Il kernel e' l'ottimizzazione per quando root e'
// disponibile: piu' veloce, stessa semantica.
//
// Che la via non privilegiata esista e' una conseguenza dell'aver rinunciato
// all'object store: `fuse-overlayfs` non implementa i layer *data-only*, che
// erano il meccanismo con cui l'immagine rimandava agli oggetti condivisi.

package nucleo

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Backend e' la sola interfaccia del montaggio. Le due implementazioni ci
// stanno dietro e il chiamante non sa quale ha in mano.
type Backend interface {
	Nome() string
	Disponibile() bool

	// MontaRO monta la sola immagine, in sola lettura.
	MontaRO(immagine, punto string) error

	// MontaStack sovrappone il delta scrivibile a uno strato gia' montato.
	MontaStack(basso, delta, lavoro, punto string) error

	// MontaFusione da' la vista fusa in sola lettura, dal delta piu' recente al
	// piu' vecchio. E' quella che si da' a mkfs.erofs per consolidare: il merge
	// lo fa il kernel, e non c'e' logica di whiteout da scrivere.
	MontaFusione(strati []string, punto string) error

	// Smonta stacca il punto. Con pigro=true lo stacca subito e libera quando
	// l'ultimo descrittore si chiude.
	//
	// Un mount tenuto da qualcuno non si smonta, e chi tiene un albero di
	// dipendenze e' quasi sempre un watcher o un language server. Lo smontaggio
	// pigro e' la via che resta a chi ha detto `--force`: il prezzo e' che le
	// scritture in volo finiscono in uno strato che nessuno rileggera' — per
	// questo non e' mai il comportamento predefinito.
	Smonta(punto string, pigro bool) error
}

// ── FUSE: la via normale, senza privilegi ────────────────────────────────────

type Fuse struct{}

func (Fuse) Nome() string { return "fuse" }

func (Fuse) Disponibile() bool {
	_, a := exec.LookPath("erofsfuse")
	_, b := exec.LookPath("fuse-overlayfs")
	return a == nil && b == nil
}

func (Fuse) MontaRO(immagine, punto string) error {
	if err := os.MkdirAll(punto, 0o755); err != nil {
		return errf("can't create %s: %v", punto, err)
	}
	return esegui("", "erofsfuse", immagine, punto)
}

func (Fuse) MontaStack(basso, delta, lavoro, punto string) error {
	for _, d := range []string{delta, lavoro} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return errf("can't create %s: %v", d, err)
		}
	}
	base, corti, err := accorcia(basso, delta, lavoro)
	if err != nil {
		return err
	}
	opzioni := "lowerdir=" + corti[0] + ",upperdir=" + corti[1] + ",workdir=" + corti[2]
	return esegui(base, "fuse-overlayfs", "-o", opzioni, punto)
}

func (Fuse) MontaFusione(strati []string, punto string) error {
	if err := os.MkdirAll(punto, 0o755); err != nil {
		return errf("can't create %s: %v", punto, err)
	}
	base, corti, err := accorcia(strati...)
	if err != nil {
		return err
	}
	return esegui(base, "fuse-overlayfs", "-o", "lowerdir="+strings.Join(corti, ":"), punto)
}

// Smonta stacca un mount FUSE, riprovando finche' e' **occupato da chi se ne sta
// andando**.
//
// `fusermount3 -u` stacca il punto dal namespace e torna subito, ma il demone
// che lo serviva esce per conto suo, un istante dopo. Chi smonta uno stack —
// prima l'overlay, poi l'immagine che gli faceva da lower — trova quindi il
// lower ancora tenuto da un fuse-overlayfs che non e' ancora morto, e si prende
// un EBUSY che al secondo tentativo non c'e' piu'. E' la corsa che faceva
// fallire `npz bye` una volta su tre, sempre sullo stesso punto.
//
// Si riprova per un tempo **corto e limitato**: la condizione dura
// millisecondi, e un mount tenuto davvero — un watcher, un language server —
// deve continuare a fallire, e in fretta, perche' il messaggio che nomina i
// processi e' piu' utile di qualunque attesa. Mezzo secondo copre la corsa e non
// si fa notare da nessuno.
//
// Con `pigro` non si riprova: `-uz` non fallisce per occupato, stacca e basta.
func (Fuse) Smonta(punto string, pigro bool) error {
	comando := "fusermount"
	if _, err := exec.LookPath("fusermount3"); err == nil {
		comando = "fusermount3"
	}
	if pigro {
		return esegui("", comando, "-uz", punto)
	}

	var ultimo error
	for tentativo := 0; tentativo < AttesaSmonta; tentativo++ {
		ultimo = esegui("", comando, "-u", punto)
		if ultimo == nil {
			return nil
		}
		if !occupato(ultimo) {
			return ultimo // un guasto vero: non lo si maschera aspettando
		}
		time.Sleep(RitmoSmonta)
	}
	return ultimo
}

// Quanto si insiste su un mount occupato: 25 tentativi ogni 20 ms, mezzo secondo
// in tutto. Misurato: il demone molla in molto meno.
const (
	AttesaSmonta = 25
	RitmoSmonta  = 20 * time.Millisecond
)

// occupato riconosce l'EBUSY, che fusermount3 riporta come testo perche' e' un
// programma esterno e non una syscall.
func occupato(err error) bool {
	if err == nil {
		return false
	}
	testo := strings.ToLower(err.Error())
	return strings.Contains(testo, "busy") || strings.Contains(testo, "ebusy")
}

// ── kernel: l'ottimizzazione, quando root c'e' ───────────────────────────────

type Kernel struct{}

func (Kernel) Nome() string      { return "kernel" }
func (Kernel) Disponibile() bool { return os.Geteuid() == 0 }

func (Kernel) MontaRO(immagine, punto string) error {
	if err := os.MkdirAll(punto, 0o755); err != nil {
		return errf("can't create %s: %v", punto, err)
	}
	return esegui("", "mount", "-t", "erofs", "-o", "loop,ro", immagine, punto)
}

func (Kernel) MontaStack(basso, delta, lavoro, punto string) error {
	for _, d := range []string{delta, lavoro} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return errf("can't create %s: %v", d, err)
		}
	}
	opzioni := "lowerdir=" + basso + ",upperdir=" + delta + ",workdir=" + lavoro
	return esegui("", "mount", "-t", "overlay", "overlay", "-o", opzioni, punto)
}

func (Kernel) MontaFusione(strati []string, punto string) error {
	if err := os.MkdirAll(punto, 0o755); err != nil {
		return errf("can't create %s: %v", punto, err)
	}
	opzioni := "lowerdir=" + strings.Join(strati, ":") + ",ro"
	return esegui("", "mount", "-t", "overlay", "overlay", "-o", opzioni, punto)
}

func (Kernel) Smonta(punto string, pigro bool) error {
	if pigro {
		return esegui("", "umount", "-l", punto)
	}
	return esegui("", "umount", punto)
}

// ── scelta ───────────────────────────────────────────────────────────────────

// Scegli restituisce FUSE se c'e', il kernel come alternativa. `preferito`
// forza la scelta.
//
// Con `percorso` si scarta anche la via kernel dove il suo overlayfs non
// accetterebbe l'upperdir — su FUSE, per dirne la sola che qui capita. Non e' un
// giudizio sul supporto: la via FUSE li' funziona, ed e' comunque quella
// preferita. Serve a non proporre da root un backend che fallirebbe al mount.
func Scegli(preferito, percorso string) (Backend, error) {
	var disponibili []Backend
	for _, b := range []Backend{Fuse{}, Kernel{}} {
		if b.Disponibile() {
			disponibili = append(disponibili, b)
		}
	}
	tipo, scartatoKernel := "", false
	if percorso != "" {
		tipo = TipoFilesystem(percorso)
		if !ReggeUpperdirKernel(tipo) {
			restanti := disponibili[:0]
			for _, b := range disponibili {
				if b.Nome() == "kernel" {
					scartatoKernel = true
					continue
				}
				restanti = append(restanti, b)
			}
			disponibili = restanti
		}
	}
	if len(disponibili) == 0 {
		// Se il kernel c'era e l'abbiamo scartato noi, dire "run as root" a chi
		// gia' e' root manderebbe a sbattere: il rimedio e' un altro.
		if scartatoKernel {
			return nil, errf("no way to mount images.\n"+
				"The kernel's overlayfs won't take an upperdir on %s, "+
				"so only the FUSE path works here.\n"+
				"Install erofsfuse and fuse-overlayfs.", tipo)
		}
		return nil, &Errore{Messaggio: "no way to mount images.\n" +
			"Install erofsfuse and fuse-overlayfs, or run as root."}
	}
	if preferito != "" {
		nomi := make([]string, 0, len(disponibili))
		for _, b := range disponibili {
			if b.Nome() == preferito {
				return b, nil
			}
			nomi = append(nomi, b.Nome())
		}
		return nil, errf("backend '%s' isn't available (available: %s)",
			preferito, strings.Join(nomi, ", "))
	}
	return disponibili[0], nil
}

// Montato replica os.path.ismount: la libreria standard di Go non ce l'ha.
// Si confronta il device con quello del genitore, e in caso di parita' l'inode
// — che e' come si riconosce la radice e come si riconoscono i bind mount sullo
// stesso device.
func Montato(punto string) bool {
	fi, err := os.Lstat(punto)
	if err != nil || fi.Mode()&os.ModeSymlink != 0 {
		return false
	}
	s1, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	genitore, err := filepath.EvalSymlinks(filepath.Join(punto, ".."))
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

// accorcia da' una base comune e i percorsi relativi a essa.
//
// Serve a `fuse-overlayfs`, che spezza il proprio `lowerdir` sui due punti e
// non sa che farsene di un percorso che ne contiene uno. Misurato: con un
// percorso assoluto che contiene `:` il montaggio fallisce con
// `cannot resolve path`; con gli stessi percorsi relativi, dopo un chdir,
// funziona. Gli spazi invece non danno alcun fastidio, in nessuna delle due
// forme.
//
// Non e' una precauzione teorica: i progetti degli utenti stanno in percorsi
// che non controlliamo.
func accorcia(percorsi ...string) (string, []string, error) {
	assoluti := make([]string, len(percorsi))
	for i, p := range percorsi {
		a, err := filepath.EvalSymlinks(p)
		if err != nil {
			a2, err2 := filepath.Abs(p)
			if err2 != nil {
				return "", nil, errf("can't resolve %s: %v", p, err)
			}
			a = a2
		}
		assoluti[i] = a
	}

	var base string
	if len(assoluti) > 1 {
		base = comune(assoluti)
	} else {
		base = filepath.Dir(assoluti[0])
	}

	corti := make([]string, len(assoluti))
	for i, a := range assoluti {
		r, err := filepath.Rel(base, a)
		if err != nil {
			return "", nil, errf("can't relativize %s against %s: %v", a, base, err)
		}
		corti[i] = r
	}
	return base, corti, nil
}

// comune e' os.path.commonpath: il prefisso comune **per componenti**, non per
// caratteri. `/a/bc` e `/a/bd` hanno in comune `/a`, non `/a/b`.
func comune(percorsi []string) string {
	pezzi := strings.Split(filepath.Clean(percorsi[0]), string(filepath.Separator))
	for _, p := range percorsi[1:] {
		altri := strings.Split(filepath.Clean(p), string(filepath.Separator))
		if len(altri) < len(pezzi) {
			pezzi = pezzi[:len(altri)]
		}
		for i := range pezzi {
			if pezzi[i] != altri[i] {
				pezzi = pezzi[:i]
				break
			}
		}
	}
	unito := strings.Join(pezzi, string(filepath.Separator))
	if unito == "" {
		return "/"
	}
	return unito
}

// esegui lancia un comando esterno e trasforma il fallimento in un *Errore con
// la prima riga di quel che ha detto. Mai una shell: i percorsi degli utenti
// contengono spazi, e qui gli argomenti restano separati per costruzione.
func esegui(cwd string, nome string, argomenti ...string) error {
	cmd := exec.Command(nome, argomenti...)
	if cwd != "" {
		cmd.Dir = cwd
	}
	var fuori, dentro strings.Builder
	cmd.Stdout = &fuori
	cmd.Stderr = &dentro
	if err := cmd.Run(); err != nil {
		testo := strings.TrimSpace(dentro.String())
		if testo == "" {
			testo = strings.TrimSpace(fuori.String())
		}
		righe := strings.Split(testo, "\n")
		if testo == "" {
			return errf("%s failed: %v", nome, err)
		}
		return errf("%s failed: %s", nome, righe[0])
	}
	return nil
}
