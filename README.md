# LensDB

A lightweight native macOS app for **browsing and editing PostgreSQL and MySQL**
databases, local or in the cloud. No Electron, no bundled runtime: a single
sub-1 MB SwiftUI binary with **zero external dependencies**. It talks to each
server through the `psql` / `mysql` command-line clients you already have, so
there is no database driver to link or download.

## What it does

- **Many connections at once.** Open local sockets and cloud URLs (Neon,
  Supabase, RDS, PlanetScale) side by side, grouped into collapsible sections.
- **Browse.** Every database (with owner and on-disk size), then its tables,
  views, and materialized views grouped by schema, with estimated row counts and
  a filter box.
- **Query.** An editable SQL field at the top: tweak the generated `SELECT`, or
  run any query of your own (Cmd+Return to run). "Load more" paging built in.
- **Edit in place.** Double-click a cell to change it, or add new rows, then
  Save. LensDB writes the `UPDATE` / `INSERT` for you and matches rows by primary
  key. Nothing is written until you save. (Editing needs a primary key; keyless
  tables stay read-only.)
- **Faithful results.** NULL vs empty string is preserved, and big integers,
  decimals, and JSON columns render exactly (values come back as JSON, parsed
  with ordered keys and lossless numbers).
- **Light, Dark, or Auto.** Follows the system, or switch with one click.

### Cloud databases

Open the gear, fill in host / user / password / **database**, and turn on
**Require SSL/TLS** if your provider mandates it. For Postgres you can instead
paste the connection string your provider gives you
(`postgresql://user:pass@host:5432/db?sslmode=require`) and the rest is filled in
for you. Set the **Database** field for providers (Neon, Heroku, Render) that do
not expose a `postgres` admin database.

## Requirements

- macOS 14.4 or later
- The client for whichever engine you use, on disk (common paths auto-detected):
  - PostgreSQL: `psql` (`brew install postgresql`, or Postgres.app / EDB)
  - MySQL: `mysql` (`brew install mysql-client`)

## Build

### Xcode (recommended)

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonsm/XcodeGen) (`brew install xcodegen`):

```sh
cp Signing.xcconfig.example Signing.xcconfig   # then set your Apple Team ID (or leave blank to build unsigned)
xcodegen generate
open LensDB.xcodeproj
```

Your Team ID lives only in `Signing.xcconfig`, which is gitignored, so it never
gets committed. To ship a notarized build: Product, Archive, then Distribute App,
Developer ID.

### Command line

```sh
./build.sh          # compiles + packages an ad-hoc-signed LensDB.app
open LensDB.app
```

`./build.sh` is fine for running locally. Downloaded ad-hoc apps are blocked by
Gatekeeper, so use the Xcode Developer ID + notarize path for distribution.

## How it works

| Concern            | Approach |
|--------------------|----------|
| Engines            | Behind one `DatabaseService` protocol; `PostgresService` and `MySQLService` are the only engine-specific code |
| Connectivity       | Shells out to `psql` / `mysql` (`Subprocess.swift`), no driver to link, 10s connect timeout |
| Result fidelity    | Rows re-emitted as JSON (`row_to_json` / `JSON_OBJECT`) plus a small ordered JSON parser (`JSON.swift`) keeps column order, NULLs, and exact numbers |
| Editing            | `UPDATE` / `INSERT` generated with engine-correct quoting, rows matched by primary key (`AppModel.saveChanges`) |
| Databases / tables | Queried from `pg_catalog` (Postgres) / `information_schema` (MySQL) |
| UI                 | SwiftUI `NavigationSplitView` with a custom editable grid (`ContentView.swift`, `DetailView.swift`, `EditableResultsGrid.swift`) |

## Project layout

```
project.yml                XcodeGen spec (generates LensDB.xcodeproj)
Package.swift              SwiftPM manifest (for ./build.sh and swift run)
Info.plist                 app bundle metadata (command-line build)
build.sh                   compile + package into LensDB.app
Resources/Assets.xcassets  app icon
Sources/LensDB/
  LensDBApp.swift          @main entry + AppDelegate
  ContentView.swift        sidebar (connections + databases) + tables column
  DetailView.swift         SQL bar + results + settings sheet
  EditableResultsGrid.swift  inline-editable results grid
  AppModel.swift           observable state / actions / save logic
  DatabaseService.swift    engine-agnostic protocol + shared helpers
  PostgresService.swift    psql queries
  MySQLService.swift       mysql queries
  Subprocess.swift         async process runner
  Models.swift             data types + connection settings (+ URL parsing)
  JSON.swift               order-preserving JSON parser
```

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) to get set up
and build, and please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

MIT. See [LICENSE](LICENSE).
