"""Il montaggio, dietro una sola interfaccia.

Due implementazioni fin da subito. **FUSE e' quella normale**: `erofsfuse` per
lo strato di sola lettura, `fuse-overlayfs` per il delta, e non serve alcun
privilegio. Il kernel e' l'ottimizzazione per quando root e' disponibile: piu'
veloce, stessa semantica.

Che la via non privilegiata esista e' una conseguenza dell'aver rinunciato
all'object store: `fuse-overlayfs` non implementa i layer *data-only*, che erano
il meccanismo con cui l'immagine rimandava agli oggetti condivisi. Senza store
quel meccanismo non serve piu'.
"""

import os
import shutil
import subprocess
import time
from pathlib import Path

from . import Errore
from .filesystem import regge_upperdir_kernel, tipo_filesystem

# Quanto si insiste su un mount occupato: 25 tentativi ogni 20 ms, mezzo secondo
# in tutto. Misurato: il demone molla in molto meno.
ATTESA_SMONTA = 25
RITMO_SMONTA = 0.02


class Backend:
    nome = "?"

    def disponibile(self) -> bool:
        raise NotImplementedError

    def monta_ro(self, immagine: Path, punto: Path) -> None:
        """Monta la sola immagine, in sola lettura."""
        raise NotImplementedError

    def monta_stack(self, basso: Path, delta: Path, lavoro: Path, punto: Path) -> None:
        """Sovrappone il delta scrivibile a uno strato gia' montato."""
        raise NotImplementedError

    def monta_fusione(self, strati: list[Path], punto: Path) -> None:
        """La vista fusa in sola lettura, dal delta piu' recente al piu' vecchio.

        E' quella che si da' a mkfs.erofs per consolidare: il merge lo fa il
        kernel, e non c'e' logica di whiteout da scrivere.
        """
        raise NotImplementedError

    def smonta(self, punto: Path, pigro: bool = False) -> None:
        """Smonta. `pigro` stacca il punto subito e libera quando l'ultimo esce.

        Un mount tenuto da qualcuno non si smonta, e chi tiene un albero di
        dipendenze e' quasi sempre un watcher o un language server. Lo
        smontaggio pigro e' la via che resta a chi ha detto `--force`: il punto
        sparisce dalla vista di tutti all'istante, e il demone se ne va quando
        l'ultimo descrittore si chiude. Il prezzo e' che le scritture in volo
        finiscono in uno strato che nessuno rileggera' — per questo non e' mai
        il comportamento predefinito.
        """
        raise NotImplementedError


class Fuse(Backend):
    nome = "fuse"

    def disponibile(self) -> bool:
        return bool(shutil.which("erofsfuse") and shutil.which("fuse-overlayfs"))

    def monta_ro(self, immagine, punto):
        punto.mkdir(parents=True, exist_ok=True)
        esegui(["erofsfuse", str(immagine), str(punto)])

    def monta_stack(self, basso, delta, lavoro, punto):
        for d in (delta, lavoro):
            d.mkdir(parents=True, exist_ok=True)
        base, (b, d, l) = accorcia(basso, delta, lavoro)
        esegui(["fuse-overlayfs", "-o",
                f"lowerdir={b},upperdir={d},workdir={l}", str(punto)], cwd=base)

    def monta_fusione(self, strati, punto):
        punto.mkdir(parents=True, exist_ok=True)
        base, corti = accorcia(*strati)
        esegui(["fuse-overlayfs", "-o", "lowerdir=" + ":".join(corti)],
               coda=[str(punto)], cwd=base)

    def smonta(self, punto, pigro=False):
        """Stacca, riprovando finche' e' **occupato da chi se ne sta andando**.

        `fusermount3 -u` stacca il punto dal namespace e torna subito, ma il
        demone che lo serviva esce per conto suo, un istante dopo. Chi smonta
        uno stack — prima l'overlay, poi l'immagine che gli faceva da lower —
        trova quindi il lower ancora tenuto da un `fuse-overlayfs` che non e'
        ancora morto, e si prende un EBUSY che al secondo tentativo non c'e'
        piu'. E' la corsa che faceva fallire `npz bye`, sempre sullo stesso
        punto.

        Si riprova per un tempo **corto e limitato**: la condizione dura
        millisecondi, e un mount tenuto davvero — un watcher, un language
        server — deve continuare a fallire, e in fretta, perche' il messaggio
        che nomina i processi e' piu' utile di qualunque attesa.

        Con `pigro` non si riprova: `-uz` non fallisce per occupato.
        """
        comando = "fusermount3" if shutil.which("fusermount3") else "fusermount"
        if pigro:
            esegui([comando, "-uz", str(punto)])
            return
        for tentativo in range(ATTESA_SMONTA):
            try:
                esegui([comando, "-u", str(punto)])
                return
            except Errore as e:
                if "busy" not in str(e).lower():
                    raise            # un guasto vero: non lo si maschera aspettando
                ultimo = e
            time.sleep(RITMO_SMONTA)
        raise ultimo


