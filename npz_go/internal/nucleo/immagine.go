// La costruzione dell'immagine, e la verifica che la si possa credere.
//
// `mkfs.erofs` senza opzioni oltre alla compressione: verificato che cosi'
// conserva mode, mtime, uid, gid, xattr, symlink e hardlink. `-T0` azzera le
// mtime e `--all-time` le riscrive a adesso: entrambe romperebbero la fedelta'
// del ripristino.

package nucleo

import (
	"bufio"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// ── la catena inversa: dal percorso relativo ai posti dentro la radice ───────

// Percorsi sono i posti di una immagine, in due famiglie che non si mescolano.
//
// Immagine/Meta/Delta sono i **dati**: sopravvivono a tutto, e i loro nomi non
// si toccano — rinominarli renderebbe illeggibile ogni store gia' scritto, che
// e' il territorio di Formato.
//
// Basso/Lavoro sono lo **stato di esercizio**, e esistono solo mentre qualcosa
// e' montato: Basso dove si monta l'immagine, Lavoro il workdir che overlayfs
// esige sullo stesso filesystem del delta per poter materializzare un copy-up e
// spostarlo intero con un rename. Sono esattamente cio' che il montaggio
// ricrea con un mkdir e cio' che a riposo si puo' buttare via.
//
// NOTA DI PORTING — il Python restituisce un dict con cinque chiavi. Qui e' una
// struct: stessi nomi, stesso contenuto, ma sbagliare una chiave diventa un
// errore di compilazione invece di un KeyError a runtime.
type PercorsiImmagine struct {
	Immagine string
	Meta     string
	Delta    string
	Lavoro   string
	Basso    string
}

func Percorsi(profilo Profilo, radice, relativo string) PercorsiImmagine {
	servizio := filepath.Join(radice, profilo.Servizio)
	return PercorsiImmagine{
		Immagine: filepath.Join(servizio, "static", relativo+".img"),
		Meta:     filepath.Join(servizio, "static", relativo+".meta"),
		Delta:    filepath.Join(servizio, "dynamic", relativo),
		Lavoro:   filepath.Join(servizio, "run", relativo, "work"),
		Basso:    filepath.Join(servizio, "run", relativo, "lower"),
	}
}

// RelativoDi da' il percorso di `cartella` relativo a `radice`, o un *Errore se
// la cartella e' fuori.
func RelativoDi(cartella, radice string) (string, error) {
	c, err := filepath.EvalSymlinks(cartella)
	if err != nil {
		c = filepath.Clean(cartella)
	}
	r, err := filepath.EvalSymlinks(radice)
	if err != nil {
		r = filepath.Clean(radice)
	}
	rel, err := filepath.Rel(r, c)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errf("%s isn't inside the root %s", cartella, radice)
	}
	return rel, nil
}

