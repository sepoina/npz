// I sei comandi intercettati, e l'aiuto.
//
// I nomi sono in inglese come tutta la superficie di npm: la CLI parla la
// lingua di chi la usa, il codice sotto resta in italiano.

package facciata

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"npz/internal/nucleo"
	"npz/internal/voce"
	"unicode/utf8"
)

// Versione di npz, scritta a tempo di collegamento da build/build.sh, che la
// legge da `progetto.conf` — la fonte di verita' del progetto.
//
// E' una `var` e non una `const` perche' `-ldflags -X` sa scrivere solo sulle
// variabili. **Il valore qui sotto non e' la versione**: e' cio' che si legge
// quando non si e' passati da build.sh, e dice esattamente quello. Un binario
// che si presenta come "sviluppo" e' stato costruito al volo, e distinguerlo a
// occhio da uno di rilascio vale piu' di un numero che sarebbe una copia — e
// che come ogni copia prima o poi divergerebbe.
var Versione = "sviluppo"

// Implementazione dice quale dei due gemelli sta girando. Finche' Python e Go
// convivono e si verificano a vicenda, chi legge un output deve poter dire da
// quale dei due viene senza indovinarlo dal percorso dell'eseguibile: un banco
// che confronta le due, o un utente che ne ha installate entrambe, altrimenti
// attribuiscono un comportamento al gemello sbagliato. La facciata Python
// dichiara `python` allo stesso modo e nello stesso posto.
const Implementazione = "go"

func fuoriDaProgetto() error {
	return &nucleo.Errore{Messaggio: "you're not inside a project"}
}

// ── status ───────────────────────────────────────────────────────────────────

func CmdStatus(radice string, stato Stato) int {
	if radice == "" {
		voce.Riferisce("you're not inside a project (no package.json above here)")
		return 1
	}
	tipo := nucleo.TipoFilesystem(radice)
	if tipo == "" {
		tipo = "?"
	}
	righe := []string{
		"project       " + radice,
		"filesystem    " + tipo,
		"status        " + string(stato),
	}
	if stato == Scavalcato {
		// Contare costa una passata sull'albero, ma `status` e' il comando che
		// si batte per capire: qui il numero e' cio' che si viene a cercare.
		if file, byte, _, err := nucleo.Conta(CartellaDi(radice), nil); err == nil {
			righe = append(righe, "folder        "+strconv.Itoa(file)+" files ("+
				nucleo.Leggibile(byte)+") — built by npm outside npz, not mounted")
		}
	}

	p := Percorsi(radice)
	if fi, err := os.Stat(p.Immagine); err == nil {
		meta := map[string]any{}
		if esiste(p.Meta) {
			if letto, e := nucleo.LeggiMeta(p.Meta); e == nil {
				meta = letto
			}
		}
		delta, voci := Somma(p.Delta), Quante(p.Delta)
		// La percentuale misura cio' che un consolidamento assorbirebbe, non
		// cio' che sta sul disco: le cache di build (§9) restano nel delta
		// comunque, e contarle qui inviterebbe a un `npz compact` che non le
		// toglierebbe.
		consolidabili := Quante(p.Delta, Escluse[:]...)
		totali := interoDa(meta["file"])
		if totali < 1 {
			totali = 1
		}
		suffisso := ""
		if consolidabili > 0 {
			suffisso = "  — " + strconv.Itoa(100*consolidabili/totali) + "% of entries"
		} else if voci > 0 {
			suffisso = "  — build cache only"
		}
		backendNome := "?"
		if b, e := nucleo.Scegli("", radice); e == nil {
			backendNome = b.Nome()
		}
		incardinata := "never"
		if s, ok := meta["incardinata"].(string); ok && s != "" {
			incardinata = s
		}
		righe = append(righe,
			"service       "+filepath.Base(ServizioDi(radice))+"/",
			"image         "+nucleo.Leggibile(fi.Size())+"  ("+
				testoDa(meta["file"])+" files, "+
				nucleo.Leggibile(int64(interoDa(meta["byte"])))+" original)",
			"delta         "+nucleo.Leggibile(delta)+" in "+strconv.Itoa(voci)+
				" entries"+suffisso,
			"attached      "+testoDa(meta["creata"]),
			"compacted     "+incardinata,
			"mount         "+backendNome,
		)
	}
	// Le copie messe da parte si elencano sempre, anche senza TTY: e' l'unico
	// modo in cui un costo che npz non toglie da solo resta visibile (§6 bis).
	for _, v := range Superate(radice) {
		var totale int64
		for _, d := range v.Dove {
			totale += Peso(d)
		}
		righe = append(righe, "set aside     "+nucleo.Leggibile(totale)+
			"  — "+v.Che+", "+data(v.Quando))
	}
	voce.Riferisce("%s", strings.Join(righe, "\n"))
	return 0
}

