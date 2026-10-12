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
- [x] "Open with" / share intents: done in M3 (see below)
- [x] Opening a document to read: TXT in M3, PDF in M4, EPUB in M5

## M3 - Reader core + TXT

- [x] Locator model (pdf / epub / txt) with JSON round-trip tests;
      undecodable stored positions are ignored, never crash the reader
- [x] Reader contract shared by all engines (`ReaderNavigator`, view
      controller, per-format engine registry); unsupported formats fall back
      to the details page
- [x] Reading-position persistence: throttled writes while reading, flush
      on pause and close; progress written on flush
- [~] Pause/resume via app lifecycle (logic tested; the Android lifecycle
      itself needs a device)
- [x] Reading sessions (5 s minimum) and total reading time on the details
      page
- [ ] Reading history view (sessions are recorded; no screen yet)
- [x] Bookmarks: add/remove at the visible position, list in reading
      order with excerpts, jump, delete
- [x] TXT engine: BOM detection, UTF-8 / UTF-16 / UTF-32, Windows-1252
      fallback, line-ending and control-character normalisation, 50 MB cap
- [x] TXT view: lazily built blocks around an anchor (jumps to the end of
      a large file do not lay out the whole text), exact character-offset
      positions that survive font and layout changes
- [~] TXT view performance on large files: verified by widget tests only,
      no device measurements yet
- [x] In-document search with context, jump and highlight
- [x] Tap zones (page back / forward, toggle toolbars), progress slider
- [~] Full-screen reading (system bars hidden until the page is tapped)
- [x] Reader preferences: font, size, line height, paragraph spacing,
      margins, justification, auto / paper / sepia / night themes
      (palette contrast tested against WCAG AA); saved globally
- [~] "Open with" (TXT) and "Share to Lectern" (PDF, EPUB): native bridge
      compile-checked against Android 16 and the Flutter embedding; its
      file-safety rules unit-tested on the JVM; the Dart side tested over a
      mocked channel. Needs a device check (no Android SDK here)
  - Only content:// URIs; no storage permission; sender-supplied names are
    reduced to a plain file name inside a fresh directory; 1 GB cap
  - Documents arriving during an import are queued, never dropped
  - "Open with" opens the document once imported (or the existing copy if
    it is already in the library); a single imported or duplicate document
    can be opened from the import summary
  - Temporary copies are deleted after import; leftovers older than an hour
    are removed at start-up
  - Android < 7 file managers that send file:// URIs are not supported
- [x] Fixed: the import sheet stayed open (empty) when the picker
      prepared files but returned none

## M4 - PDF (pdfrx)

- [x] Continuous vertical scrolling with fit-to-width pages, rendered
      lazily by pdfrx's `PdfViewer` (verified working under `flutter test`
      with the real PDFium build before building on it)
- [x] Exact position restore (page + fraction of the page, independent of
      zoom); the viewer's own initial placement centres short pages, so the
      saved position is applied explicitly
- [x] Rotation keeps the page and offset (tested by resizing the view)
- [x] Double-tap zoom in/out; [~] pinch zoom (pdfrx's, not exercised by a
      test)
- [x] Tap zones (scroll a screen back/forward, middle toggles toolbars);
      a tap first clears a text selection
- [x] Page numbers in the bottom bar; slider labelled by page
- [x] Go to page (validated), page thumbnails grid (lazy, rendered at
      ≤72 dpi, current page marked), contents from the PDF outline (current
      section marked; bounded and iterative against hostile outlines)
- [x] Text search: whitespace-tolerant (matches across line breaks),
      case-insensitive, results with context and page, jump and temporary
      highlight; superseded searches stop early
- [x] Bookmarks by page, with an excerpt of the page text
- [x] Password-protected PDFs: password prompt, retry on a wrong
      password, cancel shows an explanation with "Enter password". Passwords
      are never stored, logged or offered to autofill
- [x] Damaged PDFs are explained, with a retry
- [x] Page count recorded when a PDF imported without its password is
      first opened
