# La sonda di `filesystem.sonda()` — esiti

- data: 2026-08-08 19:16:41
- kernel: `6.12.101-1-MANJARO`
- utente: uid 1000, gid 1001
- banco: `/var/tmp/npz-sonda`

## Il montato

Quel che c'e' su questa macchina, compresi i supporti su cui npz non
girera' mai: servono a vedere che la diagnosi taccia quando non ha
niente di sensato da dire.

| supporto | tipo | sorgente | scriv. | proprietario | chmod riesce | chmod attecchisce | **x ottenibile** | riletto | uuid | `idoneita()` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `/` | `ext4` | `/dev/nvme0n1p2` | **no** | — | — | — | — | — | `d6e9c984-d7e2-4d31-a3a3-417cf5c90414` | can't write to it: [Errno 13] Permission denied: '/.fs-probe-34728' |
| `/boot/efi` | `vfat` | `/dev/nvme0n1p1` | **no** | — | — | — | — | — | `2C40-022E` | can't write to it: [Errno 13] Permission denied: '/boot/efi/.fs-probe-34728' |
| `/dev/shm` | `tmpfs` | `tmpfs` | si | mio | si | si | si | `700` | — | — |
| `/home/aldo/GoogleDrive` | `fuse.rclone` | `gdrive:` | si | mio | si | **no** | **no** | `644` | — | the execute bit doesn't survive here |
| `/mnt/400GB_FastData` | `fuseblk` | `/dev/nvme1n1p4` | si | **estraneo** | si | **no** | si | `777` | `2258E09C58E07049` | the files here belong to uid 0 |
| `/run` | `tmpfs` | `run` | **no** | — | — | — | — | — | — | can't write to it: [Errno 13] Permission denied: '/run/.fs-probe-34728' |
| `/run/credentials/systemd-journald.service` | `tmpfs` | `none` | **no** | — | — | — | — | — | — | can't write to it: [Errno 13] Permission denied: '/run/credentials/systemd-journald.service/.fs-probe-34728' |
| `/run/media/aldo/4TB_Dati` | `fuseblk` | `/dev/sdc1` | si | **estraneo** | si | **no** | si | `777` | `02D44E8D412156BD` | the files here belong to uid 0 |
| `/run/user/1000` | `tmpfs` | `tmpfs` | si | mio | si | si | si | `700` | — | — |
| `/run/user/1000/doc` | `fuse.portal` | `portal` | **no** | — | — | — | — | — | — | can't write to it: [Errno 1] Operation not permitted: '/run/user/1000/doc/.fs-probe-34728' |
| `/tmp` | `tmpfs` | `tmpfs` | si | mio | si | si | si | `700` | — | — |

## Il fabbricato

Filesystem veri costruiti dentro file e montati senza privilegi.

