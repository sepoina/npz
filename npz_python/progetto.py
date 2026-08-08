"""Il progetto: l'opposto della risalita di `freeze`.

`freeze.radice` cerca una cartella di servizio dichiarata a mano con `init`, e
si rifiuta di annidarne due. Qui la radice **non si dichiara**: e' il progetto
stesso, e la si riconosce dal `package.json`. Ne segue che due progetti annidati
— un workspace dentro un monorepo — sono legittimi, e ognuno ha il proprio
`.npz`.

La risalita vera vive in `veloce.trova_progetto`, perche' sta sul percorso
veloce e non puo' permettersi `pathlib`. Qui sopra ci si mette solo cio' che
serve al percorso lento: i `Path`, il giudizio sul filesystem, gli errori
leggibili.
"""

import os
import shutil
import sys
import textwrap
from pathlib import Path

from .lib import Errore, Profilo
from .lib import filesystem as fs
from .lib.filesystem import idoneita, tipo_filesystem     # noqa: F401  (riesportati)

from . import PROFILO, veloce
from .veloce import CARTELLA, MANIFESTO, trova_progetto


def trova(partenza: Path | str | None = None) -> Path | None:
    dove = trova_progetto(str(partenza) if partenza is not None else None)
    return Path(dove) if dove else None


def richiedi(partenza: Path | str | None = None) -> Path:
    progetto = trova(partenza)
    if progetto is None:
        raise Errore(
            f"you're not inside a project: no {MANIFESTO} above here.\n"
            f"npz works wherever npm works."
        )
    return progetto


def servizio(progetto: Path) -> Path:
    """La cartella di servizio, con il nome che ha *adesso*."""
    return progetto / (veloce.nome_servizio(str(progetto)) or veloce.SERVIZIO)


def profilo(progetto: Path) -> Profilo:
    """Il profilo da dare a `lib`, intonato al nome corrente.

    E' esattamente cio' che il refactoring del Profilo ha reso possibile: il
    nucleo non sa come si chiami la cartella di servizio, e non deve saperlo.
    """
    return Profilo(servizio=servizio(progetto).name, sentinella=PROFILO.sentinella)


# La sottocartella che esiste solo mentre si e' montati. Dentro `run/` ci sta
# tutto lo stato di esercizio — `lower` con l'immagine montata, `work` con lo
# scratch di overlayfs, `merged` durante un consolidamento — e nessuna delle tre
# significa piu' niente a mount spento. Il montaggio le ricrea tutte con un
# `mkdir`, quindi tenerle da fermi e' solo rumore dentro una cartella che deve
# spiegarsi da sola. Che siano una sola voce e non due sparse e' cio' che rende
# questa riga una regola invece di un elenco da tenere aggiornato.
EFFIMERE = ("run",)


def addormenta(progetto: Path) -> None:
    """Da `.npz` al nome visibile: la cartella e' ferma e lo dichiara.

    Ferma vuol dire anche piu' magra: si lascia cadere cio' che serviva solo al
    mount, e restano i quattro nomi che contengono davvero qualcosa — `config`,
    `lock`, `static/` con l'immagine, `dynamic/` con il delta.

    La rinomina va fatta **fuori dal lock**: il file di lock vive dentro la
    cartella che si rinomina, e un secondo processo che avesse gia' risolto il
    vecchio nome lo troverebbe sparito fra il `nome_servizio()` e l'`open()`.
    `flock` sta sull'inode e sopravvive alla rinomina, quindi l'esclusione
    regge; e' la finestra di risoluzione del nome che va tenuta stretta.
    """
    corrente = progetto / veloce.SERVIZIO
    fermo = progetto / veloce.SERVIZIO_FERMO
    if not corrente.is_dir() or fermo.exists():
        return
    for effimera in EFFIMERE:
        shutil.rmtree(corrente / effimera, ignore_errors=True)
    os.replace(corrente, fermo)


