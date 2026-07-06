# Datieve Architecture

This document talks about the architecture of Datieve.

---

## Agent

The agent running on your NAS is written in Rust, providing fewer undefined behaviors than any comparable language while being performant.

It uses a SQLite database to store indexed metadata, which allows for instant searches and browsing.

It uses inotify to track filesystem changes, with a daily scheduled crawl for anything inotify misses.

> **Why not fanotify?** Requires root, and many Synology/QNAP NAS devices don't support it at all.

It uses `statx` to fetch file and folder metadata, with a `stat()` fallback for NAS with older kernels.

It stores all config files and metadata in a single folder of your choice. It allows you to delete, backup, or move the data without it littering your system.

---

## App

The app's UI is made in Flutter, with the backend written in Rust. The file manager frontend is heavily inspired by Dolphin, and the backend is heavily derived from Files.

The app too stores everything in a single folder.

---

## Agent <-> App Communication

Communication between these happens over LAN using TLS and certificate pinning.

The app asks for your access code. Because the codes are stored encrypted, verifying them is CPU-intensive, so each code has a temporary bearer token that works for a short amount of time.

The app stores both your access code and bearer token locally. It automatically uses your bearer token to let you login, and for other API calls.

When bearer token expires, it uses the access code to ask the agent for a new one. If the code is changed, the app stops trying and you need to enter the new code.
