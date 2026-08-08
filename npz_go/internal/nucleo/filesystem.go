// Che cosa il filesystem sotto di noi puo' reggere.
//
// Sono fatti sul supporto, non politiche: valgono identici per ogni facciata,
// che sopra ci costruisce decisioni diverse. Chi decide *dove* mettere la
// propria cartella di servizio sta nella facciata; qui si risponde solo alla
// domanda se quel posto reggerebbe.
//
// Sonda misura e non giudica: restituisce fatti, uno per campo. Idoneita e' la
// prima politica costruita sopra, e per ora l'unica; ma il consiglio su *come*
// rimediare — che nomina convenzioni di distribuzione, driver e file di
// configurazione — non e' un fatto sul supporto e non abita qui.

package nucleo

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// Supporto sono i fatti misurati su un posto. Nessuno di questi campi e' un
// giudizio.
//
// Le due domande sulla chmod sono **distinte**, e tenerle separate e' tutto il
// punto di questa struttura:
//
//   - ChmodRiesce — la chiamata ritorna senza errore. E' quel che npm pretende:
//     installa uno shim e gli mette il bit di esecuzione, e un EPERM gli e'
//     fatale anche quando il bit c'era gia'.
//   - ChmodAttecchisce — il modo scritto si rilegge uguale. E' quel che serve a
//     un ripristino fedele, e **non** e' la stessa cosa: ntfs-3g accetta la
//     chiamata e non fa niente, quindi riesce senza attecchire.
//
// Attenzione a ChmodRiesce: **misurato qui riesce anche dove non dovrebbe.**
// Sul disco di prova ntfs-3g accetta la chiamata di chiunque e non fa niente,
// quindi risponde di si'; il rifiuto compare uno strato piu' su, quando
// fuse-overlayfs applica la regola POSIX che ntfs-3g non applica. Il campo che
// predice quel rifiuto e' ProprietarioEstraneo, non questo.
type Supporto struct {
	Percorso             string
	Scrivibile           bool
	Errore               string // perche' non si e' potuto scrivere, se e' il caso
	UidVisto             uint32 // di chi risultano i file, secondo il supporto
	ProprietarioEstraneo bool   // ...e non siamo noi
	ChmodRiesce          bool
	ChmodAttecchisce     bool
	EsecuzioneOttenibile bool // il bit x sopravvive: gli shim di .bin/ girano
	ModoRiletto          uint32
	Tipo                 string // ext4, fuseblk, fuse.rclone, vfat...
	Sorgente             string // /dev/sdc1, gdrive:, tmpfs...
	Opzioni              string // le super options del mount
	Uuid                 string // solo per i device a blocchi veri
}

// Device dice se la sorgente e' un device a blocchi, non un nome di fantasia.
//
// `gdrive:` e `tmpfs` sono sorgenti legittime che nessun fstab puo' indirizzare
// per UUID: e' la condizione che separa un consiglio sensato da uno sbagliato.
func (s Supporto) Device() bool {
	return strings.HasPrefix(s.Sorgente, "/dev/") && s.Uuid != ""
}

