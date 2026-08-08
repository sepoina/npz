"""Il percorso lento: quando c'e' davvero qualcosa da fare.

Qui si e' gia' pagato l'import del pacchetto, e si sta per pagare un mount o un
`mkfs.erofs`: i millisecondi non contano piu'. Valgono invece le tre invarianti
di `lib` — un solo lock, formato versionato, **costruisci prima di cancellare**.

Ogni messaggio di npz va su stderr, e ogni domanda su /dev/tty: `npm view x
--json | jq` non deve trovare parole nostre dentro la pipe.
"""

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from .lib import Errore
from .lib import immagine as img
from .lib import mount, perimetro, stato as st

from . import IMPLEMENTAZIONE, PROFILO, VERSIONE, comandi, progetto as prog, veloce

RELATIVO = veloce.CARTELLA          # "node_modules": l'unico albero che npz gestisce


def dice(*testo) -> None:
    """Diagnostica: su stderr, perche' `npz view x --json | jq` deve restare pulito."""
    veloce.voce(" ".join(str(t) for t in testo))


def riferisce(*testo) -> None:
    """Cio' che l'utente ha chiesto: su stdout, ma con lo stesso segno."""
    veloce.voce(" ".join(str(t) for t in testo), flusso=sys.stdout)


def avanza(testo: str) -> None:
    """La riga che si riscrive sopra se stessa. Come `dice`, quindi su stderr.

    Le fasi lunghe di npz sono attraversate di alberi enormi su dischi lenti, e
    fra loro non c'e' un solo momento in cui il processo abbia qualcosa da
    stampare: senza questa riga il congelamento di 100.000 file e' un quarto
    d'ora di silenzio, indistinguibile da un blocco. Misurato su NTFS: 48 secondi
    di sole attraversate prima ancora che `mkfs.erofs` parta.
    """
    veloce.avanzamento(testo)


def _quanto(fatti: int, totale: int) -> str:
    """`47.312 / 114.249 (41%)`, o il solo conteggio se il totale non si sa."""
    if totale <= 0:
        return f"{fatti:,}"
    return f"{fatti:,} / {totale:,} ({min(100, 100 * fatti // totale)}%)"


def temporanea_di(p: dict) -> Path:
    """Dove `immagine.costruisci()` scrive prima di rinominare."""
    return p["immagine"].with_name(p["immagine"].name + ".new")


def _cancella(cartella: Path, totale: int) -> None:
    """Rimuove l'albero raccontandolo. `shutil.rmtree` chiude quel che resta.

    Cancellare 100.000 file su un disco lento era l'ultima fase muta rimasta, e
    arriva quando l'utente ha gia' aspettato parecchio: il momento peggiore per
    smettere di parlare. Si scende dal fondo — `topdown=False` — perche' una
    directory si rimuove solo da vuota.

    Il `rmtree` finale non e' una ridondanza e non ignora gli errori: se qualcosa
    e' sfuggito al giro deve sparire comunque, e se non ci riesce deve sollevare
    come prima. Un `node_modules` cancellato a meta' e' l'unico esito che npz non
    lascia mai.
    """
    fatti = 0
    riferisci = img.battito(
        lambda n: avanza(f"removing the original folder … {_quanto(n, totale)}"))
    for dove, sotto, nomi in os.walk(cartella, topdown=False):
        for nome in nomi:
            try:
                os.unlink(os.path.join(dove, nome))
            except OSError:
                pass                      # ci ripassa `rmtree`, che sa protestare
            fatti += 1
            riferisci(fatti)
        for nome in sotto:
            try:
                os.rmdir(os.path.join(dove, nome))
            except OSError:
                pass
            fatti += 1
    shutil.rmtree(cartella)


def _scritti(radice: Path, libero_prima: int) -> str:
    """Quanto e' calato lo spazio libero da quando si e' cominciato.

    Una `statfs` invece di una passata: e' l'unico modo di dire i MiB senza
    ricontare quel che si sta scrivendo, e si legge a costo zero.

    E' lo spazio **occupato**, non la somma delle dimensioni: su molti file
    piccoli i due numeri divergono parecchio, perche' ogni file arrotonda a un
    blocco — 264 voci da poche centinaia di byte occupano un megabyte. Non e' un
    errore ed e' anzi il numero piu' utile dei due, visto che la domanda a cui
    risponde e' se il disco si sta riempiendo. Non e' pero' contabilita': se
    qualcun altro scrive sullo stesso filesystem, il conto se ne accorge.
    """
    try:
        calo = libero_prima - shutil.disk_usage(radice).free
    except OSError:
        return ""
    return f" · {st.leggibile(calo)}" if calo > 0 else ""


def _cresciuta(dove: Path) -> str:
    """Quanto e' grande finora l'immagine in costruzione, se si riesce a saperlo.

    Uno `stat` per ridisegno, non per voce: e' il secondo numero che dice se
    il lavoro procede, ed e' l'unico che continua a muoversi quando `mkfs.erofs`
    incontra un file grande e per un po' non ne nomina altri.
    """
    try:
        return f" · {st.leggibile(dove.stat().st_size)}"
    except OSError:
        return ""


# ── il montaggio ─────────────────────────────────────────────────────────────

def percorsi(radice: Path) -> dict:
    return img.percorsi(prog.profilo(radice), radice, RELATIVO)


def monta(radice: Path) -> None:
    """Ricrea la cartella e ci sovrappone lo stack. Il contrario di `smonta`."""
    prog.sveglia(radice)
    with st.lock(prog.profilo(radice), radice):
        _monta(percorsi(radice), prog.cartella(radice), mount.scegli(percorso=radice))


def _monta(p: dict, cartella: Path, backend: mount.Backend) -> None:
    """Il montaggio vero, **senza prendere il lock**: lo ha gia' preso chi chiama.

    Sta separato da `monta()` per il consolidamento, che smonta e rimonta dentro
    un lock solo. Non e' una preferenza di stile: `flock` sta sulla descrizione
    del file aperto, quindi due `open()` dello stesso lock nello stesso processo
    non si annidano — il secondo trova il primo e fallisce.
    """
    # Se qualcosa e' sopravvissuto a un ciclo precedente — un `bye` interrotto,
    # l'overlay caduto da solo, uno smontaggio riuscito a meta' — montarne un
    # altro sopra ne impila due sullo stesso punto, e da li' in poi ogni
    # smontaggio ne lascia indietro uno. Si toglie di mezzo prima, su entrambi.
    while mount.montato(cartella):
        backend.smonta(cartella)
    while mount.montato(p["basso"]):
        backend.smonta(p["basso"])
    cartella.mkdir(parents=True, exist_ok=True)
    # La sentinella vive sul filesystem sottostante: coperta dall'overlay
    # mentre il mount c'e', unica cosa presente quando e' caduto.
    (cartella / PROFILO.sentinella).write_text(
        "This folder's mount isn't active, but the data is safe in the\n"
        "image inside .npz/. Run any npm command from here: npz will\n"
        "remount it on its own.\n"
    )
    backend.monta_ro(p["immagine"], p["basso"])
    try:
        backend.monta_stack(p["basso"], p["delta"], p["lavoro"], cartella)
    except Errore:
        backend.smonta(p["basso"])
        raise


def smonta(radice: Path, forza: bool = False) -> None:
    """Smonta e **rimuove la cartella**, che e' la differenza con `freeze`.

    Da smontati la cartella non deve esistere: se restasse li' vuota, un builder
    non direbbe "manca node_modules" ma `cannot find module 'react'`, che e' un
    errore molto peggiore da diagnosticare — e lo direbbe a strumenti che non
    passano da npz. Lo stato *assente* e' invece indistinguibile da "mai
    installato", l'unico errore che tutto l'ecosistema JavaScript sa raccontare.
    """
    p = percorsi(radice)
    cartella = prog.cartella(radice)
    backend = mount.scegli(percorso=radice)

    attivi = perimetro.processi_attivi(cartella)
    if attivi and not forza:
        raise Errore(
            "there are processes using node_modules:\n  " +
            "\n  ".join(attivi) +
            "\nClose them and retry, or `npz bye --force` to unmount anyway."
        )

    with st.lock(prog.profilo(radice), radice):
        _smonta(p, cartella, backend, pigro=forza)
    # Fuori dal lock, e per ultima: da qui in poi la cartella e' ferma e lo dice.
    prog.addormenta(radice)


def _smonta(p: dict, cartella: Path, backend: mount.Backend,
            pigro: bool = False) -> None:
    """Lo smontaggio vero, senza lock e senza addormentare: vedi `_monta`.

    `pigro` e' cio' che `--force` promette: senza di esso un mount tenuto da un
    watcher non si stacca, e la promessa resterebbe una parola (§10).
    """
    # `while` e non `if`: se per qualsiasi ragione i mount si sono impilati, uno
    # solo non basta, e quel che resta e' invisibile finche' non si prova a
    # cancellare la cartella.
    while mount.montato(cartella):
        backend.smonta(cartella, pigro)
    while mount.montato(p["basso"]):
        backend.smonta(p["basso"], pigro)
    (cartella / PROFILO.sentinella).unlink(missing_ok=True)
    if cartella.is_dir() and not any(cartella.iterdir()):
        cartella.rmdir()


