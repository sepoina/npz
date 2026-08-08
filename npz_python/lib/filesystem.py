"""Che cosa il filesystem sotto di noi puo' reggere.

Sono fatti sul supporto, non politiche: valgono identici per `freeze` e per
`npz`, che sopra ci costruiscono decisioni diverse. Chi decide *dove* mettere la
propria cartella di servizio sta nella facciata; qui si risponde solo alla
domanda se quel posto reggerebbe.

`sonda()` misura e non giudica: restituisce fatti, uno per campo. `idoneita()`
e' la prima politica costruita sopra, e per ora l'unica; ma il consiglio su
*come rimediare* — che nomina convenzioni di distribuzione, driver e file di
configurazione — non e' un fatto sul supporto e non abita qui.
"""

import os
import shutil
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Supporto:
    """I fatti misurati su un posto. Nessuno di questi campi e' un giudizio.

    Le due domande sulla `chmod` sono **distinte**, e tenerle separate e' tutto
    il punto di questa struttura:

    - `chmod_riesce` — la chiamata ritorna senza errore. E' quel che npm
      pretende: installa uno shim e gli mette il bit di esecuzione, e un
      `EPERM` gli e' fatale anche quando il bit c'era gia'.
    - `chmod_attecchisce` — il modo scritto si rilegge uguale. E' quel che serve
      a un ripristino fedele, e **non** e' la stessa cosa: ntfs-3g accetta la
      chiamata e non fa niente, quindi riesce senza attecchire.

    Un supporto puo' fallire l'una, l'altra, entrambe o nessuna, e le quattro
    combinazioni vogliono risposte diverse. Collaudarne una sola — come si
    faceva — significa passare indenni sopra il caso che rompe davvero.

    Attenzione a `chmod_riesce`: **misurato qui riesce anche dove non
    dovrebbe.** Sul 4TB di prova ntfs-3g accetta la chiamata di chiunque e non
    fa niente, quindi risponde di si'; il rifiuto compare uno strato piu' su,
    quando fuse-overlayfs applica la regola POSIX che ntfs-3g non applica. Il
    campo che predice quel rifiuto e' `proprietario_estraneo`, non questo.
    """

    percorso: Path
    scrivibile: bool
    errore: str | None          # perche' non si e' potuto scrivere, se e' il caso
    uid_visto: int              # di chi risultano i file, secondo il supporto
    proprietario_estraneo: bool # ...e non siamo noi
    chmod_riesce: bool
    chmod_attecchisce: bool
    esecuzione_ottenibile: bool # il bit x sopravvive: gli shim di .bin/ girano
    modo_riletto: int           # cosa si rilegge dopo `chmod 700`
    tipo: str | None            # ext4, fuseblk, fuse.rclone, vfat...
    sorgente: str | None        # /dev/sdc1, gdrive:, tmpfs...
    opzioni: str | None         # le super options del mount
    uuid: str | None            # solo per i device a blocchi veri

    @property
    def device(self) -> bool:
        """Se la sorgente e' un device a blocchi, non un nome di fantasia.

        `gdrive:` e `tmpfs` sono sorgenti legittime che nessun `fstab` puo'
        indirizzare per UUID: e' la condizione che separa un consiglio sensato
        da uno sbagliato.
        """
        return bool(self.sorgente and self.sorgente.startswith("/dev/")
                    and self.uuid)


def sonda(percorso: Path) -> Supporto:
    """Prova, non chiede: un mkdir, una scrittura, una chmod, una stat.

    Non ci si fida del tipo di filesystem dichiarato. Su NTFS via ntfs-3g, per
    dirne una misurata, `chmod 700` viene riletto come `777` — e la chiamata
    *riesce*, il che e' il motivo per cui il guasto non si vede finche' non ci
    si mette in mezzo qualcosa che i permessi li controlla davvero.

    Una sola `stat`: uid e modo vengono dalla stessa chiamata, che e' anche
    l'unico modo di essere sicuri che si riferiscano allo stesso istante.
    """
    tipo, sorgente, opzioni = mountinfo(percorso)
    uuid = uuid_di(sorgente)

    def guasto(e: OSError) -> Supporto:
        """Non si e' potuto scrivere: gli altri campi non sono misurabili."""
        return Supporto(
            percorso=percorso, scrivibile=False, errore=str(e),
            uid_visto=-1, proprietario_estraneo=False,
            chmod_riesce=False, chmod_attecchisce=False,
            esecuzione_ottenibile=False, modo_riletto=0,
            tipo=tipo, sorgente=sorgente, opzioni=opzioni, uuid=uuid)

    prova = percorso / f".fs-probe-{os.getpid()}"
    try:
        prova.mkdir()
    except OSError as e:
        return guasto(e)
    try:
        file = prova / "p"
        try:
            file.write_text("x")
        except OSError as e:
            return guasto(e)

        riesce = True
        try:
            file.chmod(0o700)
        except OSError:
            # Non e' un guasto della sonda: e' un fatto sul supporto, e va
            # riportato come tale invece di interrompere la misura.
            riesce = False

        st = file.stat()
        modo = st.st_mode & 0o777
        return Supporto(
            percorso=percorso, scrivibile=True, errore=None,
            uid_visto=st.st_uid,
            proprietario_estraneo=(st.st_uid != os.geteuid()),
            chmod_riesce=riesce,
            chmod_attecchisce=(modo == 0o700),
            # I bit del modo, non `os.access(X_OK)`: su fuse.rclone `access`
            # risponde di si' e l'esecuzione poi fallisce davvero. Misurato.
            esecuzione_ottenibile=bool(modo & 0o100),
            modo_riletto=modo,
            tipo=tipo, sorgente=sorgente, opzioni=opzioni, uuid=uuid)
    finally:
        shutil.rmtree(prova, ignore_errors=True)


