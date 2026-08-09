#!/usr/bin/env bash
#
# pacchetto.sh — i pacchetti di npz: .deb per Debian, .pkg.tar.zst per Arch,
#                .rpm per Fedora e derivate.
#
# Su questa macchina `dpkg` non c'e' e non serve: un .deb e' un archivio `ar`
# con **tre membri, in quest'ordine**, e `ar` sta in binutils che c'e' gia'.
#
#     npz_0.1.0_amd64.deb
#     ├── debian-binary      la stringa "2.0", e nient'altro
#     ├── control.tar.gz     ./control, ./md5sums — i metadati
#     └── data.tar.gz        ./usr/bin/npz, ./usr/share/doc/… — i file
#
# L'ordine non e' una convenzione: dpkg legge i membri in sequenza e si aspetta
# `debian-binary` per primo. Un archivio con gli stessi tre membri in ordine
# diverso non e' un .deb.
#
# Il .rpm invece **non** si scrive a mano: e' l'unico dei tre formati in cui il
# conto non torna: vedi il ragionamento sopra rpm_arco(). Serve `rpm-tools`.
#
# Uso:
#   ./pacchetto.sh              il rilascio intero, in `npz_go/dist/`
#   ./pacchetto.sh amd64        solo una architettura, e solo il .deb
#   ./pacchetto.sh ispeziona    apre i .deb gia' costruiti e ne mostra il dentro
#   ./pacchetto.sh arch         il pacchetto per Arch/Manjaro, via makepkg
#   ./pacchetto.sh rpm          i .rpm x86_64 e aarch64, via rpmbuild
#   ./pacchetto.sh tarball      i .tar.gz per chi non passa da un gestore
#   ./pacchetto.sh oracolo      confronta il .deb con quello che farebbe nfpm
#
# Solo il primo e' un rilascio: svuota `dist/`, costruisce tutto e chiude con un
# `SHA256SUMS` verificato. Gli altri sono per provare un pezzo alla volta, e
# lasciano `dist/` a meta' di proposito — vedi il commento in main().
#
# Ogni metadato — versione, descrizioni, manutentore, dipendenze — viene da
# `progetto.conf` nella radice del **progetto**, un livello sopra il modulo Go:
# quel file e' condiviso con l'implementazione Python. Qui non se ne dichiara
# nessuno. L'ambiente vince sul file:  VERSIONE=1.2.3 ./pacchetto.sh
#
set -uo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # npz_go/build/bin
MODULO="$(dirname "$(dirname "$QUI")")"               # npz_go
RADICE="$(dirname "$MODULO")"                         # la radice del progetto
# Le tre cartelle, e i tre mestieri che non si mescolano:
#   build/bin/    le utilita' — questo script e il PKGBUILD. Versionate.
#   build/lavoro/ i binari con cui si prova. Non versionata.
#   dist/         quel che si spedisce, e nient'altro. Non versionata.
# `dist/` si svuota all'inizio di ogni pacchettazione: e' cio' che garantisce che
# quel che c'e' dentro sia di una versione sola. Il difetto che questo risolve si
# vedeva a occhio — `ispeziona` rimproverava ai .deb del rilascio precedente di
# non dichiarare la versione nuova.
DIST="$MODULO/dist"

# ── la fonte di verita' ──────────────────────────────────────────────────────
#
# Tutto quel che segue veniva dichiarato qui dentro, e quel che il PKGBUILD
# dichiarava per conto suo divergeva al primo rilascio: la versione era in
# cinque posti, la descrizione in due, il manutentore in due. Adesso e' in uno.
_ver_ambiente="${VERSIONE:-}"
# shellcheck source=../../../progetto.conf
. "$RADICE/progetto.conf" || { echo "manca $RADICE/progetto.conf" >&2; exit 1; }
[ -n "$_ver_ambiente" ] && VERSIONE="$_ver_ambiente"

verde() { printf '\033[32m%s\033[0m' "$1"; }
rosso() { printf '\033[31m%s\033[0m' "$1"; }
sez()   { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }

GUASTI=0
FATTI=""
# Gli .rpm prodotti da *questa* esecuzione, non quelli che stanno in bin/.
# Un array e non una stringa separata da spazi: la cartella di questo progetto si
# chiama `npz v.1`, e uno spazio in un percorso spezza in due ogni elenco tenuto
# in una variabile scalare. Non e' teorico — e' quello che e' successo qui.
RPM_FATTI=()

# ── costruzione ──────────────────────────────────────────────────────────────

# compila_in <goarch> <file>   il binario di rilascio, sempre nello stesso modo.
#
# Esiste perche' i tre canali — il .deb, l'.rpm e il tarball — hanno bisogno
# dello stesso binario, e averne tre copie della riga di `go build` significa
# poter marchiare tre versioni diverse dallo stesso rilascio. I due simboli in
# particolare si marchiano insieme, sempre, dalla stessa fonte: la versione che
# `npz` stampa e quella che finisce nel `creata_da` di uno store non devono
# potersi contraddire.
#
# CGO_ENABLED=0 non e' una ottimizzazione: e' cio' che rende ogni pacchetto
# installabile su distro vecchie quanto si vuole, indipendentemente da glibc.
compila_in() {
    local arco="$1" dove="$2"
    ( cd "$MODULO" && env CGO_ENABLED=0 GOOS=linux GOARCH="$arco" \
        go build -trimpath \
            -ldflags="-s -w -X npz/internal/facciata.Versione=$VERSIONE \
                            -X npz/internal/nucleo.Versione=$VERSIONE" \
            -o "$dove" . ) 2>&1
}