// ── bye ──────────────────────────────────────────────────────────────────────

func CmdBye(radice string, argv []string) error {
	if radice == "" {
		return fuoriDaProgetto()
	}
	p := Percorsi(radice)
	if !esiste(p.Immagine) {
		return &nucleo.Errore{Messaggio: "npz isn't managing anything here"}
	}
	if err := Smonta(radice, HaBandiera(argv, "--force")); err != nil {
		return err
	}
	delta := Somma(p.Delta)
	coda := ""
	if delta > 0 {
		coda = " Delta waiting: " + nucleo.Leggibile(delta) + "."
	}
	voce.Dici("node_modules unmounted and removed; the image stays in .npz/.%s", coda)
	voce.Dici("Any npm command from here remounts it.")
	return nil
}

// ── hey ──────────────────────────────────────────────────────────────────────

// CmdHey e' il montaggio esplicito, il contrario di `bye`.
//
// Monta solo cio' che `attach` ha gia' costruito — non costruisce mai. Su un
// progetto mai attaccato non c'e' niente da far tornare, e dirlo e' meglio che
// attaccare npz senza che nessuno l'abbia chiesto.
func CmdHey(radice string, stato Stato) error {
	if radice == "" {
		return fuoriDaProgetto()
	}
	p := Percorsi(radice)
	if !esiste(p.Immagine) {
		return &nucleo.Errore{Messaggio: "npz isn't attached here yet — run `npz attach` first."}
	}
	if stato == Montato {
		voce.Dici("node_modules is already here.")
	} else {
		if err := AssicuraMontato(radice, stato); err != nil {
			return err
		}
		voce.Dici("node_modules is back.")
	}
	AvvisaDelta(radice)
	return nil
}

// ── attach ───────────────────────────────────────────────────────────────────

// CmdAttach attacca adesso, scavalcando la domanda — e anche un no gia' dato.
//
// E' la via esplicita: chi lo scrive ha gia' deciso, e non ha senso chiedergli
// conferma di una cosa che ha appena chiesto. Per la stessa ragione toglie di
// mezzo il rifiuto registrato in precedenza: e' l'utente stesso a smentirlo.
func CmdAttach(radice string, stato Stato) error {
	if radice == "" {
		return fuoriDaProgetto()
	}
	if stato == Montato || stato == Congelato || stato == Rotto {
		if err := AssicuraMontato(radice, stato); err != nil {
			return err
		}
		p := Percorsi(radice)
		var peso int64
		if fi, err := os.Stat(p.Immagine); err == nil {
			peso = fi.Size()
		}
		voce.Dici("already attached: %s image, now mounted.", nucleo.Leggibile(peso))
		AvvisaDelta(radice)
		return nil
	}

	cartella := CartellaDi(radice)
	if !eDir(cartella) {
		return &nucleo.Errore{Messaggio: "there's no node_modules here for npz to attach to.\n" +
			"Install the dependencies and rerun."}
	}
	if err := VerificaIdoneita(radice); err != nil {
		return err
	}
	rifiuto := filepath.Join(ServizioDi(radice), "no")
	if esiste(rifiuto) {
		_ = os.Remove(rifiuto)
		voce.Dici("there was a recorded refusal: clearing it, since you're the one asking now.")
	}
	if err := Congela(radice); err != nil {
		return err
	}
	return Monta(radice)
}