def idoneita(percorso: Path) -> str | None:
    """Restituisce il motivo per cui il filesystem non va bene, o None.

    **Non e' piu' la politica di `freeze`**, e la differenza e' voluta. `freeze`
    conserva alberi arbitrari e deve poterli ripristinare fedeli, quindi esige
    che i permessi POSIX sopravvivano. npz congela `node_modules`, che vive
    accanto al progetto e quindi **sullo stesso filesystem del delta**: qualunque
    cosa il supporto faccia ai modi, l'ha gia' fatta all'albero prima che npz lo
    vedesse. L'immagine registra cio' che c'e', il copy-up rende cio' che il
    supporto rende, e i due coincidono per costruzione. Su NTFS l'albero e'
    uniformemente 777 e non c'e' niente da perdere — misurato: giro completo,
    consolidamento incluso, un solo regime di modi prima e dopo.

    Quel requisito **torna** il giorno in cui delta e immagine dovessero vivere
    su filesystem diversi (fase 2, o la separazione di `dynamic/`): allora
    l'immagine potrebbe contenere modi che l'upper non sa reggere, e la
    decadenza sarebbe reale. Finche' stanno insieme, no.

    Restano tre condizioni, tutte misurate su questa macchina:

    1. **si deve poter scrivere.** Ovvio, ed e' il caso piu' comune.
    2. **i file devono essere nostri.** E' la condizione dura, e non si vede da
       qui: ntfs-3g accetta la `chmod` di chiunque senza farci niente, quindi
       `chmod_riesce` risponde di si'. Il rifiuto nasce uno strato piu' su —
       fuse-overlayfs applica la regola POSIX vera — e `npm install` muore con
       `EPERM` sullo shim che sta installando. Il campo che lo predice e'
       `proprietario_estraneo`.
    3. **il bit di esecuzione si deve poter mettere.** Gli shim di `.bin/` sono
       eseguibili, e un supporto che appiattisce i modi a `644` — `fuse.rclone`,
       misurato — li rende non avviabili. Su NTFS l'appiattimento e' a `777`, che
       il bit ce l'ha, e infatti li' girano.

    Il rifiuto per tipo di filesystem **e' stato tolto**: rifiutava anche
    `fuse-overlayfs` con l'upper su ext4, cioe' lo stack di npz stesso, che ogni
    requisito reale lo soddisfa. Quel divieto riguarda l'overlayfs **del
    kernel**, non npz, e vive ora in `regge_upperdir_kernel()`, dove lo consulta
    chi sceglie il backend.
    """
    s = sonda(percorso)
    if not s.scrivibile:
        return f"can't write to it: {s.errore}"
    if s.proprietario_estraneo:
        # Il fatto e basta. Il *perche'* rompe, e come rimediare, li racconta la
        # facciata: ripeterlo qui lo farebbe stampare due volte di fila.
        return (f"the files here belong to uid {s.uid_visto}, "
                f"not to you (uid {os.geteuid()})")
    if not s.esecuzione_ottenibile:
        return (f"the execute bit doesn't survive here "
                f"(chmod 700 reads back as {s.modo_riletto:o}), "
                f"so the shims in .bin/ wouldn't run")
    return None