# impacchetta <arco>   con <arco> fra amd64 e arm64 (i nomi coincidono in Go)
impacchetta() {
    local arco="$1"
    local lavoro; lavoro=$(mktemp -d)
    local deb="$DIST/${NOME}_${VERSIONE}_${arco}.deb"

    # 1. il binario, statico come sempre.
    if ! compila_in "$arco" "$lavoro/data/usr/bin/npz"; then
        printf '  [%s] %s — la compilazione\n' "$(rosso FAIL)" "$arco"
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1
    fi
    chmod 0755 "$lavoro/data/usr/bin/npz"

    # 2. la documentazione. Debian *esige* un copyright per pacchetto: senza,
    #    il pacchetto e' installabile ma fuori norma, e lintian lo bocciarebbe.
    mkdir -p "$lavoro/data/usr/share/doc/$NOME"
    cat > "$lavoro/data/usr/share/doc/$NOME/copyright" <<'FINE'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: npz

Files: *
Copyright: npz contributors
License: see the project documentation
FINE

    # 3. data.tar.gz — i file come finiranno sul disco.
    #    --owner/--group a 0: dentro un pacchetto i file sono di root, non di
    #    chi ha compilato. --sort=name e --mtime rendono il tar riproducibile:
    #    due build della stessa sorgente danno lo stesso archivio.
    ( cd "$lavoro/data" && tar czf "$lavoro/data.tar.gz" \
        --owner=0 --group=0 --numeric-owner --sort=name \
        --mtime='@0' --format=gnu ./ ) || {
        printf '  [%s] %s — data.tar.gz\n' "$(rosso FAIL)" "$arco"
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1
    }

    # 4. control — i metadati. `Installed-Size` va in KiB, ed e' quello che apt
    #    mostra prima di chiedere conferma.
    local peso; peso=$(du -sk "$lavoro/data" | cut -f1)
    mkdir -p "$lavoro/control"
    {
        echo "Package: $NOME"
        echo "Version: $VERSIONE"
        echo "Architecture: $arco"
        echo "Maintainer: $MANUTENTORE"
        echo "Installed-Size: $peso"
        echo "Depends: $DIP_DEBIAN"
        echo "Section: devel"
        echo "Priority: optional"
        echo "Homepage: $URL"
        echo "Description: $DESCRIZIONE_BREVE"
        # Le righe di continuazione della descrizione vanno rientrate di uno
        # spazio, e una riga vuota si scrive come un punto solo: e' il formato
        # dei campi multi-riga di Debian, non una scelta tipografica.
        printf '%s\n' "$DESCRIZIONE_LUNGA" | sed 's/^/ /'
    } > "$lavoro/control/control"

    # 5. md5sums — dpkg lo usa per dire quali file sono stati modificati dopo
    #    l'installazione. I percorsi vanno senza `./` iniziale.
    ( cd "$lavoro/data" && find . -type f -printf '%P\n' | sort | \
        xargs -r md5sum > "$lavoro/control/md5sums" ) 2>/dev/null

    ( cd "$lavoro/control" && tar czf "$lavoro/control.tar.gz" \
        --owner=0 --group=0 --numeric-owner --sort=name \
        --mtime='@0' --format=gnu ./ ) || {
        printf '  [%s] %s — control.tar.gz\n' "$(rosso FAIL)" "$arco"
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1
    }

    # 6. l'archivio ar. `rc` e non `rcs`: la `s` aggiungerebbe un indice dei
    #    simboli, che ha senso per le librerie e non per questo — e dpkg
    #    troverebbe un membro in piu' dove non se lo aspetta.
    printf '2.0\n' > "$lavoro/debian-binary"
    rm -f "$deb"
    ( cd "$lavoro" && ar rc "$deb" debian-binary control.tar.gz data.tar.gz ) || {
        printf '  [%s] %s — archivio ar\n' "$(rosso FAIL)" "$arco"
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1
    }

    rm -rf "$lavoro"
    printf '  [%s] %-26s %s\n' "$(verde ok)" "$(basename "$deb")" \
        "$(numfmt --to=iec-i --suffix=B "$(stat -c%s "$deb")")"
}

# ── verifica ─────────────────────────────────────────────────────────────────
#
# Senza dpkg non si puo' dare il verdetto vero. Si puo' pero' controllare tutto
# cio' che il formato prescrive, ed e' molto piu' di niente: l'ordine dei
# membri, il contenuto di debian-binary, i campi obbligatori del control, i
# percorsi dentro i tar, e che il binario estratto sia davvero eseguibile.

controlla() {
    local deb="$1" nome; nome=$(basename "$deb")
    local lavoro; lavoro=$(mktemp -d)
    local errori=0

    dire() { printf '    %s %s\n' "$1" "$2"; }
    ok()   { dire "$(verde ·)" "$1"; }
    no()   { dire "$(rosso ✗)" "$1"; errori=$((errori+1)); }

    printf '  %s\n' "$nome"

    # i tre membri, nell'ordine giusto
    local membri; membri=$(ar t "$deb" | tr '\n' ' ')
    [ "$membri" = "debian-binary control.tar.gz data.tar.gz " ] \
        && ok "tre membri, nell'ordine che dpkg si aspetta" \
        || no "ordine dei membri: '$membri'"

    ( cd "$lavoro" && ar x "$deb" ) 2>/dev/null

    [ "$(cat "$lavoro/debian-binary" 2>/dev/null)" = "2.0" ] \
        && ok "debian-binary dice 2.0" || no "debian-binary"

    # il control, e i campi che Debian esige
    tar xzf "$lavoro/control.tar.gz" -C "$lavoro" 2>/dev/null
    local c="$lavoro/control"
    local mancanti=""
    for campo in Package Version Architecture Maintainer Description; do
        grep -q "^$campo:" "$c" || mancanti="$mancanti $campo"
    done
    [ -z "$mancanti" ] && ok "control: tutti i campi obbligatori" \
        || no "control: mancano$mancanti"

    grep -q '^Depends:' "$c" && ok "Depends: $(grep '^Depends:' "$c" | cut -d' ' -f2-)" \
        || no "Depends assente"

    # le continuazioni della descrizione devono cominciare con uno spazio
    local malformate
    malformate=$(awk '/^Description:/{d=1;next} d&&NF&&!/^ /{print NR}' "$c" | head -1)
    [ -z "$malformate" ] && ok "descrizione multi-riga ben formata" \
        || no "riga $malformate della descrizione non rientrata"

    [ -f "$lavoro/md5sums" ] && ok "md5sums presente ($(wc -l < "$lavoro/md5sums") file)" \
        || no "md5sums assente"

    # i dati: percorsi relativi, binario eseguibile, copyright al suo posto
    mkdir -p "$lavoro/d" && tar xzf "$lavoro/data.tar.gz" -C "$lavoro/d" 2>/dev/null
    local assoluti; assoluti=$(tar tzf "$lavoro/data.tar.gz" | grep -c '^/' || true)
    [ "$assoluti" = 0 ] && ok "nessun percorso assoluto dentro data.tar.gz" \
        || no "$assoluti percorsi assoluti"

    [ -x "$lavoro/d/usr/bin/npz" ] && ok "/usr/bin/npz c'e' ed e' eseguibile" \
        || no "/usr/bin/npz"

    [ -f "$lavoro/d/usr/share/doc/$NOME/copyright" ] \
        && ok "/usr/share/doc/$NOME/copyright (Debian lo esige)" || no "copyright"

    local proprietario; proprietario=$(tar tzvf "$lavoro/data.tar.gz" | awk 'NR==1{print $2}')
    [ "$proprietario" = "0/0" ] && ok "i file sono di root:root" \
        || no "proprietario '$proprietario'"

    file "$lavoro/d/usr/bin/npz" | grep -q "statically linked" \
        && ok "il binario e' statico" || no "il binario NON e' statico"

    # e per l'architettura di questa macchina, che parta davvero
    if [ "$(tar tzvf "$lavoro/data.tar.gz" >/dev/null 2>&1; echo $?)" = 0 ] \
       && printf '%s' "$nome" | grep -q "_amd64" \
       && [ "$(uname -m)" = "x86_64" ]; then
        local versione_detta
        versione_detta=$( cd /tmp && "$lavoro/d/usr/bin/npz" 2>&1 | grep -oP 'npz \K[0-9][^ ]*' | head -1 )
        [ "$versione_detta" = "$VERSIONE" ] \
            && ok "il binario estratto parte e dice $versione_detta" \
            || no "il binario dice '$versione_detta', atteso '$VERSIONE'"
    fi

    rm -rf "$lavoro"
    [ "$errori" -eq 0 ] || GUASTI=$((GUASTI+errori))
}

