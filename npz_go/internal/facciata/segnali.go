package facciata

import (
	"os"
	"os/signal"
	"syscall"
)

// I quattro segnali che il Python inoltrava a mano. Stanno in un file loro
// perche' `os/signal` non serve al percorso veloce, e tenerlo separato rende
// visibile che lo si paga solo quando si accompagna npm invece di sostituirsi
// a lui.
func notifica(canale chan<- os.Signal) {
	signal.Notify(canale, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)
}

func smetti(canale chan os.Signal) {
	signal.Stop(canale)
}
