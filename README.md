# amalgame-database-sqlite

SQLite 3 binding for [Amalgame](https://github.com/amalgame-lang/Amalgame).
Vendored amalgamation, manifest-driven dispatch. No `libsqlite3-dev` package
required on any OS — the SQLite amalgamation ships in this repo under its
own public-domain dedication.

## Install

```bash
amc package add github.com/amalgame-lang/amalgame-database-sqlite@v0.2.1
# or via the curated index:
amc package add sqlite@v0.2.1
```

Requires **amc 0.5.4+** for precompile-on-install (v0.2.1+). Older
amc back to 0.5.0 still works — it ignores `precompile = true` and
falls back to the v0.5.2 lazy `/tmp` cache, paying the compile cost
on each fresh `amc test` instead of once at install.

Since v0.2.1 the package opts into **precompile-on-install** (amc
0.5.4+): the gcc pass on the SQLite amalgamation runs once during
`amc package add`, the resulting `.o` lives at
`~/.amalgame/packages/.../build/<platform>/SQLite-sqlite3.c.o`, and
every subsequent `amc test` / `amc build` reuses it instantly. Skip
it with `--no-precompile` for install-without-build batches.

## Surface

```amalgame
import Amalgame.Database.SQLite

class Program {
    public static void Main() {
        let db = SQLite.Open(":memory:")
        if (!SQLite.IsOpen(db)) {
            Console.WriteLine("connect failed: " + SQLite.LastError(db))
            return
        }

        SQLite.Exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        SQLite.Exec(db, "INSERT INTO users (name) VALUES ('Alice'), ('Bob')")

        let rows = SQLite.QueryAll(db, "SELECT id, name FROM users")
        // rows: List<List<string>>, every column rendered as text
        for i in 0..rows.Count() {
            let row: List<string> = rows.Get(i)
            Console.WriteLine(row.Get(0) + " : " + row.Get(1))
        }

        SQLite.Close(db)
    }
}
```

### v0.1.0 method surface

| Method | Returns | Notes |
|---|---|---|
| `SQLite.Open(path)` | `AmalgameSQLite*` | `":memory:"` for transient in-memory DB |
| `SQLite.Close(db)` | `void` | Idempotent |
| `SQLite.IsOpen(db)` | `bool` | Check before use |
| `SQLite.LastError(db)` | `string` | Empty on success |
| `SQLite.Exec(db, sql)` | `bool` | DDL / DML; multiple statements OK |
| `SQLite.QueryAll(db, sql)` | `List<List<string>>` | All columns as text |
| `SQLite.LastInsertId(db)` | `int` | Rowid of last `INSERT` |
| `SQLite.Changes(db)` | `int` | Rows affected by last `INSERT`/`UPDATE`/`DELETE` |

## Deferred to v2

Parameter binding via `?` placeholders, typed column accessors
(`row.AsInt(0)` / `row.AsBytes(2)`), prepared-statement reuse,
explicit transactions (`db.Begin` / `Commit` / `Rollback`).

## Building

This package is consumed via `amc add`. To build a user program:

```bash
amc -o myapp src/main.am
# the generated .c references the runtime header from this
# package's cache directory; gcc picks it up via the include path
# amc adds automatically. The vendored sqlite3.c is precompiled
# to .o once and linked.
```

## Threading

SQLite handles concurrency internally via threading-mode at
compile time; the bundled amalgamation is built with
`SQLITE_THREADSAFE=1` (the SQLite default), suitable for the
typical service-loop caller. No mutex on the binding's side —
`AmalgameSQLite` is single-owner and immutable past `SQLite.Open`.

## Licence

Apache-2.0 for the Amalgame binding code. The vendored SQLite
amalgamation (`runtime/Amalgame_Database/sqlite/sqlite3.{c,h}`)
is in the public domain by SQLite's own dedication — see
[`NOTICE.md`](NOTICE.md) for the full third-party licence audit.