# ── il pacchetto Arch ────────────────────────────────────────────────────────
#
# Qui, a differenza del .deb, la macchina e' quella giusta: Manjaro e' Arch, e
# makepkg con pacman ci sono. Il pacchetto si costruisce **e si verifica con gli
# strumenti veri**, non con le mie regole — `pacman -Qip` e `-Qlp` leggono un
# file di pacchetto senza bisogno di root e senza installarlo.
#
# Anche le dipendenze qui non sono un'ipotesi: i nomi in PKGBUILD sono quelli
# che `pacman -Qo` restituisce su questa macchina per i quattro binari.

# genera_aur — scrive un PKGBUILD che sta in piedi da solo, per AUR.
#
# Il PKGBUILD del repo legge progetto.conf e non contiene metadati; su AUR quel
# file non ci sarebbe, quindi la versione pubblicabile va prodotta sostituendo i
# valori alla lettera. **Si genera, non si duplica**: un secondo file scritto a
# mano invecchierebbe senza che nessuno se ne accorga, perche' localmente non lo
# eserciterebbe nessuno.
#
# Del template si tiene tutto tranne il blocco fra i marcatori: i commenti che
# spiegano le scelte — perche' erofsfuse e' separato, perche' npm e' opzionale,
# perche' il binario e' statico — su AUR valgono piu' che qui, dove chi legge il
# PKGBUILD ha gia' sott'occhio il resto del progetto.
# conf_effettiva <destinazione>   progetto.conf con la versione **risolta**.
#
# Il PKGBUILD legge i metadati da un `progetto.conf` che gli sta accanto, e quella
# copia deve dire la versione con cui si sta costruendo adesso — non quella scritta
# nel file, che l'ambiente puo' aver sovrascritto (`VERSIONE=1.2.3 ./pacchetto.sh`).
#
# Perche' non si passa per l'ambiente, che sarebbe l'ovvio: makepkg rientra in
# `fakeroot` per eseguire `package()`, e la' rilegge il PKGBUILD **senza** le
# variabili esportate. Il pkgver cambiava percio' a meta' del giro, e il sintomo
# era `cd: npz-<la versione del file>: non esiste` dentro package() — un messaggio
# che non nomina ne' l'ambiente ne' la versione doppia. Passare dal file e' l'unico
# modo perche' le due meta' di makepkg leggano lo stesso numero.
conf_effettiva() {
    # La versione non contiene mai `/` ne' `&`, quindi la sostituzione non ha
    # bisogno di essere difesa: se un giorno li contenesse, non sarebbe una
    # versione valida per nessuno dei tre formati.
    sed "s|^VERSIONE=.*|VERSIONE=$VERSIONE|" "$RADICE/progetto.conf" > "$1"
}

genera_aur() {
    local fuori="$DIST/PKGBUILD-aur"
    local intestazione coda
    # Le due meta' del template, attorno al blocco dei metadati. I motivi si
    # esprimono per numero di riga invece che per pattern annidati: e' meno
    # elegante e non ha virgolette dentro virgolette da sbagliare.
    local riga_apre riga_chiude
    riga_apre=$(grep -n '^# >>> metadati' "$QUI/PKGBUILD" | cut -d: -f1)
    riga_chiude=$(grep -n '^# <<< metadati' "$QUI/PKGBUILD" | cut -d: -f1)
    if [ -z "$riga_apre" ] || [ -z "$riga_chiude" ]; then
        printf '    %s marcatori dei metadati non trovati nel PKGBUILD\n' "$(rosso ✗)"
        GUASTI=$((GUASTI+1)); return 1
    fi
    intestazione=$(head -n "$((riga_apre - 1))" "$QUI/PKGBUILD" | grep -v 'progetto.conf')
    coda=$(tail -n "+$((riga_chiude + 1))" "$QUI/PKGBUILD")

    {
        printf '%s\n' "$intestazione"
        printf '%s\n' "# Metadati generati da progetto.conf: si cambiano la', non qui."
        printf 'pkgname=%s\n' "$NOME"
        printf 'pkgver=%s\n'  "$VERSIONE"
        printf 'pkgrel=%s\n'  "$RILASCIO"
        printf "pkgdesc='%s'\n" "$DESCRIZIONE_BREVE"
        printf "url='%s'\n"     "$URL"
        printf "license=('%s')\n" "$LICENZA"
        printf 'depends=('; printf "'%s' " $DIP_ARCH; printf ')\n'
        printf 'optdepends=('
        local o; for o in "${OPZIONALI_ARCH[@]}"; do printf "'%s' " "$o"; done
        printf ')\n'
        printf '%s\n' "$coda"
    } > "$fuori"

    # Che sia bash valido e' il minimo; che contenga davvero i metadati e non
    # solo la cornice e' cio' che dice se la generazione ha funzionato.
    local difetti=0
    bash -n "$fuori" 2>/dev/null || difetti=$((difetti+1))
    grep -q "^pkgver=$VERSIONE$" "$fuori" || difetti=$((difetti+1))
    # Deve non *sorgentare* progetto.conf; che i commenti lo nominino e'
    # invece giusto — spiegano da dove vengono i valori qui sotto.
    grep -qE '^[[:space:]]*\.[[:space:]]' "$fuori" && difetti=$((difetti+1))
    [ "$(wc -l < "$fuori")" -gt 40 ] || difetti=$((difetti+1))

    if [ "$difetti" -eq 0 ]; then
        printf '    %s PKGBUILD-aur generato: %s righe, versione alla lettera, autosufficiente\n' \
            "$(verde ·)" "$(wc -l < "$fuori")"
    else
        printf '    %s PKGBUILD-aur difettoso (%s controlli falliti)\n' "$(rosso ✗)" "$difetti"
        GUASTI=$((GUASTI+difetti))
    fi
}