def assicura_montato(radice: Path, stato: str) -> None:
    """L'automontaggio: e' il segnale che il demone di `freeze` non ha mai avuto.

    Ogni comando npm passa da qui, quindi npz sa quando serve montato senza
    doverlo indovinare. Ripara anche lo stato *rotto*, che e' quel che resta
    dopo uno spegnimento o un OOM.
    """
    if stato == veloce.MONTATO:
        return
    cartella = prog.cartella(radice)
    if stato == veloce.SCAVALCATO:
        # Due alberi, e montare coprirebbe quello dell'utente lasciandolo
        # invisibile a occupare disco. Si sceglie, e chi sceglie monta da se'.
        if not conflitto(radice):
            # Breve di proposito: chi arriva qui ha appena letto il quadro
            # intero, o la riga di `avvisa_scavalcato`. Questa porta solo il
            # codice di uscita, che il comando non ha fatto quel che chiedeva.
            raise Errore("nothing mounted: node_modules is still the folder "
                         "npm built.")
        return
    if stato == veloce.ROTTO:
        # Adesso *rotto* vuol dire esattamente questo — il nostro mountpoint
        # scoperto, con dentro solo la sentinella — perche' a distinguerlo da
        # *scavalcato* ci pensa `veloce.stato()`. Si rimonta in silenzio.
        (cartella / PROFILO.sentinella).unlink(missing_ok=True)
        cartella.rmdir()
    monta(radice)


# ── il congelamento ──────────────────────────────────────────────────────────

def congela(radice: Path) -> None:
    """I tre tempi. La cartella non sparisce finche' l'immagine non e' verificata."""
    # Si sveglia prima di cominciare: costruire dentro il nome "fermo" per poi
    # rinominarlo lascerebbe, se qualcosa va storto a meta', una cartella che si
    # dichiara a riposo mentre contiene un'immagine incompleta.
    prog.sveglia(radice)
    cartella = prog.cartella(radice)
    p = percorsi(radice)
    backend = mount.scegli(percorso=radice)

    attivi = perimetro.processi_attivi(cartella)      # guarda /proc, non l'albero
    if attivi:
        raise Errore("there are processes using node_modules:\n  " +
                     "\n  ".join(attivi) + "\nClose them and retry.")
    prog.prepara_servizio(radice)
    if not (prog.servizio(radice) / "config").exists():
        st.scrivi_config(prog.profilo(radice), radice)
    config = st.leggi_config(prog.profilo(radice), radice)

    # **Una passata sola sull'albero originale**, e da quella esce tutto: la
    # fotografia che la verifica confrontera' con l'immagine, i conteggi per i
    # metadati, e gli uid per l'avviso sull'ownership. Prima erano due — si
    # contava qui e si rifotografava dentro `verifica()` — su un albero che sta
    # sul disco lento, che e' il piu' caro dei due che si attraversano.
    #
    # La fotografia si scatta **prima** della costruzione e non dopo, ed e' la
    # sola conseguenza vera del cambio: l'immagine finisce per essere confrontata
    # con quel che c'era quando si e' deciso di congelare, invece che con lo
    # stato in cui l'albero si trova alla fine. Non e' piu' debole — chi scrive
    # nell'albero durante il congelamento lo intercetta `processi_attivi()` — ed
    # e' la domanda piu' sensata delle due.
    atteso = img.inventario(
        cartella,
        lambda n: avanza(f"reading node_modules … {n:,} entries"))
    file, byte, cartelle = img.misura(atteso)
    altrui = img.uid_visti(atteso) - {os.getuid()}
    if altrui and os.geteuid() != 0:
        dice(f"warning: there are files owned by other users (uid "
             f"{', '.join(str(u) for u in sorted(altrui))}).")

    with st.lock(prog.profilo(radice), radice):
        # tempo 1 — si costruisce, e si verifica prima di crederci.
        dice(f"building the node_modules image ({file:,} files, "
             f"{st.leggibile(byte)}) …")
        # `mkfs.erofs` nomina ogni voce che scrive, cartelle comprese: il totale
        # onesto e' file + cartelle, non i soli file.
        voci = file + cartelle
        temporanea = img.costruisci(
            cartella, p["immagine"], config["compressione"],
            osserva=lambda n: avanza(f"building the image … {_quanto(n, voci)}"
                                     f"{_cresciuta(temporanea_di(p))}"))
        try:
            img.verifica(
                temporanea, cartella, p["basso"], backend,
                osserva=lambda n, quale: avanza(
                    f"verifying against {quale} … {_quanto(n, voci)}"),
                atteso=atteso)
        except Errore:
            temporanea.unlink(missing_ok=True)
            raise

        # `cartelle` non c'era: la scrive chi ha appena censito, e serve a chi
        # dovra' mostrare un avanzamento senza ricontare — `detach`, oggi. E'
        # additiva, quindi `FORMATO` non si muove: un `.meta` senza la chiave
        # resta leggibile, e chi la legge usa `.get()` e sa farne a meno.
        meta = {
            "percorso": RELATIVO, "creata": st.adesso(), "incardinata": None,
            "compressione": config["compressione"], "file": file, "byte": byte,
            "cartelle": cartelle,
        }
        # tempo 2 — si applica, con un rename atomico.
        os.replace(temporanea, p["immagine"])
        st.scrivi_meta(p["meta"], meta)
        p["delta"].mkdir(parents=True, exist_ok=True)

        # tempo 3 — solo adesso si cancella.
        _cancella(cartella, voci)

    guadagno = p["immagine"].stat().st_size
    dice(f"attached: {file} files ({st.leggibile(byte)}) → "
         f"one file ({st.leggibile(guadagno)})")


def si_puo_chiedere() -> bool:
    """Se c'e' qualcuno a cui chiedere.

    Si guarda **prima** di calcolare quel che andrebbe nella domanda: contare un
    `node_modules` vero costa una passata sull'albero, e farla per poi scoprire
    che non si puo' chiedere e' lavoro buttato su ogni comando.
    """
    return sys.stdin.isatty() and not os.environ.get("CI")


def chiedi(righe: list[str], domanda: str, ammesse: str, difetto: str,
           dopo: dict[str, str] | None = None) -> str | None:
    """Chiede sul terminale e restituisce la lettera scelta, o None.

    **None non e' un rifiuto**: e' "non c'e' nessuno a cui chiedere". Chi chiama
    deve avere una via che non passa dalla domanda — una domanda che non si e'
    in grado di porre non va posta, e in CI resterebbe senza risposta per
    sempre.

    `dopo` sono le righe da dire secondo la risposta, sullo stesso terminale e
    **dentro la stessa sbarra**: sono la risposta alla domanda appena fatta, non
    un messaggio nuovo.
    """
    if not si_puo_chiedere():
        return None
    # Due handle separati e non uno in "r+": su un terminale quest'ultimo
    # solleva io.UnsupportedOperation ("not seekable"), che eredita da OSError e
    # veniva quindi inghiottito dal ramo qui sotto. La domanda non compariva
    # mai, e npz si faceva da parte in silenzio: un guasto invisibile.
    try:
        uscita = open("/dev/tty", "w")
        ingresso = open("/dev/tty", "r")
    except OSError:
        return None
    with uscita, ingresso:
        # Anche la domanda porta il segno: chi la legge deve sapere che a
        # chiedere e' npz, non npm. La sbarra si apre sul terminale e non su
        # stderr, quindi quella eventualmente aperta altrove va prima chiusa:
        # due sbarre aperte insieme sullo stesso terminale si intreccerebbero.
        veloce.chiudi()
        veloce.voce("\n".join(righe), flusso=uscita)
        uscita.write(veloce.segno(uscita) + domanda)
        uscita.flush()
        risposta = (ingresso.readline() or "").strip().lower()[:1]
        scelta = risposta if risposta in ammesse else difetto
        if dopo and scelta in dopo:
            veloce.voce(dopo[scelta], flusso=uscita)
        veloce.chiudi(uscita)          # la coda, prima che l'handle si chiuda
    return scelta


def proponi(radice: Path) -> bool:
    """Chiede una volta sola, e ricorda anche il no.

    Se non si e' potuto chiedere npz si fa da parte in silenzio **senza segnare
    nulla**, perche' un rifiuto registrato in CI resterebbe li' per sempre.
    """
    if not si_puo_chiedere():
        return False
    file, byte, _ = img.conta(prog.cartella(radice))
    scelta = chiedi(
        [f"this project has a node_modules with {file} files "
         f"({st.leggibile(byte)}).",
         "I can attach npz to it: a single image, mounted in its place:",
         "  · disk space drops by about two-thirds, inodes to one",
         "  · everything keeps working exactly as before",
         "  · you can always go back with `npz detach`"],
        "Proceed? [y/N] ", "yn", "n",
        dopo={"n": "okay, I won't ask again. Delete .npz/no to change your mind."},
    )
    if scelta is None:
        return False
    if scelta == "y":
        return True
    prog.segna_rifiuto(radice)
    return False


