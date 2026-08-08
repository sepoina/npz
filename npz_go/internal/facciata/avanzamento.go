// Come si racconta una fase lunga mentre accade.
//
// Le fasi lunghe di npz sono attraversate di alberi enormi su dischi lenti, e
// fra loro non c'e' un solo momento in cui il processo abbia qualcosa da
// stampare: senza una riga che si riscrive, congelare 100.000 file e' un quarto
// d'ora di silenzio, indistinguibile da un blocco. Misurato su NTFS: 48 secondi
// di sole attraversate prima ancora che mkfs.erofs partisse.
//
// Qui stanno solo i tre modi di comporre quella riga. La riga in se' la scrive
// voce.Avanzamento, che sa di terminali; questi sanno di numeri.

package facciata

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"npz/internal/nucleo"
)

// Quanto compone `47.312 / 114.249 (41%)`, o il solo conteggio se il totale non
// si sa. Il tappo al 100 c'e' perche' un totale puo' essere approssimato — nel
// detach viene dal .meta, che fotografa il congelamento e non sa del delta — e
// una percentuale che sfonda si legge come un difetto, non come una stima.
func Quanto(fatti, totale int) string {
	if totale <= 0 {
		return gruppi(fatti) + " entries"
	}
	percento := 100 * fatti / totale
	if percento > 100 {
		percento = 100
	}
	return fmt.Sprintf("%s / %s (%d%%)", gruppi(fatti), gruppi(totale), percento)
}

// gruppi scrive un intero con i separatori delle migliaia. Go non ce l'ha, e
// centomila senza separatori si legge male proprio quando lo si guarda di
// fretta.
func gruppi(n int) string {
	s := strconv.Itoa(n)
	if n < 0 {
		return "-" + gruppi(-n)
	}
	var b strings.Builder
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	return b.String()
}

// cresciuta dice quanto e' grande finora l'immagine in costruzione, se si
// riesce a saperlo.
//
// Uno Stat per ridisegno, non per voce: e' il secondo numero che dice se il
// lavoro procede, ed e' l'unico che continua a muoversi quando mkfs.erofs
// incontra un file grande e per un po' non ne nomina altri.
func cresciuta(dove string) string {
	fi, err := os.Stat(dove)
	if err != nil {
		return ""
	}
	return " · " + nucleo.Leggibile(fi.Size())
}

// scritti dice quanto e' calato lo spazio libero da quando si e' cominciato.
//
// Una statfs invece di una passata: e' l'unico modo di dire i MiB senza
// ricontare quel che si sta scrivendo, e si legge a costo zero.
//
// E' lo spazio **occupato**, non la somma delle dimensioni: su molti file
// piccoli i due numeri divergono parecchio, perche' ogni file arrotonda a un
// blocco — 264 voci da poche centinaia di byte occupano un megabyte. Non e' un
// errore ed e' anzi il numero piu' utile dei due, visto che la domanda a cui
// risponde e' se il disco si sta riempiendo. Non e' pero' contabilita': se
// qualcun altro scrive sullo stesso filesystem, il conto se ne accorge.
func scritti(radice string, liberoPrima int64) string {
	adesso, err := spazioLibero(radice)
	if err != nil {
		return ""
	}
	if calo := liberoPrima - adesso; calo > 0 {
		return " · " + nucleo.Leggibile(calo)
	}
	return ""
}