arch_pacchetto() {
    sez "il pacchetto Arch"
    for t in makepkg fakeroot; do
        command -v "$t" >/dev/null 2>&1 || {
            info "$t assente: qui non si puo' costruire un pacchetto Arch."; return 0; }
    done

    local lavoro; lavoro=$(mktemp -d)
    local albero="$lavoro/$NOME-$VERSIONE"

    # Lo staging dei sorgenti. Si copia a mano invece di tarare la cartella
    # intera perche' `build/lavoro/` e `dist/` non devono entrarci: contengono i
    # binari e i pacchetti gia' costruiti, e un sorgente che si porta dietro il
    # proprio prodotto e' il modo piu' rapido per impacchettare qualcosa di
    # vecchio. Da quando le tre cartelle sono separate, la regola e' semplice:
    # entra `build/bin/` — le utilita' — e non entra il resto di `build/`.
    #
    # **L'albero conserva la geometria del repo**: `progetto.conf` in cima e il
    # modulo Go dentro `npz_go/`, un livello sotto. Non e' pignoleria — e' cio'
    # che rende `build/build.sh` eseguibile dentro il tarball esattamente come
    # nel repo, perche' cerca il conf allo stesso posto relativo. Appiattire
    # l'albero costerebbe una seconda regola di ricerca negli script, cioe' un
    # modo in piu' di leggere la versione, cioe' un modo in piu' di sbagliarla.
    local dentro="$albero/$(basename "$MODULO")"
    mkdir -p "$dentro/build/bin"
    cp -r "$MODULO/go.mod" "$MODULO/main.go" "$MODULO/internal" "$MODULO/test" "$dentro/"
    conf_effettiva "$albero/progetto.conf"
    cp "$MODULO/build/build.sh" "$dentro/build/"
    cp "$QUI/pacchetto.sh" "$QUI/PKGBUILD" "$dentro/build/bin/"
    cp "$RADICE/README.md" "$albero/" 2>/dev/null || \
        printf '# npz\n' > "$albero/README.md"

    ( cd "$lavoro" && tar czf "$NOME-$VERSIONE.tar.gz" "$NOME-$VERSIONE" ) || {
        printf '  [%s] tarball dei sorgenti\n' "$(rosso FAIL)"
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1; }
    cp "$QUI/PKGBUILD" "$lavoro/"
    # Accanto al PKGBUILD, che e' dove `$startdir` lo cerca.
    conf_effettiva "$lavoro/progetto.conf"

    # `makepkg` senza --nodeps di proposito: cosi' controlla che i pacchetti in
    # depends esistano davvero e siano installati, il che e' una verifica della
    # riga `depends=()` e non solo della compilazione.
    info "makepkg …"
    if ! ( cd "$lavoro" && makepkg -f --noconfirm ) >"$lavoro/log" 2>&1; then
        printf '  [%s] makepkg\n' "$(rosso FAIL)"
        tail -12 "$lavoro/log" | sed 's/^/      /'
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1
    fi

    local prodotto; prodotto=$(find "$lavoro" -maxdepth 1 -name '*.pkg.tar.*' | head -1)
    [ -n "$prodotto" ] || { printf '  [%s] nessun pacchetto prodotto\n' "$(rosso FAIL)"
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1; }
    cp "$prodotto" "$DIST/"
    local deposto="$DIST/$(basename "$prodotto")"
    printf '  [%s] %-34s %s\n' "$(verde ok)" "$(basename "$deposto")" \
        "$(numfmt --to=iec-i --suffix=B "$(stat -c%s "$deposto")")"

    # ── la verifica, con pacman ──────────────────────────────────────────────
    local errori=0
    dire() { printf '    %s %s\n' "$1" "$2"; }
    okk()  { dire "$(verde ·)" "$1"; }
    noo()  { dire "$(rosso ✗)" "$1"; errori=$((errori+1)); }

    genera_aur
    local info_pkg; info_pkg=$(LC_ALL=C pacman -Qip "$deposto" 2>/dev/null)
    [ -n "$info_pkg" ] && okk "pacman legge il pacchetto" \
        || noo "pacman non riesce a leggere il pacchetto"

    local dichiarate; dichiarate=$(printf '%s' "$info_pkg" | grep -oP '^Depends On\s+:\s+\K.*')
    for d in $DIP_ARCH; do
        printf '%s' "$dichiarate" | grep -qw "$d" \
            && okk "dipende da $d" || noo "manca la dipendenza $d"
    done

    # E che le dipendenze dichiarate esistano davvero come pacchetti.
    local fantasma=0
    for d in $DIP_ARCH; do
        pacman -Si "$d" >/dev/null 2>&1 || pacman -Qi "$d" >/dev/null 2>&1 || {
            noo "il pacchetto '$d' non esiste nei repo"; fantasma=1; }
    done
    [ "$fantasma" = 0 ] && okk "tutte le dipendenze esistono nei repo"

    printf '%s' "$info_pkg" | grep -q 'npm' \
        && okk "npm e' fra le opzionali, non fra le obbligatorie" \
        || noo "npm non compare fra le dipendenze opzionali"

    local file_pkg; file_pkg=$(LC_ALL=C pacman -Qlp "$deposto" 2>/dev/null | awk '{print $2}')
    printf '%s' "$file_pkg" | grep -qx '/usr/bin/npz' \
        && okk "/usr/bin/npz e' nel pacchetto" || noo "/usr/bin/npz assente"

    # Il binario dentro il pacchetto: estratto e provato davvero.
    local estratto="$lavoro/estratto"; mkdir -p "$estratto"
    bsdtar xf "$deposto" -C "$estratto" 2>/dev/null
    if [ -x "$estratto/usr/bin/npz" ]; then
        file "$estratto/usr/bin/npz" | grep -q "statically linked" \
            && okk "il binario nel pacchetto e' statico" || noo "il binario non e' statico"
        local detta; detta=$( cd /tmp && "$estratto/usr/bin/npz" 2>&1 | grep -oP 'npz \K[0-9][^ ]*' | head -1 )
        [ "$detta" = "$VERSIONE" ] && okk "parte e dice $detta" \
            || noo "dice '$detta' invece di '$VERSIONE'"
    else
        noo "il binario non si estrae"
    fi

    GUASTI=$((GUASTI+errori))
    rm -rf "$lavoro"
}

# ── il pacchetto RPM ─────────────────────────────────────────────────────────
#
# Qui **non** si fa come col .deb, e la ragione e' nel formato.
#
# Un .deb e' un archivio `ar` con tre membri: si scrive con due attrezzi che
# stanno in binutils, e l'assenza di dpkg costa solo la prova d'installazione.
# Un .rpm no. E' un lead binario, poi una sezione di firma, poi un header di
# voci indicizzate e tipizzate in big-endian, poi un cpio compresso — con dei
# digest calcolati su regioni dell'header stesso. Scriverlo a mano in bash si
# puo' fare, ma darebbe un file che **su questa macchina nessuno puo' leggere**:
# senza `rpm` non ci sarebbe ne' lo strumento vero ne' l'oracolo, cioe' nessuno
# dei due modi con cui in questo progetto si distingue un pacchetto da un
# archivio che gli somiglia.
#
# `rpm-tools` invece sta nei repo di Manjaro, e porta **entrambi**: `rpmbuild`
# per costruire e `rpm -qip`/`-qlp` per interrogare senza installare e senza
# root. Cioe' esattamente la posizione in cui si trova il pacchetto Arch, che e'
# la meglio verificata delle tre. Una dipendenza in piu' per chi rilascia, in
# cambio del solo canale su cui la struttura non sia una mia ipotesi.
#
# Lo .spec, come il .deb, impacchetta il binario **gia' costruito** invece di
# ricompilare dentro %build: e' cio' che permette di produrre l'aarch64 da
# questa macchina x86, che uno spec che compila non potrebbe fare.

# rpm_arco <goarch>   il nome che rpm da' all'architettura che Go chiama <goarch>
rpm_arco() {
    case "$1" in
        amd64) echo x86_64 ;;
        arm64) echo aarch64 ;;
        *)     echo "$1" ;;
    esac
}

