"""Il nucleo condiviso: congelare una cartella in una immagine EROFS compressa.

Qui sta il *meccanismo* — costruire l'immagine, montarla, tenere lo stato, dire
che cosa si puo' congelare — e non la *politica*, che appartiene alle due
facciate: `freeze` (una radice condivisa fra progetti, ritrovata risalendo
l'albero) e `npz` (una radice per progetto, dentro `.npz`).

Il disegno sta in claim.md, le misure che l'hanno prodotto in
"taccuino di viaggio.md". Le tre invarianti che vincolano ogni operazione che
scrive — un solo lock, formato versionato, costruisci prima di cancellare — sono
implementate qui dentro fin dalla prima riga: aggiungerle dopo costa molto.
"""

import os

# ── la versione, che non si scrive qui ───────────────────────────────────────
#
# `VERSIONE` non e' una costante di questo modulo: viene da `progetto.conf`
# nella radice del progetto, lo stesso file da cui `build.sh` marchia i due
# simboli del gemello Go. Finche' era scritta qui a mano ha fatto quel che fa
# ogni copia — e' rimasta a 0.1.0 mentre il progetto arrivava a 0.2.2, cioe' gli
# store creati dal Python dichiaravano nel `creata_da` un numero che non era
# quello di nessun rilascio.
#
# **Si legge pigramente**, con il `__getattr__` di modulo qui sotto, e non a
# import. La ragione e' il percorso veloce: questo modulo viene caricato
# davanti a ogni comando npm — `npz_python/__init__` fa `from .lib import
# Profilo` — e la versione non serve a nessuno dei comandi che passano di li'.
# Leggerla a import vorrebbe dire un `open` e una lettura per ogni `npm run`
# dentro un loop, per un numero che quel giro non stampa mai. Cosi' invece il
# file si apre solo quando qualcuno chiede davvero `VERSIONE`, e chi lo chiede
# — l'aiuto, `stato.scrivi_meta()` — sta sempre sul percorso lento.
#
# `os` non e' un import in piu': il lanciatore lo ha gia' caricato prima di
# arrivare qui, quindi costa una voce in `sys.modules` e niente altro. E' la
# stessa disciplina di `veloce`, non un'eccezione.
_CONF = "progetto.conf"

# Quel che si dice quando il conf non si trova. E' la parola del Go per lo
# stesso caso — un binario costruito senza passare da `build.sh` — e dire la
# stessa cosa nei due gemelli vale piu' di un numero inventato: "sviluppo"
# significa *questo non e' un rilascio*, e lo significa in entrambi.
_IGNOTA = "sviluppo"


def _versione() -> str:
    """`VERSIONE=` di progetto.conf, cercato risalendo da questo file.

    Si risale invece di comporre un `../..` perche' il nucleo non sa quanto sia
    profondo: e' condiviso con `freeze`, dove sta a un altro livello. Ci si
    ferma al **primo** conf incontrato — se c'e' ma non dichiara la versione,
    la risposta e' `_IGNOTA` e non quella di un conf piu' in alto, che sarebbe
    di un altro progetto.

    Il parsing e' una riga perche' il formato e' `chiave=valore` di shell e
    qui interessa una chiave sola. Un lettore generale servirebbe a chi legge
    anche le altre, e per ora quel qualcuno e' bash.
    """
    cartella = os.path.dirname(os.path.realpath(__file__))
    while True:
        percorso = os.path.join(cartella, _CONF)
        if os.path.isfile(percorso):
            try:
                with open(percorso, encoding="utf-8") as conf:
                    for riga in conf:
                        if riga.startswith("VERSIONE="):
                            return riga.split("=", 1)[1].strip().strip("\"'")
            except OSError:
                pass
            return _IGNOTA
        genitore = os.path.dirname(cartella)
        if genitore == cartella:
            return _IGNOTA
        cartella = genitore


def __getattr__(nome: str):
    """La lettura pigra (PEP 562), e una volta sola.

    Il valore si deposita in `globals()`: da li' in poi lo trova la ricerca
    normale degli attributi e questa funzione non viene piu' chiamata, quindi
    il conf si apre al massimo una volta per processo.
    """
    if nome == "VERSIONE":
        letta = globals()["VERSIONE"] = _versione()
        return letta
    raise AttributeError(f"module {__name__!r} has no attribute {nome!r}")


# Versione del formato su disco. Cambia solo quando cambia la struttura della
# cartella di servizio o dei .meta, non a ogni rilascio: e' cio' che permettera'
# di leggere store creati da versioni precedenti invece di dichiararli
# illeggibili.
FORMATO = 1

# lz4hc perche' misurato piu' veloce del non compresso e il 40% piu' piccolo:
# comprimere significa leggere meno byte, e lz4 decomprime piu' in fretta di
# quanto il supporto consegni.
COMPRESSIONE = "lz4hc"


class Errore(Exception):
    """Errore previsto, da mostrare all'utente senza traceback."""


class Profilo:
    """Come si chiamano le cose su disco. E' l'unica differenza fra le facciate.

    Il nucleo non sa se sta servendo `freeze` o `npz`, e non deve saperlo: sa
    leggere questo. Finche' i nomi erano costanti di modulo, `lib` era condiviso
    nella struttura ma non nel comportamento — `npz` non poteva ottenere `.npz`
    senza modificarlo.

    Non sta qui il *segnaposto*: quello e' un'idea di `freeze`, e `npz` ha deciso
    di non averne (cfr. npz/piano di implementazione.md, sezione 5). Vive percio'
    in `freeze.segnaposto`, come `radice` vive nella facciata e non qui.
    """

    __slots__ = ("servizio", "sentinella")

    def __init__(self, servizio: str, sentinella: str):
        # Nome della cartella di servizio nella radice di lavoro.
        self.servizio = servizio
        # File nascosto dentro il mountpoint, sul filesystem sottostante:
        # invisibile quando il mount c'e', unica cosa presente quando e' caduto.
        self.sentinella = sentinella

    def __repr__(self):
        return f"Profilo({self.servizio!r})"
