"""Cosa si puo' congelare.

Il perimetro e' corto perche' EROFS regge quasi tutto: hardlink con il loro
inode, fifo, socket, device node, symlink rotti, xattr e permessi; e i file
sparsi non vengono riespansi, perche' la compressione riduce gli zeri a nulla.
I divieti che il progetto si era dato all'inizio erano imposti dall'object store
di composefs, e sono caduti con lui.

Restano due casi, e in nessuno dei due si procede saltando in silenzio cio' che
non si sa gestire: saltare significa perdere senza dirlo.
"""

import os
from pathlib import Path

# Ogni quante voci si avvisa chi osserva: l'attraversata di un albero grande
# su un disco lento e' minuti, e va raccontata mentre accade.


def processi_attivi(cartella: Path) -> list[str]:
    """Chi sta usando *questa cartella*. Vuoto se nessuno.

    Si guarda `/proc` a mano invece di chiamare `fuser`: `fuser -m` ragiona per
    **filesystem montato**, non per directory, quindi su una cartella dentro `/`
    elenca ogni processo del sistema. Sembra funzionare — trova sempre
    qualcosa — ed e' esattamente per questo che era pericoloso.

    Guarda cwd, root e i descrittori aperti. I processi di altri utenti sono
    leggibili solo in parte senza privilegi: quello che si vede si riporta,
    quello che non si vede non si inventa.
    """
    obiettivo = str(cartella.resolve())
    prefisso = obiettivo + "/"
    trovati = []
    for voce in Path("/proc").iterdir():
        if not voce.name.isdigit():
            continue
        if _tocca(voce, obiettivo, prefisso):
            trovati.append(f"pid {voce.name} ({nome_processo(voce.name)})")
    return trovati


def _tocca(proc: Path, obiettivo: str, prefisso: str) -> bool:
    for dove in ("cwd", "root"):
        destinazione = _link(proc / dove)
        if destinazione and (destinazione == obiettivo or destinazione.startswith(prefisso)):
            return True
    try:
        descrittori = list((proc / "fd").iterdir())
    except OSError:
        return False
    for fd in descrittori:
        destinazione = _link(fd)
        if destinazione and (destinazione == obiettivo or destinazione.startswith(prefisso)):
            return True
    return False


def _link(percorso: Path) -> str | None:
    try:
        return os.readlink(percorso)
    except OSError:
        return None


def nome_processo(pid: str) -> str:
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        return "?"


def ownership_estranea(cartella: Path, osserva=None) -> set[int]:
    """Gli uid diversi dal nostro presenti nell'albero.

    Non impedisce il freeze: uid e gid finiscono correttamente nell'immagine.
    Ma un mount FUSE non privilegiato non li rende accessibili agli altri utenti
    senza `allow_other`, e l'utente va avvisato prima, non dopo.

    E' una **vista** su `immagine.censisci()`, che quella passata la fa gia' per
    contare. Chi vuole entrambe le risposte chieda quella e le prenda insieme:
    su centomila file serviti da FUSE attraversare due volte costa 24 secondi
    dove una ne costa 14, ed e' tempo speso tutto prima che il lavoro cominci.
    """
    from .immagine import censisci      # tardi: `immagine` non importa `perimetro`,
    return censisci(cartella)[3] - {os.getuid()}     # ma tenerlo qui lo dimostra


# `controlla()` non c'e' piu'. Univa i due controlli in una chiamata, ma li
# pagava in due passate; adesso l'unica passata la fa `immagine.censisci()`, e
# chi congela chiama `processi_attivi()` — che guarda /proc, non l'albero — e
# `censisci()`, prendendosi conteggi e uid insieme.
