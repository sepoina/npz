#!/usr/bin/env python3
"""Il banco di `filesystem.sonda()`: misurarla su quanti piu' supporti possibile.

Non e' codice di prodotto ed e' da buttare via: il suo scopo e' produrre una
tabella di fatti **prima** che si scriva la politica che ci sta sopra. La
politica in questione consiglia all'utente come rimontare un disco, e un
consiglio sbagliato e' peggio di nessun consiglio: da qui l'insistenza sul
provarla dove non serve, non solo dove serve.

Due popolazioni:

- **il montato** — quel che c'e' su questa macchina, compresi i supporti su cui
  npz non girera' mai. Servono a vedere che la diagnosi *taccia* quando non ha
  niente di sensato da dire.
- **il fabbricato** — filesystem veri costruiti dentro file e montati senza
  privilegi, per esplorare le combinazioni che il montato non offre.

Uso:  python3 banco-sonda.py [--senza-rete] > report-sonda.md
"""

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

QUI = Path(__file__).resolve().parent
sys.path.insert(0, str(QUI.parent.parent))

from npz_python.lib.filesystem import (  # noqa: E402
    Supporto, idoneita, punto_di_mount, sonda,
)

# Sorgenti che non sono supporti veri: pseudo-filesystem del kernel, su cui
# provare a scrivere non dice niente su niente.
PSEUDO = {
    "proc", "sysfs", "devtmpfs", "devpts", "cgroup", "cgroup2", "securityfs",
    "pstore", "bpf", "configfs", "debugfs", "tracefs", "fusectl", "autofs",
    "binfmt_misc", "mqueue", "hugetlbfs", "efivarfs", "nsfs", "ramfs",
}

montati_extra: list[tuple[str, str]] = []   # (etichetta, percorso) da smontare


def montati() -> list[tuple[str, str]]:
    """(percorso, tipo) di ogni mount degno di essere provato."""
    visti, esito = set(), []
    with open("/proc/self/mountinfo", encoding="utf-8") as fh:
        for riga in fh:
            campi = riga.split()
            if "-" not in campi:
                continue
            sep = campi.index("-")
            punto, tipo = campi[4], campi[sep + 1]
            if tipo in PSEUDO or punto in visti:
                continue
            visti.add(punto)
            esito.append((punto, tipo))
    return sorted(esito)


def esegui(*argv: str) -> tuple[int, str]:
    p = subprocess.run(argv, capture_output=True, text=True)
    return p.returncode, (p.stderr or p.stdout).strip()


def fabbrica_ntfs(base: Path, nome: str, opzioni: str) -> Path | None:
    """Un NTFS vero dentro un file, montato da noi. Nessun privilegio."""
    img, punto = base / f"{nome}.ntfs", base / nome
    punto.mkdir(parents=True, exist_ok=True)
    if not img.exists():
        subprocess.run(["fallocate", "-l", "160M", str(img)], capture_output=True)
        if esegui("mkntfs", "-Q", "-F", str(img))[0] != 0:
            return None
    if esegui("ntfs-3g", "-o", opzioni, str(img), str(punto))[0] != 0:
        return None
    montati_extra.append((nome, str(punto)))
    time.sleep(0.3)
    return punto


def fabbrica_erofs(base: Path, nome: str) -> Path | None:
    """Una immagine EROFS montata in sola lettura: il `lower` di npz."""
    seme, img, punto = base / f"{nome}-seme", base / f"{nome}.erofs", base / nome
    (seme / "pkg").mkdir(parents=True, exist_ok=True)
    (seme / "pkg" / "f.js").write_text("x")
    (seme / "pkg" / "f.js").chmod(0o644)
    punto.mkdir(parents=True, exist_ok=True)
    if esegui("mkfs.erofs", "-zlz4hc", str(img), str(seme))[0] != 0:
        return None
    if esegui("erofsfuse", str(img), str(punto))[0] != 0:
        return None
    montati_extra.append((nome, str(punto)))
    time.sleep(0.3)
    return punto


def fabbrica_overlay(base: Path, nome: str, lower: Path, upper_su: Path) -> Path | None:
    """Lo stack di npz: `fuse-overlayfs` con l'upper dove ci dicono."""
    up, wk = upper_su / f"{nome}-up", upper_su / f"{nome}-wk"
    punto = base / nome
    for d in (up, wk, punto):
        d.mkdir(parents=True, exist_ok=True)
    codice, _ = esegui("fuse-overlayfs", "-o",
                       f"lowerdir={lower},upperdir={up},workdir={wk}", str(punto))
    if codice != 0:
        return None
    montati_extra.append((nome, str(punto)))
    time.sleep(0.3)
    return punto


