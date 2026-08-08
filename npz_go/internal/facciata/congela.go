// Il congelamento, e la domanda che lo precede.

package facciata

import (
	"bufio"
	"os"
	"strconv"
	"strings"

	"io/fs"
	"npz/internal/nucleo"
	"npz/internal/voce"
	"path/filepath"
)

// Congela applica i tre tempi. La cartella non sparisce finche' l'immagine non
// e' verificata.
func Congela(radice string) error {
	// Si sveglia prima di cominciare: costruire dentro il nome "fermo" per poi
	// rinominarlo lascerebbe, se qualcosa va storto a meta', una cartella che si
	// dichiara a riposo mentre contiene un'immagine incompleta.
	Sveglia(radice)
	cartella := CartellaDi(radice)
	p := Percorsi(radice)
	backend, err := nucleo.Scegli("", radice)
	if err != nil {
		return err
	}

	attivi, err := nucleo.ProcessiAttivi(cartella) // guarda /proc, non l'albero
	if err != nil {
		return err
	}
	if len(attivi) > 0 {
		return &nucleo.Errore{Messaggio: "there are processes using node_modules:\n  " +
			strings.Join(attivi, "\n  ") + "\nClose them and retry."}
	}
	if _, err := PreparaServizio(radice); err != nil {
		return err
	}
	if !esiste(ServizioDi(radice) + "/config") {
		if err := nucleo.ScriviConfig(ProfiloDi(radice), radice, ""); err != nil {
			return err
		}
	}
	config, err := nucleo.LeggiConfig(ProfiloDi(radice), radice)
	if err != nil {
		return err
	}
	compressione, _ := config["compressione"].(string)

	// **Una passata sola sull'albero originale**, e da quella esce tutto: la
	// fotografia che la verifica confrontera' con l'immagine, i conteggi per i
	// metadati, e gli uid per l'avviso sull'ownership. Prima erano due — si
	// contava qui e si rifotografava dentro Verifica — su un albero che sta sul
	// disco lento, che e' il piu' caro dei due che si attraversano.
	//
	// La fotografia si scatta **prima** della costruzione e non dopo, ed e' la
	// sola conseguenza vera del cambio: l'immagine finisce per essere confrontata
	// con quel che c'era quando si e' deciso di congelare, invece che con lo
	// stato in cui l'albero si trova alla fine. Non e' piu' debole — chi scrive
	// nell'albero durante il congelamento lo intercetta ProcessiAttivi — ed e' la
	// domanda piu' sensata delle due.
	atteso, err := nucleo.Inventario(cartella, func(n int, _ int64) {
		voce.Avanzamento("reading node_modules … %s entries", gruppi(n))
	})
	if err != nil {
		return err
	}
	file, byte, cartelle := nucleo.Misura(atteso)
	nostro := uint32(os.Getuid())
	var altrui []string
	for _, u := range nucleo.UidVisti(atteso) {
		if u != nostro {
			altrui = append(altrui, strconv.FormatUint(uint64(u), 10))
		}
	}
	if len(altrui) > 0 && os.Geteuid() != 0 {
		voce.Dici("warning: there are files owned by other users (uid %s).",
			strings.Join(altrui, ", "))
	}
	voci := file + cartelle

	l, err := nucleo.Lock(ProfiloDi(radice), radice)
	if err != nil {
		return err
	}
	guadagno, err := func() (int64, error) {
		defer l.Rilascia()

		// tempo 1 — si costruisce, e si verifica prima di crederci.
		voce.Dici("building the node_modules image (%s files, %s) …",
			gruppi(file), nucleo.Leggibile(byte))
		temporanea, err := nucleo.Costruisci(cartella, p.Immagine, compressione, nil,
			func(n int, _ int64) {
				voce.Avanzamento("building the image … %s%s",
					Quanto(n, voci), cresciuta(p.Immagine+".new"))
			})
		if err != nil {
			return 0, err
		}
		if err := nucleo.Verifica(temporanea, cartella, p.Basso, backend,
			func(n int, quale string) {
				voce.Avanzamento("verifying against %s … %s", quale, Quanto(n, voci))
			}, atteso); err != nil {
			os.Remove(temporanea)
			return 0, err
		}

		meta := map[string]any{
			"percorso": Relativo, "creata": nucleo.Adesso(), "incardinata": nil,
			"compressione": compressione, "file": file, "byte": byte,
			// `cartelle` serve a chi dovra' mostrare un avanzamento senza
			// ricontare — detach, oggi. E' additiva, quindi FORMATO non si
			// muove: un .meta senza la chiave resta leggibile, e chi la legge
			// sa farne a meno.
			"cartelle": cartelle,
		}
		// tempo 2 — si applica, con un rename atomico.
		if err := os.Rename(temporanea, p.Immagine); err != nil {
			return 0, &nucleo.Errore{Messaggio: "can't apply the image: " + err.Error()}
		}
		if err := nucleo.ScriviMeta(p.Meta, meta); err != nil {
			return 0, err
		}
		if err := os.MkdirAll(p.Delta, 0o755); err != nil {
			return 0, &nucleo.Errore{Messaggio: "can't create the delta: " + err.Error()}
		}

		// tempo 3 — solo adesso si cancella.
		if err := cancella(cartella, voci); err != nil {
			return 0, &nucleo.Errore{Messaggio: "can't remove node_modules: " + err.Error()}
		}
		fi, err := os.Stat(p.Immagine)
		if err != nil {
			return 0, &nucleo.Errore{Messaggio: "can't stat the image: " + err.Error()}
		}
		return fi.Size(), nil
	}()
	if err != nil {
		return err
	}

	voce.Dici("attached: %d files (%s) → one file (%s)",
		file, nucleo.Leggibile(byte), nucleo.Leggibile(guadagno))
	return nil
}

