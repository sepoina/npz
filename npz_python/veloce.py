"""Il percorso veloce: quel che si fa prima di sapere se serve fare qualcosa.

`npz` sta davanti a **ogni** comando npm, compresi quelli dentro un `npm run` in
loop. La fase 0 ha misurato 14 ms contro i 128 di `npm run` — l'11%, accettabile
— ma solo con la disciplina che questo modulo incarna:

    niente `pathlib`, niente `subprocess`, niente `argparse`, niente `json`.

Solo `os` e `sys`. La stessa passata scritta con `pathlib` costa 39 ms, e
importare il pacchetto intero ne costa 49: fra la via disciplinata e quella
naturale ci sono 62 millisecondi, mentre fra Python e un binario compilato ce ne
sono dieci. **La lingua non e' la variabile dominante: lo e' non importare
niente qui.**

Lo stato di un progetto si legge con `os.stat` su tre nomi, senza aprire né
analizzare alcun file — per questo il rifiuto dell'utente e' un file vuoto e non
una chiave in una configurazione.
"""

import os
import sys

MANIFESTO = "package.json"
CARTELLA = "node_modules"

# La cartella di servizio ha due nomi, e il nome *e'* lo stato.
#
# Mentre si lavora si chiama `.npz` ed e' nascosta: accanto c'e' `node_modules`
# montata, e il progetto ha l'aspetto di sempre. Quando invece e' ferma —
# smontata, con l'albero che non esiste — prende il nome visibile, cosi' che una
# cartella di progetto dormiente non sembri una cartella a cui manca qualcosa,
# ma dichiari da sola che cosa e' successo e dove sono finiti i dati.
#
# Non e' un segnaposto: e' la stessa cartella, con addosso il nome giusto per lo
# stato in cui si trova.
SERVIZIO = ".npz"
SERVIZIO_FERMO = "node_modules.frozen"

# Sul filesystem sotto il mount: invisibile mentre il mount c'e', unica cosa
# presente quando e' caduto. Sta qui e non solo nel `PROFILO` del pacchetto
# perche' `stato()` la deve riconoscere senza importare niente — ed e' `PROFILO`
# a leggerla da qui, cosi' i due nomi non possono divergere.
SENTINELLA = ".npz_automount_here"

# Il suffisso delle copie messe da parte (§6 bis). Una sola per volta, ovunque
# si trovi: l'albero di npm resta nella radice di progetto, dove si vede,
# l'immagine vecchia e il suo delta dentro la cartella di servizio.
SUPERATO = ".superseded"
ALBERO_SUPERATO = CARTELLA + SUPERATO

RIFIUTO = os.path.join(SERVIZIO, "no")


def nome_servizio(progetto: str) -> str | None:
    """Quale dei due nomi esiste adesso, o None se non ce n'e' nessuno."""
    for nome in (SERVIZIO, SERVIZIO_FERMO):
        if os.path.isdir(os.path.join(progetto, nome)):
            return nome
    return None

# Gli stati del §6 del piano, piu' i due che non sono di npz. Gli identificatori
# restano italiani come tutto il resto di questo modulo — sono nomi di variabile,
# nessuno li legge — ma il valore che portano e' cio' che `npz status` stampa
# alla lettera, quindi e' in inglese.
ESTRANEO = "outside"         # nessun package.json qui sopra
CANDIDATO = "candidate"      # node_modules vero, npz non ne sa niente
RIFIUTATO = "declined"       # l'utente ha detto no, e non glielo si richiede
VERGINE = "fresh"            # progetto senza node_modules e senza .npz
MONTATO = "mounted"          # lo stato di lavoro
CONGELATO = "attached"       # immagine presente, cartella assente
ROTTO = "broken"             # il nostro mountpoint scoperto: dentro c'e' solo la sentinella
SCAVALCATO = "bypassed"      # un albero vero che npz non ha costruito, al posto del mount


def solo_sentinella(cartella: str) -> bool:
    """Se dentro non c'e' altro che la sentinella.

    E' cio' che separa *rotto* da *scavalcato* (§6 bis), e i due non si possono
    confondere: sul primo si rimonta in silenzio, sul secondo montare
    coprirebbe l'albero dell'utente lasciandolo invisibile a occupare disco.

    Costa uno `scandir` invece di uno `stat`, ma si esce alla prima voce che non
    sia la sentinella — quindi su un `node_modules` vero e' una lettura sola — e
    si paga solo nel ramo non montato, che va comunque al percorso lento.
    """
    try:
        with os.scandir(cartella) as voci:
            for voce in voci:
                if voce.name != SENTINELLA:
                    return False
    except OSError:
        return False
    return True