// Elenca da' le immagini presenti. Il percorso e' esso stesso l'indice: nessun
// registro separato da tenere allineato.
func Elenca(profilo Profilo, radice string) ([]string, error) {
	statica := filepath.Join(radice, profilo.Servizio, "static")
	fi, err := os.Stat(statica)
	if err != nil || !fi.IsDir() {
		return nil, nil
	}
	var nomi []string
	err = filepath.WalkDir(statica, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() || !strings.HasSuffix(p, ".img") {
			return nil
		}
		rel, err := filepath.Rel(statica, p)
		if err != nil {
			return nil
		}
		nomi = append(nomi, strings.TrimSuffix(rel, ".img"))
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(nomi)
	return nomi, nil
}

// ── avanzamento ──────────────────────────────────────────────────────────────

// Intervallo e' ogni quanto si avvisa chi osserva. **A tempo, non a
// conteggio**, ed e' una correzione: con una soglia ogni N voci il ritmo dei
// ridisegni lo detta il disco, e su FUSE, dove una voce puo' costare dieci
// millisecondi, fra due ridisegni passano cinque secondi. Chi guarda vede una
// riga ferma e conclude che il programma e' piantato — che e' esattamente cio'
// che l'avanzamento doveva smentire.
//
// A tempo il ritmo e' costante qualunque cosa faccia il disco, e la spesa e'
// nota: dieci scritture al secondo, non una ogni N voci di durata ignota.
const Intervallo = 100 * time.Millisecond

// Osservatore riceve un avanzamento: quante voci finora, e quanti byte se il
// chiamante li sa. I byte valgono -1 quando non si applicano.
type Osservatore func(voci int, byte int64)

// Battito avvolge un osservatore perche' sia chiamato a tempo invece che
// sempre. Restituisce sempre qualcosa di chiamabile, anche quando non c'e'
// nessuno da avvisare: cosi' chi attraversa non deve controllare il nil a ogni
// voce, e il ciclo caldo resta una riga.
func Battito(osserva Osservatore) Osservatore {
	if osserva == nil {
		return func(int, int64) {}
	}
	var ultimo time.Time
	return func(voci int, byte int64) {
		adesso := time.Now()
		if adesso.Sub(ultimo) >= Intervallo {
			ultimo = adesso
			osserva(voci, byte)
		}
	}
}

// EseguiContando esegue un comando contandone le righe di lavoro mentre
// scorrono.
//
// Serve ai due programmi esterni che npz aspetta a lungo — mkfs.erofs che
// costruisce l'immagine e cp che la rimaterializza — e che, se glielo si
// chiede, dicono a voce quale voce stanno trattando. Contare quelle righe da'
// un avanzamento **misurato** invece che stimato, e costa la lettura di un tubo
// che altrimenti si sarebbe buttata via.
//
// Si legge mentre scorre e non in blocco: raccogliere tutto e poi contare
// darebbe la percentuale giusta al momento in cui non serve piu' a nessuno.
//
// I due flussi si fondono in uno perche' leggerne due separati dallo stesso
// processo si blocca quando uno dei due riempie il proprio buffer e nessuno lo
// sta svuotando. Della coda si tengono le ultime righe, che sono quel che serve
// a raccontare un fallimento.
func EseguiContando(nome string, argomenti []string,
	riconosce func(string) bool, osserva Osservatore) (int, []string, error) {

	cmd := exec.Command(nome, argomenti...)
	tubo, err := cmd.StdoutPipe()
	if err != nil {
		return -1, nil, errf("can't read from %s: %v", nome, err)
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return -1, nil, errf("can't run %s: %v", nome, err)
	}

	var coda []string
	visti := 0
	riferisci := Battito(osserva)
	sc := bufio.NewScanner(tubo)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		riga := sc.Text()
		coda = append(coda, riga)
		if len(coda) > 8 {
			coda = coda[len(coda)-8:]
		}
		if riconosce(riga) {
			visti++
			riferisci(visti, -1)
		}
	}
	errAttesa := cmd.Wait()
	codice := cmd.ProcessState.ExitCode()
	if codice == 0 && osserva != nil {
		osserva(visti, -1)
	}
	if errAttesa != nil && codice < 0 {
		return codice, coda, errf("%s failed: %v", nome, errAttesa)
	}
	return codice, coda, nil
}

// ── costruzione ──────────────────────────────────────────────────────────────

// Costruisci costruisce l'immagine su un nome temporaneo e ne restituisce il
// percorso. Non tocca nulla di esistente: e' il primo dei tre tempi.
//
// `escludi` sono percorsi **relativi alla sorgente** che non devono entrare
// nell'immagine. Quali siano lo decide la facciata; qui si sa solo come si dice
// a mkfs.erofs di saltarli: `--exclude-path` vuole il percorso relativo e senza
// barra iniziale, verificato, perche' con la barra non corrisponde a niente e
// non lo dice.
func Costruisci(sorgente, destinazione, compressione string, escludi []string,
	osserva Osservatore) (string, error) {
	if _, err := exec.LookPath("mkfs.erofs"); err != nil {
		return "", &Errore{Messaggio: "mkfs.erofs is missing (package erofs-utils)"}
	}
	if err := os.MkdirAll(filepath.Dir(destinazione), 0o755); err != nil {
		return "", errf("can't create %s: %v", filepath.Dir(destinazione), err)
	}
	tmp := destinazione + ".new"
	if err := os.Remove(tmp); err != nil && !os.IsNotExist(err) {
		return "", errf("can't remove %s: %v", tmp, err)
	}

	argomenti := []string{}
	// `nessuna` e' la grafia di prima che la CLI passasse all'inglese, e si
	// accetta ancora: sta scritta dentro i `config` gia' su disco, e non
	// riconoscerla vorrebbe dire passare `-znessuna` a mkfs.erofs.
	if compressione != "" && compressione != "none" && compressione != "nessuna" {
		argomenti = append(argomenti, "-z"+compressione)
	}
	for _, e := range escludi {
		argomenti = append(argomenti, "--exclude-path="+strings.TrimPrefix(e, "/"))
	}
	argomenti = append(argomenti, tmp, sorgente)

	// Al livello di verbosita' predefinito mkfs.erofs nomina ogni voce che
	// scrive (`Processing <percorso> ...`): contarle e' l'unico avanzamento
	// **vero** disponibile, perche' il totale lo sappiamo gia' da Censisci.
	codice, coda, err := EseguiContando("mkfs.erofs", argomenti,
		func(r string) bool { return strings.HasPrefix(r, "Processing ") }, osserva)
	if err != nil {
		os.Remove(tmp)
		return "", err
	}
	if codice != 0 {
		os.Remove(tmp)
		ultima := "no message"
		if len(coda) > 0 {
			ultima = coda[len(coda)-1]
		}
		return "", errf("mkfs.erofs failed: %s", ultima)
	}
	return tmp, nil
}

