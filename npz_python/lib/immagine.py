"""La costruzione dell'immagine, e la verifica che la si possa credere.

`mkfs.erofs` senza opzioni oltre alla compressione: verificato che cosi'
conserva mode, mtime, uid, gid, xattr, symlink e hardlink. `-T0` azzera le
mtime e `--all-time` le riscrive a adesso: entrambe romperebbero la fedelta'
del ripristino.
"""

import os
import shutil
import stat as stat_mod
import subprocess
import time
from pathlib import Path

from . import COMPRESSIONE, Errore, Profilo
from .mount import Backend, montato

# Ogni quanto si avvisa chi osserva. **A tempo, non a conteggio**, ed e' una
# correzione: con una soglia ogni 512 voci il ritmo dei ridisegni lo detta il
# disco, e su FUSE, dove una voce puo' costare dieci millisecondi, fra due
# ridisegni passano cinque secondi. Chi guarda vede una riga ferma e conclude
# che il programma e' piantato — che e' esattamente cio' che l'avanzamento
# doveva smentire.
#
# A tempo il ritmo e' costante qualunque cosa faccia il disco, e la spesa e'
# nota: dieci scritture al secondo, non una ogni 512 voci di durata ignota.
# Leggere l'orologio a ogni voce costa un centesimo di quel che costa la `lstat`
# che gli sta accanto.
INTERVALLO = 0.1


def battito(osserva, intervallo: float = INTERVALLO):
    """Avvolge un osservatore perche' sia chiamato a tempo invece che sempre.

    Restituisce sempre qualcosa di chiamabile, anche quando non c'e' nessuno da
    avvisare: cosi' chi attraversa non deve controllare `is not None` a ogni
    voce, e il ciclo caldo resta una riga.
    """
    if osserva is None:
        return lambda *_: None
    ultimo = 0.0

    def battuta(*dati):
        nonlocal ultimo
        adesso = time.monotonic()
        if adesso - ultimo >= intervallo:
            ultimo = adesso
            osserva(*dati)
    return battuta


# ── la catena inversa: dal percorso relativo ai posti dentro .freeze-blobs ───

def percorsi(profilo: Profilo, radice: Path, relativo: str) -> dict[str, Path]:
    """I posti di una immagine, in due famiglie che non si mescolano.

    `static/` e `dynamic/` sono i **dati**: l'immagine, i suoi metadati, il delta
    che le si accumula sopra. Sopravvivono a tutto, e i loro nomi non si toccano
    — rinominarli renderebbe illeggibile ogni store gia' scritto, che e' il
    territorio di `FORMATO`.

    `run/<relativo>/` e' lo **stato di esercizio**, e esiste solo mentre qualcosa
    e' montato: `lower`, dove si monta l'immagine; `work`, il workdir che
    overlayfs esige sullo stesso filesystem del delta per poter materializzare un
    copy-up e spostarlo intero con un `rename`; e, per la durata di un
    consolidamento, `merged`. Tenerli sotto un tetto solo non e' ordine per
    l'ordine: sono esattamente cio' che il montaggio ricrea con un `mkdir` e cio'
    che a riposo si puo' buttare via, e una cartella sola lo dice senza doverlo
    spiegare.
    """
    servizio = radice / profilo.servizio
    return {
        "immagine": servizio / "static" / (relativo + ".img"),
        "meta": servizio / "static" / (relativo + ".meta"),
        "delta": servizio / "dynamic" / relativo,
        "lavoro": servizio / "run" / relativo / "work",
        "basso": servizio / "run" / relativo / "lower",
    }


def relativo_di(cartella: Path, radice: Path) -> str:
    try:
        return str(cartella.resolve().relative_to(radice.resolve()))
    except ValueError:
        raise Errore(f"{cartella} isn't inside the root {radice}") from None


def elenca(profilo: Profilo, radice: Path) -> list[str]:
    """Le immagini presenti. Il percorso e' esso stesso l'indice: nessun registro."""
    statica = radice / profilo.servizio / "static"
    if not statica.is_dir():
        return []
    return sorted(
        str(p.relative_to(statica))[:-len(".img")]
        for p in statica.rglob("*.img")
    )


# ── costruzione ──────────────────────────────────────────────────────────────