def trova_progetto(partenza: str | None = None) -> str | None:
    """La prima cartella, risalendo, che contiene un package.json.

    E' il criterio con cui npm stesso decide dove sta il progetto: usarne un
    altro produrrebbe divergenze silenziose fra cio' che npz crede di gestire e
    cio' su cui npm opera. Ci si ferma al **confine di filesystem** come fa
    `freeze.radice`, perche' l'upperdir di overlayfs deve stare sullo stesso
    filesystem del suo workdir.
    """
    corrente = os.path.realpath(partenza or os.getcwd())
    try:
        dispositivo = os.stat(corrente).st_dev
    except OSError:
        return None
    while True:
        if os.path.isfile(os.path.join(corrente, MANIFESTO)):
            return corrente
        genitore = os.path.dirname(corrente)
        if genitore == corrente:
            return None
        try:
            if os.stat(genitore).st_dev != dispositivo:
                return None
        except OSError:
            return None
        corrente = genitore


def stato(progetto: str | None) -> str:
    """In quale degli otto stati siamo. Quattro `os.stat`, nel caso normale."""
    if progetto is None:
        return ESTRANEO
    cartella = os.path.join(progetto, CARTELLA)
    servizio = nome_servizio(progetto)
    if servizio is None:
        return CANDIDATO if os.path.isdir(cartella) else VERGINE
    if os.path.isfile(os.path.join(progetto, servizio, "static", CARTELLA + ".img")):
        if not os.path.isdir(cartella):
            return CONGELATO
        if os.path.ismount(cartella):
            return MONTATO
        return ROTTO if solo_sentinella(cartella) else SCAVALCATO
    if os.path.exists(os.path.join(progetto, servizio, "no")):
        return RIFIUTATO
    return CANDIDATO if os.path.isdir(cartella) else VERGINE


# ── consegnare il comando a npm ──────────────────────────────────────────────

def trova_npm(io_stesso: str) -> str | None:
    """npm risolto a percorso assoluto, saltando noi stessi.

    Un wrapper che esegue `npm` per nome, su una macchina dove qualcuno ha messo
    in PATH un `npm` che punta a `npz`, entra in ricorsione infinita. Le alias di
    shell non si ereditano e non fanno danno; un symlink si'.
    """
    for cartella in os.environ.get("PATH", "").split(os.pathsep):
        if not cartella:
            continue
        candidato = os.path.join(cartella, "npm")
        try:
            if not os.access(candidato, os.X_OK) or os.path.isdir(candidato):
                continue
            if os.path.realpath(candidato) == io_stesso:
                continue                      # siamo noi travestiti: si tira dritto
        except OSError:
            continue
        return candidato
    return None


def consegna(npm: str, argv: list[str]) -> None:
    """Sostituisce il processo con npm. Non torna.

    E' il motivo per cui il percorso veloce e' davvero veloce: il processo Python
    sparisce, e npm eredita TTY, segnali e codice di uscita senza una riga di
    codice. Node non ha un `exec` che sostituisca il processo, e questa e' la
    ragione principale per cui npz non e' scritto in JavaScript.
    """
    chiudi()                              # il turno di parola finisce qui
    os.execv(npm, [npm] + argv)


def accompagna(npm: str, argv: list[str]) -> int:
    """Esegue npm e ne aspetta la fine, restituendone il codice di uscita.

    Serve quando dopo npm c'e' del lavoro da fare — guardare il delta, decidere
    se consolidare — e quindi non ci si puo' sostituire a lui. Costa un processo
    in piu' che resta in attesa, ed e' il caso non frequente.
    """
    import signal

    chiudi()                              # e anche qui: dopo, parla npm
    figlio = os.fork()
    if figlio == 0:
        os.execv(npm, [npm] + argv)
        os._exit(127)

    # I segnali vanno inoltrati: chi preme ctrl-c si aspetta di fermare npm, e
    # noi dobbiamo comunque sopravvivergli per finire il lavoro.
    def inoltra(numero, _frame):
        try:
            os.kill(figlio, numero)
        except ProcessLookupError:
            pass

    precedenti = {}
    for numero in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
        try:
            precedenti[numero] = signal.signal(numero, inoltra)
        except (OSError, ValueError):
            pass
    try:
        while True:
            try:
                _, esito = os.waitpid(figlio, 0)
                break
            except InterruptedError:
                continue
    finally:
        for numero, precedente in precedenti.items():
            try:
                signal.signal(numero, precedente)
            except (OSError, ValueError):
                pass

    if os.WIFSIGNALED(esito):
        return 128 + os.WTERMSIG(esito)
    return os.WEXITSTATUS(esito)


