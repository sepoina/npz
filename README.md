<!-- NOTA PER CHI MODIFICA (uomo o macchina): questo README sta entro le 800
     parole, ed è un limite, non una media. Chi aggiunge una sezione conta le
     parole (`wc -w README.md`) e, se sfonda, taglia altrove nello stesso
     passaggio. Il posto per approfondire è doc/, non questa pagina: qui si
     decide se provare npz, e quella decisione la si prende in due minuti.
     Stato attuale: ~600 parole. -->

# 🧊 npz

> node_modules without the node_modules

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.2.4-informational.svg)](progetto.conf)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#requirements)
[![Privileges](https://img.shields.io/badge/privileges-none-brightgreen.svg)](#requirements)

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

It all lives in **[doc/](doc/)**, indexed by
[doc/_index.md](doc/_index.md) — the documents, the map of the code, the benches
and the state of progress. In a hurry, read
[the travel journal](<doc/taccuino di viaggio.md>): the measurements that
dismantled, one after another, the ideas the project was born from. It is
written in Italian; this README is the English entry point.

## Status

Version **0.2.4**, under active development. The on-disk format is versioned —
`config` and every `.meta` carry a `version` field — so that today's images stay
readable when the format moves.

Licensed under the Apache License 2.0 — see [LICENSE](LICENSE).

[EROFS]: https://docs.kernel.org/filesystems/erofs.html
