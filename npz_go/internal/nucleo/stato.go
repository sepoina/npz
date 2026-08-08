// Lo stato su disco: lock, configurazione, metadati.
//
// Il `.meta` accanto all'immagine e' la fonte di verita': tutto il resto se ne
// deriva.

package nucleo

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// ── il lock ──────────────────────────────────────────────────────────────────

// Lucchetto e' il lock esclusivo sulla radice. Tiene aperto il descrittore
// perche' e' il descrittore a portare il flock: se il file venisse chiuso — o
// raccolto dal GC — il lock cadrebbe da solo, in silenzio.
type Lucchetto struct {
	fh *os.File
}

// Lock prende un solo lock per tutta la radice, esclusivo, su ogni operazione
// che scrive.
//
// Granulare si potra' sempre diventare; introdurre il *primo* lock in un codice
// scritto assumendo l'esclusivita' e' invece doloroso.
//
// La proprieta' che serve — il lock si rilascia da solo alla morte del processo
// — e' del kernel e non del linguaggio: flock la garantisce anche se npz muore
// per un segnale senza eseguire nulla di differito. E' la ragione per cui il §3
// del piano aveva scartato Node, che flock non ce l'ha.
func Lock(profilo Profilo, radice string) (*Lucchetto, error) {
	percorso := filepath.Join(radice, profilo.Servizio, "lock")
	if err := os.MkdirAll(filepath.Dir(percorso), 0o755); err != nil {
		return nil, errf("can't create %s: %v", filepath.Dir(percorso), err)
	}
	fh, err := os.OpenFile(percorso, os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, errf("can't open the lock %s: %v", percorso, err)
	}
	if err := syscall.Flock(int(fh.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		fh.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			// Il messaggio non nomina la facciata: da qui passa chiunque, e il
			// nucleo non sa chi sta servendo. Dire un nome di comando a chi ne
			// ha battuto un altro manderebbe a cercare la cosa sbagliata.
			return nil, &Errore{Messaggio: "another operation is already running here.\n" +
				"Wait for it to finish, or check that no process is left hanging."}
		}
		return nil, errf("can't lock %s: %v", percorso, err)
	}
	return &Lucchetto{fh: fh}, nil
}

// Rilascia sblocca e chiude. Va messo in un defer subito dopo Lock.
func (l *Lucchetto) Rilascia() error {
	if l == nil || l.fh == nil {
		return nil
	}
	err := syscall.Flock(int(l.fh.Fd()), syscall.LOCK_UN)
	if e := l.fh.Close(); err == nil {
		err = e
	}
	l.fh = nil
	return err
}

// Adesso e' l'istante corrente nella grafia che finisce nei metadati.
// Corrisponde a datetime.now().replace(microsecond=0).isoformat(sep=" ").
func Adesso() string {
	return time.Now().Format("2006-01-02 15:04:05")
}

// ── configurazione della radice ──────────────────────────────────────────────

// Config e' il contenuto di `<servizio>/config`.
//
// E' una struct e non una mappa perche' i campi JSON escano nello **stesso
// ordine** del Python: encoding/json ordina le mappe alfabeticamente, e un
// `config` scritto da Go dovrebbe essere byte per byte quello che scriverebbe
// il Python — e' la prova piu' facile da fare e la piu' facile da rompere.
type Config struct {
	Formato      int    `json:"formato"`
	CreataDa     string `json:"creata_da"`
	Creata       string `json:"creata"`
	Compressione string `json:"compressione"`
}

func ScriviConfig(profilo Profilo, radice, compressione string) error {
	if compressione == "" {
		compressione = Compressione
	}
	dati := Config{
		Formato:      Formato,
		CreataDa:     Versione,
		Creata:       Adesso(),
		Compressione: compressione,
	}
	testo, err := json.MarshalIndent(dati, "", "  ")
	if err != nil {
		return errf("can't serialize the configuration: %v", err)
	}
	percorso := filepath.Join(radice, profilo.Servizio, "config")
	if err := os.WriteFile(percorso, append(testo, '\n'), 0o644); err != nil {
		return errf("can't write %s: %v", percorso, err)
	}
	return nil
}

