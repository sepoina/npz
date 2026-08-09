#!/bin/sh
#
# install.sh — installa npz su qualunque distribuzione Linux.
#
# Sceglie da sé il formato: il pacchetto nativo dove c'è un gestore che lo sa
# installare, il tarball altrove. La ragione per preferire il pacchetto nativo
# non è l'eleganza — è che `pacman -R npz` esiste e `rm /usr/local/bin/npz` va
# ricordato a mano. Un installatore che non lascia una via di disinstallazione è
# lo stesso difetto che `npz detach` esiste per non avere.
#
# ── perché è /bin/sh e non bash ──────────────────────────────────────────────
#
# Perché è la sola cosa che si può dare per scontata su una distribuzione che
# non si conosce: Alpine ha `ash`, un container Debian minimale non ha bash.
# Tutto il resto del repo è bash e resta bash; questo file no, ed è l'unico.
#
# Uso:
#   curl -fsSL https://github.com/sepoina/npz/releases/latest/download/install.sh | sh
#   sh install.sh                    dopo averlo letto, che è l'abitudine migliore
#
#   NPZ_VERSIONE=0.2.5 sh install.sh una versione precisa invece dell'ultima
#   NPZ_METODO=tarball sh install.sh il binario in /usr/local/bin, e basta
#
set -eu

# L'indirizzo del progetto. È una copia di `URL` in `progetto.conf`, e non si
# può evitare: questo script viene scaricato da solo, senza il repo intorno.
# `build/bin/coerenza.sh` la controlla a ogni rilascio, che è il patto di
# sempre — la copia non si vieta, si rende incapace di divergere in silenzio.
PROGETTO="https://github.com/sepoina/npz" # coerenza: URL

# Il `pkgrel`, che compare in coda ai nomi dei pacchetti. Copia anche questo, e
# controllata dallo stesso guardiano.
RILASCIO=1 # coerenza: RILASCIO

# I quattro programmi che npz pretende a run time. Non li installa questo
# script: appartengono alla distribuzione, e i pacchetti nativi li dichiarano
# già. Servono qui per dire in tempo che cosa manca.
NECESSARI="mkfs.erofs erofsfuse fuse-overlayfs fusermount3"

rosso() { printf '\033[31m%s\033[0m' "$1"; }
verde() { printf '\033[32m%s\033[0m' "$1"; }
info()  { printf '  %s\n' "$*"; }
muori() { printf '\n  [%s] %s\n\n' "$(rosso errore)" "$*" >&2; exit 1; }

c_e() { command -v "$1" >/dev/null 2>&1; }

# ── dove siamo ───────────────────────────────────────────────────────────────

[ "$(uname -s)" = Linux ] || muori "npz gira solo su Linux: EROFS e overlayfs sono filesystem del kernel Linux."

for t in curl tar sha256sum; do
    c_e "$t" || muori "manca \`$t\`, che serve a questo script."
done

# Due nomi per la stessa architettura, perché i formati non si sono messi
# d'accordo: il .deb e il tarball dicono amd64, il .rpm e l'Arch dicono x86_64.
case "$(uname -m)" in
    x86_64|amd64)  ARCO_DEB=amd64; ARCO_RPM=x86_64 ;;
    aarch64|arm64) ARCO_DEB=arm64; ARCO_RPM=aarch64 ;;
    *) muori "architettura $(uname -m) non rilasciata: restano i sorgenti, $PROGETTO" ;;
esac

# ── quale versione ───────────────────────────────────────────────────────────
#
# `releases/latest` è una redirezione verso il tag vero, e leggerla costa una
# richiesta senza autenticazione. L'API di GitHub avrebbe detto la stessa cosa
# in JSON, ma ha un tetto di 60 richieste all'ora per indirizzo IP: dietro il
# NAT di un ufficio, quel tetto lo si trova già superato da qualcun altro.
versione_ultima() {
    curl -fsSL -o /dev/null -w '%{url_effective}' "$PROGETTO/releases/latest" \
        | sed 's#.*/tag/v##'
}

VERSIONE="${NPZ_VERSIONE:-$(versione_ultima)}"
[ -n "$VERSIONE" ] || muori "non riesco a capire qual è l'ultima versione. Riprova, o indica NPZ_VERSIONE=…"
SCARICO="$PROGETTO/releases/download/v$VERSIONE"

printf '\033[1mnpz %s · %s\033[0m\n' "$VERSIONE" "$ARCO_DEB"

# ── con che cosa si installa ─────────────────────────────────────────────────
#
# L'ordine non è alfabetico: si cerca prima il gestore che *possiede* il
# sistema. Su una Manjaro con `apt` installato per sbaglio, pacman resta la
# risposta giusta.
if [ -n "${NPZ_METODO:-}" ]; then
    METODO="$NPZ_METODO"
