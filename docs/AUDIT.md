# Project Audit & Architecture Plan

Audit date: 2026-10-11. Toolchain used for verification: Flutter 3.47.7 (stable),
Dart 3.13.5. Every package version and capability below was checked against
pub.dev metadata or the package source, not assumed.

## 1. Current state (before this work)

| Area | Finding |
| --- | --- |
| Purpose | A demo app ("api_testing") that downloads motivational quotes from a GitHub Pages JSON file. Unrelated to reading. |
| Size | 4 Dart files, ~166 lines (`main.dart`, `models/models.dart`, `services/service.dart`, `screens/homescreen.dart`). |
| Flutter / Dart | Created with a Flutter 3.32-era revision; `sdk: ^3.8.1`. |
| Dependencies | `http`, `cupertino_icons`; dev: `flutter_lints ^5`. |
| State management | `setState` only. |
| Navigation | None (`MaterialApp(home: ...)`). |
| Theme | Default seed-colour theme, no dark theme. |
| Database / storage | None. |
| Android | AGP 8.7.3, Kotlin 2.1.0, Gradle 8.12, Java 11. `minSdk`/`targetSdk` inherit Flutter defaults (Flutter 3.47: min 24, target/compile 36). `applicationId` `com.example.api_testing`. Release build signed with debug keys (template TODO). |
| Tests | One test: the untouched counter template. **It fails** (no counter exists, and the screen makes a real network call in tests). |
| `flutter analyze` | Clean. |

### Problems found in the existing code

1. **Release build cannot reach the network**: `INTERNET` is only declared in
   the debug manifest, so the quotes feature would silently fail in release.
2. `QuoteService.fetchQuotes` re-downloads the entire JSON file for every page
   of 10 quotes, including repeatedly once the end of the list is reached
   (the scroll listener keeps firing).
3. `_loadMoreQuotes` has no error handling: one failed request leaves
   `_isLoading` stuck at `true` (an unhandled async error) and can call
   `setState` after `dispose`.
4. The only test is stale and fails.
5. Placeholder identity (`com.example.*`, "Flutter Demo" title), release
   signing with debug keys.

### What is worth preserving

Nothing in the quotes feature is reusable for a reader (it is network-only,
and an offline-first reader should not ship an unrelated network feature).
The quotes code is removed; it remains in git history (`9898a36`). The
platform scaffolding (Android Gradle setup, Kotlin DSL) is kept and adjusted.

## 2. Recommended architecture

Feature-first modules, each with its own layers. Presentation never touches
SQL, files, or parsers directly.

```
lib/
  main.dart                  bootstrap: open DB, load settings, runApp
  app/                       App widget, router, dependency wiring
  core/
    theme/                   tokens (colour, spacing, radii, type), ThemeData, reader palettes
    widgets/                 shared states (empty / error / loading), section header, dialogs
    utils/                   debouncer, safe logging helpers
  data/database/             drift schema, migrations, generated code
  features/
    library/                 domain (Document, enums, sort/filter), repository, cubits, screens
    collections/             repository (+ UI in M2)
    settings/                repository, cubit, screen
    home/                    home cubit + screen
    import/          (M2)    picker, format sniffing, hashing, copy, metadata, thumbnails
    reader/
      common/        (M3)    locators, debounced progress saving, bookmarks, reader chrome
      txt/ pdf/ epub/(M3-M5) one reader per engine, behind a shared contract
```

* **State management**: `flutter_bloc` (Cubits). Repositories are injected with
  `RepositoryProvider`; no service locator.
* **Routing**: `go_router` with a `StatefulShellRoute` (bottom bar on phones,
  navigation rail on tablets); readers are full-screen routes above the shell.
* **Persistence**: SQLite via `drift` (type-safe queries, reactive streams for
  the home/library screens, real migrations, migration test tooling). drift
  runs SQLite on a background isolate, keeping queries off the UI isolate.
* **Material library**: Flutter 3.47 decoupled Material into the
  `material_ui` package; `package:flutter/material.dart` is now the legacy
  path. go_router 18 and pdfrx 2.6 already depend on `material_ui`, so the app
  uses it directly to avoid two incompatible `ThemeData` types.
* **Document storage model (recommended default)**: imported files are
  *copied* into app-private storage and identified by SHA-256 content hash.
  - Works with every Android document provider (Downloads, Drive, USB, cloud
    providers) via the system picker - no storage permission, no reliance on
    a filesystem path existing, no broken links when a persisted URI grant is
    revoked or the file moves.
  - The original file is never modified or deleted.
  - Trade-off: uses extra storage (one copy per book). The alternative -
    persisted SAF URI grants with in-place reading - avoids the copy but needs
    custom native code, PDFium cannot open `content://` URIs directly, and
    books disappear when the provider revokes access. Recommend copying now;
    "link instead of copy" can be added later for large files if needed.
* **Reading locations**: format-specific, font-independent locators stored as
  JSON (`pdf`: page + vertical fraction; `epub`: spine href + character
  offset + chapter progression; `txt`: character offset). Changing font size
  never invalidates a stored location.

## 3. Dependency evaluation