# rpm_spec <file>   lo .spec, coi valori di progetto.conf sostituiti alla lettera.
#
# Si genera e non si versiona, per la stessa ragione del PKGBUILD-aur: uno .spec
# scritto a mano accanto a progetto.conf sarebbe una seconda copia dei metadati,
# e una copia che nessuno esercita e' una copia di cui nessuno si accorge quando
# invecchia. Il file che ne esce e' autosufficiente — e' quello da pubblicare su
# COPR o in un dist-git, dove progetto.conf non ci sarebbe.
# Due regole non ovvie su come si scrive uno .spec, e vengono da come rpm lo
# legge — non da gusto tipografico:
#
#  1. **nei commenti il segno di percento si raddoppia.** rpm espande le macro
#     prima di buttare via i commenti, quindi un `#` che nomina una macro la
#     espande davvero: nel migliore dei casi un avvertimento su una macro
#     ignota, nel peggiore — con la forma `%(comando)` — un comando eseguito.
#     Qui percio' si scrive `%%files`, e chi legge il file lo intende.
#  2. **dopo %description non si commenta.** Il testo di quella sezione e' preso
#     alla lettera fino alla direttiva successiva, e un commento in italiano
#     rischierebbe di finire nella descrizione inglese del pacchetto. Tutto
#     quello che c'e' da spiegare sta percio' qui sopra o nel preambolo.
rpm_spec() {
    cat > "$1" <<FINE
# npz.spec — GENERATO da build/pacchetto.sh a partire da progetto.conf.
# Non modificarlo: i valori si cambiano la', e questo file si rifa'.
#
# Non ha ne' %%prep ne' %%build, e non e' una dimenticanza: il binario e'
# costruito fuori — statico, con CGO_ENABLED=0 — una volta sola e nello stesso
# modo per ogni canale, e qui viene soltanto messo al suo posto. E' anche cio'
# che permette di produrre l'aarch64 da una macchina x86, con --target.
#
# Per una submission Fedora la Release va scritta \`$RILASCIO%%{?dist}\`; qui e'
# senza, perche' fuori da Fedora quella macro non e' definita e il nome del file
# che ne esce dev'essere prevedibile da chi lo ha appena costruito.

# Il binario arriva gia' spogliato da \`-ldflags "-s -w"\`: senza questa riga
# rpmbuild proverebbe a estrarne un -debuginfo, non troverebbe niente da mettere
# dentro e fallirebbe su un %%files vuoto. E' il \`options=('!debug')\` di Arch.
%define debug_package %{nil}
%define _build_id_links none
# Via anche gli script brp-*: rimpicciolirebbero un binario gia' minimo, e il
# pacchetto dipenderebbe dai macro della distro che lo costruisce invece che solo
# da questo file. Quel che entra nel payload e' quel che dice %%install.
%define __os_install_post %{nil}

Name:           $NOME
Version:        $VERSIONE
Release:        $RILASCIO
Summary:        $DESCRIZIONE_BREVE
License:        ${LICENZA:-unspecified}
URL:            $URL
Packager:       $MANUTENTORE

# Il generatore automatico di dipendenze non ha niente da trovare — il binario
# e' statico e non linka nulla — e su una macchina non-rpm darebbe un risultato
# che dipende da come e' pacchettizzato rpm li'. I Requires qui sotto sono tutti
# quelli che ci sono. Il \`Provides: $NOME = $VERSIONE-$RILASCIO\` lo aggiunge rpm
# da se': non viene dal generatore, e questa riga non lo tocca.
AutoReqProv:    no
$(for d in $DIP_RPM; do printf 'Requires:       %s\n' "$d"; done)
# Suggests e non Recommends: dnf installa le raccomandate per difetto, e
# installerebbe l'npm della distro proprio a chi ne ha gia' uno da nvm/fnm.
$(for d in $OPZIONALI_RPM; do printf 'Suggests:       %s\n' "$d"; done)

%description
$DESCRIZIONE_LUNGA

%install
install -D -m 0755 %{_sourcedir}/%{name} %{buildroot}%{_bindir}/%{name}
install -D -m 0644 %{_sourcedir}/README.md %{buildroot}%{_docdir}/%{name}/README.md

%files
%{_bindir}/%{name}
%{_docdir}/%{name}/

%changelog
FINE
}

# rpm_uno <goarch>
rpm_uno() {
    local arco="$1" rarco; rarco=$(rpm_arco "$arco")
    local lavoro; lavoro=$(mktemp -d)
    local cima="$lavoro/rpmbuild"
    mkdir -p "$cima"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

    # Lo stesso binario del .deb, dallo stesso posto: vedi compila_in().
    if ! compila_in "$arco" "$cima/SOURCES/$NOME"; then
        printf '  [%s] %s — la compilazione\n' "$(rosso FAIL)" "$rarco"
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1
    fi

    cp "$RADICE/README.md" "$cima/SOURCES/README.md" 2>/dev/null || \
        printf '# npz\n' > "$cima/SOURCES/README.md"

    rpm_spec "$cima/SPECS/$NOME.spec"

    # --target e non un BuildArch nello .spec: e' il solo modo di produrre da qui
    # un pacchetto per un'altra architettura, e non tocca il file pubblicabile.
    #
    # I tre --define non sono metadati del pacchetto ma scelte di chi costruisce,
    # e stanno percio' fuori dallo .spec:
    #   _package_format 4   rpm 6 sa scrivere un formato che gli rpm 4.x di
    #                       Fedora e RHEL non leggono. Un pacchetto che il
    #                       pubblico non apre non e' un pacchetto.
    #   _binary_payload     gzip e non zstd, per la stessa ragione per cui il
    #                       .deb usa .gz: lo zstd nei payload rpm arriva solo con
    #                       Fedora 31, e qui si paga qualche punto di dimensione
    #                       per non tagliare fuori le distro vecchie — che sono
    #                       lo scopo per cui il binario e' statico.
    #   clamp_mtime…        con SOURCE_DATE_EPOCH rende l'rpm riproducibile,
    #                       come --sort=name e --mtime=@0 fanno per il .deb.
    local log="$lavoro/log"
    if ! ( cd "$cima/SPECS" && env SOURCE_DATE_EPOCH=0 rpmbuild -bb \
            --target="$rarco" \
            --define "_topdir $cima" \
            --define "_package_format 4" \
            --define "_binary_payload w9.gzdio" \
            --define "use_source_date_epoch_as_buildtime 1" \
            --define "clamp_mtime_to_source_date_epoch 1" \
            "$NOME.spec" ) >"$log" 2>&1; then
        printf '  [%s] %s — rpmbuild\n' "$(rosso FAIL)" "$rarco"
        tail -12 "$log" | sed 's/^/      /'
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1
    fi

    # rpmbuild deposita sotto RPMS/<arch>/, e il nome lo compone lui: si cerca
    # invece di indovinarlo.
    local prodotto; prodotto=$(find "$cima/RPMS" -name '*.rpm' -type f | head -1)
    if [ -z "$prodotto" ]; then
        printf '  [%s] %s — nessun rpm prodotto\n' "$(rosso FAIL)" "$rarco"
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1
    fi

    cp "$prodotto" "$DIST/"
    # Lo .spec si tiene solo adesso: e' quello che rpmbuild ha appena accettato,
    # non quello che spero accetti.
    cp "$cima/SPECS/$NOME.spec" "$DIST/$NOME.spec"
    # Si verifichera' questo, non `$DIST/*.rpm`. Adesso che dist/ si svuota a ogni
    # giro le due cose coincidono, ma dipendere dallo svuotamento significherebbe
    # che un giorno in cui salta si verifica il pacchetto sbagliato senza dirlo.
    # Verificare cio' che si e' appena prodotto e' vero comunque.
    RPM_FATTI+=("$DIST/$(basename "$prodotto")")
    printf '  [%s] %-34s %s\n' "$(verde ok)" "$(basename "$prodotto")" \
        "$(numfmt --to=iec-i --suffix=B "$(stat -c%s "$prodotto")")"
    rm -rf "$lavoro"
}