// Sonda prova, non chiede: un mkdir, una scrittura, una chmod, una stat.
//
// Non ci si fida del tipo di filesystem dichiarato. Su NTFS via ntfs-3g, per
// dirne una misurata, `chmod 700` viene riletto come `777` — e la chiamata
// *riesce*, il che e' il motivo per cui il guasto non si vede finche' non ci si
// mette in mezzo qualcosa che i permessi li controlla davvero.
//
// Una sola stat: uid e modo vengono dalla stessa chiamata, che e' anche l'unico
// modo di essere sicuri che si riferiscano allo stesso istante.
func Sonda(percorso string) Supporto {
	tipo, sorgente, opzioni := Mountinfo(percorso)
	s := Supporto{
		Percorso: percorso,
		Tipo:     tipo,
		Sorgente: sorgente,
		Opzioni:  opzioni,
		Uuid:     UuidDi(sorgente),
	}

	prova := filepath.Join(percorso, fmt.Sprintf(".fs-probe-%d", os.Getpid()))
	if err := os.Mkdir(prova, 0o755); err != nil {
		s.Errore = err.Error()
		return s
	}
	defer os.RemoveAll(prova)

	file := filepath.Join(prova, "p")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		s.Errore = err.Error()
		return s
	}
	s.Scrivibile = true

	// Non e' un guasto della sonda: e' un fatto sul supporto, e va riportato
	// come tale invece di interrompere la misura.
	s.ChmodRiesce = os.Chmod(file, 0o700) == nil

	fi, err := os.Stat(file)
	if err != nil {
		s.Scrivibile, s.Errore = false, err.Error()
		return s
	}
	modo := uint32(fi.Mode().Perm())
	s.ModoRiletto = modo
	s.ChmodAttecchisce = modo == 0o700
	// I bit del modo, non un access(X_OK): su fuse.rclone `access` risponde di
	// si' e l'esecuzione poi fallisce davvero. Misurato.
	s.EsecuzioneOttenibile = modo&0o100 != 0
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		s.UidVisto = st.Uid
		s.ProprietarioEstraneo = st.Uid != uint32(os.Geteuid())
	}
	return s
}

// Idoneita restituisce il motivo per cui il filesystem non va bene, o "".
//
// **Non e' piu' la politica di freeze**, e la differenza e' voluta. freeze
// conserva alberi arbitrari e deve poterli ripristinare fedeli, quindi esige
// che i permessi POSIX sopravvivano. npz congela node_modules, che vive accanto
// al progetto e quindi **sullo stesso filesystem del delta**: qualunque cosa il
// supporto faccia ai modi, l'ha gia' fatta all'albero prima che npz lo vedesse.
// L'immagine registra cio' che c'e', il copy-up rende cio' che il supporto
// rende, e i due coincidono per costruzione. Su NTFS l'albero e' uniformemente
// 777 e non c'e' niente da perdere — misurato: giro completo, consolidamento
// incluso, un solo regime di modi prima e dopo.
//
// Quel requisito **torna** il giorno in cui delta e immagine dovessero vivere
// su filesystem diversi (fase 2, o la separazione di dynamic/): allora
// l'immagine potrebbe contenere modi che l'upper non sa reggere, e la decadenza
// sarebbe reale. Finche' stanno insieme, no.
//
// Restano tre condizioni, tutte misurate:
//
//  1. **si deve poter scrivere.** Ovvio, ed e' il caso piu' comune.
//  2. **i file devono essere nostri.** E' la condizione dura, e non si vede da
//     qui: ntfs-3g accetta la chmod di chiunque senza farci niente, quindi
//     ChmodRiesce risponde di si'. Il rifiuto nasce uno strato piu' su —
//     fuse-overlayfs applica la regola POSIX vera — e `npm install` muore con
//     EPERM sullo shim che sta installando.
//  3. **il bit di esecuzione si deve poter mettere.** Gli shim di .bin/ sono
//     eseguibili, e un supporto che appiattisce i modi a 644 — fuse.rclone,
//     misurato — li rende non avviabili. Su NTFS l'appiattimento e' a 777, che
//     il bit ce l'ha, e infatti li' girano.
//
// Il rifiuto per tipo di filesystem **e' stato tolto**: rifiutava anche
// fuse-overlayfs con l'upper su ext4, cioe' lo stack di npz stesso, che ogni
// requisito reale lo soddisfa. Quel divieto riguarda l'overlayfs **del kernel**,
// non npz, e vive ora in ReggeUpperdirKernel, dove lo consulta chi sceglie il
// backend.
func Idoneita(percorso string) string {
	s := Sonda(percorso)
	if !s.Scrivibile {
		return fmt.Sprintf("can't write to it: %s", s.Errore)
	}
	if s.ProprietarioEstraneo {
		// Il fatto e basta. Il *perche'* rompe, e come rimediare, li racconta la
		// facciata: ripeterlo qui lo farebbe stampare due volte di fila.
		return fmt.Sprintf("the files here belong to uid %d, not to you (uid %d)",
			s.UidVisto, os.Geteuid())
	}
	if !s.EsecuzioneOttenibile {
		return fmt.Sprintf(
			"the execute bit doesn't survive here (chmod 700 reads back as %o), "+
				"so the shims in .bin/ wouldn't run", s.ModoRiletto)
	}
	return ""
}