| Need | Choice | Version | Licence | Notes |
| --- | --- | --- | --- | --- |
| Material UI | `material_ui` | 1.6.0 | BSD-3 | Official, required by go_router 18 / pdfrx 2.6. |
| State | `flutter_bloc` / `bloc` | 9.1.1 / 9.2.1 | MIT | Flutter Favorite. |
| Routing | `go_router` | 18.0.2 | BSD-3 | Flutter Favorite, first-party. |
| Database | `drift` + `drift_flutter` | 2.35.2 / 0.3.1 | MIT | `sqlite3` 3.x bundles SQLite through native-asset hooks; `sqlite3_flutter_libs` is EOL and is not used. Verified working in tests here (SQLite 3.53.4). |
| Paths | `path_provider`, `path` | 2.1.6 / 1.9.1 | BSD-3 | First-party. |
| PDF (M4) | `pdfrx` | 2.6.5 | MIT (PDFium: BSD/Apache) | PDFium-based; file-path opening (no full load into memory), password provider, per-page text with character boxes (search + selection), links, async rendering of page regions. Renders existing PDF annotations but has **no API to author annotations into the file** -> highlights/notes will be stored in our DB and drawn as overlays. PDFium binaries are downloaded at **build time** via native-asset hooks (CI needs network to GitHub). |
| PDF (rejected) | `syncfusion_flutter_pdfviewer` | 35.x | Commercial / community licence | Licence terms unsuitable as a default. |
| PDF (rejected) | `pdfx` | 2.11 | MIT | Rendering only; weaker text/search support than pdfrx. |
| EPUB (M5) | Own parser on `archive` + `xml` + `html` | 4.5.1 / 7.1.0 / 0.15.7 | MIT / MIT / MIT | See below. |
| EPUB (rejected) | `flutter_epub_viewer` | 2.0.0 | BSD-3 | epub.js in a WebView via `flutter_inappwebview` (last release 2024-10). ~1.8k downloads/30 days. Runs a JS engine over untrusted book content; WebView memory cost; cannot be tested in unit tests. |
| EPUB (rejected) | `epub_view` / `epubx` | 3.3.0 / 4.0.0 | MIT | Low adoption; `epubx` unmaintained since 2023; limited location model. |
| Import (M2) | `file_picker` | 13.1.0 | MIT | System picker (SAF) - no storage permission. API to be verified against source in M2. |
| Hashing (M2) | `crypto` | 3.0.7 | BSD-3 | Streaming SHA-256 for duplicate detection. |
| TTS (later) | `flutter_tts` | 4.2.5 | MIT | Optional, evaluated when TTS is scheduled. |

### EPUB recommendation (decision needed before M5)

Parse EPUB 2/3 in pure Dart (OPF manifest/spine, NCX and EPUB 3 nav TOC) and
render chapters as native Flutter text, converting a safe subset of XHTML
(headings, paragraphs, emphasis, lists, block quotes, images, links, tables
as text) to lazily-built blocks.

* Pros: no scripting engine at all (imported books cannot execute code);
  locations are exact character offsets (stable across font changes); search
  and highlights work on the same text model; everything is unit-testable;
  low memory (one chapter at a time, lazy lists).
* Cons: complex CSS layouts (floats, multi-column, fixed-layout comics) are
  not reproduced faithfully. Fixed-layout EPUBs would be flagged as
  unsupported rather than shown broken.
* Alternative: WebView + epub.js gives better CSS fidelity and native
  pagination but adds a JS runtime over untrusted content, depends on a
  WebView plugin with slow maintenance, and is untestable outside a device.

### Formats

| Format | Plan | Status |
| --- | --- | --- |
| PDF | pdfrx | M4 |
| EPUB 2/3 (reflowable) | own engine | M5 |
| TXT | own reader, encoding detection (UTF-8/16 BOM, UTF-8 validation, Windows-1252 fallback) | M3 |
| HTML / XHTML | reuse EPUB XHTML renderer, scripts never executed | after M5 |
| FB2 | XML, feasible with the same renderer | evaluate after M5 |
| DOCX, MOBI/AZW, DJVU, CBZ | no reliable maintained Flutter engine identified | **not supported**; detected and reported as unsupported on import |

## 4. Major technical risks

1. **Device verification gap**: this cloud environment cannot download the
   Android SDK (`dl.google.com` is blocked by network policy), so APKs cannot
   be built or run here. Dart/Flutter analysis and tests run here; Android
   builds, PDF rendering and performance profiling must be verified on a real
   device. The Definition of Done item "tested on actual Android devices"
   requires the project owner.
2. **PDFium native binaries** are downloaded at build time (pdfrx). Offline or
   locked-down CI must mirror them.
3. **EPUB fidelity** with the native renderer (see trade-off above).
4. **Large documents**: big TXT files and very long EPUB chapters must be
   chunked and built lazily; PDF pages rendered on demand with a bounded
   cache. Needs on-device profiling to confirm.
5. **Storage duplication** from the copy-on-import model.
6. **App identity**: `applicationId` is still `com.example.api_testing`; the
   owner must choose a permanent ID before any store release (it cannot be
   changed after publishing).

## 5. Implementation phases

See [ROADMAP.md](ROADMAP.md) for the live checklist.

1. **M1 Foundation** - identity cleanup, dependencies, design system, database
   schema v1 + migration tooling, domain models, repositories, app shell,
   settings (theme), tests.
2. **M2 Import & Library** - picker, format detection, hashing/duplicates,
   copy, metadata, covers; library grid/list, sort/filter/search, favourites,
   status, details, multi-select, collections UI.
3. **M3 Reader core + TXT** - reader contract, debounced progress
   persistence, bookmarks, reading sessions/history, TXT reader.
4. **M4 PDF** - pdfrx viewer, thumbnails, search, bookmarks, zoom,
   full-screen, encrypted/corrupt handling.
5. **M5 EPUB** - parser, renderer, TOC, typography settings, themes, search,
   bookmarks.
6. **M6 Annotations** - highlights + notes for TXT/EPUB/PDF (DB-backed).
7. **M7 Hardening** - performance baselines on device, large-file tests,
   integration tests, backup/export.