elif c_e pacman; then METODO=arch
elif c_e apt-get; then METODO=deb
elif c_e dnf || c_e zypper; then METODO=rpm
else METODO=tarball
fi

case "$METODO" in
    arch)    FILE="npz-$VERSIONE-$RILASCIO-$ARCO_RPM.pkg.tar.zst" ;;
    deb)     FILE="npz_$VERSIONE-${RILASCIO}_$ARCO_DEB.deb" ;;
    rpm)     FILE="npz-$VERSIONE-$RILASCIO.$ARCO_RPM.rpm" ;;
    tarball) FILE="npz-$VERSIONE-linux-$ARCO_DEB.tar.gz" ;;
    *)       muori "NPZ_METODO=$METODO non esiste: usa arch, deb, rpm o tarball." ;;
esac

# ── si scarica, si verifica, si installa ─────────────────────────────────────

LAVORO=$(mktemp -d)
# Anche sui percorsi di errore, e anche su Ctrl-C: uno script che lascia
# spazzatura in /tmp la lascia per sempre, perché nessuno la va a cercare.
trap 'rm -rf "$LAVORO"' EXIT INT TERM

info "scarico $FILE"
curl -fsSL --proto '=https' --tlsv1.2 -o "$LAVORO/$FILE" "$SCARICO/$FILE" \
    || muori "non trovo $FILE fra gli allegati di v$VERSIONE."

# La verifica non è un di più: `curl | sh` ha già chiesto fiducia una volta, e
# questo è il punto in cui la si può smettere di chiedere. `--ignore-missing`
# perché il SHA256SUMS copre l'intero rilascio e qui c'è un file solo.
info "verifico la somma"
curl -fsSL --proto '=https' --tlsv1.2 -o "$LAVORO/SHA256SUMS" "$SCARICO/SHA256SUMS" \
    || muori "manca il SHA256SUMS del rilascio: mi fermo invece di installare qualcosa che non ho verificato."
( cd "$LAVORO" && sha256sum -c --ignore-missing --quiet SHA256SUMS ) \
    || muori "la somma non torna. Il file scaricato non è quello pubblicato: non lo installo."

# Il sudo si nomina prima di usarlo, così chi legge sa che cosa sta per
# succedere; se manca, si dice invece di fallire dentro un comando altrui.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    c_e sudo || muori "servono i privilegi di root e \`sudo\` non c'è. Rilancialo da root, o usa NPZ_METODO=tarball."
    SUDO=sudo
fi

case "$METODO" in
    arch) info "pacman -U"; $SUDO pacman -U --noconfirm "$LAVORO/$FILE" ;;
    # `apt install ./file` e non `dpkg -i`: apt risolve le dipendenze, dpkg si
    # limita a lamentarsene lasciando il pacchetto mezzo installato.
    deb)  info "apt install"; $SUDO apt-get install -y "$LAVORO/$FILE" ;;
    rpm)  if c_e dnf; then info "dnf install"; $SUDO dnf install -y "$LAVORO/$FILE"
          else info "zypper install"; $SUDO zypper --non-interactive install --allow-unsigned-rpm "$LAVORO/$FILE"; fi ;;
    tarball)
        tar xzf "$LAVORO/$FILE" -C "$LAVORO" npz
        DOVE=/usr/local/bin
        info "install in $DOVE"
        $SUDO install -m 0755 "$LAVORO/npz" "$DOVE/npz"
        info "per toglierlo: $SUDO rm $DOVE/npz" ;;
esac

# ── che cosa manca ancora ────────────────────────────────────────────────────

printf '\n  [%s] npz %s installato.\n' "$(verde ok)" "$VERSIONE"

MANCANTI=""
for t in $NECESSARI; do
    c_e "$t" || MANCANTI="$MANCANTI $t"
done

if [ -n "$MANCANTI" ]; then
    printf '\n  [%s] manca ancora:%s\n' "$(rosso attenzione)" "$MANCANTI"
    info "npz li usa per costruire e montare l'immagine, e senza non parte."
    if c_e pacman; then      info "sudo pacman -S erofs-utils erofsfuse fuse-overlayfs fuse3"
    elif c_e apt-get; then   info "sudo apt install erofs-utils fuse-overlayfs fuse3"
    elif c_e dnf; then       info "sudo dnf install erofs-utils fuse-overlayfs fuse3"
    elif c_e zypper; then    info "sudo zypper install erofs-utils fuse-overlayfs fuse3"
    fi
    # `erofsfuse` è pacchetto a sé solo su Arch, dove la riga qui sopra lo
    # nomina già. Altrove non è stato verificato contro i repo, e promettere un
    # nome che non esiste sarebbe peggio che tacerlo.
    info "su alcune distribuzioni erofsfuse ha un pacchetto proprio, o non c'è affatto."
fi

printf '\n  Per cominciare, dentro un progetto:  npz install\n'
printf '  La via d'\''uscita, in qualunque momento:  npz detach\n\n'