def sveglia(progetto: Path) -> None:
    """Dal nome visibile a `.npz`: si torna a lavorare, la cartella si nasconde."""
    fermo = progetto / veloce.SERVIZIO_FERMO
    corrente = progetto / veloce.SERVIZIO
    if fermo.is_dir() and not corrente.exists():
        os.replace(fermo, corrente)


def cartella(progetto: Path) -> Path:
    return progetto / CARTELLA


def verifica_idoneita(progetto: Path) -> None:
    """Rifiuta i supporti su cui npz non potrebbe funzionare, e dice come fare.

    Il giudizio e' di `lib.filesystem.idoneita()`; qui si aggiunge il **rimedio**,
    che nel nucleo non puo' stare: nomina convenzioni di distribuzione, un driver
    e un file di configurazione, e sono tutte cose che il nucleo non sa e non
    deve sapere.

    Il rimedio si compone solo quando c'e' davvero, ed e' misurato invece che
    indovinato: device e UUID da `mountinfo` e da `/dev/disk/by-uuid`, il nome
    del driver dalla riga di comando del demone. Dove uno di questi manca — un
    mount di rete, un tmpfs, una immagine dentro un file — non si propone
    niente, perche' un `fstab` per UUID li' non esiste.
    """
    motivo = idoneita(progetto)
    if not motivo:
        return
    righe = [f"npz can't work here: {motivo}."]
    rimedio = _rimedio(fs.sonda(progetto))
    righe.extend(rimedio if rimedio else [
        f"The filesystem is {tipo_filesystem(progetto) or 'unknown'}. "
        "Move the project to a local POSIX filesystem."
    ])
    raise Errore("\n".join(righe))


# I driver NTFS in user space. Il rimedio si scrive solo per questi: e' l'unico
# caso in cui sappiamo davvero quale riga di `fstab` funzionerebbe.
_NTFS = ("mount.ntfs", "ntfs-3g", "mount.ntfs-3g", "lowntfs-3g", "mount.lowntfs-3g")


def _rimedio(s: fs.Supporto) -> list[str] | None:
    """Come rimontare il disco perche' i file siano nostri, o None."""
    if not (s.proprietario_estraneo and s.device):
        return None
    punto = fs.punto_di_mount(s.percorso)
    driver = fs.driver_di_mount(s.sorgente, punto)
    if driver not in _NTFS or not punto:
        return None
    uid, gid = os.geteuid(), os.getegid()
    # In `fstab` va il **tipo**, non l'aiutante: `mount` cerca `mount.<tipo>`, e
    # scriverci `mount.ntfs` gli farebbe cercare `mount.mount.ntfs`. Il tipo si
    # ricava togliendo il prefisso, ed e' giusto per costruzione: l'aiutante lo
    # abbiamo trovato perche' e' lui a servire questo mount.
    tipo = driver.removeprefix("mount.")
    C, Z = _accento()
    return [
        "",
        *_avvolgi(
            f"{tipo} is elastic about permissions: it takes any chmod and quietly "
            f"drops it. The overlay npz puts on top is not — only an owner may "
            f"change a mode — so npm's chmod on the shims it installs comes back "
            f"EPERM and the install stops."
        ),
        "",
        "Remount it as yours, as root:",
        f"  {C}umount {punto}{Z}",
        f"  {C}{driver} -o uid={uid},gid={gid},allow_other {s.sorgente} {punto}{Z}",
        "",
        "To keep it, in /etc/fstab:",
        f"  {C}UUID={s.uuid} {punto} {tipo} "
        f"uid={uid},gid={gid},allow_other,nofail 0 0{Z}",
        "",
        *_avvolgi(f"allow_other needs user_allow_other in /etc/fuse.conf, or "
                  f"node_modules can't be mounted inside a path on {s.tipo}."),
    ]


