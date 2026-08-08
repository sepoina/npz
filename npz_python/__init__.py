"""npz — wrapper di npm che congela `node_modules` in una immagine montata.

La facciata di dominio sul nucleo di `lib`, gemella di `freeze`. Dove `freeze`
ha una radice condivisa fra progetti dichiarata con `init`, `npz` ha **una
radice per progetto**, che nasce da sola accanto al `package.json` e si chiama
`.npz`.

Il disegno sta in "doc/piano di implementazione.md", e la fase 2 — una immagine
per strato invece di una sola — in "doc/piano di implementazione fase 2.md".

Attenzione a cosa si importa qui dentro: questo modulo viene caricato anche sul
percorso veloce, che sta davanti a ogni comando npm e ha un budget di pochi
millisecondi. `lib` non importa niente che il lanciatore non abbia gia' caricato
— `os`, e basta — e va tenuto cosi'. Vale anche per cio' che si *legge*: la
versione viene da `progetto.conf`, ma quel file si apre solo se qualcuno chiede
`VERSIONE`, che sul percorso veloce non succede mai.
"""

from .lib import Profilo

from .veloce import SENTINELLA, SERVIZIO

# I simboli di versione sono due — questo e `lib.VERSIONE` — e il gemello Go ne
# ha due per la stessa ragione: `facciata.Versione` e `nucleo.Versione`, che
# `build.sh` marchia insieme da `progetto.conf`. Qui la fonte e' quello stesso
# file, e passa da `lib`: la versione che l'aiuto stampa e quella che finisce
# nel `creata_da` di uno store non sono due valori che si somigliano, sono lo
# stesso valore letto una volta.
#
# Pigro come quello di `lib`, e per la stessa ragione: questo modulo sta sul
# percorso veloce, e sul percorso veloce la versione non serve. Chi la chiede —
# `cli.aiuto()` — e' gia' sul percorso lento.
def __getattr__(nome: str):
    if nome == "VERSIONE":
        from .lib import VERSIONE
        letta = globals()["VERSIONE"] = VERSIONE
        return letta
    raise AttributeError(f"module {__name__!r} has no attribute {nome!r}")


# Quale delle due implementazioni sta girando. Finche' Python e Go convivono e
# si verificano a vicenda, chi legge un output deve poter dire da quale dei due
# viene senza indovinarlo dal percorso dell'eseguibile: un banco che confronta
# le due, o un utente che ne ha installate entrambe, altrimenti attribuiscono un
# comportamento al gemello sbagliato. La facciata Go dichiara `go` allo stesso
# modo e nello stesso posto.
IMPLEMENTAZIONE = "python"

# I nomi vengono da `veloce`, che e' l'unico modulo che li deve conoscere senza
# importare niente: `stato()` riconosce la sentinella per distinguere *rotto* da
# *scavalcato* (§6 bis). Tenerli anche qui a mano vorrebbe dire due verita' che
# possono divergere in silenzio — e divergendo, l'autoriparazione smetterebbe di
# riconoscere il proprio mountpoint.
PROFILO = Profilo(servizio=SERVIZIO, sentinella=SENTINELLA)