- [x] Text selection: long press selects a word (pdfrx); [~] its copy
      menu is pdfrx's and not exercised by a test
- [x] Internal links jump within the document; web links are shown with a
      "Copy link" option and never opened (the app makes no network calls)
- [x] Reading settings show themes only for PDFs (typography does not
      apply to fixed pages)
- [x] "Open with" offered for PDFs (`application/pdf` in the intent
      filter)
- [~] Memory bounds: rendered page images capped at 64 MB (pdfrx cache
      limit), page texts kept for at most 24 pages; documents are released
      when the reader closes (pdfrx reference counting). Not measured on a
      device
- [~] Performance with large PDFs (hundreds of pages, scans): not measured
      on a device yet
- [ ] Night mode for page content (dark pages); the night theme currently
      darkens only the area around pages
- [ ] Search results for very large PDFs appear only once the whole
      document has been searched (no streaming or progress yet)

## M5 - EPUB (own engine)

- [x] Parser: container, OPF manifest/spine (linear reading order,
      duplicates skipped), EPUB 3 navigation document and EPUB 2 NCX
      contents (iterative, bounded in entries and depth)
- [x] XHTML reduced to a safe subset on a background isolate, with a
      streaming, lenient XML parser: paragraphs, headings, quotes, lists
      (numbered and bulleted, nested), preformatted text, captions, tables
      as text, rules, images (including SVG-wrapped covers), bold / italic /
      underline / strikethrough / monospace / small / super- and subscript.
      Scripts, styles, forms, frames and embedded objects are never shown
      or run; the book's CSS, fonts and colours are ignored in favour of the
      reader's typography
- [x] Hostile-content bounds: per-chapter (8 MB, 4 M characters) and
      per-book (40 M characters) limits with a visible notice when a book is
      cut short; tracked nesting depth capped; images read on demand
      (15 MB cap) and decoded no larger than the screen
- [x] Shared flow view for TXT and EPUB (extracted from the TXT reader;
      its tests guard the refactor): lazily built blocks anchored at the
      reading position, exact character-offset positions
- [x] Continuous scrolling across chapters, with extra space at chapter
      starts
- [x] Position restore by spine href + character offset; survives text
      size changes (re-anchored on the same character)
- [x] Table of contents with exact anchor offsets and the current section
      marked
- [x] Internal links (footnotes, cross-references) jump within the book;
      web links are shown with a copy option, never opened
- [x] Search across chapters (whitespace-tolerant), jump and highlight
- [x] Bookmarks with text excerpts
- [x] Typography settings apply (font, size, spacing, margins, justify,
      themes)
- [x] DRM-protected and damaged books explained in the reader
- [x] "Open with" offered for EPUBs (`application/epub+zip`)
- [x] Library: tapping any book opens it; details are reached by
      long-pressing a book and choosing "Details" (a single selection)
- [~] Performance: opening a 3.2-million-character book took 0.25-0.5 s on
      the development VM (debug mode); not measured on a device. The book's
      text model is held in memory while reading (bounded as above)
- [ ] Fixed-layout EPUBs: still rejected at import; the reader would show
      their pages as a sequence of images
- [ ] Footnotes as pop-ups (they are followed as links for now)
- [ ] Publisher styling beyond structure (alignment from CSS, drop caps,
      tables as grids) is not reproduced
- [ ] Inline images are shown as their own blocks

## M6 - Annotations

- [x] Annotation model: ranges stored as versioned JSON in the existing
      `annotations` table (no migration): character ranges as start/end
      locators for TXT and EPUB; for PDF, rectangles on each page in
      normalised page coordinates (stable whatever text extraction does),
      with the selected text kept alongside. Malformed rows are skipped,
      coordinates clamped, stored text and notes bounded (10,000 characters,
      never cutting a surrogate pair); annotations go with their document
- [x] TXT and EPUB: long-press selects a word, dragging extends the
      selection word by word (across paragraphs and chapters); then
      highlight in one of four colours, add a note, or copy
