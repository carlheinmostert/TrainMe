# Three surfaces, three independent versioning schemes

The Flutter trainer app (`pubspec.yaml` `X.Y.Z+N` + `mobile-v*` git tags), the web surfaces (git SHA + auto date-tag `v{YYYY-MM-DD}.{N}`), and the database (timestamp-named migration files) version independently. Deploy cadences are deliberately uncoupled: a web tweak shouldn't need a TestFlight upload, a schema migration shouldn't need a web rebuild, a TestFlight upload shouldn't need a schema change.