// ReggeUpperdirKernel dice se l'overlayfs **del kernel** accetterebbe un
// upperdir di questo tipo.
//
// E' un fatto sul kernel, non una politica di npz, ed e' vero soltanto per la
// via privilegiata: fuse-overlayfs invece un upper su FUSE lo regge — usa
// `user.fuseoverlayfs.*` e whiteout `.wh.` invece degli xattr `trusted.*` che il
// kernel pretende e che un filesystem in user space non puo' garantire.
//
// Serve a chi sceglie il backend, non a chi giudica il supporto: su un disco
// dove npz funziona benissimo via FUSE, la via kernel semplicemente non e'
// disponibile.
func ReggeUpperdirKernel(tipo string) bool {
	if tipo == "" {
		return true
	}
	if strings.HasPrefix(tipo, "fuse") {
		return false
	}
	switch tipo {
	case "ntfs", "ntfs3", "vfat", "exfat":
		return false
	}
	return true
}

// Mountinfo restituisce tipo, sorgente e opzioni del mount che contiene il
// percorso.
//
// Tutti e tre dalla stessa riga di /proc/self/mountinfo, che si leggeva gia' per
// il solo tipo: gli altri due campi erano li' accanto e costavano zero. Si tiene
// il mount **piu' profondo** che contiene il percorso, perche' e' quello che lo
// serve davvero.
//
// NOTA DI PORTING — i mount point in mountinfo sono ottal-escaped (uno spazio e'
// `\040`) e questa funzione, come l'originale Python, **non li decodifica**. Su
// una macchina con uno spazio nel percorso di un mount point il tipo puo' non
// essere riconosciuto. E' una divergenza dal comportamento corretto, non
// dall'originale: si e' scelto di portarla identica perche' l'oracolo
// differenziale confronta i due. Va sistemata in tutte e due le implementazioni
// insieme.
func Mountinfo(percorso string) (tipo, sorgente, opzioni string) {
	obiettivo, err := filepath.EvalSymlinks(percorso)
	if err != nil {
		obiettivo = filepath.Clean(percorso)
	}

	fh, err := os.Open("/proc/self/mountinfo")
	if err != nil {
		return "", "", ""
	}
	defer fh.Close()

	migliore := -1
	sc := bufio.NewScanner(fh)
	for sc.Scan() {
		campi := strings.Fields(sc.Text())
		indice := -1
		for i, c := range campi {
			if c == "-" {
				indice = i
				break
			}
		}
		if indice < 0 || indice+1 >= len(campi) || len(campi) < 5 {
			continue
		}
		punto := filepath.Clean(campi[4])
		if punto == obiettivo || dentro(punto, obiettivo) {
			if n := profondita(punto); n > migliore {
				migliore = n
				tipo = campi[indice+1]
				sorgente = campo(campi, indice+2)
				opzioni = campo(campi, indice+3)
			}
		}
	}
	return tipo, sorgente, opzioni
}

