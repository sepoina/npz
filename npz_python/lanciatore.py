#!/usr/bin/env -S python3 -SE
"""npz — lanciatore.

Il percorso veloce sta qui, prima di qualsiasi import che non sia `os` e `sys`.
Nel caso normale — progetto attivo, albero montato, comando che non tocca
`node_modules` — questo file fa tre `os.stat` e poi **sparisce**, sostituito da
npm con `execv`: TTY, segnali e codice di uscita passano senza una riga di
codice che se ne occupi.

`-S` toglie `site`, `-E` fa ignorare le variabili d'ambiente: insieme valgono
una decina di millisecondi e rendono il comando indipendente dall'ambiente di
chi lo invoca. Poiché `-E` fa ignorare anche `PYTHONPATH`, il lanciatore si
localizza da sé — che è anche cio' che lo rende collegabile da `~/.local/bin`,
dove `__file__` sarebbe il symlink e non il bersaglio.
"""

import os
import sys

QUI = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.dirname(QUI))            # la radice del repo

from npz_python import comandi, veloce              # noqa: E402


def lento(argv: list[str], progetto: str | None, stato: str) -> int:
    """Tutto cio' che non e' il caso normale. Solo qui si paga il pacchetto."""
    from npz_python.cli import governa
    return governa(argv, progetto, stato)


def main() -> int:
    argv = sys.argv[1:]

    # `npz` nudo: il nostro aiuto e a seguire quello di npm. Non si risale ad
    # alcun progetto e non si chiede niente — chi vuole l'aiuto vuole l'aiuto.
    if not argv:
        from npz_python.cli import aiuto
        return aiuto()

    classe = comandi.classifica(argv)

    if classe == comandi.NOSTRO:
        return lento(argv, veloce.trova_progetto(), "")

    npm = veloce.trova_npm(os.path.realpath(__file__))
    if npm is None:
        return veloce.manca_npm()

    progetto = veloce.trova_progetto()
    stato = veloce.stato(progetto)

    # Fuori da un progetto, o in un progetto che non ci riguarda, npz non
    # esiste: si consegna il comando e si sparisce.
    if stato in (veloce.ESTRANEO, veloce.RIFIUTATO, veloce.VERGINE):
        veloce.consegna(npm, argv)

    # Il caso caldo: montato, e il comando non tocca l'albero.
    if stato == veloce.MONTATO and classe == comandi.NEUTRO:
        veloce.consegna(npm, argv)

    return lento(argv, progetto, stato)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        os._exit(0)