class Kernel(Backend):
    nome = "kernel"

    def disponibile(self) -> bool:
        return os.geteuid() == 0

    def monta_ro(self, immagine, punto):
        punto.mkdir(parents=True, exist_ok=True)
        esegui(["mount", "-t", "erofs", "-o", "loop,ro", str(immagine), str(punto)])

    def monta_stack(self, basso, delta, lavoro, punto):
        for d in (delta, lavoro):
            d.mkdir(parents=True, exist_ok=True)
        esegui(["mount", "-t", "overlay", "overlay", "-o",
                f"lowerdir={basso},upperdir={delta},workdir={lavoro}", str(punto)])

    def monta_fusione(self, strati, punto):
        punto.mkdir(parents=True, exist_ok=True)
        esegui(["mount", "-t", "overlay", "overlay", "-o",
                "lowerdir=" + ":".join(str(s) for s in strati) + ",ro", str(punto)])

    def smonta(self, punto, pigro=False):
        esegui(["umount"] + (["-l"] if pigro else []) + [str(punto)])


def scegli(preferito: str | None = None, percorso: Path | None = None) -> Backend:
    """FUSE se c'e', kernel come alternativa. `preferito` forza la scelta.

    Con `percorso` si scarta anche la via kernel dove il suo overlayfs non
    accetterebbe l'`upperdir` — su FUSE, per dirne la sola che qui capita. Non
    e' un giudizio sul supporto: la via FUSE li' funziona, ed e' comunque quella
    preferita. Serve a non proporre da root un backend che fallirebbe al mount.
    """
    disponibili = [b for b in (Fuse(), Kernel()) if b.disponibile()]
    tipo = tipo_filesystem(percorso) if percorso is not None else None
    scartato_kernel = False
    if percorso is not None and not regge_upperdir_kernel(tipo):
        prima = len(disponibili)
        disponibili = [b for b in disponibili if b.nome != "kernel"]
        scartato_kernel = len(disponibili) < prima
    if not disponibili:
        # Se il kernel c'era e l'abbiamo scartato noi, dire "run as root" a chi
        # gia' e' root manderebbe a sbattere: il rimedio e' un altro.
        raise Errore(
            "no way to mount images.\n" + (
                f"The kernel's overlayfs won't take an upperdir on {tipo}, "
                "so only the FUSE path works here.\n"
                "Install erofsfuse and fuse-overlayfs."
                if scartato_kernel else
                "Install erofsfuse and fuse-overlayfs, or run as root."
            )
        )
    if preferito:
        for b in disponibili:
            if b.nome == preferito:
                return b
        raise Errore(f"backend '{preferito}' isn't available "
                     f"(available: {', '.join(b.nome for b in disponibili)})")
    return disponibili[0]


def montato(punto: Path) -> bool:
    try:
        return os.path.ismount(punto)
    except OSError:
        return False


def accorcia(*percorsi: Path) -> tuple[str, list[str]]:
    """Una base comune e i percorsi relativi a essa.

    Serve a `fuse-overlayfs`, che spezza il proprio `lowerdir` sui due punti e
    non sa che farsene di un percorso che ne contiene uno. Misurato: con un
    percorso assoluto che contiene `:` il montaggio fallisce con
    `cannot resolve path`; con gli stessi percorsi relativi, dopo un `chdir`,
    funziona. Gli spazi invece non danno alcun fastidio, in nessuna delle due
    forme.

    Non e' una precauzione teorica: i progetti degli utenti stanno in percorsi
    che non controlliamo.
    """
    assoluti = [str(p.resolve()) for p in percorsi]
    base = os.path.commonpath(assoluti) if len(assoluti) > 1 else os.path.dirname(assoluti[0])
    return base, [os.path.relpath(a, base) for a in assoluti]


def esegui(comando: list[str], coda: list[str] | None = None,
           cwd: str | None = None) -> None:
    esito = subprocess.run(comando + (coda or []), capture_output=True,
                           text=True, cwd=cwd)
    if esito.returncode != 0:
        messaggio = (esito.stderr or esito.stdout).strip().splitlines()
        raise Errore(f"{comando[0]} failed: " +
                     (messaggio[0] if messaggio else f"exit code {esito.returncode}"))