// PuntoDiMount e' dove e' montato il filesystem che contiene il percorso.
func PuntoDiMount(percorso string) string {
	obiettivo, err := filepath.EvalSymlinks(percorso)
	if err != nil {
		obiettivo = filepath.Clean(percorso)
	}
	fh, err := os.Open("/proc/self/mountinfo")
	if err != nil {
		return ""
	}
	defer fh.Close()

	migliore, punto := -1, ""
	sc := bufio.NewScanner(fh)
	for sc.Scan() {
		campi := strings.Fields(sc.Text())
		if len(campi) < 5 {
			continue
		}
		candidato := filepath.Clean(campi[4])
		if candidato == obiettivo || dentro(candidato, obiettivo) {
			if n := profondita(candidato); n > migliore {
				migliore, punto = n, campi[4]
			}
		}
	}
	return punto
}

// TipoFilesystem e' il tipo di filesystem che contiene il percorso, letto da
// /proc/self/mountinfo. Restituisce "" se non si sa.
func TipoFilesystem(percorso string) string {
	tipo, _, _ := Mountinfo(percorso)
	return tipo
}

// UuidDi e' il UUID di un device, dal solo /dev/disk/by-uuid.
//
// Niente blkid e niente lsblk: sono sottoprocessi, il primo vuole privilegi, e i
// symlink che udev mantiene dicono la stessa cosa a chiunque sappia leggere una
// directory.
func UuidDi(sorgente string) string {
	if !strings.HasPrefix(sorgente, "/dev/") {
		return ""
	}
	atteso, err := filepath.EvalSymlinks(sorgente)
	if err != nil {
		return ""
	}
	base := "/dev/disk/by-uuid"
	voci, err := os.ReadDir(base)
	if err != nil {
		return ""
	}
	for _, voce := range voci {
		risolto, err := filepath.EvalSymlinks(filepath.Join(base, voce.Name()))
		if err == nil && risolto == atteso {
			return voce.Name()
		}
	}
	return ""
}

// DriverDiMount e' il programma che serve un mount FUSE, letto da
// /proc/<pid>/cmdline.
//
// mountinfo dice `fuseblk` e si ferma li': il tipo non nomina il driver, e
// indovinarlo sarebbe il modo piu' rapido di dare un consiglio sbagliato. Il
// demone invece e' un processo, la sua riga di comando contiene device e
// mountpoint, e /proc/<pid>/cmdline si legge anche quando il processo e' di root
// — verificato.
//
// Si scandisce /proc una volta sola e solo quando si sta gia' per rifiutare: nel
// caso normale questa funzione non viene chiamata mai.
func DriverDiMount(sorgente, punto string) string {
	if sorgente == "" || punto == "" {
		return ""
	}
	voci, err := os.ReadDir("/proc")
	if err != nil {
		return ""
	}
	for _, voce := range voci {
		if !soloCifre(voce.Name()) {
			continue
		}
		grezzo, err := os.ReadFile(filepath.Join("/proc", voce.Name(), "cmdline"))
		if err != nil {
			continue
		}
		var argv []string
		for _, a := range strings.Split(string(grezzo), "\x00") {
			if a != "" {
				argv = append(argv, a)
			}
		}
		if len(argv) < 3 {
			continue
		}
		var haSorgente, haPunto bool
		for _, a := range argv {
			if a == sorgente {
				haSorgente = true
			}
			if a == punto {
				haPunto = true
			}
		}
		if haSorgente && haPunto {
			return filepath.Base(argv[0])
		}
	}
	return ""
}

func campo(campi []string, i int) string {
	if i < len(campi) {
		return campi[i]
	}
	return ""
}

// dentro dice se `antenato` e' un genitore (a qualsiasi livello) di `figlio`.
// E' il `punto in obiettivo.parents` del Python.
func dentro(antenato, figlio string) bool {
	if antenato == "/" {
		return figlio != "/"
	}
	return strings.HasPrefix(figlio, antenato+string(filepath.Separator))
}

// profondita conta i componenti di un percorso, come len(Path(p).parts).
func profondita(p string) int {
	if p == "/" {
		return 1
	}
	return 1 + strings.Count(strings.TrimSuffix(p, "/"), "/")
}
