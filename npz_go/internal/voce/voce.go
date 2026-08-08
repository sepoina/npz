// Package voce e' la sbarra: come npz parla, e come si distingue da npm.
//
// Ogni riga che npz emette porta il proprio segno. Serve perche' in una stessa
// esecuzione npz e npm parlano a turno — npz annuncia, npm lavora, npz conclude
// — e senza un marcatore le due voci si confondono. Il segno sta su *ogni* riga
// e non solo sulla prima: i messaggi di errore sono spesso elenchi, e una riga
// senza segno in mezzo a un elenco sembra output di npm.
//
//	╥
//	║  attached: 31667 files (588 MiB) → one file (234 MiB)
//	╨
//
// Testa e coda non sono decorazione: delimitano il **turno di parola**. La
// sbarra non appartiene al singolo messaggio ma a tutta la sequenza di messaggi
// consecutivi, e si chiude esattamente dove npz cede il terminale.
//
// ATTENZIONE (§6.1 del piano Go) — in Python la chiusura era anche registrata
// con atexit. In Go non esiste un atexit, e soprattutto **syscall.Exec non
// esegue i defer**: il processo viene sostituito e tutto cio' che era in coda
// semplicemente non succede. La coda va quindi chiusa **esplicitamente** prima
// di ogni Exec, prima di ogni Start, e su ogni uscita di main. Un
// `defer ChiudiTutto()` funzionerebbe sull'uscita normale e fallirebbe proprio
// sul percorso piu' frequente del programma.
package voce

import (
	"fmt"
	"os"
	"strings"
)

const (
	testa = " ╥"
	segno = " ║  "
	coda  = " ╨"

	// Giallo tenue: un terminale non ha opacita', ha `2` — l'attributo *faint*,
	// che e' il modo in cui i terminali dicono "meta' intensita'". Vale piu' di
	// un giallo a 24 bit smorzato a mano verso il fondo, perche' quello andrebbe
	// scelto sapendo se il tema e' chiaro o scuro, mentre faint lo compone col
	// fondo vero.
	tintaVoce   = "\033[2;33m"
	tintaErrore = "\033[31m" // rosso pieno: quando si ferma, il segno non sussurra
	spento      = "\033[0m"
)

// aperte tiene, per ogni flusso su cui la sbarra e' aperta, se in questo turno
// si e' detto un errore. Un errore detto a meta' turno tinge di rosso anche la
// coda: il colore della chiusura e' il modo piu' economico per dire com'e'
// andata a chi guarda la fine di un blocco senza rileggerlo.
var aperte = map[*os.File]bool{}

// ordine conserva l'ordine di apertura, cosi' che ChiudiTutto sia deterministico
// — l'iterazione su una mappa in Go non lo e', e due flussi aperti insieme
// chiuderebbero in ordine casuale.
var ordine []*os.File