func LeggiConfig(profilo Profilo, radice string) (map[string]any, error) {
	percorso := filepath.Join(radice, profilo.Servizio, "config")
	grezzo, err := os.ReadFile(percorso)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, errf("no configuration here: %s is missing", percorso)
		}
		return nil, errf("can't read %s: %v", percorso, err)
	}
	var dati map[string]any
	if err := json.Unmarshal(grezzo, &dati); err != nil {
		return nil, errf("unreadable configuration in %s: %v", percorso, err)
	}

	formato, _ := dati["formato"].(float64) // JSON non ha interi: sono float64
	if int(formato) != Formato {
		creataDa := "unknown"
		if s, ok := dati["creata_da"].(string); ok {
			creataDa = s
		}
		mostrato := any(int(formato))
		if _, c := dati["formato"]; !c {
			mostrato = "None"
		}
		// Anche qui senza nome di facciata: vedi Lock.
		return nil, errf("this store uses format %v, this version speaks format %d.\n"+
			"Upgrade, or use the version that created it (%s).",
			mostrato, Formato, creataDa)
	}
	return dati, nil
}

// ── metadati di una immagine ─────────────────────────────────────────────────

// ScriviMeta scrive i metadati in modo atomico: prima il temporaneo, poi il
// rename. E' il terzo tempo applicato anche qui — non esiste un istante in cui
// il `.meta` sia a meta'.
//
// NOTA DI PORTING — i campi extra arrivano dalla facciata come mappa, e
// encoding/json ordina le chiavi di una mappa alfabeticamente mentre Python
// conserva l'ordine di inserimento. Il file risulta quindi **semanticamente
// identico ma non byte-identico** a quello del Python. Il `.meta` e' JSON e si
// legge parsato, quindi non e' un problema di formato; il banco della fase 1 lo
// confronta di conseguenza (parsato per il .meta, byte a byte per la .img).
func ScriviMeta(percorsoMeta string, dati map[string]any) error {
	if err := os.MkdirAll(filepath.Dir(percorsoMeta), 0o755); err != nil {
		return errf("can't create %s: %v", filepath.Dir(percorsoMeta), err)
	}
	completo := map[string]any{"formato": Formato}
	for k, v := range dati {
		completo[k] = v
	}
	testo, err := json.MarshalIndent(completo, "", "  ")
	if err != nil {
		return errf("can't serialize the metadata: %v", err)
	}
	tmp := percorsoMeta + ".tmp"
	if err := os.WriteFile(tmp, append(testo, '\n'), 0o644); err != nil {
		return errf("can't write %s: %v", tmp, err)
	}
	if err := os.Rename(tmp, percorsoMeta); err != nil {
		os.Remove(tmp)
		return errf("can't replace %s: %v", percorsoMeta, err)
	}
	return nil
}

func LeggiMeta(percorsoMeta string) (map[string]any, error) {
	grezzo, err := os.ReadFile(percorsoMeta)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, errf("missing metadata: %s", percorsoMeta)
		}
		return nil, errf("can't read %s: %v", percorsoMeta, err)
	}
	var dati map[string]any
	if err := json.Unmarshal(grezzo, &dati); err != nil {
		return nil, errf("unreadable metadata in %s: %v", percorsoMeta, err)
	}
	return dati, nil
}

// Leggibile formatta dei byte per un umano.
func Leggibile(byte int64) string {
	valore := float64(byte)
	for _, unita := range []string{"B", "KiB", "MiB", "GiB", "TiB"} {
		if valore < 1024 && valore > -1024 {
			if unita == "B" {
				return fmt.Sprintf("%.0f B", valore)
			}
			return fmt.Sprintf("%.1f %s", valore, unita)
		}
		valore /= 1024
	}
	return fmt.Sprintf("%.1f PiB", valore)
}
