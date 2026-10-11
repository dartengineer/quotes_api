# Lectern

An offline-first ebook and document reader for Android, built with Flutter.

> Status: import, library management and readers for TXT (M3), PDF (M4)
> and EPUB (M5) are in place, including "Open with" and sharing from other
> apps. Annotations come next - see [docs/ROADMAP.md](docs/ROADMAP.md).

## Principles

- **Offline first.** Everything works without a network connection. The app
  makes no network calls.
- **Private.** Documents, reading progress and notes stay on the device. App
  data is excluded from Android cloud backup. No storage permission is
  requested: you pick files with the system picker (or send them from another
  app with "Open with" / share), and the app keeps its own copy; your
  original files are never modified.
- **Honest about formats.** Only formats with a working, tested reader are
  advertised: TXT, PDF and reflowable EPUB.
- **Safe with untrusted books.** EPUBs are read by Lectern's own engine:
  no scripts run, no web content loads, and every size is bounded.

## Architecture

Feature-first modules with Cubits (`flutter_bloc`), `go_router` navigation and
a SQLite database via `drift`. See [docs/AUDIT.md](docs/AUDIT.md) for the full
audit, dependency evaluation and design decisions.

```
lib/
  app/        app widget, router, shell, dependency wiring
  core/       theme tokens, shared widgets, utilities (zip, images, isolates)
  data/       database schema and migrations; private library storage
  engines/    format engines (EPUB, PDF inspection, TXT, shared text blocks)
  features/   home, library, collections, import, reader, settings

android/app/src/main/kotlin/   receives documents from other apps
```

## Development

Requires Flutter 3.47+ (Dart 3.13+).

```sh
flutter pub get
dart run build_runner build      # regenerate drift code after schema edits
flutter analyze
flutter test
```

The Android side has JVM unit tests for its file-safety rules
(`android/app/src/test/`); run them with `./gradlew :app:testDebugUnitTest`
from `android/` (needs the Android SDK).

PDF tests use the real PDFium engine. Its host build is downloaded by the
`pdfium_dart` build hook into `.dart_tool/` on the first `flutter test`; if it
is unavailable the PDF tests are skipped and say so.

### Database changes

1. Edit `lib/data/database/tables.dart`.
2. Bump `schemaVersion` in `app_database.dart` and add a migration step.
3. Run `dart run build_runner build` and
   `dart run drift_dev make-migrations` to snapshot the schema and generate
   migration tests under `test/drift/`.

## Platform support

Android is the only supported platform. Other platform folders are Flutter
scaffolding and are not built or tested.