- [x] Highlights drawn translucently on every theme; a dotted underline
      marks a note; tapping highlighted text opens it (precise glyph hit
      test, like links)
- [x] PDF: pdfrx's selection (long-press, handles) gains "Highlight…";
      highlights are painted over the pages, a dot marks a note, tapping a
      highlight opens it
- [x] Respect for PDF permissions: when a PDF forbids copying text,
      neither "Highlight…" nor "Copy" is offered. pdfrx 2.6.5's own check
      reads the wrong permission bit (printing instead of copying), so the
      permission is read directly (PDF 32000-1, table 22, bit 5)
- [x] Edit a highlight: change colour, add or edit its note, copy it,
      delete it (with undo)
- [x] "Highlights & notes" list in reading order (colour, text, note,
      page or percentage); tapping one jumps to it
- [x] Export to Markdown through the system "save as" dialog (the user
      picks the place; no permission; nothing leaves the device otherwise)
- [ ] Selection handles for TXT/EPUB and selecting beyond the visible
      screen (selection is long-press and drag within the screen for now)
- [ ] Highlights in rotated PDF pages: drawing accounts for rotation, but
      tapping a highlight on a rotated page is untested
- [ ] Notes overview across the whole library

## M7 - Hardening

- [x] Uncaught errors (framework and asynchronous) are logged and handled
      instead of ending the app; release builds log only the error's type,
      never its message, which could hold document text or notes
- [x] Reading-data backup and restore (Settings, "Your data"): progress,
      positions, statuses, favourites, bookmarks, highlights and notes,
      reading history, collections, theme and reading settings, saved as
      versioned JSON where the user chooses. Books are not included; data
      finds its book again by the SHA-256 of the file, whatever it is
      called. Restoring merges and never deletes: favourites and statuses
      only move forward, a position replaces the library's only if it is
      newer, bookmarks and highlights are added unless already there, a
      highlight's newer note or colour is taken over, collections are
      matched by name. One transaction, so a failure changes nothing;
      restoring twice changes nothing the second time. A summary lists
      what changed and which books are missing from the library
- [x] Backups are treated as untrusted input: strict checks on the format,
      version and structure; invalid entries skipped and counted; text
      bounded as in the app; positions that do not fit the book's format
      refused; 32 MB limit, enforced when reading (before parsing) and when
      writing (a backup that could not be restored is never written)
- [~] The file picker's temporary copy of a backup (it holds the notes) is
      deleted right after reading; this is Android plugin behaviour that
      cannot be exercised here
- [x] Damaged-file corpus: valid EPUB, PDF, TXT, zip and backup samples,
      cut short, bit-flipped and partly scrambled with a fixed seed, run
      through import and the readers' loaders. It found and led to fixes
      for: a damaged PDF on which pdfrx 2.6.5 throws a `RangeError`
      (reported as a generic failure; now "damaged"; pdfrx's in-memory
      open path also frees memory twice in that case, which the app avoids
      by always opening files); cut-off EPUBs reported as "not supported"
      (now "damaged")
- [x] Text files larger than the reader can open (50 MB) are refused at
      import with that reason, instead of being imported and failing later
- [x] Layout at 320 dp width with text at 200%: every main screen, sheet
      and dialog is opened in a test that fails on any overflow. The note
      editor overflowed; all dialogs now scroll instead
- [~] Performance baselines on the development VM (debug mode) with an
      opt-in benchmark suite: see [PERFORMANCE.md](PERFORMANCE.md). Not
      device numbers
- [ ] On-device performance profiling (startup, library scroll, open time,
      memory) with DevTools / Android profiler
- [ ] Integration tests on a device/emulator
- [ ] Creating and restoring a backup for a very large library runs about a
      second of work on the UI isolate (see PERFORMANCE.md); move it to a
      background isolate if device profiling shows it matters
- [ ] Encrypted backups (a password) - backups are plain JSON today; the
      Settings screen says so
- [ ] Release signing and final application ID (owner decision)
