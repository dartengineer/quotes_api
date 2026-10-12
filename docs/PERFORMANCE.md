# Performance notes

**These are not device numbers.** Everything below was measured in the
Flutter test VM (JIT compiler, debug mode) on the development container.
Release builds on a phone are compiled ahead of time and usually run pure
Dart work several times faster, but phones also have slower cores, less
memory and thermal limits. Treat these figures as a baseline for spotting
regressions on the same machine, not as a promise about a device.
On-device profiling is still open (see the M7 section of
[ROADMAP.md](ROADMAP.md)).

## How to reproduce

```sh
flutter test test/benchmarks --dart-define=BENCHMARK=true -r expanded
```

The benchmarks are skipped in normal test runs. Each figure is the median of
five runs after one warm-up run, except for staging and backup collection or
encoding (three runs) and restores (one run, since a restore changes the
database).

Machine: 4 vCPU Intel Xeon @ 2.80 GHz, 15 GB RAM, Linux, Flutter 3.47.7 /
Dart 3.13.5. Measured on 2026-10-12.

## Results

| What | Input | Median |
| --- | --- | --- |
| TXT: load (read, detect encoding, decode, split into blocks) | 22.3 MB, 400,000 lines | 1,564 ms |
| TXT: search for a rare term | same text | 70 ms |
| EPUB: parse every chapter into the text model | 40 chapters, 2.66 M characters | 291 ms |
| EPUB: same, on a background isolate including the transfer back | same book | 296 ms |
| EPUB: build the flow document from the parsed book | same book | 1 ms |
| Import: copy into app storage while hashing (SHA-256) | 50 MB | 1,448 ms |
| Backup: collect reading data from the database | 1,000 books, each with a position, 10 bookmarks, 20 highlights, 50 reading sessions | 1,280 ms |
| Backup: encode as JSON | same; 14.6 MB file | 690 ms |
| Backup: decode and validate a file | same file | 1,006 ms |
| Restore into a library that has the books but not the data | same; adds 20,000 highlights, 50,000 sessions | 1,375 ms |
| Restore the same backup again (nothing to add) | same | 1,407 ms |

## What runs where

- **Off the UI isolate:** format detection, hashing and copying at import,
  EPUB parsing, TXT loading and search, EPUB search, thumbnail encoding,
  and encoding and decoding backups (`Isolate.run`). Database queries run
  on drift's background isolate. PDF parsing and rendering run on pdfrx's
  PDFium worker.
- **On the UI isolate:** turning database rows into reading data when
  creating a backup, and the merge decisions when restoring one. For the
  large library above that is about one second during which the UI does not
  respond (the progress indicator on the Settings screen stalls). A
  typical library (tens of books, a few hundred highlights) takes a small
  fraction of that. Moving this work to a background isolate would remove
  the pause entirely if device profiling shows it matters.

## Observations

- **TXT loading is the slowest single step measured.** It runs on a
  background isolate, so the reader shows a spinner rather than freezing,
  but a 20 MB log takes about 1.5 s here. Files over 50 MB are refused at
  import, because the reader keeps the whole text in memory.
- **EPUB size is bounded.** Chapters are capped at 8 MB of markup or
  4 million characters each, and books at 40 million characters. Beyond
  that, a notice ends the book instead of memory growing without limit.
- **Hashing throughput** is about 35 MB/s here, in pure Dart in debug mode.
  It runs on a background isolate and can be cancelled. On a device it
  bounds how quickly very large PDFs import.
- **Backups are capped at 32 MB** both ways. The app reads nothing larger,
  and refuses to write a backup it could not restore. The heavy library
  above comes to 14.6 MB.
- **Restoring the same backup again is about as slow as the first
  restore.** The time goes into reading what the library already has, not
  into writing.

## Not measured yet (needs a device)

- Cold start to first frame, and to an interactive library.
- Scrolling the library grid with hundreds of covers (frame times).
- Opening and scrolling a large PDF; page rendering times at various zooms.
- Memory while reading the largest allowed EPUB and TXT files.
- Battery and thermal behaviour during long reading sessions.