// ── detach ───────────────────────────────────────────────────────────────────

// CmdDetach e' la via d'uscita: un node_modules vero, senza piu' traccia di npz.
//
// Vale qui l'invariante di sempre — si costruisce, si applica, si cancella.
// L'albero vero nasce accanto a quello montato con un nome di lavoro, viene
// confrontato con la vista da cui proviene, e solo allora prende il suo posto;
// `.npz/` sparisce per ultima. Se qualcosa va storto a meta', l'immagine e'
// ancora li' e non si e' perso niente.
func CmdDetach(radice string, stato Stato, argv []string) error {
	if radice == "" {
		return fuoriDaProgetto()
	}
	p := Percorsi(radice)
	if !esiste(p.Immagine) {
		return &nucleo.Errore{Messaggio: "npz isn't managing anything here"}
	}
	if err := AssicuraMontato(radice, stato); err != nil {
		return err
	}
	cartella := CartellaDi(radice)
	forza := HaBandiera(argv, "--force")

	attivi, err := nucleo.ProcessiAttivi(cartella)
	if err != nil {
		return err
	}
	if len(attivi) > 0 && !forza {
		return &nucleo.Errore{Messaggio: "there are processes using node_modules:\n  " +
			strings.Join(attivi, "\n  ") + "\nClose them and retry, or `npz detach --force`."}
	}

	// Non si riconta niente: il .meta sa gia' quanto pesava l'albero quando e'
	// entrato nell'immagine, e il delta e' quanto gli e' cresciuto sopra. La
	// somma dei due e' una **sovrastima** — il delta spesso riscrive file che
	// nell'immagine ci sono gia', e li conterebbe due volte — ma per decidere se
	// c'e' posto sbagliare per eccesso e' esattamente il verso giusto. Una
	// passata su centomila file, misurata a 13 secondi, per un numero che era
	// gia' su disco.
	meta, _ := nucleo.LeggiMeta(p.Meta)
	file, byte := interoDa(meta["file"]), int64(interoDa(meta["byte"]))
	byte += Peso(p.Delta)
	// cp -v nomina anche le cartelle, quindi il denominatore onesto e' la somma.
	// Uno store scritto prima che la chiave esistesse non ce l'ha: li' `voci`
	// resta 0 e l'avanzamento mostra i soli valori assoluti, che e' il
	// comportamento giusto — meglio un numero che cresce di una percentuale che
	// arriva al 110%.
	voci := 0
	if c := interoDa(meta["cartelle"]); c > 0 {
		voci = file + c
	}
	libero, err := spazioLibero(radice)
	if err != nil {
		return err
	}
	if libero < byte*11/10 {
		return &nucleo.Errore{Messaggio: "not enough space to restore the tree in the open: need about " +
			nucleo.Leggibile(byte) + ", have " + nucleo.Leggibile(libero) + "."}
	}

	// Il nome e' in inglese perche' nasce **dentro la cartella di progetto**,
	// accanto ai file dell'utente, come `node_modules.frozen`: quel che si vede
	// da fuori parla la lingua della CLI, non quella del codice.
	lavoro := cartella + ".npz-in-progress"
	_ = os.RemoveAll(lavoro)
	voce.Dici("detaching: restoring about %s files (%s) …",
		gruppi(file), nucleo.Leggibile(byte))

	// tempo 1 — si costruisce l'albero vero, accanto, senza toccare nulla.
	//
	// `-v` non e' per il registro: e' l'unico modo che cp ha di dire a che punto
	// e', e rimaterializzare centomila file su un disco lento e' la fase piu'
	// lunga che npz abbia — piu' lunga del congelamento, perche' qui si scrive
	// invece di leggere. Ogni riga e' una voce copiata.
	//
	// Il denominatore viene dal .meta, che quei numeri li ha gia': nessuna
	// passata per procurarseli. I MiB invece sono assoluti — vengono dallo
	// spazio libero che cala, una statfs per aggiornamento — e non hanno bisogno
	// di un totale.
	prima, _ := spazioLibero(radice)
	codice, coda, err := nucleo.EseguiContando("cp",
		[]string{"-a", "-v", "--", cartella + "/.", lavoro},
		func(r string) bool { return strings.Contains(r, " -> ") },
		func(n int, _ int64) {
			voce.Avanzamento("restoring node_modules … %s%s",
				Quanto(n, voci), scritti(radice, prima))
		})
	if err != nil || codice != 0 {
		_ = os.RemoveAll(lavoro)
		messaggio := "no message"
		if len(coda) > 0 {
			messaggio = coda[len(coda)-1]
		}
		if err != nil {
			messaggio = err.Error()
		}
		return &nucleo.Errore{Messaggio: "the copy failed: " + messaggio}
	}

	// …e si verifica, come fa il congelamento al contrario.
	montato, err := nucleo.Inventario(cartella, func(n int, _ int64) {
		voce.Avanzamento("verifying against the mounted tree … %s", Quanto(n, voci))
	})
	if err != nil {
		_ = os.RemoveAll(lavoro)
		return err
	}
	copia, err := nucleo.Inventario(lavoro, func(n int, _ int64) {
		voce.Avanzamento("verifying the restored folder … %s", Quanto(n, voci))
	})
	if err != nil {
		_ = os.RemoveAll(lavoro)
		return err
	}
	if scarto := nucleo.Differenze(montato, copia, 5); len(scarto) > 0 {
		_ = os.RemoveAll(lavoro)
		return &nucleo.Errore{Messaggio: "the copy doesn't match the mounted tree:\n  " +
			strings.Join(scarto, "\n  ") + "\nNothing was touched."}
	}

	// tempo 2 — si applica: si smonta e l'albero vero prende il posto del mount.
	if err := Smonta(radice, forza); err != nil {
		return err
	}
	if err := os.Rename(lavoro, cartella); err != nil {
		return &nucleo.Errore{Messaggio: "can't put the folder back: " + err.Error()}
	}

	// L'albero messo da parte da uno scavalcamento (§6 bis) sta nella radice di
	// progetto e sopravvive alla cartella di servizio. Va nominato **prima** di
	// dichiarare che di npz non resta niente: da qui in poi non c'e' piu'
	// nessuno che possa tornare a chiederne conto, e la scadenza che lo avrebbe
	// raccolto se ne va con `.npz/`.
	albero := filepath.Join(radice, AlberoSuperato)
	avanzo := ""
	if esiste(albero) {
		avanzo = " " + nucleo.Leggibile(Peso(albero)) + " in " + AlberoSuperato +
			"/ is still yours to delete."
	}

	// tempo 3 — solo adesso si cancella.
	_ = os.RemoveAll(ServizioDi(radice))
	voce.Dici("detached: node_modules is a normal folder with %d files again. "+
		"Nothing of npz is left.%s", file, avanzo)
	return nil
}

