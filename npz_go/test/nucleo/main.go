// nucleo — un guscio sottile sul nucleo, per il banco della fase 1.
//
// Non e' la CLI di npz e non lo diventera': quella e' la facciata, che alla
// fase 1 non esiste ancora. Questo binario espone una funzione del nucleo per
// sottocomando, in una forma che uno script di shell puo' confrontare con
// l'equivalente Python — cioe' e' l'attrezzo con cui si accende l'oracolo
// differenziale del §7 del piano.
//
// L'uscita e' deliberatamente spoglia e stabile: campi separati da tabulazione,
// ordinamento fisso, niente colori. Deve essere confrontabile con `diff`.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"time"

	"npz/internal/nucleo"
)

var profilo = nucleo.Profilo{Servizio: ".npz", Sentinella: ".npz_automount_here"}

func main() {
	if len(os.Args) < 2 {
		aiuto()
		os.Exit(2)
	}
	if err := esegui(os.Args[1], os.Args[2:]); err != nil {
		fmt.Fprintln(os.Stderr, "errore:", err)
		os.Exit(1)
	}
}

func aiuto() {
	fmt.Fprintln(os.Stderr, `nucleo — guscio sul nucleo, per il banco della fase 1

  inventario <dir>                        percorso, tipo, modo, dim, link, uid, gid
  conta <dir>                             "<file> <byte>"
  costruisci <sorgente> <dest> [compr]    costruisce e stampa il temporaneo
  verifica <immagine> <sorgente> <punto>  monta e confronta; esce 1 se diverge
  differenze <dirA> <dirB>                le differenze fra due alberi
  percorsi <radice> <relativo>            i cinque posti di una immagine
  elenca <radice>                         le immagini presenti
  fs-tipo <percorso>                      il tipo di filesystem
  fs-idoneita <percorso>                  "" se va bene, il motivo se no
  config-scrivi <radice> [compressione]
  config-leggi <radice>
  meta-scrivi <percorso.meta> <json>
  meta-leggi <percorso.meta>
  leggibile <byte>
  backend                                 quale backend si sceglie
  relativo <cartella> <radice>
  lock <radice> [secondi]                 prende il lock e lo tiene`)
}