// ── verifica ─────────────────────────────────────────────────────────────────

// Voce sono gli attributi di una singola voce dell'albero. Comparabile, cosi'
// che il confronto fra due inventari sia un `!=` e non una funzione.
//
// Dimensione vale -1 dove non ha senso (tutto cio' che non e' un file
// regolare): il Python ci mette None, e il sentinella qui fa lo stesso lavoro
// senza costringere a un puntatore.
type Voce struct {
	Tipo         uint32 // S_IFMT: il tipo, senza i permessi
	Modo         uint32 // S_IMODE: i permessi, senza il tipo
	Dimensione   int64  // -1 se non e' un file regolare
	Destinazione string // dove punta il symlink, "" se non lo e'
	Uid, Gid     uint32
}

func (v Voce) String() string {
	return fmt.Sprintf("(%o, %o, %d, %q, %d, %d)",
		v.Tipo, v.Modo, v.Dimensione, v.Destinazione, v.Uid, v.Gid)
}

// Inventario e' una fotografia dell'albero, confrontabile: percorso relativo ->
// attributi.
//
// Non legge i contenuti: confronta tipo, permessi, dimensione, destinazione dei
// symlink e proprietario. Sono gli attributi che il ripristino deve conservare
// e che un errore di costruzione perderebbe.
func Inventario(radice string, osserva Osservatore) (map[string]Voce, error) {
	base, err := filepath.EvalSymlinks(radice)
	if err != nil {
		base = filepath.Clean(radice)
	}

	// Prima i nomi, camminando; poi gli attributi, in parallelo.
	//
	// Su un albero servito da FUSE una lstat non e' calcolo, e' **latenza**: il
	// processo aspetta un giro completo verso il demone, e mentre aspetta la
	// macchina non fa niente. Misurato su 10.400 voci dietro erofsfuse: 0,45 s
	// in fila indiana, 0,04 con otto operai — dieci volte. Sullo stesso albero
	// su ext4 il guadagno e' 2x, che e' la prova che quel che si recupera qui
	// e' attesa e non lavoro.
	var nomi []string
	err = filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			// Come il Python, che fa `continue` su OSError: cio' che non si
			// riesce a leggere non entra nell'inventario, e la differenza si
			// vedra' nel confronto invece di fermare la passata.
			if p == base {
				return err
			}
			return nil
		}
		if p == base {
			return nil // os.walk non riporta la radice fra le voci
		}
		nomi = append(nomi, p)
		return nil
	})
	if err != nil {
		return nil, errf("can't read %s: %v", radice, err)
	}

	fotografia := make(map[string]Voce, len(nomi))
	var mu sync.Mutex
	var fatte atomic.Int64
	riferisci := Battito(osserva)

	var attesa sync.WaitGroup
	lavoro := make(chan string, 1024)
	for i := 0; i < Operai; i++ {
		attesa.Add(1)
		go func() {
			defer attesa.Done()
			locale := map[string]Voce{}
			for p := range lavoro {
				if v, rel, ok := guarda(base, p); ok {
					locale[rel] = v
				}
				// Il battito si prende il lucchetto perche' chi osserva scrive
				// su un terminale, che e' uno solo: la misura e' parallela, il
				// racconto no.
				n := fatte.Add(1)
				mu.Lock()
				riferisci(int(n), -1)
				mu.Unlock()
			}
			mu.Lock()
			for k, v := range locale {
				fotografia[k] = v
			}
			mu.Unlock()
		}()
	}
	for _, p := range nomi {
		lavoro <- p
	}
	close(lavoro)
	attesa.Wait()
	if osserva != nil {
		osserva(len(fotografia), -1)
	}
	return fotografia, nil
}