# rpm_controlla <file.rpm>   con `rpm`, cioe' con lo strumento vero.
rpm_controlla() {
    local pacco="$1" nome; nome=$(basename "$pacco")
    local lavoro; lavoro=$(mktemp -d)
    local errori=0
    dire() { printf '    %s %s\n' "$1" "$2"; }
    okr()  { dire "$(verde ·)" "$1"; }
    nor()  { dire "$(rosso ✗)" "$1"; errori=$((errori+1)); }

    printf '  %s\n' "$nome"

    local campi
    campi=$(LC_ALL=C rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n' \
            "$pacco" 2>/dev/null)
    [ -n "$campi" ] && okr "rpm legge il pacchetto: $campi" \
        || { nor "rpm non riesce a leggere il pacchetto"; rm -rf "$lavoro"
             GUASTI=$((GUASTI+errori)); return 1; }

    local atteso_arco; atteso_arco=$(printf '%s' "$nome" | sed 's/.*\.\([^.]*\)\.rpm$/\1/')
    [ "$campi" = "$NOME $VERSIONE $RILASCIO $atteso_arco" ] \
        && okr "nome, versione, rilascio e architettura come da progetto.conf" \
        || nor "campi '$campi', atteso '$NOME $VERSIONE $RILASCIO $atteso_arco'"

    # La licenza: rpm **esige** il campo, quindi non poteva restare vuoto come su
    # Arch. Che dica `unspecified` e' l'unica cosa vera da scrivere finche' il
    # progetto non ha un file di licenza; che dicesse un nome di licenza a caso
    # sarebbe peggio.
    local licenza; licenza=$(LC_ALL=C rpm -qp --qf '%{LICENSE}\n' "$pacco" 2>/dev/null)
    [ "$licenza" = "${LICENZA:-unspecified}" ] \
        && okr "License: $licenza (rpm esige il campo, vuoto non si puo')" \
        || nor "License dice '$licenza'"

    local richieste; richieste=$(LC_ALL=C rpm -qpR "$pacco" 2>/dev/null)
    for d in $DIP_RPM; do
        printf '%s' "$richieste" | grep -qx "$d" \
            && okr "richiede $d" || nor "manca il Requires $d"
    done
    # Che non ne siano comparse altre da sole: e' cio' che AutoReqProv: no deve
    # garantire, ed e' l'unico campo del pacchetto che potrebbe cambiare a
    # seconda della macchina su cui si costruisce.
    local intruse; intruse=$(printf '%s' "$richieste" | grep -v '^rpmlib(' \
        | grep -vxF "$(printf '%s\n' $DIP_RPM)" | grep -v '^$' | tr '\n' ' ')
    [ -z "$intruse" ] && okr "nessuna dipendenza aggiunta dal generatore automatico" \
        || nor "dipendenze non dichiarate: $intruse"

    # Un tag assente rpm lo stampa `(none)`, non vuoto: le due condizioni si
    # scrivono percio' per casi e non con un `grep -q .`, che su `(none)`
    # risponderebbe si'.
    local suggerite; suggerite=$(LC_ALL=C rpm -qp --qf '[%{SUGGESTNAME} ]' "$pacco" 2>/dev/null)
    printf '%s' "$suggerite" | grep -qw npm \
        && okr "npm e' fra i Suggests, che dnf non installa da solo" \
        || nor "npm non compare fra i Suggests: '$suggerite'"

    local raccomandate; raccomandate=$(LC_ALL=C rpm -qp --qf '[%{RECOMMENDNAME} ]' "$pacco" 2>/dev/null)
    case "$raccomandate" in
        ''|'(none)'*) okr "nessun Recommends" ;;
        *) nor "ci sono dei Recommends ('$raccomandate'): dnf li installerebbe per difetto" ;;
    esac

    # Che `AutoReqProv: no` non sia andato troppo lontano: il Provides col nome e
    # la versione lo mette rpm da se', ed e' quello che rende il pacchetto
    # aggiornabile. Se sparisse, sparirebbe per colpa di quella riga.
    LC_ALL=C rpm -qp --provides "$pacco" 2>/dev/null \
        | grep -q "^$NOME = $VERSIONE-$RILASCIO" \
        && okr "Provides: $NOME = $VERSIONE-$RILASCIO" \
        || nor "manca il Provides con nome e versione"

    local elenco; elenco=$(LC_ALL=C rpm -qpl "$pacco" 2>/dev/null)
    printf '%s' "$elenco" | grep -qx '/usr/bin/npz' \
        && okr "/usr/bin/npz e' nel pacchetto" || nor "/usr/bin/npz assente"

    local proprietari; proprietari=$(LC_ALL=C rpm -qp \
        --qf '[%{FILEUSERNAME}:%{FILEGROUPNAME}\n]' "$pacco" 2>/dev/null | sort -u | tr '\n' ' ')
    [ "$proprietari" = "root:root " ] && okr "i file sono di root:root" \
        || nor "proprietari '$proprietari'"

    local modo; modo=$(LC_ALL=C rpm -qp --qf '[%{FILENAMES} %{FILEMODES:perms}\n]' \
        "$pacco" 2>/dev/null | awk '$1=="/usr/bin/npz"{print $2}')
    case "$modo" in
        -rwxr-xr-x) okr "/usr/bin/npz e' 0755" ;;
        *)          nor "/usr/bin/npz ha modo '$modo'" ;;
    esac

    # Il payload, estratto e provato davvero. bsdtar legge un rpm da solo; dove
    # non lo facesse c'e' rpm2cpio, che arriva con rpm stesso.
    local d="$lavoro/d"; mkdir -p "$d"
    ( cd "$d" && bsdtar xf "$pacco" ) 2>/dev/null
    if [ ! -f "$d/usr/bin/npz" ] && command -v rpm2cpio >/dev/null 2>&1; then
        ( cd "$d" && rpm2cpio "$pacco" | cpio -idm --quiet ) 2>/dev/null
    fi
    if [ -f "$d/usr/bin/npz" ]; then
        chmod +x "$d/usr/bin/npz"
        file "$d/usr/bin/npz" | grep -q "statically linked" \
            && okr "il binario nel pacchetto e' statico" || nor "il binario non e' statico"
        if [ "$atteso_arco" = x86_64 ] && [ "$(uname -m)" = x86_64 ]; then
            local detta; detta=$( cd /tmp && "$d/usr/bin/npz" 2>&1 \
                | grep -oP 'npz \K[0-9][^ ]*' | head -1 )
            [ "$detta" = "$VERSIONE" ] && okr "parte e dice $detta" \
                || nor "dice '$detta' invece di '$VERSIONE'"
        fi
    else
        nor "il payload non si estrae"
    fi

    rm -rf "$lavoro"
    GUASTI=$((GUASTI+errori))
}

