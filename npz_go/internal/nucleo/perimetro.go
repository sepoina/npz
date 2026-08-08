// Cosa si puo' congelare.
//
// Il perimetro e' corto perche' EROFS regge quasi tutto: hardlink con il loro
// inode, fifo, socket, device node, symlink rotti, xattr e permessi; e i file
// sparsi non vengono riespansi, perche' la compressione riduce gli zeri a
// nulla. I divieti che il progetto si era dato all'inizio erano imposti
// dall'object store, e sono caduti con lui.
//
// Restano due casi, e in nessuno dei due si procede saltando in silenzio cio'
// che non si sa gestire: saltare significa perdere senza dirlo.

package nucleo

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ProcessiAttivi dice chi sta usando *questa cartella*. Vuoto se nessuno.
//
// Si guarda /proc a mano invece di chiamare `fuser`: `fuser -m` ragiona per
// **filesystem montato**, non per directory, quindi su una cartella dentro `/`
// elenca ogni processo del sistema. Sembra funzionare — trova sempre qualcosa —
// ed e' esattamente per questo che era pericoloso.
//
// Guarda cwd, root e i descrittori aperti. I processi di altri utenti sono
// leggibili solo in parte senza privilegi: quello che si vede si riporta,
// quello che non si vede non si inventa.
func ProcessiAttivi(cartella string) ([]string, error) {
	obiettivo, err := filepath.EvalSymlinks(cartella)
	if err != nil {
		obiettivo = filepath.Clean(cartella)
	}
	prefisso := obiettivo + string(filepath.Separator)

	voci, err := os.ReadDir("/proc")
	if err != nil {
		return nil, errf("can't read /proc: %v", err)
	}
	var trovati []string
	for _, v := range voci {
		if !soloCifre(v.Name()) {
			continue
		}
		proc := filepath.Join("/proc", v.Name())
		if tocca(proc, obiettivo, prefisso) {
			trovati = append(trovati, fmt.Sprintf("pid %s (%s)",
				v.Name(), NomeProcesso(v.Name())))
		}
	}
	return trovati, nil
}

func soloCifre(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func tocca(proc, obiettivo, prefisso string) bool {
	for _, dove := range []string{"cwd", "root"} {
		if d := link(filepath.Join(proc, dove)); d != "" {
			if d == obiettivo || strings.HasPrefix(d, prefisso) {
				return true
			}
		}
	}
	descrittori, err := os.ReadDir(filepath.Join(proc, "fd"))
	if err != nil {
		return false
	}
	for _, fd := range descrittori {
		if d := link(filepath.Join(proc, "fd", fd.Name())); d != "" {
			if d == obiettivo || strings.HasPrefix(d, prefisso) {
				return true
			}
		}
	}
	return false
}

func link(percorso string) string {
	d, err := os.Readlink(percorso)
	if err != nil {
		return ""
	}
	return d
}

func NomeProcesso(pid string) string {
	grezzo, err := os.ReadFile(filepath.Join("/proc", pid, "comm"))
	if err != nil {
		return "?"
	}
	return strings.TrimSpace(string(grezzo))
}

// OwnershipEstranea da' gli uid diversi dal nostro presenti nell'albero.
//
// Non impedisce il freeze: uid e gid finiscono correttamente nell'immagine. Ma
// un mount FUSE non privilegiato non li rende accessibili agli altri utenti
// senza `allow_other`, e l'utente va avvisato prima, non dopo.
//
// OwnershipEstranea da' gli uid diversi dal nostro presenti nell'albero.
//
// Non impedisce il freeze: uid e gid finiscono correttamente nell'immagine. Ma
// un mount FUSE non privilegiato non li rende accessibili agli altri utenti
// senza `allow_other`, e l'utente va avvisato prima, non dopo.
//
// E' una **vista** su Censisci, che quella passata la fa gia' per contare. Chi
// vuole entrambe le risposte chieda quella e le prenda insieme: su centomila
// file serviti da FUSE attraversare due volte costa 24 secondi dove una ne costa
// 14, ed e' tempo speso tutto prima che il lavoro cominci.
func OwnershipEstranea(cartella string) ([]uint32, error) {
	_, _, _, uid, err := Censisci(cartella, nil)
	if err != nil {
		return nil, err
	}
	nostro := uint32(os.Getuid())
	altrui := make([]uint32, 0, len(uid))
	for _, u := range uid {
		if u != nostro {
			altrui = append(altrui, u)
		}
	}
	return altrui, nil
}

// Controlla non c'e' piu'. Univa i due controlli in una chiamata, ma li pagava
// in due passate; adesso l'unica passata la fa Censisci, e chi congela chiama
// ProcessiAttivi — che guarda /proc, non l'albero — e Censisci, prendendosi
// conteggi e uid insieme.