// Operai e' quanti attributi si chiedono insieme. Otto bastano: la misura dice
// 9,3x con quattro, 10,3 con otto e 11,4 con sedici, cioe' la curva si appiattisce
// appena la coda del demone e' piena. Sedici sono un compromesso fra il poco che
// si guadagna ancora e il non tempestare un filesystem di rete.
const Operai = 16

// guarda legge gli attributi di una voce. E' il corpo di quel che prima stava
// dentro il cammino, estratto perche' adesso lo eseguono in molti.
func guarda(base, p string) (Voce, string, bool) {
	rel, err := filepath.Rel(base, p)
	if err != nil {
		return Voce{}, "", false
	}
	fi, err := os.Lstat(p)
	if err != nil {
		return Voce{}, "", false
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return Voce{}, "", false
	}
	modo := uint32(st.Mode)
	v := Voce{
		Tipo:       modo & syscall.S_IFMT,
		Modo:       modo & 0o7777,
		Dimensione: -1,
		Uid:        st.Uid,
		Gid:        st.Gid,
	}
	if modo&syscall.S_IFMT == syscall.S_IFREG {
		v.Dimensione = st.Size
	}
	if modo&syscall.S_IFMT == syscall.S_IFLNK {
		if d, err := os.Readlink(p); err == nil {
			v.Destinazione = d
		}
	}
	return v, rel, true
}

// Differenze elenca in che cosa due inventari non coincidono, fino a `limite`
// voci.
// UidVisti da' gli uid presenti in un inventario gia' fatto.
//
// Come Misura: il dato c'e' gia', e ripercorrere l'albero per riprenderlo
// costerebbe una passata intera su cio' che e' appena stato letto.
func UidVisti(fotografia map[string]Voce) []uint32 {
	visti := map[uint32]bool{}
	for _, v := range fotografia {
		visti[v.Uid] = true
	}
	uid := make([]uint32, 0, len(visti))
	for u := range visti {
		uid = append(uid, u)
	}
	sort.Slice(uid, func(i, j int) bool { return uid[i] < uid[j] })
	return uid
}

func Differenze(atteso, ottenuto map[string]Voce, limite int) []string {
	if limite <= 0 {
		limite = 5
	}
	var voci []string

	var mancanti, aggiunti, comuni []string
	for k := range atteso {
		if _, c := ottenuto[k]; c {
			comuni = append(comuni, k)
		} else {
			mancanti = append(mancanti, k)
		}
	}
	for k := range ottenuto {
		if _, c := atteso[k]; !c {
			aggiunti = append(aggiunti, k)
		}
	}
	sort.Strings(mancanti)
	sort.Strings(aggiunti)
	sort.Strings(comuni)

	for i, rel := range mancanti {
		if i >= limite {
			break
		}
		voci = append(voci, "missing: "+rel)
	}
	for i, rel := range aggiunti {
		if i >= limite {
			break
		}
		voci = append(voci, "extra: "+rel)
	}
	for _, rel := range comuni {
		if atteso[rel] != ottenuto[rel] {
			voci = append(voci, fmt.Sprintf("different: %s — %s vs %s",
				rel, atteso[rel], ottenuto[rel]))
			if len(voci) >= limite {
				break
			}
		}
	}
	if rimasti := len(mancanti) + len(aggiunti) - len(voci); rimasti > 0 {
		voci = append(voci, fmt.Sprintf("…and %d more", rimasti))
	}
	return voci
}