func spazioLibero(percorso string) (int64, error) {
	var s syscall.Statfs_t
	if err := syscall.Statfs(percorso, &s); err != nil {
		return 0, &nucleo.Errore{Messaggio: "can't check free space on " + percorso +
			": " + err.Error()}
	}
	return int64(s.Bavail) * int64(s.Bsize), nil
}

// ── compact ──────────────────────────────────────────────────────────────────

// CmdCompact porta il delta dentro l'immagine, adesso, invece di aspettare la
// soglia.
//
// Funziona in entrambi gli stati in cui c'e' un'immagine: da montati costa lo
// smontaggio e il rimontaggio attorno alla costruzione, da fermi neppure quelli
// — e in nessuno dei due il progetto cambia stato.
func CmdCompact(radice string, stato Stato, argv []string) error {
	if radice == "" {
		return fuoriDaProgetto()
	}
	p := Percorsi(radice)
	if !esiste(p.Immagine) {
		return &nucleo.Errore{Messaggio: "npz isn't managing anything here"}
	}

	if stato == Rotto {
		// Si ripara prima di lavorare, con la rete di sicurezza di §6: costa un
		// montaggio che verra' disfatto subito, e in cambio il caso della
		// cartella non montata con dentro qualcosa lo racconta chi lo sa gia'
		// raccontare, invece di finire coperto dal mount del consolidamento.
		if err := AssicuraMontato(radice, stato); err != nil {
			return err
		}
		stato = Montato
		p = Percorsi(radice) // il montaggio ha svegliato la cartella di servizio
	}

	forza := HaBandiera(argv, "--force")
	if HaBandiera(argv, "--discard") {
		return Butta(radice, stato, forza)
	}

	if Quante(p.Delta, Escluse[:]...) == 0 {
		// Non e' un errore: N2 ha misurato che tre installazioni su dieci non
		// producono delta, e chiedere il consolidamento dopo una di quelle e'
		// ragionevole. Si dice che non c'era niente da fare e si esce da fermi.
		cache := Somma(p.Delta)
		coda := ""
		if cache > 0 {
			coda = " The " + nucleo.Leggibile(cache) + " in the delta is build cache, " +
				"and stays out of the image by design."
		}
		voce.Dici("nothing to compact: node_modules is already all image.%s", coda)
		return nil
	}
	return Compatta(radice, stato, forza)
}

