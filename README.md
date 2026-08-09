<!-- NOTA PER CHI MODIFICA (uomo o macchina).

     Questo README sta entro le 800 parole, ed è un limite, non una media. Si
     contano dalla prima intestazione in giù, che è dove comincia la pagina:

         sed -n '/^# /,$p' README.md | wc -w

     Così questa nota resta fuori dal conto. Un `wc` nudo la conterebbe, e
     boccerebbe un README che invece va benissimo.

     Chi aggiunge una sezione conta, e se sfonda taglia altrove nello stesso
     passaggio. Il posto per approfondire è doc/, non questa pagina — qui si
     decide se provare npz, e quella decisione si prende in due minuti.

     Nessun numero di versione scritto a mano: ce n'erano due, fermi alla 0.2.4
     mentre il progetto era alla 0.2.7. Ci pensa il badge dinamico.

     Attenzione, e ci si è già cascati: qui dentro non va scritta la sequenza
     che chiude un commento HTML. Un comando che la contenga chiude la nota
     dove capita, e tutto il resto finisce visibile in cima alla pagina. -->

# 🧊 npz

> node_modules without the node_modules

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/github/v/release/sepoina/npz?label=version)](https://github.com/sepoina/npz/releases/latest)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#requirements)
[![Privileges](https://img.shields.io/badge/privileges-none-brightgreen.svg)](#requirements)

![Before: a node_modules folder spilling thousands of files, 31,667 entries and
588 MiB. After: a single block under a dashed folder outline, 1 file and 234
MiB.](doc/img1/img1.png)

***`npz` is a Linux `npm` wrapper***. Every argument goes through to `npm`
untouched; it adds one thing — `node_modules` becomes a single compressed
[EROFS] image, read-only, mounted in its place with a writable delta on top. On
the reference fixture, **31,667 entries and 588 MiB** become a **234 MiB** image
in 1.74 s, and mounting costs 0.07 s.

The toolchain — `node`, `npx`, the bundlers, the language server — sees the tree
exactly as before. Traversal tools that stop at a filesystem boundary (`du -x`,
`find -xdev`, `rsync -x`, `tar --one-file-system`) stop paying for it **without
knowing anything about `npz`**: as a mount point, the folder is *more*
excludable than it was as a directory.

## Install

```bash
curl -fsSL https://github.com/sepoina/npz/releases/latest/download/install.sh | sh
```

It picks the native package where a package manager exists — so that removing
npz later is `pacman -R` and not `rm` — and installs the static binary where
none does, and verifies every download against `SHA256SUMS`. Read it first —
the better habit. The [release page](https://github.com/sepoina/npz/releases/latest)
also carries per-distribution commands.

## Quick start

```bash
cd my-project
npz install      # runs npm install, then asks once whether to freeze
npz status       # state, image size, delta size
npz bye          # unmount: back to the frozen state
npz hey          # mount again — 0.07 s
npz detach       # changed your mind: a plain folder, and .npz is gone
```

It asks **once**, and remembers a no. Everything else reaches `npm` unchanged —
and the inverse holds too: `npz -- attach` passes `attach` to npm.

| Command | Effect |
| --- | --- |
| `npz attach` | turn npz on for this project now, no questions asked |
| `npz hey` | mount what `attach` already built; never builds |
| `npz bye` | unmount, remove the folder, keep `.npz`: back to frozen |
| `npz status` | what state we are in, how big the image and the delta are |
| `npz compact` | force consolidation now, instead of waiting for the threshold |
| `npz detach` | materialise `node_modules` as a real folder, delete `.npz` |

`npz detach` is the way out, and without it the system does not get adopted:
nobody walks into a system you can only walk into.

## Requirements

**Linux only** — the design rests on EROFS and overlayfs, which are Linux
filesystems. **No privileges**: the stack mounts entirely in user space, and the
kernel path (`mount -t erofs` + `overlay`) is an optimisation for when root is
around, not a requirement.

You need `mkfs.erofs`, `erofsfuse`, `fuse-overlayfs`, `fusermount3`, plus `npm`
and `node`. On Arch and Manjaro: `erofs-utils`, `erofsfuse`, `fuse-overlayfs`,
`fuse3` — `erofsfuse` is a separate package.

The project must live on a medium that is writable, whose files belong to the
user, and that supports the execute bit. `npz` checks this before touching
anything, and when it refuses it prints the `fstab` line that fixes it.

## Building

```bash
cd npz_go/build && ./build.sh        # npz for this machine, into build/lavoro/
./build.sh tutti                     # also linux/amd64 and linux/arm64
```

Version, descriptions, maintainer, license and dependencies all live in
[progetto.conf](progetto.conf) and **nowhere else**: whoever cuts a release
touches that file and nothing more. Two implementations share it — `npz_go/`,
the one that gets built and packaged, and `npz_python/`.

Bumping `VERSIONE` there and pushing to `main` is the whole release procedure:
CI tags it, and GoReleaser publishes the binaries, the `.deb`, `.rpm` and Arch
packages, and a `SHA256SUMS` that covers them.

## Documentation

It all lives in **[doc/](doc/)**, indexed by [doc/_index.md](doc/_index.md). In
a hurry, read [the travel journal](<doc/taccuino di viaggio.md>): the
measurements that dismantled, one after another, the ideas the project was born
from. It is written in Italian; this README is the English entry point.

## Status

Under active development. The on-disk format is versioned — `config` and every
`.meta` carry a `version` field — so that today's images stay readable when the
format moves.

Licensed under the Apache License 2.0 — see [LICENSE](LICENSE).

[EROFS]: https://docs.kernel.org/filesystems/erofs.html
