# agent

Rust binary. Runs on the NAS, indexes folders you tell it to watch, serves a HTTPS API the desktop app talks to.

## build

```sh
cargo build --release --bin datieve
```

binary ends up at `target/release/datieve`

## run

```sh
./datieve serve
```

listens on `0.0.0.0:34514` by default. first-time setup (admin password, watched folders) happens from the desktop app.

config file is `config.json` in the working directory. pass `--config /path/to/config.json` to put it somewhere else. db and certs live next to the config.

```sh
./datieve --help
```

## notes

uses inotify for watching. on ZFS it uses snapshot diffs if it can.

to uninstall: delete the binary and the data directory. nothing written system-wide.