// Il girello. Sono i punti braille di npm, e non per somiglianza: hanno la
// stessa larghezza in ogni cella, quindi la riga non balla mentre giri, e sono
// gia' installati ovunque giri npm — che e' la definizione del nostro pubblico.
var girello = []rune("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

var (
	inCorso = map[*os.File]bool{} // c'e' una riga di avanzamento da sgombrare
	giro    int                   // a che punto e' il girello
)

func eTty(f *os.File) bool {
	if f == nil {
		return false
	}
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

// tinge colora il glifo. Il colore sta sul segno, mai sul testo: il testo resta
// copiabile.
func tinge(glifo string, dove *os.File, errore bool) string {
	if !eTty(dove) {
		return glifo
	}
	if errore {
		return tintaErrore + glifo + spento
	}
	return tintaVoce + glifo + spento
}

// Apri stampa la testa, se la sbarra su questo flusso non e' gia' aperta.
func Apri(dove *os.File, errore bool) {
	if precedente, c := aperte[dove]; c {
		aperte[dove] = precedente || errore
		return
	}
	aperte[dove] = errore
	ordine = append(ordine, dove)
	fmt.Fprintln(dove, tinge(testa, dove, errore))
}

// Chiudi chiude la sbarra su un flusso e svuota i buffer.
func Chiudi(dove *os.File) {
	andataMale, c := aperte[dove]
	if !c {
		return
	}
	delete(aperte, dove)
	for i, f := range ordine {
		if f == dove {
			ordine = append(ordine[:i], ordine[i+1:]...)
			break
		}
	}
	sgombra(dove)
	fmt.Fprintln(dove, tinge(coda, dove, andataMale))
	_ = dove.Sync()
}

// ChiudiTutto chiude la sbarra su ogni flusso. Va chiamata prima di cedere il
// terminale a npm — vedi la nota del pacchetto: qui non c'e' nessun atexit che
// lo faccia al posto nostro, e Exec non esegue i defer.
func ChiudiTutto() {
	for len(ordine) > 0 {
		Chiudi(ordine[0])
	}
	_ = os.Stdout.Sync()
	_ = os.Stderr.Sync()
}

// Avanzamento scrive una riga che si riscrive sopra se stessa, invece di
// accumularsi.
//
// Serve alle operazioni lunghe, che qui sono lunghe davvero: congelare 100.000
// file su un disco servito da FUSE sono minuti, e un messaggio solo all'inizio
// non distingue "sta lavorando" da "si e' piantato" — che e' esattamente la
// domanda a cui l'utente ha bisogno di rispondere.
//
// **Solo su TTY.** Redirigendo, \r produrrebbe un file con dentro tutte le
// revisioni della stessa riga; e un log non ha bisogno di sapere che a un certo
// istante si era al 47%. Fuori dal terminale questa funzione tace, e restano i
// messaggi di Su(), che sono lo scheletro del racconto.
//
// La riga **non e' il messaggio finale**: e' impaginazione che scade. Chi ha
// qualcosa da lasciare scritto lo dice con Dici(), che la sgombra da se'.
//
// **Il girello avanza a ogni ridisegno**, e non e' decorazione. I numeri qui
// dentro a volte stanno fermi — due ridisegni consecutivi possono cadere sullo
// stesso migliaio, o su un file grande che tiene occupato mkfs.erofs — e una
// riga identica alla precedente si legge come un programma piantato. Il
// carattere che gira dice l'unica cosa che il numero da solo non dice: che
// qualcuno e' ancora vivo e sta contando.
func Avanzamento(formato string, argomenti ...any) {
	dove := os.Stderr
	if !eTty(dove) {
		return
	}
	Apri(dove, false)
	inCorso[dove] = true
	g := girello[giro%len(girello)]
	giro++
	// \r torna a inizio riga, \033[K cancella fino a fine riga: senza, una riga
	// piu' corta della precedente ne lascerebbe scoperta la coda.
	fmt.Fprintf(dove, "\r%s%c %s\033[K",
		tinge(segno, dove, false), g, fmt.Sprintf(formato, argomenti...))
	_ = dove.Sync()
}

// sgombra toglie di mezzo l'avanzamento prima che qualcun altro scriva.
//
// Chiamata da Su(), da Segno() e da Chiudi(): tutto cio' che stampa passa da
// una delle tre, quindi nessuno puo' scrivere sopra una riga viva senza
// accorgersene.
func sgombra(dove *os.File) {
	if inCorso[dove] {
		delete(inCorso, dove)
		fmt.Fprint(dove, "\r\033[K")
	}
}

// Segno e' il prefisso di riga, tinto, aprendo la sbarra se serve.
//
// Serve a chi non passa da Su() perche' scrive una riga senza a capo — la
// domanda della conferma, che aspetta la risposta sulla stessa riga.
func Segno(dove *os.File, errore bool) string {
	if dove == nil {
		dove = os.Stderr
	}
	Apri(dove, errore)
	sgombra(dove)
	return tinge(segno, dove, errore)
}

// Su scrive su un flusso qualsiasi, riga per riga, con il segno.
func Su(dove *os.File, errore bool, testo string) {
	if dove == nil {
		dove = os.Stderr
	}
	Apri(dove, errore)
	sgombra(dove)
	pieno := tinge(segno, dove, errore)
	// Sulle righe vuote la sbarra resta — e' la continuita' del turno di parola
	// — ma gli spazi dopo no: una riga senza testo non deve avere una coda di
	// bianchi che si vede solo quando la si copia.
	vuoto := tinge(strings.TrimRight(segno, " "), dove, errore)
	righe := strings.Split(testo, "\n")
	for _, r := range righe {
		if r == "" {
			fmt.Fprintln(dove, vuoto)
			continue
		}
		fmt.Fprintln(dove, pieno+r)
	}
}

// Dici e' la diagnostica: su stderr, perche' `npz view x --json | jq` deve
// restare pulito.
func Dici(formato string, argomenti ...any) {
	Su(os.Stderr, false, fmt.Sprintf(formato, argomenti...))
}

// Riferisce e' cio' che l'utente ha chiesto: su stdout, ma con lo stesso segno.
func Riferisce(formato string, argomenti ...any) {
	Su(os.Stdout, false, fmt.Sprintf(formato, argomenti...))
}

// Sbaglia dice un errore: stderr, e il turno si tinge di rosso fino alla coda.
func Sbaglia(formato string, argomenti ...any) {
	Su(os.Stderr, true, fmt.Sprintf(formato, argomenti...))
}