# ── la voce di npz ───────────────────────────────────────────────────────────
#
# Ogni riga che npz emette passa di qui e porta il proprio segno. Serve perche'
# in una stessa esecuzione npz e npm parlano a turno — npz annuncia, npm lavora,
# npz conclude — e senza un marcatore le due voci si confondono. Il segno sta su
# *ogni* riga e non solo sulla prima: i messaggi di errore sono spesso elenchi,
# e una riga senza segno in mezzo a un elenco sembra output di npm.
#
# E' una sbarra verticale in box drawing, tinta, che si apre con una testa e si
# chiude con una coda:
#
#      ╥
#      ║  congelata: 588 MiB in 31.667 file → 234 MiB in un file solo
#      ╨
#
# Testa e coda non sono decorazione: delimitano il **turno di parola**. La sbarra
# non appartiene al singolo messaggio ma a tutta la sequenza di messaggi
# consecutivi, e si chiude esattamente dove npz cede il terminale — prima di ogni
# `exec` e di ogni fork verso npm — e all'uscita del processo. Quel che sta fra
# la testa e la coda l'ha detto npz; tutto il resto e' di npm.

TESTA = " ╥"
SEGNO = " ║  "
CODA = " ╨"

# Giallo tenue: un terminale non ha opacita', ha `2` — l'attributo *faint*, che
# e' il modo in cui i terminali dicono "meta' intensita'". Vale piu' di un giallo
# a 24 bit smorzato a mano verso il fondo, perche' quello andrebbe scelto sapendo
# se il tema e' chiaro o scuro, mentre `faint` lo compone col fondo vero.
VOCE = "\033[2;33m"        # giallo a meta' intensita': la voce di npz
ERRORE = "\033[31m"        # rosso pieno: quando si ferma, il segno non sussurra
SPENTO = "\033[0m"

_aperte: dict = {}         # flusso -> se in questo turno si e' detto un errore


def _tinge(glifo: str, dove, errore: bool = False) -> str:
    """Il colore sta sul segno, mai sul testo: il testo resta copiabile."""
    try:
        if not dove.isatty():
            return glifo
    except (AttributeError, ValueError):
        return glifo
    return (ERRORE if errore else VOCE) + glifo + SPENTO


def apri(dove, errore: bool = False) -> None:
    """Stampa la testa, se la sbarra su questo flusso non e' gia' aperta.

    Un errore detto a meta' turno tinge di rosso anche la coda: il colore della
    chiusura e' il modo piu' economico per dire com'e' andata a chi guarda la
    fine di un blocco senza rileggerlo.
    """
    if dove in _aperte:
        _aperte[dove] = _aperte[dove] or errore
        return
    if not _aperte:
        # Solo alla prima parola, e mai a import: sul percorso veloce npz tace,
        # e questo modulo non deve importare niente oltre `os` e `sys`.
        import atexit
        atexit.register(chiudi)
    _aperte[dove] = errore
    print(_tinge(TESTA, dove, errore), file=dove)


def chiudi(dove=None) -> None:
    """Chiude la sbarra — su un flusso, o su tutti — e svuota i buffer.

    Va chiamata prima di cedere il terminale a npm. Non e' solo cortesia
    tipografica: `execv` non fa girare gli `atexit`, e il `fork` di
    `accompagna()` duplicherebbe nel figlio quel che non e' stato svuotato,
    facendo comparire due volte le stesse righe.
    """
    for flusso in ([dove] if dove is not None else list(_aperte)):
        if flusso not in _aperte:
            continue
        andata_male = _aperte.pop(flusso)
        try:
            _sgombra(flusso)
            print(_tinge(CODA, flusso, andata_male), file=flusso)
        except (OSError, ValueError):
            pass
    for flusso in (sys.stdout, sys.stderr, dove):
        try:
            flusso.flush()
        except (AttributeError, OSError, ValueError):
            pass


