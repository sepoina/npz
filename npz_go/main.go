// npz — un wrapper di npm che congela node_modules in una immagine montata.
//
// Gira ogni parametro a npm tale e quale, e si riserva tre comportamenti
// propri: chiede una volta se congelare node_modules, lo congela e lo monta, e
// con `npz bye` rilascia il mount.
//
// Questo file e' il lanciatore. Nel caso normale — progetto attivo, albero
// montato, comando che non tocca node_modules — fa quattro Stat e poi
// **sparisce**, sostituito da npm con Exec: TTY, segnali e codice di uscita
// passano senza una riga di codice che se ne occupi.
//
// La disciplina sugli import che il Python doveva rispettare qui non serve piu':
// era il prezzo del costo di import di Python, e compilato quel costo e' zero.
// Resta invece intatta la divisione che conta, che e' un'altra — Consegna
// contro Accompagna, cioe' sostituirsi a npm o accompagnarlo — e quella e' nel
// disegno, non nel linguaggio.
package main

import (
	"os"

	"npz/internal/facciata"
	"npz/internal/voce"
)

func main() {
	os.Exit(esegui())
}

func esegui() int {
	argv := os.Args[1:]

	// `npz` nudo: il nostro aiuto e a seguire quello di npm. Non si risale ad
	// alcun progetto e non si chiede niente — chi vuole l'aiuto vuole l'aiuto.
	if len(argv) == 0 {
		codice := facciata.Aiuto()
		voce.ChiudiTutto()
		return codice
	}

	classe := facciata.Classifica(argv)

	if classe == facciata.Nostro {
		codice := facciata.Governa(argv, facciata.TrovaProgetto(""), "")
		voce.ChiudiTutto()
		return codice
	}

	npm := facciata.TrovaNpm(facciata.IoStesso())
	if npm == "" {
		return facciata.MancaNpm()
	}

	progetto := facciata.TrovaProgetto("")
	stato := facciata.StatoDi(progetto)

	// Fuori da un progetto, o in un progetto che non ci riguarda, npz non
	// esiste: si consegna il comando e si sparisce.
	if stato == facciata.Estraneo || stato == facciata.Rifiutato || stato == facciata.Vergine {
		facciata.Consegna(npm, argv) // non torna
	}

	// Il caso caldo: montato, e il comando non tocca l'albero.
	if stato == facciata.Montato && classe == facciata.Neutro {
		facciata.Consegna(npm, argv) // non torna
	}

	codice := facciata.Governa(argv, progetto, stato)
	// La coda si chiude qui e non con un defer: os.Exit non li esegue, e tutti
	// i rami qui sopra che finiscono in Consegna non tornano mai. Vedi §6.1.
	voce.ChiudiTutto()
	return codice
}