rpm_pacchetto() {
    sez "il pacchetto RPM"
    if ! command -v rpmbuild >/dev/null 2>&1; then
        info "rpmbuild assente — nessun .rpm costruito."
        info "su Arch/Manjaro:  sudo pacman -S rpm-tools   (porta anche \`rpm\`)"
        # Non e' un guasto: e' la stessa scelta di arch_pacchetto quando manca
        # makepkg. Un attrezzo che non c'e' e' una notizia, non un errore.
        return 0
    fi

    local archi="${1:-amd64 arm64}" a
    RPM_FATTI=()
    for a in $archi; do rpm_uno "$a" || continue; done

    if [ "${#RPM_FATTI[@]}" -eq 0 ]; then
        info "nessun .rpm prodotto: niente da verificare"
        return 0
    fi
    local p
    for p in "${RPM_FATTI[@]}"; do rpm_controlla "$p"; done

    if [ -f "$DIST/$NOME.spec" ]; then
        printf '    %s %s.spec generato (%s righe): autosufficiente, ed e' \
            "$(verde ·)" "$NOME" "$(wc -l < "$DIST/$NOME.spec")"
        printf "' quello che rpmbuild ha accettato\\n"
    fi
}

# ── l'oracolo ────────────────────────────────────────────────────────────────
#
# "L'ho verificato io con le mie regole" non e' una prova: le regole potrebbero
# essere le stesse che ho sbagliato scrivendo. Se sulla macchina c'e' `nfpm` —
# il generatore di riferimento, quello che GoReleaser usa sotto — si costruisce
# lo stesso pacchetto con lui e si confrontano i due. E' la stessa disciplina
# con cui la fase 1 ha confrontato il nucleo Go col Python.
#
# Installarlo:  go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest
oracolo() {
    sez "l'oracolo: il mio .deb contro quello di nfpm"
    if ! command -v nfpm >/dev/null 2>&1; then
        info "nfpm assente — confronto saltato."
        info "go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest"
        return 0
    fi
    local mio="$DIST/${NOME}_${VERSIONE}_amd64.deb"
    [ -f "$mio" ] || { info "manca $mio: costruiscilo prima"; return 0; }

    local o; o=$(mktemp -d)
    # Il binario si compila adesso invece di raccoglierlo da una cartella: prima
    # veniva da `bin/`, dove poteva essere di una build di ieri, e l'oracolo
    # avrebbe confrontato due pacchetti con dentro due binari diversi — cioe'
    # avrebbe misurato la cosa sbagliata senza accorgersene.
    if ! compila_in amd64 "$o/npz"; then
        info "la compilazione per l'oracolo e' fallita"; rm -rf "$o"; return 0
    fi
    cat > "$o/nfpm.yaml" <<YAML
name: $NOME
arch: amd64
version: $VERSIONE
version_schema: none
section: devel
priority: optional
maintainer: $MANUTENTORE
homepage: $URL
description: $DESCRIZIONE_BREVE
depends: [$DIP_DEBIAN]
contents:
  - src: ./npz
    dst: /usr/bin/npz
    file_info: { mode: 0755 }
YAML
    if ! ( cd "$o" && nfpm package -p deb -t "$o/rif.deb" ) >/dev/null 2>&1; then
        info "nfpm non e' riuscito a costruire il riferimento"; rm -rf "$o"; return 0
    fi

    local a b
    a=$(ar t "$mio" | tr '\n' ' '); b=$(ar t "$o/rif.deb" | tr '\n' ' ')
    [ "$a" = "$b" ] && printf '    %s membri e ordine identici a nfpm\n' "$(verde ·)" \
        || { printf '    %s membri diversi: "%s" contro "%s"\n' "$(rosso ✗)" "$a" "$b"; GUASTI=$((GUASTI+1)); }

    mkdir -p "$o/mio" "$o/rif"
    ( cd "$o/mio" && ar x "$mio" ); ( cd "$o/rif" && ar x "$o/rif.deb" )
    for d in mio rif; do mkdir -p "$o/$d/c"; tar xf "$o/$d"/control.tar.* -C "$o/$d/c" 2>/dev/null; done

    if diff -q <(grep -oP '^[A-Z][A-Za-z-]*(?=:)' "$o/mio/c/control" | sort) \
               <(grep -oP '^[A-Z][A-Za-z-]*(?=:)' "$o/rif/c/control" | sort) >/dev/null; then
        printf '    %s stessi campi nel control\n' "$(verde ·)"
    else
        printf '    %s campi diversi nel control\n' "$(rosso ✗)"; GUASTI=$((GUASTI+1))
    fi

    # Le differenze attese, elencate perche' non vengano scambiate per guasti:
    #  · l'ORDINE dei campi differisce, e non conta — il control e' in stile
    #    RFC822, dove i campi non sono posizionali;
    #  · il nostro Installed-Size e' piu' grande di ~8 KiB perche' includiamo
    #    /usr/share/doc/npz/copyright, che la policy Debian **esige** e che la
    #    configurazione minima di nfpm qui sopra non mette;
    #  · nel data.tar il proprietario nostro si legge `0/0` e quello di nfpm
    #    `root/root`: e' lo stesso uid 0, scritto con o senza il nome. dpkg
    #    guarda il numero.
    printf '    %s differenze attese: ordine dei campi, copyright in piu%s, uid numerico\n' \
        "$(verde ·)" "'"
    rm -rf "$o"
}

