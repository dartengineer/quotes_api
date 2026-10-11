# Roadmap & Checklist

Status legend: `[x]` done and tested here, `[~]` done but needs on-device
verification, `[ ]` not started.

"Tested here" means `flutter analyze` and `flutter test` in CI-like
conditions (Linux, Flutter 3.47.7). Nothing has been run on an Android device
yet; see the risks section of [AUDIT.md](AUDIT.md).

## M1 - Foundation

- [x] Audit existing project ([AUDIT.md](AUDIT.md))
- [x] Remove the quotes demo (kept in git history) and stale template test
- [x] Package renamed to `lectern`; Android launcher label "Lectern"
- [x] Dependencies: material_ui, flutter_bloc, go_router, drift, drift_flutter
- [x] Lints: resource/async hygiene rules (`unawaited_futures`,
      `cancel_subscriptions`, `close_sinks`, ...), strict casts
- [x] Design system: spacing/radius/breakpoint tokens, brand seed colour,
      light + dark Material 3 themes, system theme mode
- [x] Shared widgets: loading / empty / error states, section header
- [x] Database schema v1: documents, reading positions, collections,
      memberships, bookmarks, annotations, reading sessions, preferences;
      indexes; foreign keys with cascades; CHECK constraints
- [x] Schema v1 snapshot for future migration tests (`drift_schemas/`)
- [x] Repositories: library (search, sort, filters, home sections),
      collections, settings
- [x] App shell: bottom navigation (phones) / navigation rail (tablets),
      per-tab navigation state
- [x] Home: continue reading, recently opened, recently added, empty state
- [x] Library: grid/list, sorting, lazily built tiles, empty/error states
- [x] Settings: theme (system/light/dark) persisted; licences page
- [x] Start-up error screen if the database cannot be opened
- [~] Android: cloud backup disabled for app data (device transfer allowed
      on Android 12+) - XML not yet validated by an Android build

## M2 - Import & Library management

- [x] Verified `file_picker` 13 on Android: SAF (`ACTION_OPEN_DOCUMENT`),
      picked documents are copied into the app cache and returned as paths;
      no storage permission is requested
- [x] Single and multiple file import via the system picker
- [x] Format detection by content (PDF header, EPUB zip structure, UTF-8 /
      UTF-16 / legacy-encoding text heuristics); unsupported formats are
      named (Word, MOBI, FB2, HTML, images, archives, ...) and not imported
- [x] Streaming SHA-256 + copy in one pass on a killable background
      isolate; picker temp copies are moved instead of copied twice;
      duplicate detection by content hash
- [x] App-private library directory; originals are never modified
- [x] Metadata: EPUB OPF title / authors (role-aware) / language /
      publisher / description; PDF page count; TXT title from file name
- [x] EPUB safety: zip-bomb caps enforced during decompression, path
      traversal ignored, DRM-encrypted and fixed-layout books rejected
      with a clear reason
- [~] PDF handling via PDFium (pdfrx): damaged files rejected,
      password-protected files imported without preview; verified with
      the host PDFium build in tests, not yet on a device
- [~] Cover thumbnails (EPUB cover image or PDF first page), decoded at
      reduced size and stored as bounded JPEGs; decode path verified in
      tests, rendering quality to be checked on a device
- [x] Import progress sheet with cancel; per-file summary with reasons
- [x] Library search (debounced, multi-word, Unicode case-insensitive)
      and filter chips (favourites, reading status)
- [x] Document details page: status, favourite, collections, description,
      file facts; remove from library (app copy only, with confirmation)
- [x] Multi-select: favourite, status, add to / remove from collection,
      remove from library
- [x] Collections tab: create, rename, delete, browse a collection
- [x] Home: import and search entry points; documents open details
- [ ] "Open with" / share intents from other apps (planned with M3)
- [ ] Opening a document to read (readers arrive in M3-M5)

## M3 - Reader core + TXT

- [ ] Locator model (pdf / epub / txt) with JSON round-trip tests
- [ ] Reader contract shared by all engines
- [ ] Debounced reading-position persistence + flush on pause/close
- [ ] Reading sessions and history
- [ ] Bookmarks (add, list, jump, delete)
- [ ] TXT: encoding detection, chunked lazy rendering for large files,
      character-offset positions
- [ ] Reader preferences (font size, line height, margins, paper/sepia/night)

## M4 - PDF (pdfrx)

- [ ] Continuous scrolling, zoom, page navigation, full-screen, landscape
- [ ] Page thumbnails, bounded caches, resource disposal
- [ ] Text search with result navigation
- [ ] Bookmarks by page; position restore
- [ ] Password-protected, corrupted and unsupported PDF handling
- [ ] Text selection

## M5 - EPUB (own engine, pending approval)

- [ ] Parser: container.xml, OPF manifest/spine, EPUB 2 NCX + EPUB 3 nav
- [ ] Safe XHTML subset to Flutter text blocks; images; internal links
- [ ] Table of contents, chapter navigation, typography settings
- [ ] Position restore by spine href + character offset
- [ ] Search, bookmarks
- [ ] Fixed-layout EPUBs detected and reported as unsupported

## M6 - Annotations

- [ ] Highlights and notes for TXT and EPUB (character ranges)
- [ ] PDF highlights as overlays from page text character ranges
- [ ] Annotation list, edit, delete, export

## M7 - Hardening

- [ ] On-device performance baselines (startup, library scroll, open time,
      memory) with DevTools / Android profiler
- [ ] Large-file and corrupt-file test corpus
- [ ] Integration tests on a device/emulator
- [ ] User-initiated backup/export and restore
- [ ] Release signing and final application ID (owner decision)