| supporto | tipo | sorgente | scriv. | proprietario | chmod riesce | chmod attecchisce | **x ottenibile** | riletto | uuid | `idoneita()` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| NTFS, mio (silent) | `fuse` | `/var/tmp/npz-sonda/ntfs-mio.ntfs` | si | mio | si | **no** | si | `777` | — | — |
| NTFS, mio (permissions) | `fuse` | `/var/tmp/npz-sonda/ntfs-perm.ntfs` | si | mio | si | **no** | si | `777` | — | — |
| NTFS, mio (sola lettura) | `fuse` | `/var/tmp/npz-sonda/ntfs-ro.ntfs` | **no** | — | — | — | — | — | — | can't write to it: [Errno 30] Read-only file system: '/var/tmp/npz-sonda/ntfs-ro/.fs-probe-34728' |
| NTFS, di root | `fuse` | `/var/tmp/npz-sonda/ntfs-root.ntfs` | si | **estraneo** | **no** | **no** | si | `777` | — | the files here belong to uid 0 |
| EROFS (erofsfuse, sola lettura) | `fuse.erofsfuse` | `erofsfuse` | **no** | — | — | — | — | — | — | can't write to it: [Errno 38] Function not implemented: '/var/tmp/npz-sonda/erofs/.fs-probe-34728' |
| fuse-overlayfs, upper su ext4 | `fuse.fuse-overlayfs` | `fuse-overlayfs` | si | mio | si | si | si | `700` | — | — |
| fuse-overlayfs, upper su NTFS | `fuse.fuse-overlayfs` | `fuse-overlayfs` | si | mio | si | **no** | si | `777` | — | — |
<!-- Da qui in giu' si scrive a mano. Rigenerando le tabelle (`python3
     banco-sonda.py > report-sonda.md`) questa sezione si perde: va rimessa,
     o spostata in una voce del taccuino quando le decisioni si consolidano. -->

## Letture

**1. Il predittore giusto e' il proprietario, non l'esito della `chmod`.**
Sul 4TB vero la sonda misura `chmod riesce = si`: ntfs-3g accetta la chiamata e
non fa niente. L'`EPERM` che ammazza `npm install` compare **uno strato piu' su**,
quando fuse-overlayfs applica la regola POSIX che ntfs-3g non applica. Una
diagnosi appoggiata a `chmod_riesce` misurato sul substrato nudo **mancherebbe
proprio il caso che rompe**. Discrimina `proprietario_estraneo`, vero sui due
NTFS di questa macchina e falso ovunque altro.

**2. Il requisito vero non e' «i modi si conservano», e' «il bit x si ottiene».**
`chmod_attecchisce` e' falso su NTFS *e* su rclone, ma i due casi non si
somigliano: NTFS appiattisce a `777`, che il bit di esecuzione ce l'ha, e gli
shim di `.bin/` girano; rclone appiattisce a `644` e **lo shim non parte** —
provato eseguendone uno davvero, `interprete errato: Permesso negato`. Il campo
che separa i due e' `esecuzione_ottenibile`.

E si guardano i **bit del modo**, non `os.access(X_OK)`: su rclone `access`
risponde di si' e l'esecuzione poi fallisce. Misurato.

**3. La conservazione dei modi non serve a npz finche' albero e delta stanno
insieme.** `node_modules` vive accanto al progetto, quindi sullo stesso supporto
del delta: qualunque cosa il supporto faccia ai modi l'ha gia' fatta all'albero
prima che npz lo vedesse, l'immagine registra cio' che c'e', il copy-up rende
cio' che il supporto rende, e i due coincidono per costruzione. Il requisito
torna il giorno in cui `dynamic/` finisse altrove.

**4. Il falso negativo di `idoneita()` e' chiuso.**
`fuse-overlayfs, upper su ext4` — lo stack di npz — era rifiutato dalla sola
lista nera per fstype pur soddisfacendo ogni requisito reale. Ora passa. Il
divieto riguardava l'overlayfs **del kernel** e vive in
`regge_upperdir_kernel()`, che `mount.scegli()` consulta per non proporre da
root un backend che fallirebbe.

**5. Il consiglio si compone solo dove e' vero, e la fonte e' misurata.**
`mountinfo` dice `fuseblk` e non nomina il driver: indovinarlo sarebbe il modo
piu' rapido di dare l'istruzione sbagliata. Il nome vero si legge da
`/proc/<pid>/cmdline` del demone — leggibile anche per processi di root,
verificato — ed e' `mount.ntfs`. In `fstab` ci va pero' il **tipo** (`ntfs`),
non l'aiutante, o `mount` cercherebbe `mount.mount.ntfs`.

Dove device, UUID o driver mancano — rclone (`gdrive:`), tmpfs, gli NTFS
fabbricati dentro un file — non si propone niente. Verificato: su rclone il
messaggio resta quello generico.

**6. `-o permissions` non porta i permessi POSIX su NTFS.**
Misurato due volte: `chmod 700` si rilegge `777` con e senza. Non va consigliato.

**7. L'NTFS «di root» fabbricato non replica il disco vero.**
Fabbricato: `chmod riesce = no`. Reale: `si`. La differenza e' chi esegue il
demone — root via udisks nel primo caso, l'utente nel secondo — non il
filesystem. Le conclusioni sul disco vero si prendono dal disco vero. Per la
politica non cambia niente: entrambi vengono rifiutati per la proprieta', che e'
il campo giusto.

**8. Gli errno dei supporti non scrivibili sono distinti e informativi.**
`ENOSYS` (erofsfuse), `EROFS` (ntfs in sola lettura), `EACCES` (`/`,
`/boot/efi`), `EPERM` (portal). Oggi finiscono tutti in `can't write to it`, che
per rifiutare basta; il dato per distinguere «rimontalo rw» da «non e' roba tua»
e' gia' misurato.
