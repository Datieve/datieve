# Datieve — desktop app

Flutter + Rust FFI desktop app for Linux (macOS and Windows builds are untested but plausible).

## Build

Requires Flutter SDK and a Rust toolchain.

```sh
cd app-flutter
flutter build linux --release
```

The built binary lands in `build/linux/x64/release/bundle/`.