func esegui(comando string, a []string) error {
	switch comando {

	case "inventario":
		if len(a) < 1 {
			return fmt.Errorf("serve una directory")
		}
		fotografia, err := nucleo.Inventario(a[0], nil)
		if err != nil {
			return err
		}
		chiavi := make([]string, 0, len(fotografia))
		for k := range fotografia {
			chiavi = append(chiavi, k)
		}
		sort.Strings(chiavi)
		for _, k := range chiavi {
			v := fotografia[k]
			fmt.Printf("%s\t%o\t%o\t%d\t%s\t%d\t%d\n",
				k, v.Tipo, v.Modo, v.Dimensione, v.Destinazione, v.Uid, v.Gid)
		}

	case "conta":
		if len(a) < 1 {
			return fmt.Errorf("serve una directory")
		}
		file, byte, cartelle, err := nucleo.Conta(a[0], nil)
		if err != nil {
			return err
		}
		fmt.Printf("%d %d %d\n", file, byte, cartelle)

	case "costruisci":
		if len(a) < 2 {
			return fmt.Errorf("servono sorgente e destinazione")
		}
		compressione := nucleo.Compressione
		if len(a) > 2 {
			compressione = a[2]
		}
		tmp, err := nucleo.Costruisci(a[0], a[1], compressione, nil, nil)
		if err != nil {
			return err
		}
		fmt.Println(tmp)

	case "verifica":
		if len(a) < 3 {
			return fmt.Errorf("servono immagine, sorgente e punto")
		}
		backend, err := nucleo.Scegli("", "")
		if err != nil {
			return err
		}
		if err := nucleo.Verifica(a[0], a[1], a[2], backend, nil, nil); err != nil {
			return err
		}
		fmt.Println("ok")

	case "differenze":
		if len(a) < 2 {
			return fmt.Errorf("servono due directory")
		}
		x, err := nucleo.Inventario(a[0], nil)
		if err != nil {
			return err
		}
		y, err := nucleo.Inventario(a[1], nil)
		if err != nil {
			return err
		}
		for _, riga := range nucleo.Differenze(x, y, 20) {
			fmt.Println(riga)
		}

	case "percorsi":
		if len(a) < 2 {
			return fmt.Errorf("servono radice e relativo")
		}
		p := nucleo.Percorsi(profilo, a[0], a[1])
		fmt.Printf("immagine\t%s\nmeta\t%s\ndelta\t%s\nlavoro\t%s\nbasso\t%s\n",
			p.Immagine, p.Meta, p.Delta, p.Lavoro, p.Basso)

	case "elenca":
		if len(a) < 1 {
			return fmt.Errorf("serve una radice")
		}
		nomi, err := nucleo.Elenca(profilo, a[0])
		if err != nil {
			return err
		}
		for _, n := range nomi {
			fmt.Println(n)
		}

	case "fs-tipo":
		if len(a) < 1 {
			return fmt.Errorf("serve un percorso")
		}
		fmt.Println(nucleo.TipoFilesystem(a[0]))

	case "fs-idoneita":
		if len(a) < 1 {
			return fmt.Errorf("serve un percorso")
		}
		fmt.Println(nucleo.Idoneita(a[0]))

	// I **fatti**, uno per riga, invece della frase che ne nasce. E' quel che
	// l'oracolo deve confrontare: un messaggio si rompe al primo ritocco e non
	// si accorge di una semantica cambiata, un campo fa l'opposto.
	case "fs-sonda":
		if len(a) < 1 {
			return fmt.Errorf("serve un percorso")
		}
		s := nucleo.Sonda(a[0])
		fmt.Printf("scrivibile=%v\n", s.Scrivibile)
		fmt.Printf("proprietario_estraneo=%v\n", s.ProprietarioEstraneo)
		fmt.Printf("uid_visto=%d\n", s.UidVisto)
		fmt.Printf("chmod_riesce=%v\n", s.ChmodRiesce)
		fmt.Printf("chmod_attecchisce=%v\n", s.ChmodAttecchisce)
		fmt.Printf("esecuzione_ottenibile=%v\n", s.EsecuzioneOttenibile)
		fmt.Printf("modo_riletto=%o\n", s.ModoRiletto)
		fmt.Printf("tipo=%s\n", s.Tipo)
		fmt.Printf("sorgente=%s\n", s.Sorgente)
		fmt.Printf("uuid=%s\n", s.Uuid)
		fmt.Printf("device=%v\n", s.Device())

	case "config-scrivi":
		if len(a) < 1 {
			return fmt.Errorf("serve una radice")
		}
		compressione := ""
		if len(a) > 1 {
			compressione = a[1]
		}
		return nucleo.ScriviConfig(profilo, a[0], compressione)

	case "config-leggi":
		if len(a) < 1 {
			return fmt.Errorf("serve una radice")
		}
		dati, err := nucleo.LeggiConfig(profilo, a[0])
		if err != nil {
			return err
		}
		return stampaOrdinato(dati)

	case "meta-scrivi":
		if len(a) < 2 {
			return fmt.Errorf("servono percorso e json")
		}
		var dati map[string]any
		if err := json.Unmarshal([]byte(a[1]), &dati); err != nil {
			return err
		}
		return nucleo.ScriviMeta(a[0], dati)

	case "meta-leggi":
		if len(a) < 1 {
			return fmt.Errorf("serve un percorso")
		}
		dati, err := nucleo.LeggiMeta(a[0])
		if err != nil {
			return err
		}
		return stampaOrdinato(dati)

	case "leggibile":
		if len(a) < 1 {
			return fmt.Errorf("servono dei byte")
		}
		n, err := strconv.ParseInt(a[0], 10, 64)
		if err != nil {
			return err
		}
		fmt.Println(nucleo.Leggibile(n))

	case "backend":
		b, err := nucleo.Scegli("", "")
		if err != nil {
			return err
		}
		fmt.Println(b.Nome())

	case "lock":
		// Prende il lock, lo dichiara e lo tiene per <secondi>. Serve al banco
		// per provare che il flock di Go e quello del Python si vedano a
		// vicenda: sono lo stesso lock del kernel, e se non si escludessero
		// l'invariante "un solo lock" varrebbe solo dentro una implementazione.
		if len(a) < 1 {
			return fmt.Errorf("serve una radice")
		}
		secondi := 2.0
		if len(a) > 1 {
			if s, err := strconv.ParseFloat(a[1], 64); err == nil {
				secondi = s
			}
		}
		l, err := nucleo.Lock(profilo, a[0])
		if err != nil {
			return err
		}
		fmt.Println("preso")
		os.Stdout.Sync()
		time.Sleep(time.Duration(secondi * float64(time.Second)))
		return l.Rilascia()

	case "relativo":
		if len(a) < 2 {
			return fmt.Errorf("servono cartella e radice")
		}
		rel, err := nucleo.RelativoDi(a[0], a[1])
		if err != nil {
			return err
		}
		fmt.Println(rel)

	default:
		aiuto()
		return fmt.Errorf("comando sconosciuto: %s", comando)
	}
	return nil
}

// stampaOrdinato emette una mappa come righe `chiave<TAB>valore` ordinate per
// chiave. E' cio' che rende confrontabile con `diff` un JSON che Go e Python
// serializzano con ordini diversi.
func stampaOrdinato(dati map[string]any) error {
	chiavi := make([]string, 0, len(dati))
	for k := range dati {
		chiavi = append(chiavi, k)
	}
	sort.Strings(chiavi)
	for _, k := range chiavi {
		switch v := dati[k].(type) {
		case float64:
			if v == float64(int64(v)) {
				fmt.Printf("%s\t%d\n", k, int64(v))
				continue
			}
			fmt.Printf("%s\t%v\n", k, v)
		default:
			fmt.Printf("%s\t%v\n", k, v)
		}
	}
	return nil
}