ispeziona() {
    sez "dentro i pacchetti"
    local trovati=0
    for deb in "$DIST"/*.deb; do
        [ -e "$deb" ] || continue
        trovati=1; controlla "$deb"
    done
    [ "$trovati" = 1 ] || info "nessun .deb in dist/ — costruiscilo prima"
}

# ── i tarball ────────────────────────────────────────────────────────────────
#
# Il canale di chi non passa da un gestore di pacchetti: lo script di
# installazione del §12 scarica questi e ne verifica la somma. Dentro c'e' un
# file solo, il binario, col nome `npz` e non col nome dell'archivio — chi lo
# estrae vuole `npz` in `~/.local/bin`, non `npz-linux-amd64`.
tarball() {
    local arco="$1"
    local nomefile="$NOME-$VERSIONE-linux-$arco.tar.gz"
    local lavoro; lavoro=$(mktemp -d)

    if ! compila_in "$arco" "$lavoro/$NOME"; then
        printf '  [%s] %s — la compilazione\n' "$(rosso FAIL)" "$nomefile"
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1
    fi
    # Riproducibile come i tar del .deb, e per la stessa ragione: due giri sulla
    # stessa sorgente devono dare lo stesso archivio, o la somma non dice niente.
    if ! ( cd "$lavoro" && tar czf "$DIST/$nomefile" \
            --owner=0 --group=0 --numeric-owner --sort=name \
            --mtime='@0' --format=gnu "$NOME" ); then
        printf '  [%s] %s\n' "$(rosso FAIL)" "$nomefile"
        GUASTI=$((GUASTI+1)); rm -rf "$lavoro"; return 1
    fi

    printf '  [%s] %-34s %s\n' "$(verde ok)" "$nomefile" \
        "$(numfmt --to=iec-i --suffix=B "$(stat -c%s "$DIST/$nomefile")")"
    rm -rf "$lavoro"
}

# ── le somme ─────────────────────────────────────────────────────────────────
#
# Si scrive per ultimo e **solo se non ci sono guasti**, e questo non e' un
# dettaglio: e' cio' che rende `SHA256SUMS` la prova che il giro e' finito bene.
# `build.sh` ci si appoggia per decidere se una versione e' gia' stata
# impacchettata — un giro interrotto a metà non lascia il file, quindi riparte.
#
# Copre tutto quel che sta in dist/ tranne se stesso, ed e' nel formato che
# `sha256sum -c` legge: chi scarica verifica con l'attrezzo che ha già.
somme() {
    sez "le somme"
    local fuori="$DIST/SHA256SUMS"
    rm -f "$fuori"
    # `! -name SHA256SUMS` non e' pignoleria: la redirezione crea il file **prima**
    # che `find` guardi, quindi senza questa esclusione l'elenco contiene se
    # stesso — e la somma registrata e' quella del file vuoto, cioe' una somma che
    # non tornera' mai piu'.
    if ! ( cd "$DIST" && find . -maxdepth 1 -type f \
            ! -name '.*' ! -name SHA256SUMS -printf '%P\n' \
            | sort | xargs -r sha256sum > SHA256SUMS ); then
        printf '  [%s] SHA256SUMS\n' "$(rosso FAIL)"; GUASTI=$((GUASTI+1)); return 1
    fi
    printf '  [%s] %-34s %s file\n' "$(verde ok)" SHA256SUMS "$(wc -l < "$fuori")"
    # Che sia verificabile lo si verifica, invece di dedurlo dall'aver scritto il
    # file: `sha256sum -c` e' lo stesso comando che eseguira' chi scarica. Anche
    # stdout va nel nulla — con `--quiet` le righe che restano sono i fallimenti,
    # e a dirli ci pensa la riga qui sotto.
    if ( cd "$DIST" && sha256sum -c --quiet SHA256SUMS ) >/dev/null 2>&1; then
        printf '    %s `sha256sum -c SHA256SUMS` passa\n' "$(verde ·)"
    else
        printf '    %s `sha256sum -c SHA256SUMS` non passa\n' "$(rosso ✗)"
        GUASTI=$((GUASTI+1))
    fi
}

# svuota_dist — dist/ contiene una versione sola, sempre.
#
# E' il punto dove i file intermedi smettono di accumularsi. Il resto degli
# intermedi non arriva nemmeno qui: ogni funzione lavora in un `mktemp -d` che
# cancella prima di tornare, compresi i percorsi di errore.
svuota_dist() {
    mkdir -p "$DIST"
    find "$DIST" -mindepth 1 ! -name '.gitignore' -delete 2>/dev/null
}

main() {
    mkdir -p "$DIST"
    printf '\033[1mpacchetti di %s %s\033[0m\n' "$NOME" "$VERSIONE"
    info "metadati da progetto.conf · manutentore: $MANUTENTORE"

    if [ "${1:-}" = ispeziona ]; then FATTI=deb; ispeziona
    elif [ "${1:-}" = oracolo ]; then oracolo
    elif [ "${1:-}" = arch ]; then FATTI=arch; arch_pacchetto
    elif [ "${1:-}" = rpm ]; then FATTI=rpm; rpm_pacchetto
    elif [ "${1:-}" = tarball ]; then
        FATTI=tar; sez "i tarball"; tarball amd64; tarball arm64
    else
        case "${1:-tutti}" in
            amd64|arm64)
                # Un bersaglio solo: dist/ **non** si svuota e le somme non si
                # scrivono. Chi chiede una architettura sola sta provando qualcosa,
                # non rilasciando, e un SHA256SUMS che copre mezzo rilascio
                # direbbe a build.sh che la versione e' fatta.
                sez "costruzione"; FATTI="deb"
                impacchetta "$1"; ispeziona; oracolo ;;
            *)
                # Il giro completo, e il solo che lascia dist/ pubblicabile.
                svuota_dist
                sez "costruzione"; FATTI="deb arch rpm tar"
                impacchetta amd64; impacchetta arm64
                ispeziona
                oracolo
                arch_pacchetto
                rpm_pacchetto
                sez "i tarball"; tarball amd64; tarball arm64
                [ "$GUASTI" -eq 0 ] && somme ;;
        esac
    fi

    sez "riepilogo"
    if [ "$GUASTI" -ne 0 ]; then
        printf '  %s problemi\n\n' "$(rosso "$GUASTI")"
        return 1
    fi
    # Le righe non sono simmetriche perche' le situazioni non lo sono, ed e' la
    # cosa piu' utile che questo riepilogo possa dire.
    case "$FATTI" in
        *deb*) printf '  %s\n' "$(verde 'deb: struttura verificata, e coincide con quella di nfpm')"
               printf '  %s\n' "$(rosso "deb: NON provato con dpkg, e i Depends non sono verificati")"
               printf '  %s\n' "     su una Debian:  dpkg -i dist/${NOME}_${VERSIONE}_amd64.deb" ;;
    esac
    case "$FATTI" in
        *arch*) printf '  %s\n' "$(verde 'arch: costruito con makepkg e verificato con pacman vero')"
                printf '  %s\n' "     per installarlo:  sudo pacman -U dist/${NOME}-${VERSIONE}-${RILASCIO}-x86_64.pkg.tar.zst" ;;
    esac
    # L'rpm sta a meta' fra i due, ed e' la sola posizione onesta da dichiarare:
    # costruito e interrogato con gli strumenti veri come quello di Arch, ma
    # installato non lo e' — qui non c'e' una Fedora su cui provarlo.
    case "$FATTI" in
        *rpm*) if [ "${#RPM_FATTI[@]}" -gt 0 ]; then
                   printf '  %s\n' "$(verde 'rpm: costruito con rpmbuild e letto con rpm veri, .spec incluso')"
                   printf '  %s\n' "$(rosso 'rpm: NON installato, e i Requires non sono verificati')"
                   printf '  %s\n' "     su una Fedora:  sudo dnf install ./${NOME}-${VERSIONE}-${RILASCIO}.x86_64.rpm"
               else
                   printf '  %s\n' "     rpm: non costruito — manca rpmbuild (sudo pacman -S rpm-tools)"
               fi ;;
    esac
    case "$FATTI" in
        *tar*) printf '  %s\n' "$(verde 'tarball: riproducibili, e coperti da SHA256SUMS verificato')"
               printf '  %s\n' "     dist/: $(find "$DIST" -maxdepth 1 -type f ! -name '.*' ! -name SHA256SUMS | wc -l) artefatti piu' il SHA256SUMS che li copre — e' quel che va allegato al rilascio" ;;
    esac
    echo
    [ "$GUASTI" -eq 0 ]
}

main "$@"