# ── lo scavalcamento ─────────────────────────────────────────────────────────
#
# §6 bis del piano. Qualcuno ha battuto `npm` al posto di `npz`, e da fermi npm
# ha ricostruito `node_modules`: adesso ci sono due alberi, e nessuno dei due e'
# sbagliato. **Non si fondono** — non sono due rami della stessa cosa, sono due
# soluzioni distinte dello stesso problema di vincoli, e meta' dell'una piu'
# meta' dell'altra non e' una soluzione. Si sceglie un albero intero.
#
# Chi perde non si cancella: si rinomina. E' `metti_da_parte()` applicata al
# conflitto — li' non si distrugge lo stato congelato prima di sapere se npm
# riuscira', qui non lo si distrugge prima di sapere se l'utente ha scelto bene.

# La grazia prima di chiedere se togliere una copia messa da parte. Si guarda
# l'`mtime`, che sta gia' sul filesystem: contare le invocazioni vorrebbe dire
# tenere un contatore, ed e' il pezzo di stato che il §5 ha deciso di non
# scrivere da nessuna parte. Misura anche la cosa giusta — non "cinque comandi",
# ma *aver avuto il tempo di accorgersi se serviva ancora*.
GRAZIA_IMMAGINE = 86400            # un file solo, e superato da una immagine verificata
GRAZIA_ALBERO = 7 * 86400          # l'annullamento dell'utente: gli si lascia una settimana


def peso(percorso: Path) -> int:
    """Quanto occupa, che sia un file solo o un albero intero."""
    if percorso.is_dir() and not percorso.is_symlink():
        return somma(percorso)
    try:
        return percorso.lstat().st_size
    except OSError:
        return 0


def superate(radice: Path) -> list[dict]:
    """Le copie messe da parte che esistono adesso.

    Si **cercano per nome** invece di tenerne un elenco: il filesystem e' la
    fonte di verita' (§5), e un registro scritto a mano potrebbe contraddirlo.
    Non si pesano qui: pesare un albero e' una passata su decine di migliaia di
    file, e chi chiama spesso vuole solo sapere se ce n'e' una.
    """
    p = percorsi(radice)
    voci = [
        {"che": "the folder npm built",
         "dove": [radice / veloce.ALBERO_SUPERATO],
         "grazia": GRAZIA_ALBERO},
        {"che": "the previous image and its delta",
         "dove": [p["immagine"].with_name(p["immagine"].name + veloce.SUPERATO),
                  p["delta"].with_name(p["delta"].name + veloce.SUPERATO)],
         "grazia": GRAZIA_IMMAGINE},
        # L'orfano di un `npm ci` ucciso a meta': `metti_da_parte()` lo crea e
        # solo il giro completo lo toglie, quindi finora restava li' per sempre
        # mentre `veloce.stato()` dichiarava il progetto *candidato*. La grazia
        # di un giorno garantisce anche che un `npm ci` **vivo**, che dura
        # minuti, non venga mai scambiato per un residuo.
        {"che": "an image left behind by an interrupted `npm ci`",
         "dove": [p["immagine"].with_name(p["immagine"].name + ".aside")],
         "grazia": GRAZIA_IMMAGINE},
    ]
    presenti = []
    for voce in voci:
        esistono = [d for d in voce["dove"] if d.exists()]
        if not esistono:
            continue
        presenti.append(voce | {"dove": esistono,
                                "quando": min(d.lstat().st_mtime for d in esistono)})
    return presenti


def data(quando: float) -> str:
    return time.strftime("%Y-%m-%d", time.localtime(quando))


def butta_via(percorso: Path) -> None:
    if percorso.is_dir() and not percorso.is_symlink():
        shutil.rmtree(percorso, ignore_errors=True)
    else:
        percorso.unlink(missing_ok=True)


def fai_posto(radice: Path) -> bool:
    """Una sola copia messa da parte per volta, e restituisce se si puo' andare.

    Senza questa regola il failsafe diventa `.superseded.2`, `.superseded.3`, cioe'
    esattamente la perdita di spazio che doveva evitare. Con, il costo massimo e'
    **una generazione**, sempre, per costruzione.

    Senza TTY si sovrascrive dicendolo — che e' gia' cio' che fa
    `metti_da_parte()` con l'unlink prima del rename.
    """
    presenti = superate(radice)
    if not presenti:
        return True
    quanto = st.leggibile(sum(peso(d) for v in presenti for d in v["dove"]))
    scelta = chiedi(
        [f"there's already a copy set aside: {v['che']} ({data(v['quando'])})."
         for v in presenti] +
        [f"That's {quanto}. npz keeps one at a time, so making room means "
         f"removing it."],
        "Remove it and go on? [y/N] ", "yn", "n",
        dopo={"n": "nothing was touched."})
    if scelta == "n":
        return False
    if scelta is None:
        dice(f"overwriting the copy already set aside ({quanto}): npz keeps "
             f"one at a time.")
    for voce in presenti:
        for dove in voce["dove"]:
            butta_via(dove)
    return True