def costruisci(sorgente: Path, destinazione: Path, compressione: str = COMPRESSIONE,
               escludi: tuple[str, ...] = (), osserva=None) -> Path:
    """Costruisce l'immagine su un nome temporaneo. Non tocca nulla di esistente.

    `escludi` sono percorsi **relativi alla sorgente** che non devono entrare
    nell'immagine. Quali siano lo decide la facciata — per `npz` sono le cache di
    build, §9 del suo piano — qui si sa solo come si dice a `mkfs.erofs` di
    saltarli: `--exclude-path` vuole il percorso relativo e senza barra iniziale,
    verificato, perche' con la barra non corrisponde a niente e non lo dice.
    """
    if not shutil.which("mkfs.erofs"):
        raise Errore("mkfs.erofs is missing (package erofs-utils)")
    destinazione.parent.mkdir(parents=True, exist_ok=True)
    tmp = destinazione.with_name(destinazione.name + ".new")
    tmp.unlink(missing_ok=True)

    comando = ["mkfs.erofs"]
    # `nessuna` e' la grafia di prima che la CLI passasse all'inglese, e si
    # accetta ancora: sta scritta dentro i `config` gia' su disco, e non
    # riconoscerla vorrebbe dire passare `-znessuna` a mkfs.erofs.
    if compressione and compressione not in ("none", "nessuna"):
        comando.append(f"-z{compressione}")
    comando += [f"--exclude-path={e.lstrip('/')}" for e in escludi]
    comando += [str(tmp), str(sorgente)]

    # Al livello di verbosita' predefinito `mkfs.erofs` nomina ogni voce che
    # scrive: contarle e' l'unico avanzamento **vero** disponibile, perche' il
    # totale lo sappiamo gia' da `conta()`.
    codice, coda = esegui_contando(
        comando, lambda r: r.startswith("Processing "), osserva)
    if codice != 0:
        tmp.unlink(missing_ok=True)
        raise Errore("mkfs.erofs failed: " + (coda[-1] if coda else "no message"))
    return tmp


