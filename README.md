# npz

> node_modules without the node_modules

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.2.4-informational.svg)](progetto.conf)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#requirements)
[![Privileges](https://img.shields.io/badge/privileges-none-brightgreen.svg)](#requirements)

`npz` is an `npm` wrapper. It forwards every argument to `npm` untouched, and
reserves three behaviours of its own: it asks once whether to freeze
`node_modules`, freezes it into a compressed [EROFS] image mounted in its place,
and releases the mount with `npz bye`.

The dependency folder stops being tens of thousands of inodes and becomes **a
single file**, read-only, with a writable delta on top. On the reference
fixture: **31,667 entries and 588 MiB** become a **234 MiB** image in 1.74
seconds, and mounting costs 0.07 s.

The toolchain — `node`, `npx`, the bundlers, the language server — keeps seeing
the tree exactly as before. Traversal tools that know how to stop at a
filesystem boundary (`du -x`, `find -xdev`, `rsync -x`,
`tar --one-file-system`) stop paying for it **without knowing anything about
`npz`**: as a mount point, the folder is *more* excludable than it was as a
directory.

## Quick start

```bash
cd my-project
npz install      # runs npm install, then asks once whether to freeze
npz status       # what state we are in, image size, delta size
npz bye          # unmount: back to the frozen state
npz hey          # mount again — 0.07 s
npz detach       # changed your mind: a plain folder, and .npz is gone
```

## The commands

Everything else goes to `npm` unchanged — and the inverse holds too:
`npz -- attach` passes `attach` to npm.

| Command | Effect |
| --- | --- |
| `npz attach` | turn npz on for this project right now, no questions asked |
| `npz hey` | mount what `attach` already built; never builds |
| `npz bye` | unmount, remove the folder, keep `.npz`: back to the frozen state |
| `npz status` | what state we are in, how big the image is, how big the delta |
| `npz compact` | force consolidation now, instead of waiting for the threshold |
| `npz detach` | materialise `node_modules` as a real folder and delete `.npz` |

`npz detach` is the way out, and without it the system does not get adopted:
nobody walks into a system you can only walk into.

## Requirements

**Linux only.** The whole design rests on EROFS and overlayfs, which are Linux
filesystems; there is no macOS or Windows path, and there is not going to be
one.

`mkfs.erofs`, `erofsfuse`, `fuse-overlayfs`, `fusermount3`, plus `npm` and
`node`. On Arch and Manjaro: `erofs-utils`, `erofsfuse`, `fuse-overlayfs`,
`fuse3` — `erofsfuse` is a separate package.

**No privileges**: the stack mounts entirely in user space. The kernel path
(`mount -t erofs` + `overlay`) is an optimisation for when root is available,
not a requirement.

The project must live on a medium that is writable, whose files belong to the
user, and that supports the execute bit — `npz` checks this before touching
anything, and when it refuses it prints the `fstab` line that fixes it.

## Building

```bash
cd npz_go/build && ./build.sh        # npz for this machine, into build/lavoro/
./build.sh tutti                     # also linux/amd64 and linux/arm64
```

Version, descriptions, maintainer, licence and dependencies all live in
[progetto.conf](progetto.conf) and **nowhere else**: whoever cuts a release
touches that file and nothing more.

## Documentation

It lives in **[doc/](doc/)**, and the index is **[doc/_index.md](doc/_index.md)**:
the documents, the map of the code, the benches and the state of progress.

In a hurry? Read [the travel journal](<doc/taccuino di viaggio.md>) — the
measurements that dismantled, one after another, the ideas the project was born
from.

> **Note.** The documentation under `doc/` is written in Italian. This README is
> the English entry point; the design documents have not been translated.

## Status

`npz` is at **0.2.4** and under active development. The format is versioned —
`config` and every `.meta` carry a `version` field — precisely so that today's
images stay readable when the format moves.

Two implementations live in this repository: `npz_go/` (the one that gets built
and packaged) and `npz_python/`. They share [progetto.conf](progetto.conf) as
their single source of truth for the version.

## Licence

Apache License 2.0 — see [LICENSE](LICENSE).

[EROFS]: https://docs.kernel.org/filesystems/erofs.html