// ── la domanda ───────────────────────────────────────────────────────────────

// SiPuoChiedere dice se c'e' qualcuno a cui chiedere.
//
// Si guarda **prima** di calcolare quel che andrebbe nella domanda: contare un
// node_modules vero costa una passata sull'albero, e farla per poi scoprire che
// non si puo' chiedere e' lavoro buttato su ogni comando.
func SiPuoChiedere() bool {
	fi, err := os.Stdin.Stat()
	if err != nil || fi.Mode()&os.ModeCharDevice == 0 {
		return false
	}
	return os.Getenv("CI") == ""
}

// Chiedi chiede sul terminale e restituisce la lettera scelta, o "".
//
// **"" non e' un rifiuto**: e' "non c'e' nessuno a cui chiedere". Chi chiama
// deve avere una via che non passa dalla domanda — una domanda che non si e' in
// grado di porre non va posta, e in CI resterebbe senza risposta per sempre.
//
// `dopo` sono le righe da dire secondo la risposta, sullo stesso terminale e
// **dentro la stessa sbarra**: sono la risposta alla domanda appena fatta, non
// un messaggio nuovo.
func Chiedi(righe []string, domanda, ammesse, difetto string, dopo map[string]string) string {
	if !SiPuoChiedere() {
		return ""
	}
	// Due handle separati e non uno in lettura-scrittura: sul terminale
	// quest'ultimo dava problemi anche in Python, e la domanda non compariva
	// mai — un guasto invisibile.
	uscita, err := os.OpenFile("/dev/tty", os.O_WRONLY, 0)
	if err != nil {
		return ""
	}
	defer uscita.Close()
	ingresso, err := os.Open("/dev/tty")
	if err != nil {
		return ""
	}
	defer ingresso.Close()

	// Anche la domanda porta il segno: chi la legge deve sapere che a chiedere
	// e' npz, non npm. La sbarra si apre sul terminale e non su stderr, quindi
	// quella eventualmente aperta altrove va prima chiusa: due sbarre aperte
	// insieme sullo stesso terminale si intreccerebbero.
	voce.ChiudiTutto()
	voce.Su(uscita, false, strings.Join(righe, "\n"))
	_, _ = uscita.WriteString(voce.Segno(uscita, false) + domanda)

	lettore := bufio.NewReader(ingresso)
	riga, _ := lettore.ReadString('\n')
	risposta := strings.ToLower(strings.TrimSpace(riga))
	scelta := difetto
	if len(risposta) > 0 && strings.Contains(ammesse, risposta[:1]) {
		scelta = risposta[:1]
	}
	if dopo != nil {
		if testo, c := dopo[scelta]; c {
			voce.Su(uscita, false, testo)
		}
	}
	voce.Chiudi(uscita) // la coda, prima che l'handle si chiuda
	return scelta
}

// Proponi chiede una volta sola, e ricorda anche il no.
//
// Se non si e' potuto chiedere npz si fa da parte in silenzio **senza segnare
// nulla**, perche' un rifiuto registrato in CI resterebbe li' per sempre.
func Proponi(radice string) bool {
	if !SiPuoChiedere() {
		return false
	}
	file, byte, _, err := nucleo.Conta(CartellaDi(radice), nil)
	if err != nil {
		return false
	}
	scelta := Chiedi([]string{
		"this project has a node_modules with " + strconv.Itoa(file) +
			" files (" + nucleo.Leggibile(byte) + ").",
		"I can attach npz to it: a single image, mounted in its place:",
		"  · disk space drops by about two-thirds, inodes to one",
		"  · everything keeps working exactly as before",
		"  · you can always go back with `npz detach`",
	}, "Proceed? [y/N] ", "yn", "n",
		map[string]string{"n": "okay, I won't ask again. Delete .npz/no to change your mind."})

	if scelta == "" {
		return false
	}
	if scelta == "y" {
		return true
	}
	SegnaRifiuto(radice)
	return false
}

// cancella rimuove l'albero raccontandolo. os.RemoveAll chiude quel che resta.
//
// Cancellare 100.000 file su un disco lento era l'ultima fase muta rimasta, e
// arriva quando l'utente ha gia' aspettato parecchio: il momento peggiore per
// smettere di parlare. Si scende dal fondo, perche' una directory si rimuove
// solo da vuota.
//
// Il RemoveAll finale non e' una ridondanza e non ignora gli errori: se qualcosa
// e' sfuggito al giro deve sparire comunque, e se non ci riesce deve protestare
// come prima. Un node_modules cancellato a meta' e' l'unico esito che npz non
// lascia mai.
func cancella(cartella string, totale int) error {
	fatti := 0
	riferisci := nucleo.Battito(func(n int, _ int64) {
		voce.Avanzamento("removing the original folder … %s", Quanto(n, totale))
	})
	var dentro []string
	_ = filepath.WalkDir(cartella, func(p string, d fs.DirEntry, e error) error {
		if e != nil {
			return nil
		}
		if d.IsDir() {
			dentro = append(dentro, p)
			return nil
		}
		_ = os.Remove(p) // ci ripassa RemoveAll, che sa protestare
		fatti++
		riferisci(fatti, -1)
		return nil
	})
	for i := len(dentro) - 1; i >= 0; i-- {
		_ = os.Remove(dentro[i])
		fatti++
	}
	return os.RemoveAll(cartella)
}