def segno(dove=None, errore: bool = False) -> str:
    """Il prefisso di riga, tinto, aprendo la sbarra se serve.

    Serve a chi non passa da `voce()` perche' scrive una riga senza a capo —
    la domanda della conferma, che aspetta la risposta sulla stessa riga.
    """
    dove = dove or sys.stderr
    apri(dove, errore)
    _sgombra(dove)
    return _tinge(SEGNO, dove, errore)


# Il girello. Sono i punti braille di npm, e non per somiglianza: hanno la
# stessa larghezza in ogni cella, quindi la riga non balla mentre giri, e sono
# gia' installati ovunque giri npm — che e' la definizione del nostro pubblico.
GIRELLO = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

_in_corso: dict = {}       # flusso -> c'e' una riga di avanzamento da sgombrare
_giro = 0                  # a che punto e' il girello


def avanzamento(testo: str, flusso=None) -> None:
    """Una riga che si riscrive sopra se stessa, invece di accumularsi.

    Serve alle operazioni lunghe, che qui sono lunghe davvero: congelare 100.000
    file su un disco servito da FUSE sono minuti, e un messaggio solo all'inizio
    non distingue "sta lavorando" da "si e' piantato" — che e' esattamente la
    domanda a cui l'utente ha bisogno di rispondere.

    **Solo su TTY.** Redirigendo, `\\r` produrrebbe un file con dentro tutte le
    revisioni della stessa riga; e un log non ha bisogno di sapere che a un certo
    istante si era al 47%. Fuori dal terminale questa funzione tace, e restano i
    messaggi di `voce()`, che sono lo scheletro del racconto.

    La riga **non e' il messaggio finale**: e' impaginazione che scade. Chi ha
    qualcosa da lasciare scritto lo dice con `voce()`, che la sgombra da se'.

    **Il girello avanza a ogni ridisegno**, e non e' decorazione. I numeri qui
    dentro a volte stanno fermi — due ridisegni consecutivi possono cadere sullo
    stesso migliaio, o su un file grande che tiene occupato `mkfs.erofs` — e una
    riga identica alla precedente si legge come un programma piantato. Il
    carattere che gira dice l'unica cosa che il numero da solo non dice: che
    qualcuno e' ancora vivo e sta contando.
    """
    global _giro
    dove = flusso or sys.stderr
    try:
        if not dove.isatty():
            return
    except (AttributeError, ValueError):
        return
    apri(dove)
    _in_corso[dove] = True
    giro = GIRELLO[_giro % len(GIRELLO)]
    _giro += 1
    # `\r` torna a inizio riga, `\033[K` cancella fino a fine riga: senza, una
    # riga piu' corta della precedente ne lascerebbe scoperta la coda.
    print(f"\r{_tinge(SEGNO, dove)}{giro} {testo}\033[K", end="", file=dove)
    _svuota(dove)


def _sgombra(dove) -> None:
    """Toglie di mezzo l'avanzamento prima che qualcun altro scriva.

    Chiamata da `voce()`, da `segno()` e da `chiudi()`: tutto cio' che stampa
    passa da una delle tre, quindi nessuno puo' scrivere sopra una riga viva
    senza accorgersene.
    """
    if _in_corso.pop(dove, None):
        print("\r\033[K", end="", file=dove)


def _svuota(dove) -> None:
    try:
        dove.flush()
    except (AttributeError, OSError, ValueError):
        pass


def voce(testo: object, flusso=None, errore: bool = False) -> None:
    dove = flusso or sys.stderr
    apri(dove, errore)
    _sgombra(dove)
    pieno = _tinge(SEGNO, dove, errore)
    # Sulle righe vuote la sbarra resta — e' la continuita' del turno di parola —
    # ma gli spazi dopo no: una riga senza testo non deve avere una coda di
    # bianchi che si vede solo quando la si copia.
    vuoto = _tinge(SEGNO.rstrip(), dove, errore)
    for riga in str(testo).splitlines() or [""]:
        print(f"{pieno if riga else vuoto}{riga}", file=dove)


def manca_npm() -> int:
    voce("npm isn't on PATH.", errore=True)
    return 127
