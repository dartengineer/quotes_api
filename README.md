# Lectern

An offline-first ebook and document reader for Android, built with Flutter.

> Status: foundation milestone (M1). Importing and reading documents are not
> implemented yet - see [docs/ROADMAP.md](docs/ROADMAP.md).

## Principles

- **Offline first.** Everything works without a network connection. The app
  makes no network calls.
- **Private.** Documents, reading progress and notes stay on the device. App
  data is excluded from Android cloud backup.
- **Honest about formats.** Only formats with a working, tested reader are
  advertised. Planned: PDF, EPUB (reflowable) and TXT.

## Architecture

Feature-first modules with Cubits (`flutter_bloc`), `go_router` navigation and
a SQLite database via `drift`. See [docs/AUDIT.md](docs/AUDIT.md) for the full
audit, dependency evaluation and design decisions.

```
lib/
  app/        app widget, router, shell, dependency wiring
  core/       theme tokens, shared widgets, utilities
  data/       database schema and migrations
  features/   home, library, collections, settings (reader engines to come)
```

## Development

Requires Flutter 3.47+ (Dart 3.13+).

```sh
flutter pub get
dart run build_runner build      # regenerate drift code after schema edits
flutter analyze
flutter test
```

### Database changes

1. Edit `lib/data/database/tables.dart`.
2. Bump `schemaVersion` in `app_database.dart` and add a migration step.
3. Run `dart run build_runner build` and
   `dart run drift_dev make-migrations` to snapshot the schema and generate
   migration tests under `test/drift/`.

## Platform support

Android is the only supported platform. Other platform folders are Flutter
scaffolding and are not built or tested.