def esegui_contando(comando: list[str], riconosce, osserva=None,
                    ) -> tuple[int, list[str]]:
    """Esegue un comando contandone le righe di lavoro mentre scorrono.

    Serve ai due programmi esterni che npz aspetta a lungo — `mkfs.erofs` che
    costruisce l'immagine e `cp` che la rimaterializza — e che, se glielo si
    chiede, dicono a voce quale voce stanno trattando. Contare quelle righe da'
    un avanzamento **misurato** invece che stimato, e costa la lettura di un
    tubo che altrimenti si sarebbe buttata via.

    Si legge mentre scorre e non in blocco: raccogliere tutto e poi contare
    darebbe la percentuale giusta al momento in cui non serve piu' a nessuno.

    I due flussi si fondono in uno perche' leggerne due separati dallo stesso
    processo si blocca quando uno dei due riempie il proprio buffer e nessuno lo
    sta svuotando. Della coda si tengono le ultime righe, che sono quel che
    serve a raccontare un fallimento.
    """
    processo = subprocess.Popen(comando, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
    coda: list[str] = []
    visti = 0
    riferisci = battito(osserva)
    for riga in processo.stdout:                       # type: ignore[union-attr]
        coda.append(riga.rstrip())
        del coda[:-8]
        if riconosce(riga):
            visti += 1
            riferisci(visti)
    processo.wait()
    if osserva is not None and processo.returncode == 0:
        osserva(visti)
    return processo.returncode, coda


# ── verifica ─────────────────────────────────────────────────────────────────

def inventario(radice: Path, osserva=None) -> dict[str, tuple]:
    """Una fotografia dell'albero, confrontabile: percorso -> attributi.

    Non legge i contenuti: confronta tipo, permessi, dimensione, destinazione dei
    symlink e proprietario. Sono gli attributi che il ripristino deve conservare
    e che un errore di costruzione perderebbe.

    Si cammina con `os.scandir` e si chiedono gli attributi alla **voce**, non al
    percorso, ed e' una differenza che su FUSE si sente: `lstat("a/b/c/d")` fa
    risolvere al kernel ogni componente, e ogni componente e' un giro verso il
    demone, mentre `DirEntry.stat()` guarda dal descrittore della directory che
    e' gia' aperta. Misurato su 10.400 voci dietro erofsfuse: 0,415 s con
    `os.walk` piu' `Path.lstat`, **0,093 con scandir** — quattro volte e mezzo, a
    parita' di risultato.

    Il gemello Go arriva allo stesso posto per un'altra strada: li' la `lstat`
    resta per percorso e a guadagnare e' il parallelismo, che qui non serve a
    niente — misurato, con i thread Python la stessa passata *peggiora* dello
    0,1, perche' il GIL rende la contesa piu' cara dell'attesa che eviterebbe.
    """
    fotografia: dict[str, tuple] = {}
    base = os.path.realpath(radice)
    taglio = len(base) + 1
    riferisci = battito(osserva)
    pila = [base]
    while pila:
        dove = pila.pop()
        try:
            voci = list(os.scandir(dove))
        except OSError:
            continue
        for voce in voci:
            try:
                st = voce.stat(follow_symlinks=False)
            except OSError:
                continue
            if voce.is_dir(follow_symlinks=False):
                pila.append(voce.path)
            tipo = stat_mod.S_IFMT(st.st_mode)
            destinazione = os.readlink(voce.path) if stat_mod.S_ISLNK(st.st_mode) else None
            dimensione = st.st_size if stat_mod.S_ISREG(st.st_mode) else None
            fotografia[voce.path[taglio:]] = (
                tipo, stat_mod.S_IMODE(st.st_mode),
                dimensione, destinazione, st.st_uid, st.st_gid)
            riferisci(len(fotografia))
    if osserva is not None:
        osserva(len(fotografia))
    return fotografia


def uid_visti(fotografia: dict) -> set[int]:
    """Gli uid presenti in un inventario gia' fatto.

    Come `misura()`: il dato c'e' gia', e ripercorrere l'albero per riprenderlo
    costerebbe una passata intera su cio' che e' appena stato letto.
    """
    return {voce[4] for voce in fotografia.values()}


def differenze(atteso: dict, ottenuto: dict, limite: int = 5) -> list[str]:
    voci = []
    mancanti = sorted(set(atteso) - set(ottenuto))
    aggiunti = sorted(set(ottenuto) - set(atteso))
    for rel in mancanti[:limite]:
        voci.append(f"missing: {rel}")
    for rel in aggiunti[:limite]:
        voci.append(f"extra: {rel}")
    for rel in sorted(set(atteso) & set(ottenuto)):
        if atteso[rel] != ottenuto[rel]:
            voci.append(f"different: {rel} — {atteso[rel]} vs {ottenuto[rel]}")
            if len(voci) >= limite:
                break
    rimasti = len(mancanti) + len(aggiunti) - len(voci)
    if rimasti > 0:
        voci.append(f"…and {rimasti} more")
    return voci


def verifica(immagine: Path, sorgente: Path, punto: Path, backend: Backend,
             osserva=None, atteso: dict | None = None) -> None:
    """Monta l'immagine appena costruita e la confronta con l'originale.

    E' il cuore dell'invariante: la cartella originale non sparisce finche' non
    e' dimostrato che l'immagine la contiene davvero. Costa un mount e una
    passata di `lstat`, ed e' cio' che separa questo da un `rm -rf` con speranza.
    """
    punto.mkdir(parents=True, exist_ok=True)
    # Se sul punto c'e' gia' qualcosa — un ciclo precedente interrotto, un mount
    # sopravvissuto a una cartella cancellata — montarci sopra ne impila due, e
    # cio' che si finirebbe per confrontare non e' l'immagine appena costruita.
    # Il guasto si presenterebbe come "l'immagine non corrisponde all'originale",
    # che manda a cercare un difetto dove non c'e'.
    while montato(punto):
        backend.smonta(punto)
    backend.monta_ro(immagine, punto)
    try:
        # Due passate: prima l'originale, poi l'immagine montata. Si distinguono
        # per chi osserva, che altrimenti vedrebbe il conteggio ripartire da zero
        # senza sapere perche'.
        if atteso is None:
            atteso = inventario(sorgente, _fase(osserva, "the original"))
        scarto = differenze(
            atteso, inventario(punto, _fase(osserva, "the image")))
        if scarto:
            raise Errore("the image doesn't match the original:\n  " +
                         "\n  ".join(scarto) +
                         "\nThe source folder was NOT touched.")
    finally:
        if montato(punto):
            backend.smonta(punto)


def misura(fotografia: dict) -> tuple[int, int, int]:
    """Gli stessi tre numeri di `conta()`, ma da un inventario gia' fatto.

    Serve dove l'albero sta dietro uno strato FUSE e ripercorrerlo costa quanto
    il resto dell'operazione: il consolidamento di `npz` ha gia' in mano la
    fotografia dell'immagine appena verificata, e da quella i numeri si ricavano
    senza toccare il disco una seconda volta.

    Il `+ 1` sulle cartelle e' la **radice**, che `inventario()` non elenca —
    registra i percorsi relativi a essa, e relativo a se stessa non e' un
    percorso. `censisci()` invece la conta, e `mkfs.erofs` e `cp -v` la nominano:
    i tre numeri devono voler dire la stessa cosa, o il totale su cui si calcola
    un avanzamento cambia a seconda di chi l'ha prodotto.
    """
    file = sum(1 for voce in fotografia.values() if voce[0] != stat_mod.S_IFDIR)
    byte = sum(voce[2] for voce in fotografia.values() if voce[2] is not None)
    cartelle = sum(1 for voce in fotografia.values() if voce[0] == stat_mod.S_IFDIR)
    return file, byte, cartelle + 1


def conta(cartella: Path, osserva=None) -> tuple[int, int, int]:
    """Quanti file, quanti byte e quante directory.

    I primi due vanno nei metadati e nel segnaposto. Le directory servono a chi
    deve mostrare un avanzamento su `mkfs.erofs`, che nomina **ogni voce** che
    scrive, cartelle comprese: misurare la percentuale sui soli file la
    manderebbe oltre il 100% proprio verso la fine, che e' il momento in cui una
    barra di avanzamento viene guardata di piu'.
    """
    file, byte, cartelle, _ = censisci(cartella, osserva)
    return file, byte, cartelle


def censisci(cartella: Path, osserva=None) -> tuple[int, int, int, set[int]]:
    """Quanti file, quanti byte, quante directory, e **quali uid** si incontrano.

    Le quattro risposte in una passata sola perche' vengono tutte dalla stessa
    `lstat`, e perche' la passata e' la cosa cara: su 100.000 file serviti da
    FUSE, misurato, contare costa 13 secondi e guardare gli uid altri 11, mentre
    farlo insieme ne costa 14. Chiederle separatamente era il 42% di lavoro
    buttato, tutto speso prima che `mkfs.erofs` cominciasse — cioe' dentro il
    silenzio che faceva sembrare npz piantato.

    Gli uid si **riportano**, non si giudicano: quali siano estranei lo decide
    chi chiama, che e' l'unico a sapere per conto di chi sta guardando.
    """
    file = byte = cartelle = 0
    uid: set[int] = set()
    riferisci = battito(osserva)

    # `os.scandir` e non `os.walk` piu' `lstat`, per la stessa ragione di
    # `inventario()`: gli attributi si chiedono alla **voce**, che il descrittore
    # della directory ce l'ha gia' aperto, invece che al percorso, che il kernel
    # dovrebbe risolvere un componente alla volta — e su FUSE ogni componente e'
    # un giro verso il demone.
    radice = os.fspath(cartella)
    try:
        pila = [(radice, list(os.scandir(radice)))]
    except OSError:
        return 0, 0, 0, uid          # come `os.walk`, che su una radice illeggibile non da' nulla

    while pila:
        dove, voci = pila.pop()
        cartelle += 1                     # `dove` stesso: cosi' la radice si conta
        try:
            uid.add(os.lstat(dove).st_uid)
        except OSError:
            pass
        for voce in voci:
            try:
                st = voce.stat(follow_symlinks=False)
            except OSError:
                continue
            if voce.is_dir(follow_symlinks=False):
                try:
                    pila.append((voce.path, list(os.scandir(voce.path))))
                except OSError:
                    pass                  # illeggibile: non si scende, e non si conta
                continue
            # Un symlink a directory conta **fra i file**, non fra le cartelle:
            # per `lstat` e' un link, e la classificazione dev'essere la stessa
            # di `misura()`, che lavora su un inventario dove i tipi vengono da
            # `lstat`. Finche' le due contavano diversamente i totali tornavano
            # ma la ripartizione no, e il `file` scritto nel `.meta` dipendeva da
            # quale delle due l'aveva prodotto.
            file += 1
            uid.add(st.st_uid)
            if stat_mod.S_ISREG(st.st_mode):
                byte += st.st_size
            riferisci(file, byte)
    if osserva is not None:
        osserva(file, byte)
    return file, byte, cartelle, uid


def _fase(osserva, quale: str):
    """Lega un nome di fase a un osservatore, o restituisce None se non ce n'e'."""
    if osserva is None:
        return None
    return lambda n: osserva(n, quale)