def riga(etichetta: str, s: Supporto, motivo: str | None) -> str:
    def si(v: bool) -> str:
        return "si" if v else "**no**"
    prop = "**estraneo**" if s.proprietario_estraneo else "mio"
    if not s.scrivibile:
        prop, ch, at, ex, modo = "—", "—", "—", "—", "—"
    else:
        ch, at = si(s.chmod_riesce), si(s.chmod_attecchisce)
        ex, modo = si(s.esecuzione_ottenibile), f"`{s.modo_riletto:o}`"
    breve = "—" if motivo is None else motivo.split(",")[0].split("(")[0].strip()
    return (f"| {etichetta} | `{s.tipo}` | `{s.sorgente}` | "
            f"{si(s.scrivibile)} | {prop} | {ch} | {at} | {ex} | {modo} | "
            f"{'`' + s.uuid + '`' if s.uuid else '—'} | {breve} |")


INTESTAZIONE = (
    "| supporto | tipo | sorgente | scriv. | proprietario | chmod riesce | "
    "chmod attecchisce | **x ottenibile** | riletto | uuid | `idoneita()` |\n"
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
)


def main() -> int:
    senza_rete = "--senza-rete" in sys.argv
    base = Path(os.environ.get("BANCO", "/var/tmp/npz-sonda"))
    shutil.rmtree(base, ignore_errors=True)
    base.mkdir(parents=True, exist_ok=True)

    print("# La sonda di `filesystem.sonda()` — esiti\n")
    print(f"- data: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"- kernel: `{os.uname().release}`")
    print(f"- utente: uid {os.geteuid()}, gid {os.getegid()}")
    print(f"- banco: `{base}`\n")

    print("## Il montato\n")
    print("Quel che c'e' su questa macchina, compresi i supporti su cui npz non")
    print("girera' mai: servono a vedere che la diagnosi taccia quando non ha")
    print("niente di sensato da dire.\n")
    print(INTESTAZIONE)
    for punto, _tipo in montati():
        p = Path(punto)
        if senza_rete and "GoogleDrive" in punto:
            print(f"| `{punto}` | — | — | *saltato* | | | | | | | rete, `--senza-rete` |")
            continue
        try:
            s, motivo = sonda(p), idoneita(p)
        except Exception as e:                                   # noqa: BLE001
            print(f"| `{punto}` | | | | | | | | | | **eccezione**: `{e!r}` |")
            continue
        print(riga(f"`{punto}`", s, motivo))

    print("\n## Il fabbricato\n")
    print("Filesystem veri costruiti dentro file e montati senza privilegi.\n")
    print(INTESTAZIONE)

    io = f"uid={os.geteuid()},gid={os.getegid()}"
    fabbricati: list[tuple[str, Path | None]] = [
        ("NTFS, mio (silent)",
         fabbrica_ntfs(base, "ntfs-mio", f"no_def_opts,silent,{io}")),
        ("NTFS, mio (permissions)",
         fabbrica_ntfs(base, "ntfs-perm", f"no_def_opts,silent,permissions,{io}")),
        ("NTFS, mio (sola lettura)",
         fabbrica_ntfs(base, "ntfs-ro", f"no_def_opts,silent,ro,{io}")),
        ("NTFS, di root",
         fabbrica_ntfs(base, "ntfs-root", "no_def_opts,silent,uid=0,gid=0")),
        ("EROFS (erofsfuse, sola lettura)",
         fabbrica_erofs(base, "erofs")),
    ]
    lower = dict(fabbricati).get("EROFS (erofsfuse, sola lettura)")
    if lower:
        fabbricati.append(("fuse-overlayfs, upper su ext4",
                           fabbrica_overlay(base, "ov-ext4", lower, base)))
        ntfs = dict(fabbricati).get("NTFS, mio (silent)")
        if ntfs:
            fabbricati.append(("fuse-overlayfs, upper su NTFS",
                               fabbrica_overlay(base, "ov-ntfs", lower, ntfs)))

    for etichetta, punto in fabbricati:
        if punto is None:
            print(f"| {etichetta} | | | | | | | | | | **non fabbricabile** |")
            continue
        try:
            s, motivo = sonda(punto), idoneita(punto)
            print(riga(etichetta, s, motivo))
        except Exception as e:                                   # noqa: BLE001
            print(f"| {etichetta} | | | | | | | | | | **eccezione**: `{e!r}` |")

    for _nome, punto in reversed(montati_extra):
        subprocess.run(["fusermount3", "-u", punto], capture_output=True)
    time.sleep(0.5)
    shutil.rmtree(base, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