def raccogli(radice: Path) -> None:
    """Chiede se togliere le copie a cui la grazia e' scaduta.

    Sta in cima al percorso lento: il giro che crea una copia non la vede —
    non esisteva ancora — quindi la domanda arriva dal giro dopo, che e' il
    punto in cui l'utente ha gia' avuto una sessione per accorgersi di aver
    scelto male.

    Rispondere no **non registra un rifiuto**: rimette l'orologio a zero, e la
    domanda torna fra un'altra grazia. L'`mtime` e' la memoria — non c'e' niente
    da mantenere, non si puo' inchiodare, e non nagga.
    """
    if not si_puo_chiedere():
        return                                  # senza TTY non si cancella mai niente
    adesso = time.time()
    for voce in superate(radice):
        if adesso - voce["quando"] < voce["grazia"]:
            continue
        giorni = max(int(voce["grazia"]) // 86400, 1)
        quanto = st.leggibile(sum(peso(d) for d in voce["dove"]))
        # Il suggerimento sta **prima** della domanda: dopo `[y/N]` ci va solo il
        # cursore, altrimenti chi risponde scrive in fondo a una frase.
        scelta = chiedi(
            # La descrizione sta dopo i due punti e non come soggetto: cosi' non
            # deve concordare col verbo, e "the previous image and its delta"
            # non chiede un plurale che le altre voci non vogliono.
            [f"still set aside: {voce['che']}, from {data(voce['quando'])}. "
             f"Nothing has read it since, and it's taking {quanto}.",
             f"Saying no keeps it another "
             f"{'week' if giorni > 1 else 'day'}."],
            "Remove it? [y/N] ", "yn", "n")
        if scelta == "y":
            for dove in voce["dove"]:
                butta_via(dove)
            dice(f"removed: {voce['che']} ({quanto} freed).")
        else:
            for dove in voce["dove"]:
                try:
                    os.utime(dove, None)
                except OSError:
                    pass


def avvisa_scavalcato() -> None:
    """La riga che si dice quando non si puo' — o non si deve — chiedere.

    Non porta numeri: contarli vorrebbe dire una passata su tutto l'albero, e
    questa riga esce anche davanti a un `npm run` che deve solo partire.
    """
    # Neutra rispetto a chi la dice: esce sia davanti a un comando che sta per
    # passare a npm, sia da dentro `npz hey`, e nominare un comando andrebbe
    # bene solo per il primo dei due.
    dice("npz was bypassed here: npm rebuilt node_modules on its own, and the "
         "image is still in the service folder.\nBoth are on disk — run npz "
         "from a terminal to pick one.")


def conflitto(radice: Path) -> bool:
    """Due alberi, se ne sceglie uno intero. Restituisce se npz e' tornato in mano.

    Falso vuol dire che npz si e' fatto da parte: la cartella che npm ha
    costruito resta al suo posto e funziona, ed e' esattamente il motivo per cui
    non chiedere e' una via legittima invece di un guasto.
    """
    if not si_puo_chiedere():
        avvisa_scavalcato()
        return False

    cartella = prog.cartella(radice)
    p = percorsi(radice)
    file, byte, _ = img.conta(cartella)
    meta = st.leggi_meta(p["meta"]) if p["meta"].exists() else {}
    quadro = [
        "npz was bypassed here: npm rebuilt node_modules on its own.",
        f"  · the folder has {file} files ({st.leggibile(byte)})",
        f"  · the image from {meta.get('creata', '?')} has "
        f"{meta.get('file', '?')} files "
        f"({st.leggibile(p['immagine'].stat().st_size)} on disk)",
        "You're paying for both, and npz won't mount over a folder it didn't "
        "build.",
        # Va detto, perche' e' la prima cosa che viene in mente guardando due
        # alberi, ed e' quella che romperebbe tutto in silenzio.
        "They can't be merged: they're two different dependency trees, and half "
        "of one plus half of the other isn't a working tree.",
        "  [f] keep the folder npm built — it becomes the new image",
        "  [i] keep the image — the folder is set aside, nothing is deleted",
        "  [x] do nothing now",
    ]
    # La risposta al "non fare niente" sta dentro `dopo`, cioe' sullo stesso
    # terminale e nella stessa sbarra della domanda: e' la risposta a quel che
    # e' appena stato chiesto, non un messaggio nuovo.
    scelta = chiedi(quadro, "Which one? [f/i/X] ", "fix", "x",
                    dopo={"x": "nothing was touched. node_modules stays as npm "
                               "left it, and the image stays where it is."})
    if scelta == "f":
        return adotta(radice)
    if scelta == "i":
        return ripudia(radice)
    return False


def adotta(radice: Path) -> bool:
    """L'albero di npm diventa l'immagine nuova; la vecchia si mette da parte.

    L'immagine si parcheggia **prima** di costruire. Rinominare non e'
    cancellare, quindi l'invariante regge — e se la costruzione fallisce restano
    sul disco sia l'albero vero sia l'immagine di prima, cioe' tutto.
    """
    cartella = prog.cartella(radice)
    # Prima di toccare qualsiasi cosa: al tempo 3 quell'albero sparisce, e
    # fermarsi dopo aver parcheggiato l'immagine sarebbe il momento peggiore.
    attivi = perimetro.processi_attivi(cartella)
    if attivi:
        raise Errore("there are processes using node_modules:\n  " +
                     "\n  ".join(attivi) + "\nClose them and retry.")
    prog.verifica_idoneita(radice)
    if not fai_posto(radice):
        return False

    prog.sveglia(radice)
    p = percorsi(radice)
    for chiave in ("immagine", "delta"):
        if p[chiave].exists():
            os.replace(p[chiave], p[chiave].with_name(p[chiave].name + veloce.SUPERATO))
    dice("the previous image is set aside, not deleted.")
    congela(radice)
    monta(radice)
    return True


def ripudia(radice: Path) -> bool:
    """L'immagine vince: l'albero che npm ha costruito si mette da parte, intero.

    Va detto forte che cosi' si perde di vista quel che npm aveva appena
    installato — chi ha battuto `npm install lodash` e sceglie qui l'immagine si
    ritrova senza lodash. E' la scelta piu' sospetta delle due, e per questo la
    copia da parte le sopravvive una settimana invece di un giorno.
    """
    if not fai_posto(radice):
        return False
    # Idempotente, e serve a chi e' stato attaccato da una versione che il nome
    # `node_modules.superseded` non lo conosceva: senza, l'albero messo da parte
    # comparirebbe fra gli untracked del progetto.
    prog.prepara_servizio(radice)
    cartella = prog.cartella(radice)
    da_parte = radice / veloce.ALBERO_SUPERATO
    # Un rename e non una copia: e' atomico, istantaneo, e non serve il doppio
    # dello spazio per una cartella che stiamo mettendo via.
    os.replace(cartella, da_parte)
    monta(radice)
    dice(f"node_modules is the image again. What npm built is set aside in "
         f"{veloce.ALBERO_SUPERATO}/ — anything it installed is not in the "
         f"mounted tree.")
    return True


# ── il consolidamento ────────────────────────────────────────────────────────
#
# §9 del piano. E' `freeze.cli.consolida()` **meno la rotazione del delta**, e la
# differenza non e' una semplificazione ma una conseguenza: `freeze` consolida
# sotto un mount vivo, e deve tenere il delta ruotato come strato inferiore
# perche' nessuno perda cio' che scrive durante la costruzione. Qui la cartella
# non esiste dal momento in cui si smonta a quello in cui si rimonta — §6, da non
# montati la cartella non deve esistere — quindi non c'e' nessuno che scrive, e
# non c'e' finestra da chiudere.
#
# Il prezzo e' l'indisponibilita' dell'albero per la durata: N4 l'ha misurata in
# 12–15 s su un `node_modules` vero, ed e' la voce di costo piu' alta di tutto il
# progetto. Da cui il fatto che sia un comando esplicito e non un automatismo:
# arriva quando l'utente ha deciso di pagarla.

# Cio' che nell'immagine non deve entrare (§9). Sono cache di build: si
# rigenerano, cambiano a ogni comando, e comprimerle dentro un'immagine e' lavoro
# sprecato che diventa peso permanente — si ricomprimerebbero a ogni
# consolidamento per essere invalidate subito dopo. Restano dove sono, nel delta,
# che e' esattamente il posto per cio' che cambia.
#
# **Escluse dall'immagine non vuol dire perse.** Se una di queste cartelle sta
# gia' dentro l'immagine — perche' c'era quando si e' fatto `attach` — il
# consolidamento la sposta nel delta invece di lasciarla cadere: la vista fusa
# dopo deve essere identica a quella di prima, ed e' la verifica stessa del
# consolidamento a esigerlo. Costa una copia, una volta sola: dalla seconda
# passata quelle cartelle nell'immagine non ci sono piu'.
ESCLUSE = (".cache", ".vite")


def esigi_libera(cartella: Path, forza: bool, uscita: str) -> None:
    """Il consolidamento porta via l'albero: prima ci si assicura che non serva.

    E' il rifiuto di §10, che per `npz` e' la norma e non l'eccezione — in un
    ambiente di sviluppo c'e' sempre un language server o un watcher dentro
    `node_modules`. Si elencano i colpevoli per nome, che e' l'uscita preferita
    del piano, e si lascia `--force` a chi sa cosa sta facendo.
    """
    attivi = perimetro.processi_attivi(cartella)
    if attivi and not forza:
        raise Errore("there are processes using node_modules:\n  " +
                     "\n  ".join(attivi) +
                     f"\nCompacting takes the tree away for a few seconds. "
                     f"Close them and retry, or `{uscita}`.")


def deposito(p: dict) -> Path:
    """Dove si mette da parte cio' che esce dall'immagine e va nel delta.

    Accanto al delta, cioe' sullo stesso filesystem: il ritorno e' un rename e
    non una seconda copia, ed e' atomico.
    """
    return p["delta"].with_name(p["delta"].name + ".excluded")


def deposita(fusione: Path, dove: Path, nomi: tuple[str, ...]) -> None:
    """Copia dalla vista fusa le cartelle che l'immagine nuova non conterra'."""
    shutil.rmtree(dove, ignore_errors=True)
    dove.mkdir(parents=True, exist_ok=True)
    for nome in nomi:
        esito = subprocess.run(["cp", "-a", "--", str(fusione / nome), str(dove / nome)],
                               capture_output=True, text=True)
        if esito.returncode != 0:
            righe = (esito.stderr or esito.stdout).strip().splitlines()
            raise Errore(f"couldn't set aside node_modules/{nome}: " +
                         (righe[-1] if righe else "no message"))


def riporta(dove: Path, delta: Path) -> None:
    """Rimette nel delta cio' che era stato messo da parte, e sparisce."""
    if not dove.is_dir():
        return
    for voce in dove.iterdir():
        bersaglio = delta / voce.name
        shutil.rmtree(bersaglio, ignore_errors=True)
        os.replace(voce, bersaglio)
    dove.rmdir()


def svuota(delta: Path, tenere: tuple[str, ...] = ()) -> None:
    """Svuota il delta, lasciando i nomi che l'immagine non ha assorbito."""
    if not delta.is_dir():
        return
    for voce in delta.iterdir():
        if voce.name in tenere:
            continue
        if voce.is_dir() and not voce.is_symlink():
            shutil.rmtree(voce, ignore_errors=True)
        else:
            voce.unlink(missing_ok=True)      # anche i whiteout: sono nodi di device


def compatta(radice: Path, stato: str, forza: bool = False) -> None:
    """I passi di §9, con i tre tempi di sempre: costruisci, applica, cancella."""
    # Chi era montato torna montato, chi era fermo torna fermo: il consolidamento
    # cambia l'immagine, non lo stato del progetto. E si sveglia prima di
    # cominciare, per la stessa ragione del congelamento: dentro il nome fermo
    # non si costruisce mai.
    rimontare = stato == veloce.MONTATO
    cartella = prog.cartella(radice)
    # Il controllo sui processi viene **prima** della sveglia: e' il rifiuto piu'
    # probabile di tutti (§10), e fermarsi dopo aver rinominato la cartella
    # lascerebbe un progetto fermo con addosso il nome di uno al lavoro.
    esigi_libera(cartella, forza, "npz compact --force")

    prog.sveglia(radice)
    p = percorsi(radice)
    backend = mount.scegli(percorso=radice)
    config = st.leggi_config(prog.profilo(radice), radice)
    meta = st.leggi_meta(p["meta"])
    # Accanto a `lower` e `work`, che sono i suoi fratelli dentro `run/`: quel
    # che si vede su disco parla inglese, gli identificatori qui sopra no.
    fusione = p["basso"].with_name("merged")

    voci, peso = quante(p["delta"]), somma(p["delta"])
    dice(f"compacting: {voci} entries ({st.leggibile(peso)}) in the delta …")

    with st.lock(prog.profilo(radice), radice):
        try:
            # Lo smontaggio sta dentro il `try` perche' puo' riuscire a meta' —
            # la vista staccata e il lower no — e anche allora l'albero deve
            # tornare: e' `_monta` che sa rimettere in ordine i due strati.
            _smonta(p, cartella, backend, pigro=forza)
            shutil.rmtree(deposito(p), ignore_errors=True)   # residuo di un giro interrotto
            file, byte, escluse = ricostruisci(p, fusione, config, meta, backend)

            # tempo 3 — solo adesso si cancella, e si cancella il delta che e'
            # appena stato assorbito. Un'uccisione fra il rename e questo punto
            # lascia un delta che verrebbe riapplicato sopra un'immagine che lo
            # contiene gia': identico, quindi innocuo. Il consolidamento
            # converge anche se lo si interrompe.
            svuota(p["delta"], tenere=escluse)
            riporta(deposito(p), p["delta"])
            shutil.rmtree(p["lavoro"], ignore_errors=True)
        except BaseException:
            # L'albero torna comunque: che il consolidamento sia fallito non e'
            # una ragione per lasciare il progetto senza `node_modules`. Se anche
            # il rimontaggio fallisce, l'errore da riportare resta il primo — e lo
            # stato *congelato* che ne risulta si ripara al prossimo comando npm.
            if rimontare:
                try:
                    _monta(p, cartella, backend)
                except Errore:
                    pass
            raise
        if rimontare:
            _monta(p, cartella, backend)

    # I due numeri si leggono adesso, finche' i percorsi valgono: `addormenta`
    # rinomina la cartella di servizio, e dopo di lei `p` non punta piu' a nulla.
    guadagno, rimasto = p["immagine"].stat().st_size, somma(p["delta"])
    if not rimontare:
        # Fuori dal lock, che la rinomina lo esige. Se invece il consolidamento
        # fosse fallito non si arriva qui, e la cartella resta col nome da
        # sveglia: lo stato non cambia — `veloce.stato` guarda tutti e due i nomi
        # — e il primo montaggio che capita la rimette a posto.
        prog.addormenta(radice)

    dice(f"compacted: {file} files ({st.leggibile(byte)}) → one file "
         f"({st.leggibile(guadagno)}); "
         + (f"{st.leggibile(rimasto)} of build cache stays in the delta."
            if rimasto else "the delta is empty again."))


def ricostruisci(p: dict, fusione: Path, config: dict, meta: dict,
                 backend: mount.Backend) -> tuple[int, int, tuple[str, ...]]:
    """Dalla vista fusa alla nuova immagine, verificata e applicata.

    Il merge lo fa il kernel — o `fuse-overlayfs`: whiteout e directory opache
    arrivano gia' risolti nella vista che ci consegna, e non c'e' una riga di
    logica dei whiteout da scrivere ne' da sbagliare.
    """
    backend.monta_ro(p["immagine"], p["basso"])
    try:
        backend.monta_fusione([p["delta"], p["basso"]], fusione)
        try:
            # `lexists` e non `exists`: un symlink rotto e' comunque una voce da
            # tenere fuori, e `exists()` risponderebbe di no.
            escluse = tuple(n for n in ESCLUSE if os.path.lexists(fusione / n))
            # Quelle che stanno anche nell'immagine vecchia vanno portate via da
            # li' prima che l'immagine venga sostituita. Le altre stanno gia'
            # tutte nel delta, e restarci non costa niente.
            emigranti = tuple(n for n in escluse if os.path.lexists(p["basso"] / n))
            for nome in emigranti:
                dice(f"moving node_modules/{nome} out of the image: it's a build "
                     f"cache, and from now on it lives in the delta.")

            # Un delta che cancella tutto e' il caso di §2: `rm -rf node_modules`
            # battuto a mano, o uno script che lo fa, riempie il delta di
            # whiteout invece che di file. Consolidarlo scriverebbe un'immagine
            # vuota, cioe' butterebbe l'albero per obbedire a una cancellazione
            # che l'utente potrebbe non aver voluto. Non si indovina: si chiede.
            if not any(fusione.iterdir()):
                raise Errore(
                    "the delta deletes the whole tree: compacting now would "
                    "write an empty image.\nNothing was touched — the image "
                    "still has everything. Two ways out:\n"
                    "  · `npz compact --discard` throws the delta away and "
                    "brings the tree back\n"
                    "  · `npz bye` keeps the deletion, and node_modules stays "
                    "away until you ask for it"
                )

            # tempo 1 — si costruisce, e non si tocca niente di esistente.
            temporanea = img.costruisci(fusione, p["immagine"],
                                        config["compressione"], escluse)
            atteso = {rel: voce for rel, voce in img.inventario(fusione).items()
                      if rel.split(os.sep, 1)[0] not in escluse}
            # La copia si fa qui, mentre la vista fusa c'e' ancora: e' l'unico
            # posto in cui quelle cartelle si vedono intere, delta e immagine
            # insieme.
            deposita(fusione, deposito(p), emigranti)
        finally:
            backend.smonta(fusione)
    finally:
        backend.smonta(p["basso"])

    # …e si verifica prima di crederci, con la stessa prova del congelamento
    # fatta al contrario: qui l'originale e' la vista fusa e la copia e'
    # l'immagine. Attributi, non nomi.
    backend.monta_ro(temporanea, p["basso"])
    try:
        ottenuto = img.inventario(p["basso"])
    finally:
        backend.smonta(p["basso"])
    scarto = img.differenze(atteso, ottenuto)
    if scarto:
        temporanea.unlink(missing_ok=True)
        raise Errore("the compacted image doesn't match the merged view:\n  " +
                     "\n  ".join(scarto) + "\nNothing was applied.")

    # tempo 2 — si applica, con un rename atomico. I due numeri escono
    # dall'inventario appena fatto: ripercorrere l'albero attraverso FUSE per
    # ricontarlo costerebbe quanto un pezzo della costruzione.
    file, byte, cartelle = img.misura(ottenuto)
    os.replace(temporanea, p["immagine"])
    meta["incardinata"] = st.adesso()
    meta["file"], meta["byte"], meta["cartelle"] = file, byte, cartelle
    st.scrivi_meta(p["meta"], meta)
    return file, byte, escluse


def butta(radice: Path, stato: str, forza: bool = False) -> int:
    """L'altra uscita di §2: il delta si butta, e l'albero torna l'immagine.

    Serve quando il delta non e' lavoro ma una cancellazione — `rm -rf
    node_modules` da shell, o uno script che lo fa — e consolidarlo scriverebbe
    il vuoto. Cio' che era stato scritto a mano dentro `node_modules` se ne va
    con esso: e' cio' che la parola *discard* dichiara, e per questo e' un flag
    che si scrive e non una cosa che accade da sola.
    """
    p = percorsi(radice)
    voci, peso = quante(p["delta"]), somma(p["delta"])
    if not voci:
        dice("the delta is already empty: nothing to discard.")
        return 0

    rimontare = stato == veloce.MONTATO
    cartella = prog.cartella(radice)
    esigi_libera(cartella, forza, "npz compact --discard --force")

    prog.sveglia(radice)
    p = percorsi(radice)                      # la cartella di servizio si e' rinominata
    backend = mount.scegli(percorso=radice)

    with st.lock(prog.profilo(radice), radice):
        try:
            _smonta(p, cartella, backend, pigro=forza)
            svuota(p["delta"])
            shutil.rmtree(p["lavoro"], ignore_errors=True)
        finally:
            if rimontare:
                _monta(p, cartella, backend)
    if not rimontare:
        prog.addormenta(radice)

    dice(f"delta discarded: {voci} entries ({st.leggibile(peso)}) thrown away. "
         f"node_modules is the image again.")
    return 0


# ── i comandi nostri ─────────────────────────────────────────────────────────

def cmd_status(radice: Path | None, stato: str) -> int:
    if radice is None:
        riferisce("you're not inside a project (no package.json above here)")
        return 1
    righe = [
        f"project       {radice}",
        f"filesystem    {prog.tipo_filesystem(radice) or '?'}",
        f"status        {stato}",
    ]
    if stato == veloce.SCAVALCATO:
        # Contare costa una passata sull'albero, ma `status` e' il comando che
        # si batte per capire: qui il numero e' cio' che si viene a cercare.
        file, byte, _ = img.conta(prog.cartella(radice))
        righe.append(f"folder        {file} files ({st.leggibile(byte)}) — built "
                     f"by npm outside npz, not mounted")
    p = percorsi(radice)
    if p["immagine"].exists():
        meta = st.leggi_meta(p["meta"]) if p["meta"].exists() else {}
        delta, voci = somma(p["delta"]), quante(p["delta"])
        # La percentuale misura cio' che un consolidamento assorbirebbe, non cio'
        # che sta sul disco: le cache di build (§9) restano nel delta comunque, e
        # contarle qui inviterebbe a un `npz compact` che non le toglierebbe.
        consolidabili = quante(p["delta"], ESCLUSE)
        totali = max(meta.get("file") or 1, 1)
        righe += [
            f"service       {prog.servizio(radice).name}/",
            f"image         {st.leggibile(p['immagine'].stat().st_size)}  "
            f"({meta.get('file', '?')} files, {st.leggibile(meta.get('byte', 0))} original)",
            f"delta         {st.leggibile(delta)} in {voci} entries"
            + (f"  — {100 * consolidabili // totali}% of entries" if consolidabili
               else "  — build cache only" if voci else ""),
            f"attached      {meta.get('creata', '?')}",
            f"compacted     {meta.get('incardinata') or 'never'}",
            f"mount         {mount.scegli(percorso=radice).nome}",
        ]
    # Le copie messe da parte si elencano sempre, anche senza TTY: e' l'unico
    # modo in cui un costo che npz non toglie da solo resta visibile (§6 bis).
    for voce in superate(radice):
        righe.append(
            f"set aside     {st.leggibile(sum(peso(d) for d in voce['dove']))}"
            f"  — {voce['che']}, {data(voce['quando'])}")
    riferisce("\n".join(righe))
    return 0


def cmd_bye(radice: Path | None, argv: list[str]) -> int:
    if radice is None:
        raise Errore("you're not inside a project")
    p = percorsi(radice)
    if not p["immagine"].exists():
        raise Errore("npz isn't managing anything here")
    smonta(radice, forza="--force" in argv)
    delta = somma(p["delta"])
    dice("node_modules unmounted and removed; the image stays in .npz/."
         + (f" Delta waiting: {st.leggibile(delta)}." if delta else ""))
    dice("Any npm command from here remounts it.")
    return 0


def cmd_hey(radice: Path | None, stato: str) -> int:
    """Explicit mount: the counterpart of `bye`.

    Monta solo cio' che `attach` ha gia' costruito — non costruisce mai. Su un
    progetto mai attaccato non c'e' niente da far tornare, e dirlo e' meglio che
    attaccare npz senza che nessuno l'abbia chiesto.
    """
    if radice is None:
        raise Errore("you're not inside a project")
    p = percorsi(radice)
    if not p["immagine"].exists():
        raise Errore("npz isn't attached here yet — run `npz attach` first.")
    if stato == veloce.MONTATO:
        dice("node_modules is already here.")
    else:
        assicura_montato(radice, stato)
        dice("node_modules is back.")
    avvisa_delta(radice)
    return 0


def cmd_attach(radice: Path | None, stato: str) -> int:
    """Attaches now, overriding the question — and any earlier no.

    E' la via esplicita: chi lo scrive ha gia' deciso, e non ha senso chiedergli
    conferma di una cosa che ha appena chiesto. Per la stessa ragione toglie di
    mezzo il rifiuto registrato in precedenza: e' l'utente stesso a smentirlo.
    """
    if radice is None:
        raise Errore("you're not inside a project")
    if stato in (veloce.MONTATO, veloce.CONGELATO, veloce.ROTTO):
        assicura_montato(radice, stato)
        p = percorsi(radice)
        dice(f"already attached: {st.leggibile(p['immagine'].stat().st_size)} "
             f"image, now mounted.")
        avvisa_delta(radice)
        return 0

    cartella = prog.cartella(radice)
    if not cartella.is_dir():
        raise Errore("there's no node_modules here for npz to attach to.\n"
                     "Install the dependencies and rerun.")

    prog.verifica_idoneita(radice)
    rifiuto = prog.servizio(radice) / "no"
    if rifiuto.exists():
        rifiuto.unlink()
        dice("there was a recorded refusal: clearing it, since you're the "
             "one asking now.")
    congela(radice)
    monta(radice)
    return 0


def cmd_detach(radice: Path | None, stato: str, argv: list[str]) -> int:
    """The way out: a real node_modules, with no trace of npz left.

    Vale qui l'invariante di sempre — si costruisce, si applica, si cancella.
    L'albero vero nasce accanto a quello montato con un nome di lavoro, viene
    confrontato con la vista da cui proviene, e solo allora prende il suo posto;
    `.npz/` sparisce per ultima. Se qualcosa va storto a meta', l'immagine e' ancora
    li' e non si e' perso niente.
    """
    if radice is None:
        raise Errore("you're not inside a project")
    p = percorsi(radice)
    if not p["immagine"].exists():
        raise Errore("npz isn't managing anything here")

    assicura_montato(radice, stato)
    cartella = prog.cartella(radice)

    attivi = perimetro.processi_attivi(cartella)
    if attivi and "--force" not in argv:
        raise Errore("there are processes using node_modules:\n  " +
                     "\n  ".join(attivi) +
                     "\nClose them and retry, or `npz detach --force`.")

    # Non si riconta niente: il `.meta` sa gia' quanto pesava l'albero quando e'
    # entrato nell'immagine, e il delta e' quanto gli e' cresciuto sopra. La
    # somma dei due e' una **sovrastima** — il delta spesso riscrive file che
    # nell'immagine ci sono gia', e li conterebbe due volte — ma per decidere se
    # c'e' posto sbagliare per eccesso e' esattamente il verso giusto. Una
    # passata su centomila file, misurata a 13 secondi, per un numero che era
    # gia' su disco.
    meta = st.leggi_meta(p["meta"]) if p["meta"].exists() else {}
    byte = (meta.get("byte") or 0) + somma(p["delta"])
    file = meta.get("file") or 0
    # `cp -v` nomina anche le cartelle, quindi il denominatore onesto e' la
    # somma. Uno store scritto prima che la chiave esistesse non ce l'ha: li'
    # `voci` resta 0 e l'avanzamento mostra i soli valori assoluti, che e' il
    # comportamento giusto — meglio un numero che cresce di una percentuale che
    # arriva al 110%.
    voci = (file + meta["cartelle"]) if meta.get("cartelle") else 0
    libero = shutil.disk_usage(radice).free
    if libero < byte * 11 // 10:
        raise Errore(
            f"not enough space to restore the tree in the open: need about "
            f"{st.leggibile(byte)}, have {st.leggibile(libero)}."
        )

    # Il nome e' in inglese perche' nasce **dentro la cartella di progetto**,
    # accanto ai file dell'utente, come `node_modules.frozen`: quel che si vede
    # da fuori parla la lingua della CLI, non quella del codice.
    lavoro = cartella.with_name(cartella.name + ".npz-in-progress")
    shutil.rmtree(lavoro, ignore_errors=True)
    dice(f"detaching: restoring about {file:,} files ({st.leggibile(byte)}) …")

    # tempo 1 — si costruisce l'albero vero, accanto, senza toccare nulla.
    #
    # `-v` non e' per il registro: e' l'unico modo che `cp` ha di dire a che
    # punto e', e rimaterializzare centomila file su un disco lento e' la fase
    # piu' lunga che npz abbia — piu' lunga del congelamento, perche' qui si
    # scrive invece di leggere. Ogni riga e' una voce copiata.
    #
    # Il denominatore viene dal `.meta`, che quei numeri li ha gia': nessuna
    # passata per procurarseli. E' **approssimato per difetto o per eccesso** di
    # quanto il delta ha aggiunto o tolto dal congelamento in poi, ed e' per
    # questo che la percentuale ha il tappo al 100 e il messaggio dice *about*.
    # I MiB invece sono esatti e assoluti: vengono dallo spazio libero che cala,
    # una sola `statfs` per aggiornamento, e non hanno bisogno di un totale.
    prima = shutil.disk_usage(radice).free
    codice, coda = img.esegui_contando(
        ["cp", "-a", "-v", "--", str(cartella) + "/.", str(lavoro)],
        lambda r: " -> " in r,
        lambda n: avanza(f"restoring node_modules … "
                         f"{_quanto(n, voci) if voci else f'{n:,} entries'}"
                         f"{_scritti(radice, prima)}"))
    if codice != 0:
        shutil.rmtree(lavoro, ignore_errors=True)
        raise Errore("the copy failed: " + (coda[-1] if coda else "no message"))

    # …e si verifica, come fa il congelamento al contrario.
    scarto = img.differenze(
        img.inventario(cartella, lambda n: avanza(
            f"verifying against the mounted tree … "
            f"{_quanto(n, voci) if voci else f'{n:,} entries'}")),
        img.inventario(lavoro, lambda n: avanza(
            f"verifying the restored folder … "
            f"{_quanto(n, voci) if voci else f'{n:,} entries'}")))
    if scarto:
        shutil.rmtree(lavoro, ignore_errors=True)
        raise Errore("the copy doesn't match the mounted tree:\n  " +
                     "\n  ".join(scarto) + "\nNothing was touched.")

    # tempo 2 — si applica: si smonta e l'albero vero prende il posto del mount.
    smonta(radice, forza="--force" in argv)
    os.replace(lavoro, cartella)

    # L'albero messo da parte da uno scavalcamento (§6 bis) sta nella radice di
    # progetto e sopravvive alla cartella di servizio. Va nominato **prima** di
    # dichiarare che di npz non resta niente: da qui in poi non c'e' piu' nessuno
    # che possa tornare a chiederne conto, e la scadenza che lo avrebbe raccolto
    # se ne va con `.npz/`.
    albero = radice / veloce.ALBERO_SUPERATO
    avanzo = f" {st.leggibile(peso(albero))} in {veloce.ALBERO_SUPERATO}/ is " \
             f"still yours to delete." if albero.exists() else ""

    # tempo 3 — solo adesso si cancella.
    shutil.rmtree(prog.servizio(radice), ignore_errors=True)
    dice(f"detached: node_modules is a normal folder with {file} files again. "
         f"Nothing of npz is left." + avanzo)
    return 0


def cmd_compact(radice: Path | None, stato: str, argv: list[str]) -> int:
    """Porta il delta dentro l'immagine, adesso, invece di aspettare la soglia.

    Funziona in entrambi gli stati in cui c'e' un'immagine: da montati costa lo
    smontaggio e il rimontaggio attorno alla costruzione, da fermi neppure
    quelli — e in nessuno dei due il progetto cambia stato.
    """
    if radice is None:
        raise Errore("you're not inside a project")
    p = percorsi(radice)
    if not p["immagine"].exists():
        raise Errore("npz isn't managing anything here")

    if stato == veloce.ROTTO:
        # Si ripara prima di lavorare, con la rete di sicurezza di §6: costa un
        # montaggio che verra' disfatto subito, e in cambio il caso della
        # cartella non montata con dentro qualcosa lo racconta chi lo sa gia'
        # raccontare, invece di finire coperto dal mount del consolidamento.
        assicura_montato(radice, stato)
        stato = veloce.MONTATO
        p = percorsi(radice)        # il montaggio ha svegliato la cartella di servizio

    forza = "--force" in argv
    if "--discard" in argv:
        return butta(radice, stato, forza)

    if not quante(p["delta"], ESCLUSE):
        # Non e' un errore: N2 ha misurato che tre installazioni su dieci non
        # producono delta, e chiedere il consolidamento dopo una di quelle e'
        # ragionevole. Si dice che non c'era niente da fare e si esce da fermi.
        cache = somma(p["delta"])
        dice("nothing to compact: node_modules is already all image."
             + (f" The {st.leggibile(cache)} in the delta is build cache, and "
                f"stays out of the image by design." if cache else ""))
        return 0
    compatta(radice, stato, forza)
    return 0


def non_ancora(nome: str) -> int:
    raise Errore(f"`npz {nome}` isn't implemented yet in this phase.")


# ── l'aiuto ──────────────────────────────────────────────────────────────────

def aiuto() -> int:
    """`npz` senza argomenti: il nostro aiuto, e a seguire quello di npm.

    L'ordine e' il messaggio. npz non e' un comando che *assomiglia* a npm: e'
    npm, con tre comportamenti in piu' — e mostrare il suo aiuto dopo il nostro
    lo dice meglio di qualunque frase. Il codice di uscita resta quello di npm.
    """
    tinta = sys.stdout.isatty()
    G = "\033[1m" if tinta else ""          # grassetto
    A = "\033[36m" if tinta else ""         # accento, sui nomi dei comandi
    D = "\033[2m" if tinta else ""          # tenue
    Z = "\033[0m" if tinta else ""

    # `titolo` non si stampa: serve solo a misurare il rientro della seconda
    # riga, e deve percio' contenere gli stessi caratteri *visibili* della prima
    # — le sequenze di colore no, che occupano zero colonne.
    titolo = f"npz {VERSIONE} ({IMPLEMENTAZIONE}) — "
    indent = " " * len(titolo)

    riferisce("\n".join([
        f"{G}npz{Z} {D}{VERSIONE} ({IMPLEMENTAZIONE}){Z}"
        f" — node_modules without the node_modules",
        f"{indent}npm, with node_modules compacted into a mounted image",
        "",
        "npz wraps npm: every command passes through unchanged.",
        "npz only adds one thing: smarter node_modules handling.",
        "",
        f"{G}npz commands, for this folder{Z}",
        f"  {A}npz attach{Z}      enable npz for this folder and mount",
        f"  {A}npz detach{Z}      disable npz for this folder, restore original node_modules",
        f"  {A}npz hey{Z}         mount node_modules",
        f"  {A}npz bye{Z}         unmount node_modules",
        f"  {A}npz status{Z}      image, delta, mount",
        f"  {A}npz compact{Z}     merge delta into image",
        "",
        f"{G}Automatic{Z}",
        f"  · asks {G}once{Z} when a real node_modules is found",
        "  · mounts when needed",
        f"  · handles {A}npm ci{Z} specially",
        "",
        f"  {A}npz -- <command>{Z}   send <command> directly to npm",
        "",
        f"{D}Below the tail, npm is talking. Inside the bar, npz is.{Z}",
    ]))
    # La sbarra si chiude da se' dentro `accompagna`, che e' anche il punto in
    # cui i buffer vengono svuotati prima di cedere il terminale a npm.

    npm = veloce.trova_npm(os.path.realpath(__file__))
    if npm is None:
        return veloce.manca_npm()
    return veloce.accompagna(npm, [])


# ── misure sul delta ─────────────────────────────────────────────────────────
#
# `tranne` serve a distinguere le due domande che si fanno al delta, e che non
# hanno la stessa risposta: *quanto occupa* — e allora si conta tutto, perche'
# tutto sta sul disco — contro *quanto ne assorbirebbe un consolidamento*, che
# esclude cio' che nell'immagine non entrerebbe comunque (§9). Senza la
# distinzione, una cache di build da 40 MiB reclamerebbe per sempre un
# consolidamento che non puo' toglierla di li'.

def sotto(delta: Path, tranne: tuple[str, ...]) -> list[Path]:
    """Le voci di primo livello del delta da guardare, e se sono da percorrere."""
    if not delta.is_dir():
        return []
    return [v for v in delta.iterdir() if v.name not in tranne]


def dentro(voce: Path) -> bool:
    """Una cartella vera, in cui scendere. Un symlink a cartella non lo e'."""
    return voce.is_dir() and not voce.is_symlink()


def somma(delta: Path, tranne: tuple[str, ...] = ()) -> int:
    totale = 0
    for voce in sotto(delta, tranne):
        if not dentro(voce):
            try:
                totale += voce.lstat().st_size
            except OSError:
                pass
            continue
        for dove, _, file in os.walk(voce):
            for nome in file:
                try:
                    totale += (Path(dove) / nome).lstat().st_size
                except OSError:
                    pass
    return totale


def quante(delta: Path, tranne: tuple[str, ...] = ()) -> int:
    totale = 0
    for voce in sotto(delta, tranne):
        totale += 1
        if dentro(voce):
            totale += sum(len(c) + len(f) for _, c, f in os.walk(voce))
    return totale


# ── il governo del percorso lento ────────────────────────────────────────────

def governa(argv: list[str], dove: str | None, stato: str) -> int:
    radice = Path(dove) if dove else None
    try:
        return _governa(argv, radice, stato)
    except Errore as e:
        veloce.voce(e, errore=True)
        return 1


def _governa(argv: list[str], radice: Path | None, stato: str) -> int:
    classe = comandi.classifica(argv)
    comando, _ = comandi.separa(argv)

    # La raccolta dei residui sta in cima al percorso lento: il giro che crea
    # una copia da parte non la vede — non esisteva ancora — quindi la domanda
    # arriva dal giro dopo, che e' il punto in cui l'utente ha gia' avuto una
    # sessione per accorgersi di aver scelto male. Non davanti a `status`, che
    # e' il comando che si batte *per guardare*, e che le elenca da se'.
    if radice is not None and comando != "status":
        raccogli(radice)

    if classe == comandi.NOSTRO:
        if radice is not None:
            stato = veloce.stato(str(radice))
        if comando == "status":
            return cmd_status(radice, stato)
        if comando == "attach":
            return cmd_attach(radice, stato)
        if comando == "detach":
            return cmd_detach(radice, stato, argv)
        if comando == "hey":
            return cmd_hey(radice, stato)
        if comando == "bye":
            return cmd_bye(radice, argv)
        if comando == "compact":
            return cmd_compact(radice, stato, argv)
        return non_ancora(comando)

    npm = veloce.trova_npm(os.path.realpath(__file__))
    if npm is None:
        return veloce.manca_npm()

    if stato == veloce.SCAVALCATO:
        # npz **non si mette in mezzo**: l'albero e' reale e completo, e npm ci
        # lavora meglio di quanto npz possa fare adesso. Bloccare qui — che e'
        # cio' che si faceva — significava far fallire anche un `npz ls`, cioe'
        # rendere npz un ostacolo davanti a comandi che npm esegue benissimo.
        #
        # I neutri se ne vanno subito, con una riga; dopo un mutante riuscito si
        # propone di scegliere, e li' un codice di uscita di npm c'e' — che e'
        # esattamente cio' che manca a npz per fidarsi di un albero (§8).
        if classe == comandi.NEUTRO:
            avvisa_scavalcato()
            veloce.consegna(npm, argv)
        esito = veloce.accompagna(npm, argv)
        if esito == 0:
            conflitto(radice)
        return esito

    # Il progetto e' candidato: si chiede, una volta sola, e *prima* che npm
    # parta. Quando si agisce dipende invece da che comando e': subito se e'
    # neutro, alla fine se puo' toccare l'albero. Vedi `attacca_subito()`.
    congelare_dopo = False
    da_parte = None
    if stato == veloce.CANDIDATO:
        # L'idoneita' del filesystem si controlla PRIMA di chiedere. Chiederlo
        # dopo significherebbe far dire di si' all'utente, fargli aspettare npm,
        # e solo allora dirgli che qui non si puo' fare: una domanda che non si
        # e' in grado di onorare non va posta.
        try:
            prog.verifica_idoneita(radice)
        except Errore as e:
            dice(str(e).splitlines()[0])
            prog.segna_rifiuto(radice)
            veloce.consegna(npm, argv)
        if not proponi(radice):
            veloce.consegna(npm, argv)
        if classe == comandi.NEUTRO:
            # Il si' si onora adesso, e poi npz sparisce dentro npm.
            if not attacca_subito(radice):
                return 1
            veloce.consegna(npm, argv)
        congelare_dopo = True

    elif classe == comandi.DISTRUTTIVO:
        # `npm ci` cancella node_modules: sull'overlay sono 35.000 whiteout e poi
        # l'albero intero riestratto nel delta. Misurato in fase 0: 3,0–3,5x piu'
        # lento, e 821 MiB contro i 588 del nativo. Si porta sull'albero nudo.
        if stato in (veloce.MONTATO, veloce.ROTTO, veloce.CONGELATO):
            dice(f"`npm {comando}` rebuilds node_modules from scratch: running it "
                 f"on the bare tree, then re-attaching.")
            da_parte = metti_da_parte(radice)
            congelare_dopo = True

    elif stato in (veloce.CONGELATO, veloce.ROTTO):
        assicura_montato(radice, stato)

    esito = veloce.accompagna(npm, argv)

    if not congelare_dopo:
        if classe in (comandi.MUTANTE, comandi.DISTRUTTIVO) and radice is not None:
            avvisa_delta(radice)
        return esito

    albero = prog.cartella(radice).is_dir()

    if esito != 0:
        # npm ha fallito per ragioni sue, e qui il comando era di quelli che
        # l'albero lo compongono: cio' che sta in node_modules non e' l'albero
        # che l'utente voleva, ma uno a meta'. Non si congela — e lo si **dice**,
        # perche' un si' che non produce niente e non spiega perche' e' peggio di
        # un no. (Per i neutri non si arriva mai qui: hanno gia' attaccato prima,
        # e il loro codice di uscita dell'albero non dice nulla.)
        if da_parte is not None:
            dice(f"`npm {comando}` failed (exit code {esito}): "
                 f"restoring the previous image.")
            riprendi(radice, da_parte)
        else:
            dice(f"`npm {comando}` failed (exit code {esito}): npz isn't "
                 f"touching node_modules. Run `npz attach` when it's settled.")
        return esito

    if not albero:
        # npm e' riuscito e non ha prodotto node_modules: il progetto non ha
        # dipendenze. Rimettere l'immagine vecchia resusciterebbe un albero che
        # npm ha appena deciso non dover esistere — npz si fa da parte.
        if da_parte is not None:
            da_parte.unlink(missing_ok=True)
            dice("no dependencies to manage: npz steps aside.")
        return esito

    try:
        prog.verifica_idoneita(radice)
        congela(radice)
        monta(radice)
    except Errore:
        if da_parte is not None:
            dice("attaching failed: restoring the previous image.")
            riprendi(radice, da_parte)
        raise
    if da_parte is not None:
        da_parte.unlink(missing_ok=True)          # solo ora la vecchia si butta
    return esito


def attacca_subito(radice: Path) -> bool:
    """Il si' dell'utente si onora adesso, prima di consegnare il comando a npm.

    Vale per i **neutri**, che l'albero non lo toccano: congelare prima non
    duplica niente — il delta nasce vuoto e resta vuoto — e il comando parte
    gia' sul montato, cioe' nella configurazione in cui vivra' da li' in avanti.

    Aspettare la fine e' invece giusto per i **mutanti**, ed e' quello che il §8
    prescrive: li' l'albero lo sta componendo npm, e congelarlo prima vorrebbe
    dire far scrivere l'installazione dentro il delta appena creato. Applicata
    anche ai neutri, la stessa regola diventa un difetto — e uno grave, perche'
    silenzioso: `npm run dev` dura ore, la conseguenza del si' arriverebbe al
    ctrl-c, e un comando interrotto esce con un codice diverso da zero che di
    quell'albero non dice niente. Il risultato misurato era che npz chiedeva,
    l'utente diceva di si', e non veniva creato nulla.

    Una domanda che ferma chi lavora deve avere una conseguenza che si vede
    subito. Se la conseguenza non arriva, il si' non era una domanda: era un
    disturbo.

    Restituisce se il comando dell'utente puo' partire.
    """
    try:
        congela(radice)
    except Errore as e:
        # L'invariante tiene: se il congelamento fallisce, node_modules non e'
        # stata toccata. Il comando dell'utente non e' ostaggio del nostro
        # lavoro, quindi si spiega e si tira dritto.
        veloce.voce(e, errore=True)
        dice("npz isn't attaching now; running your command as usual.")
        return True
    try:
        monta(radice)
    except Errore as e:
        # Qui invece l'albero e' dentro l'immagine e la cartella non c'e': far
        # partire adesso un build che non trovera' `node_modules` produrrebbe un
        # errore peggiore da leggere del nostro. Ci si ferma e si dice dov'e'
        # finita la roba.
        veloce.voce(e, errore=True)
        dice("your files are safe inside the image, but mounting it failed, so "
             "node_modules isn't there right now.\nRun `npz hey` to retry, or "
             "`npz detach` to get the plain folder back.")
        return False
    return True


def metti_da_parte(radice: Path) -> Path | None:
    """Smonta e sposta l'immagine di lato. **Non la cancella.**

    E' l'invariante del progetto applicata al caso di `npm ci`: si costruisce
    prima di cancellare. Cancellare qui significherebbe distruggere lo stato
    congelato *prima* di sapere se npm riuscira' — e npm fallisce per ragioni
    ordinarie, un lockfile che manca o la rete che non c'e'. L'immagine vecchia
    si butta solo quando la nuova esiste ed e' stata verificata.
    """
    p = percorsi(radice)
    # Senza condizioni: lo strato inferiore puo' essere montato anche quando
    # l'overlay sopra non lo e', e saltare lo smontaggio lo lascerebbe li'.
    smonta(radice, forza=True)
    if not p["immagine"].exists():
        return None
    da_parte = p["immagine"].with_name(p["immagine"].name + ".aside")
    with st.lock(prog.profilo(radice), radice):
        da_parte.unlink(missing_ok=True)
        os.replace(p["immagine"], da_parte)
        p["meta"].unlink(missing_ok=True)
        shutil.rmtree(p["delta"], ignore_errors=True)
        shutil.rmtree(p["lavoro"], ignore_errors=True)
        p["delta"].mkdir(parents=True, exist_ok=True)
    return da_parte


def riprendi(radice: Path, da_parte: Path) -> None:
    """Rimette al suo posto l'immagine messa da parte, e rimonta.

    Quel che npm ha lasciato a meta' nella cartella e' spazzatura derivabile e
    va tolta: se restasse, il mount la coprirebbe e resterebbe li' invisibile a
    occupare spazio.
    """
    p = percorsi(radice)
    cartella = prog.cartella(radice)
    if cartella.is_dir():
        shutil.rmtree(cartella, ignore_errors=True)
    os.replace(da_parte, p["immagine"])
    monta(radice)


def avvisa_delta(radice: Path) -> None:
    """La soglia di §9, tarata su N2: si guarda il delta, non il comando.

    Si guarda pero' solo il delta *consolidabile*: proporre un consolidamento
    per una cache di build sarebbe proporre un lavoro che non la toglierebbe di
    li', e lo si riproporrebbe identico subito dopo.
    """
    p = percorsi(radice)
    if not p["meta"].exists():
        return
    voci = quante(p["delta"], ESCLUSE)
    if not voci:
        return                                  # N2: capita spesso
    totali = st.leggi_meta(p["meta"]).get("file") or 1
    if voci * 100 // totali >= 10:
        dice(f"the delta is at {voci * 100 // totali}% of the image's entries "
             f"({voci}); a `npz compact` is worth it.")