def regge_upperdir_kernel(tipo: str | None) -> bool:
    """Se l'overlayfs **del kernel** accetterebbe un `upperdir` di questo tipo.

    E' un fatto sul kernel, non una politica di npz, ed e' vero soltanto per la
    via privilegiata: `fuse-overlayfs` invece un upper su FUSE lo regge — usa
    `user.fuseoverlayfs.*` e whiteout `.wh.` invece degli xattr `trusted.*` che
    il kernel pretende e che un filesystem in user space non puo' garantire.

    Serve a chi sceglie il backend, non a chi giudica il supporto: su un disco
    dove npz funziona benissimo via FUSE, la via kernel semplicemente non e'
    disponibile.
    """
    if not tipo:
        return True
    return not (tipo.startswith("fuse")
                or tipo in ("ntfs", "ntfs3", "vfat", "exfat"))


def mountinfo(percorso: Path) -> tuple[str | None, str | None, str | None]:
    """Tipo, sorgente e opzioni del mount che contiene il percorso.

    Tutti e tre dalla stessa riga di `/proc/self/mountinfo`, che si leggeva gia'
    per il solo tipo: gli altri due campi erano li' accanto e costavano zero.
    Si tiene il mount **piu' profondo** che contiene il percorso, perche' e'
    quello che lo serve davvero.
    """
    try:
        obiettivo = percorso.resolve()
        migliore, esito = -1, (None, None, None)
        with open("/proc/self/mountinfo", encoding="utf-8") as fh:
            for riga in fh:
                campi = riga.split()
                if "-" not in campi:
                    continue
                sep = campi.index("-")
                punto = Path(campi[4])
                if obiettivo == punto or punto in obiettivo.parents:
                    if len(punto.parts) > migliore:
                        migliore = len(punto.parts)
                        esito = (_campo(campi, sep + 1),
                                 _campo(campi, sep + 2),
                                 _campo(campi, sep + 3))
        return esito
    except OSError:
        return (None, None, None)


def punto_di_mount(percorso: Path) -> str | None:
    """Dove e' montato il filesystem che contiene il percorso."""
    try:
        obiettivo = percorso.resolve()
        migliore, punto = -1, None
        with open("/proc/self/mountinfo", encoding="utf-8") as fh:
            for riga in fh:
                campi = riga.split()
                if "-" not in campi:
                    continue
                candidato = Path(campi[4])
                if obiettivo == candidato or candidato in obiettivo.parents:
                    if len(candidato.parts) > migliore:
                        migliore, punto = len(candidato.parts), campi[4]
        return punto
    except OSError:
        return None


def tipo_filesystem(percorso: Path) -> str | None:
    """Il tipo di filesystem che contiene il percorso, letto da mountinfo."""
    return mountinfo(percorso)[0]


def uuid_di(sorgente: str | None) -> str | None:
    """Il UUID di un device, dal solo `/dev/disk/by-uuid`.

    Niente `blkid` e niente `lsblk`: sono sottoprocessi, il primo vuole
    privilegi, e i symlink che udev mantiene dicono la stessa cosa a chiunque
    sappia leggere una directory.
    """
    if not sorgente or not sorgente.startswith("/dev/"):
        return None
    try:
        atteso = os.path.realpath(sorgente)
        base = "/dev/disk/by-uuid"
        for nome in os.listdir(base):
            if os.path.realpath(os.path.join(base, nome)) == atteso:
                return nome
    except OSError:
        pass
    return None


def driver_di_mount(sorgente: str | None, punto: str | None) -> str | None:
    """Il programma che serve un mount FUSE, letto da `/proc/*/cmdline`.

    `mountinfo` dice `fuseblk` e si ferma li': il tipo non nomina il driver, e
    indovinarlo sarebbe il modo piu' rapido di dare un consiglio sbagliato. Il
    demone invece e' un processo, la sua riga di comando contiene device e
    mountpoint, e `/proc/<pid>/cmdline` si legge anche quando il processo e' di
    root — verificato su questa macchina.

    Si scandisce `/proc` una volta sola e solo quando si sta gia' per rifiutare:
    nel caso normale questa funzione non viene chiamata mai.
    """
    if not sorgente or not punto:
        return None
    try:
        voci = os.listdir("/proc")
    except OSError:
        return None
    for voce in voci:
        if not voce.isdigit():
            continue
        try:
            with open(f"/proc/{voce}/cmdline", "rb") as fh:
                argv = fh.read().split(b"\0")
        except OSError:
            continue
        args = [a.decode("utf-8", "replace") for a in argv if a]
        if len(args) >= 3 and sorgente in args and punto in args:
            return os.path.basename(args[0])
    return None


def _campo(campi: list[str], i: int) -> str | None:
    return campi[i] if i < len(campi) else None