// ── l'aiuto ──────────────────────────────────────────────────────────────────

// Aiuto: `npz` senza argomenti stampa il nostro aiuto, e a seguire quello di npm.
//
// L'ordine e' il messaggio. npz non e' un comando che *assomiglia* a npm: e'
// npm, con tre comportamenti in piu' — e mostrarne l'aiuto dopo il nostro lo
// dice meglio di qualunque frase. Il codice di uscita resta quello di npm.
func Aiuto() int {
	fi, _ := os.Stdout.Stat()
	tinta := fi != nil && fi.Mode()&os.ModeCharDevice != 0
	G, A, D, Z := "", "", "", ""
	if tinta {
		G, A, D, Z = "\033[1m", "\033[36m", "\033[2m", "\033[0m"
	}
	// `indent` non si stampa: serve solo a misurare il rientro della seconda
	// riga, e va contato in **rune**, non in byte. L'em dash e' 3 byte in UTF-8
	// e con len() ne valeva 3 invece di 1: la seconda riga usciva 2 colonne
	// troppo a destra, misurate.
	titolo := "npz " + Versione + " (" + Implementazione + ") — "
	indent := strings.Repeat(" ", utf8.RuneCountInString(titolo))

	voce.Riferisce("%s", strings.Join([]string{
		G + "npz" + Z + " " + D + Versione + " (" + Implementazione + ")" + Z +
			" — node_modules without the node_modules",
		indent + "npm, with node_modules compacted into a mounted image",
		"",
		"npz wraps npm: every command passes through unchanged.",
		"npz only adds one thing: smarter node_modules handling.",
		"",
		G + "npz commands, for this folder" + Z,
		"  " + A + "npz attach" + Z + "      enable npz for this folder and mount",
		"  " + A + "npz detach" + Z + "      disable npz for this folder, restore original node_modules",
		"  " + A + "npz hey" + Z + "         mount node_modules",
		"  " + A + "npz bye" + Z + "         unmount node_modules",
		"  " + A + "npz status" + Z + "      image, delta, mount",
		"  " + A + "npz compact" + Z + "     merge delta into image",
		"",
		G + "Automatic" + Z,
		"  · asks " + G + "once" + Z + " when a real node_modules is found",
		"  · mounts when needed",
		"  · handles " + A + "npm ci" + Z + " specially",
		"",
		"  " + A + "npz -- <command>" + Z + "   send <command> directly to npm",
		"",
		D + "Below the tail, npm is talking. Inside the bar, npz is." + Z,
	}, "\n"))
	// La sbarra si chiude da se' dentro Accompagna, che e' anche il punto in cui
	// i buffer vengono svuotati prima di cedere il terminale a npm.

	npm := TrovaNpm(IoStesso())
	if npm == "" {
		return MancaNpm()
	}
	return Accompagna(npm, nil)
}
