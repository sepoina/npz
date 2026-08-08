"""Lo stato su disco: lock, configurazione, metadati.

Il `.meta` accanto all'immagine e' la fonte di verita': tutto il resto se ne
deriva. Il segnaposto, che da questa verita' discende, e' un'idea di `freeze` e
vive in `freeze.segnaposto` — `npz` non ne ha.
"""

import fcntl
import json
import os
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

from . import COMPRESSIONE, FORMATO, VERSIONE, Errore, Profilo


@contextmanager
def lock(profilo: Profilo, radice: Path):
    """Un solo lock per tutta la radice, esclusivo, su ogni operazione che scrive.

    Granulare si potra' sempre diventare; introdurre il *primo* lock in un
    codice scritto assumendo l'esclusivita' e' invece doloroso.
    """
    percorso = radice / profilo.servizio / "lock"
    percorso.parent.mkdir(parents=True, exist_ok=True)
    with open(percorso, "w") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # Il messaggio non nomina la facciata: da qui passano sia `freeze`
            # che `npz`, e il nucleo non sa chi sta servendo. Dire "freeze" a chi
            # ha battuto `npm install` manderebbe a cercare un comando che non ha
            # eseguito.
            raise Errore(
                "another operation is already running here.\n"
                "Wait for it to finish, or check that no process is left hanging."
            ) from None
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def adesso() -> str:
    return datetime.now().replace(microsecond=0).isoformat(sep=" ")


# ── configurazione della radice ──────────────────────────────────────────────

def scrivi_config(profilo: Profilo, radice: Path, compressione: str = COMPRESSIONE) -> None:
    dati = {
        "formato": FORMATO,
        "creata_da": VERSIONE,
        "creata": adesso(),
        "compressione": compressione,
    }
    (radice / profilo.servizio / "config").write_text(json.dumps(dati, indent=2) + "\n")


def leggi_config(profilo: Profilo, radice: Path) -> dict:
    percorso = radice / profilo.servizio / "config"
    try:
        dati = json.loads(percorso.read_text())
    except FileNotFoundError:
        raise Errore(f"no configuration here: {percorso} is missing") from None
    except json.JSONDecodeError as e:
        raise Errore(f"unreadable configuration in {percorso}: {e}") from None

    formato = dati.get("formato")
    if formato != FORMATO:
        # Anche qui senza nome di facciata: vedi `lock`.
        raise Errore(
            f"this store uses format {formato}, this version speaks format "
            f"{FORMATO}.\nUpgrade, or use the version that created it "
            f"({dati.get('creata_da', 'unknown')})."
        )
    return dati


# ── metadati di una immagine ─────────────────────────────────────────────────

def scrivi_meta(percorso_meta: Path, dati: dict) -> None:
    percorso_meta.parent.mkdir(parents=True, exist_ok=True)
    completo = {"formato": FORMATO, **dati}
    tmp = percorso_meta.with_suffix(".meta.tmp")
    tmp.write_text(json.dumps(completo, indent=2) + "\n")
    os.replace(tmp, percorso_meta)


def leggi_meta(percorso_meta: Path) -> dict:
    try:
        return json.loads(percorso_meta.read_text())
    except FileNotFoundError:
        raise Errore(f"missing metadata: {percorso_meta}") from None
    except json.JSONDecodeError as e:
        raise Errore(f"unreadable metadata in {percorso_meta}: {e}") from None


def leggibile(byte: int) -> str:
    valore = float(byte)
    for unita in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(valore) < 1024:
            return f"{valore:.1f} {unita}" if unita != "B" else f"{valore:.0f} B"
        valore /= 1024
    return f"{valore:.1f} PiB"