// Verifica monta l'immagine appena costruita e la confronta con l'originale.
//
// E' il cuore dell'invariante: la cartella originale non sparisce finche' non
// e' dimostrato che l'immagine la contiene davvero. Costa un mount e una
// passata di lstat, ed e' cio' che separa questo da un `rm -rf` con speranza.
func Verifica(immagine, sorgente, punto string, backend Backend,
	osserva func(voci int, quale string), atteso map[string]Voce) error {
	if err := os.MkdirAll(punto, 0o755); err != nil {
		return errf("can't create %s: %v", punto, err)
	}
	// Se sul punto c'e' gia' qualcosa — un ciclo precedente interrotto, un
	// mount sopravvissuto a una cartella cancellata — montarci sopra ne impila
	// due, e cio' che si finirebbe per confrontare non e' l'immagine appena
	// costruita. Il guasto si presenterebbe come "l'immagine non corrisponde
	// all'originale", che manda a cercare un difetto dove non c'e'.
	for Montato(punto) {
		if err := backend.Smonta(punto, false); err != nil {
			return err
		}
	}
	if err := backend.MontaRO(immagine, punto); err != nil {
		return err
	}
	defer func() {
		if Montato(punto) {
			_ = backend.Smonta(punto, false)
		}
	}()

	// Due passate: prima l'originale, poi l'immagine montata. Si distinguono per
	// chi osserva, che altrimenti vedrebbe il conteggio ripartire da zero senza
	// sapere perche'.
	if atteso == nil {
		var err error
		atteso, err = Inventario(sorgente, fase(osserva, "the original"))
		if err != nil {
			return err
		}
	}
	ottenuto, err := Inventario(punto, fase(osserva, "the image"))
	if err != nil {
		return err
	}
	if scarto := Differenze(atteso, ottenuto, 5); len(scarto) > 0 {
		return errf("the image doesn't match the original:\n  %s\n"+
			"The source folder was NOT touched.", strings.Join(scarto, "\n  "))
	}
	return nil
}

// Misura da' gli stessi due numeri di Conta, ma da un inventario gia' fatto.
//
// Serve dove l'albero sta dietro uno strato FUSE e ripercorrerlo costa quanto
// il resto dell'operazione: il consolidamento ha gia' in mano la fotografia
// dell'immagine appena verificata, e da quella i numeri si ricavano senza
// toccare il disco una seconda volta.
func Misura(fotografia map[string]Voce) (file int, byte int64, cartelle int) {
	for _, v := range fotografia {
		if v.Tipo != syscall.S_IFDIR {
			file++
		} else {
			cartelle++
		}
		if v.Dimensione >= 0 {
			byte += v.Dimensione
		}
	}
	// Il +1 sulle cartelle e' la **radice**, che Inventario non elenca —
	// registra i percorsi relativi a essa, e relativo a se stessa non e' un
	// percorso. Censisci invece la conta, e mkfs.erofs e cp -v la nominano: i
	// tre numeri devono voler dire la stessa cosa, o il totale su cui si calcola
	// un avanzamento cambia a seconda di chi l'ha prodotto.
	return file, byte, cartelle + 1
}

// Conta dice quanti file, quanti byte e quante directory.
//
// I primi due vanno nei metadati. Le directory servono a chi deve mostrare un
// avanzamento su mkfs.erofs o su cp, che nominano **ogni voce** che trattano,
// cartelle comprese: misurare la percentuale sui soli file la manderebbe oltre
// il 100% proprio verso la fine, che e' il momento in cui una barra di
// avanzamento viene guardata di piu'.
func Conta(cartella string, osserva Osservatore) (int, int64, int, error) {
	file, byte, cartelle, _, err := Censisci(cartella, osserva)
	return file, byte, cartelle, err
}