def _accento() -> tuple[str, str]:
    """Ciano e spegnimento per i comandi, o due stringhe vuote se non e' un TTY.

    Gli errori escono da `veloce.voce(..., errore=True)`, cioe' su **stderr**: e'
    li' che si guarda se c'e' un terminale, e non su stdout, che potrebbe essere
    in una pipe mentre il terminale c'e' lo stesso.

    E' lo stesso ciano che `cli.aiuto()` mette sui nomi dei comandi — qui come
    la' colora *quel che si digita*, che e' l'unica cosa in un messaggio d'errore
    a cui serva saltare all'occhio.
    """
    try:
        if not sys.stderr.isatty():
            return "", ""
    except (AttributeError, ValueError):
        return "", ""
    return "\033[36m", "\033[0m"


def _avvolgi(testo: str) -> list[str]:
    """Manda a capo alla larghezza utile del terminale, entro 120 colonne.

    Utile e' quella che resta tolta la sbarra, che `veloce.voce()` antepone a
    ogni riga: mandare a capo a 120 e poi vederne stampate 124 vanificherebbe il
    lavoro. Il tetto a 120 c'e' perche' una riga di prosa larga quanto un
    terminale a schermo intero non si legge — l'occhio perde il capo.

    I comandi non passano di qui: si spezzano dove capita, e uno spezzato non si
    puo' copiare. Meglio che sia il terminale a mandarlo a capo come vuole.
    """
    larghezza = min(shutil.get_terminal_size((80, 24)).columns, 120)
    return textwrap.wrap(testo, width=max(40, larghezza - len(veloce.SEGNO)))


def prepara_servizio(progetto: Path) -> Path:
    """Crea `.npz/` e la esclude da git, senza toccare il .gitignore dell'utente.

    `.git/info/exclude` e' il posto giusto: non e' versionato, quindi non compare
    nei diff di nessuno, e non si sovrappone a scelte che l'utente ha gia' fatto
    nel proprio `.gitignore`.
    """
    dove = servizio(progetto)
    # Solo le due che contengono dati: `run/` la fa nascere il montaggio, ed e'
    # giusto che una cartella di servizio appena creata non ce l'abbia — non c'e'
    # ancora niente in esercizio.
    for sotto in ("static", "dynamic"):
        (dove / sotto).mkdir(parents=True, exist_ok=True)

    esclusioni = progetto / ".git" / "info" / "exclude"
    if esclusioni.parent.is_dir():
        try:
            righe = esclusioni.read_text().splitlines() if esclusioni.exists() else []
            # Tutti e tre i nomi: la cartella di servizio ne cambia uno a
            # seconda dello stato, ed escluderne uno solo la farebbe ricomparire
            # fra gli untracked appena il progetto va a riposo. Il terzo e'
            # l'albero messo da parte dopo uno scavalcamento (§6 bis): sta nella
            # radice di progetto, in vista, e non e' roba da committare.
            nomi = (veloce.SERVIZIO, veloce.SERVIZIO_FERMO, veloce.ALBERO_SUPERATO)
            mancanti = [n + "/" for n in nomi if n + "/" not in righe]
            if mancanti:
                with esclusioni.open("a") as fh:
                    fh.write("\n# added by npz\n" + "\n".join(mancanti) + "\n")
        except OSError:
            pass          # non poter escludere non e' un motivo per fermarsi
    return dove


def segna_rifiuto(progetto: Path) -> None:
    """Ricorda che l'utente ha detto no.

    Un file vuoto e non una chiave in una configurazione: il percorso veloce lo
    legge con un `os.stat`, senza aprire né analizzare niente. E ricordare il
    "no" e' importante quanto ricordare il "si'" — senza, si richiederebbe a
    ogni comando, per sempre.
    """
    dove = servizio(progetto)
    dove.mkdir(parents=True, exist_ok=True)
    (dove / "no").write_text(
        "npz isn't managing this project: the user answered no.\n"
        "Delete this file to be asked again.\n"
    )
