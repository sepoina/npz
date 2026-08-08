// Consegnare il comando a npm, nei due modi.
//
// La divisione fra Consegna e Accompagna non e' un'ottimizzazione di Python: e'
// il motivo per cui `npm run dev` non si trascina dietro un processo npz fermo
// per ore, ed e' la ragione principale per cui il §3 del piano aveva scartato
// Node — che un exec che sostituisce il processo non ce l'ha.

package facciata

import (
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"npz/internal/voce"
)

// IoStesso: il nostro eseguibile a percorso reale, per non rincorrerci.
func IoStesso() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if reale, err := filepath.EvalSymlinks(exe); err == nil {
		return reale
	}
	return exe
}

// TrovaNpm da' npm risolto a percorso assoluto, saltando noi stessi.
//
// Un wrapper che esegue `npm` per nome, su una macchina dove qualcuno ha messo
// in PATH un `npm` che punta a `npz`, entra in ricorsione infinita. Le alias di
// shell non si ereditano e non fanno danno; un symlink si'.
func TrovaNpm(io string) string {
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		if dir == "" {
			continue
		}
		candidato := filepath.Join(dir, "npm")
		if syscall.Access(candidato, 0x01 /* X_OK */) != nil {
			continue
		}
		if eDir(candidato) {
			continue
		}
		if io != "" {
			if reale, err := filepath.EvalSymlinks(candidato); err == nil && reale == io {
				continue // siamo noi travestiti: si tira dritto
			}
		}
		return candidato
	}
	return ""
}

// MancaNpm e' l'uscita quando npm non c'e'.
func MancaNpm() int {
	voce.Sbaglia("npm isn't on PATH.")
	voce.ChiudiTutto()
	return 127
}

// Consegna sostituisce il processo con npm. Non torna.
//
// E' il motivo per cui il percorso veloce e' davvero veloce: il processo npz
// sparisce, e npm eredita TTY, segnali e codice di uscita senza una riga di
// codice che se ne occupi.
//
// La chiamata a ChiudiTutto() **non e' un defer**, e non e' una svista.
// syscall.Exec non esegue le funzioni differite: il processo viene sostituito e
// tutto cio' che era in coda a un defer semplicemente non succede. Un
// `defer voce.ChiudiTutto()` in cima a main funzionerebbe sull'uscita normale e
// fallirebbe proprio sul percorso piu' frequente del programma, lasciando
// l'output di npm dentro il turno di parola di npz. E' il §6.1 del piano.
func Consegna(npm string, argv []string) {
	voce.ChiudiTutto() // il turno di parola finisce qui
	err := syscall.Exec(npm, append([]string{npm}, argv...), os.Environ())
	// Si arriva qui solo se exec fallisce.
	voce.Sbaglia("couldn't run npm: %v", err)
	voce.ChiudiTutto()
	os.Exit(127)
}

// Accompagna esegue npm e ne aspetta la fine, restituendone il codice di uscita.
//
// Serve quando dopo npm c'e' del lavoro da fare — guardare il delta, decidere
// se consolidare — e quindi non ci si puo' sostituire a lui. Costa un processo
// in piu' che resta in attesa, ed e' il caso non frequente.
//
// NOTA DI PORTING (§6.2) — il Python fa fork(), poi execv nel figlio, poi
// installa quattro gestori di segnale, poi waitpid in un ciclo che ritenta su
// EINTR, poi ripristina i gestori, poi decodifica WIFSIGNALED per rendere
// 128+segnale. In Go **fork() senza exec immediato non e' supportato** — il
// runtime ha gia' avviato thread e scheduler — ma non serve: os/exec fa
// fork+exec internamente e in modo sicuro, e il resto sono dieci righe invece
// di quaranta. E' l'unico punto del porting in cui il codice Go e' piu'
// leggibile dell'originale.
func Accompagna(npm string, argv []string) int {
	voce.ChiudiTutto() // e anche qui: dopo, parla npm

	cmd := exec.Command(npm, argv...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Start(); err != nil {
		voce.Sbaglia("couldn't run npm: %v", err)
		voce.ChiudiTutto()
		return 127
	}

	// I segnali vanno inoltrati: chi preme ctrl-c si aspetta di fermare npm, e
	// noi dobbiamo comunque sopravvivergli per finire il lavoro.
	segnali := make(chan os.Signal, 4)
	notifica(segnali)
	fine := make(chan struct{})
	go func() {
		for {
			select {
			case s := <-segnali:
				_ = cmd.Process.Signal(s)
			case <-fine:
				return
			}
		}
	}()

	err := cmd.Wait()
	close(fine)
	smetti(segnali)

	if err == nil {
		return 0
	}
	if uscita, ok := err.(*exec.ExitError); ok {
		if s, ok := uscita.Sys().(syscall.WaitStatus); ok {
			if s.Signaled() {
				return 128 + int(s.Signal())
			}
			return s.ExitStatus()
		}
		return uscita.ExitCode()
	}
	return 127
}