// Censisci dice quanti file, quanti byte, quante directory, e **quali uid** si
// incontrano.
//
// Le quattro risposte in una passata sola perche' vengono tutte dalla stessa
// lstat, e perche' la passata e' la cosa cara: su 100.000 file serviti da FUSE,
// misurato, contare costa 13 secondi e guardare gli uid altri 11, mentre farlo
// insieme ne costa 14. Chiederle separatamente era il 42% di lavoro buttato,
// tutto speso prima che mkfs.erofs cominciasse — cioe' dentro il silenzio che
// faceva sembrare npz piantato.
//
// Gli uid si **riportano**, non si giudicano: quali siano estranei lo decide chi
// chiama, che e' l'unico a sapere per conto di chi sta guardando.
//
// NOTA DI PORTING — os.walk separa le voci con `entry.is_dir()`, che **segue** i
// symlink: un link a una directory finisce fra le cartelle e non viene contato
// come file. filepath.WalkDir invece lo tratta come non-directory. Per non
// divergere si ripete qui la classificazione del Python, con uno Stat che segue
// il link.
func Censisci(cartella string, osserva Osservatore) (
	file int, byte int64, cartelle int, uid []uint32, err error) {

	// Si scende **per livelli**, e ogni livello si legge in parallelo. Come in
	// Inventario: su un albero servito da FUSE leggere una directory e' latenza,
	// non calcolo, e aspettare in fila indiana e' lo spreco. A differenza di
	// Inventario, qui non basta la lista dei nomi — servono gli attributi di
	// ogni voce — quindi il parallelismo sta sulle directory, che sono l'unita'
	// che si puo' leggere in modo indipendente.
	visti := map[uint32]bool{}
	riferisci := Battito(osserva)
	var fatti atomic.Int64
	var mu sync.Mutex

	livello := []string{cartella}
	primo := true
	for len(livello) > 0 {
		var prossimo []string
		var attesa sync.WaitGroup
		lavoro := make(chan string, 256)
		for i := 0; i < Operai; i++ {
			attesa.Add(1)
			go func() {
				defer attesa.Done()
				for dove := range lavoro {
					f, b, c, u, sotto, e := leggiCartella(dove)
					mu.Lock()
					if e == nil {
						file += f
						byte += b
						cartelle += c
						for _, x := range u {
							visti[x] = true
						}
						prossimo = append(prossimo, sotto...)
					}
					n := fatti.Add(int64(f))
					riferisci(int(n), byte)
					mu.Unlock()
				}
			}()
		}
		for _, d := range livello {
			lavoro <- d
		}
		close(lavoro)
		attesa.Wait()

		if primo && cartelle == 0 {
			// La radice non si e' potuta leggere: come os.walk, che su una
			// radice illeggibile non da' nulla, ma qui si dice perche'.
			return 0, 0, 0, nil, errf("can't read %s", cartella)
		}
		primo = false
		livello = prossimo
	}

	if osserva != nil {
		osserva(file, byte)
	}
	uid = make([]uint32, 0, len(visti))
	for u := range visti {
		uid = append(uid, u)
	}
	sort.Slice(uid, func(i, j int) bool { return uid[i] < uid[j] })
	return file, byte, cartelle, uid, nil
}

// leggiCartella guarda una directory sola: conta le sue voci, ne raccoglie gli
// uid, e restituisce le sottodirectory in cui scendere.
//
// La directory stessa si conta qui, cosi' la radice entra nel totale come nel
// gemello Python. Un symlink a directory si conta **fra le cartelle** e non fra
// i file — os.walk lo mette li' e non ci scende — ma il suo uid e' quello del
// link, non del bersaglio: e' la voce che sta in questo albero.
func leggiCartella(dove string) (file int, byte int64, cartelle int,
	uid []uint32, sotto []string, err error) {

	voci, err := os.ReadDir(dove)
	if err != nil {
		return 0, 0, 0, nil, nil, err
	}
	cartelle = 1
	if fi, e := os.Lstat(dove); e == nil {
		if st, ok := fi.Sys().(*syscall.Stat_t); ok {
			uid = append(uid, st.Uid)
		}
	}
	for _, voce := range voci {
		p := filepath.Join(dove, voce.Name())
		fi, e := os.Lstat(p)
		if e != nil {
			continue
		}
		st, ok := fi.Sys().(*syscall.Stat_t)
		if !ok {
			continue
		}
		if voce.IsDir() {
			sotto = append(sotto, p)
			continue // si contera' da se', quando tocchera' a lei
		}
		// Un symlink a directory conta **fra i file**, non fra le cartelle: per
		// lstat e' un link, e la classificazione dev'essere la stessa di
		// Misura, che lavora su un inventario dove i tipi vengono da lstat.
		// Finche' le due contavano diversamente i totali tornavano ma la
		// ripartizione no, e il `file` scritto nel .meta dipendeva da quale
		// delle due l'aveva prodotto.
		file++
		uid = append(uid, st.Uid)
		if fi.Mode().IsRegular() {
			byte += st.Size
		}
	}
	return file, byte, cartelle, uid, sotto, nil
}

// fase lega un nome di fase a un osservatore, o restituisce nil se non ce n'e'.
func fase(osserva func(voci int, quale string), quale string) Osservatore {
	if osserva == nil {
		return nil
	}
	return func(voci int, _ int64) { osserva(voci, quale) }
}
