#!/usr/bin/env python3
"""
lunrollhistory_import.py -- turn LunRollHistory's SavedVariables into a real database.

WoW addons cannot write files. Everything the addon records lands in
    WTF/Account/<ACCOUNT>/SavedVariables/LunRollHistory.lua
as a Lua table, written on logout or /reload. This script parses that file and
loads it into SQLite (or CSV), keyed so repeated runs accumulate history instead
of duplicating it -- which matters, because the in-game log is a rolling window
that prunes its oldest entries.

Several raiders' files can be imported into one database. Rolls carry a key
derived from the encounter, item, roller and roll value, which every witness
computes identically, so partial records from five clients merge into one
complete set rather than five overlapping ones.

Usage:
    python3 lunrollhistory_import.py ~/WoW/_retail_/WTF/Account/*/SavedVariables/LunRollHistory.lua
    python3 lunrollhistory_import.py LunRollHistory.lua --db rolls.sqlite --csv rolls.csv
"""

from __future__ import annotations

import argparse
import csv
import glob
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Lua parsing
# ---------------------------------------------------------------------------
# Blizzard's serializer emits a small, predictable subset: nested tables,
# ["key"] = value, bare array items, numbers, quoted strings, booleans, and
# "-- [n]" trailing comments. A full Lua parser would be overkill.

TOKEN_RE = re.compile(
    r"""
      (?P<ws>\s+)
    | (?P<longcomment>--\[(?P<eq>=*)\[.*?\](?P=eq)\])
    | (?P<comment>--[^\n]*)
    | (?P<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')
    | (?P<number>-?(?:0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?))
    | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
    | (?P<punct>[{}\[\]=,;])
    """,
    re.VERBOSE | re.DOTALL,
)

STRING_ESCAPES = {
    "n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b",
    "f": "\f", "v": "\v", "\\": "\\", '"': '"', "'": "'", "\n": "\n",
}


class LuaSyntaxError(ValueError):
    pass


def _unescape(raw: str) -> str:
    body = raw[1:-1]
    out, i = [], 0
    while i < len(body):
        ch = body[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        i += 1
        if i >= len(body):
            break
        nxt = body[i]
        if nxt in STRING_ESCAPES:
            out.append(STRING_ESCAPES[nxt])
            i += 1
        elif nxt == "x":
            out.append(chr(int(body[i + 1:i + 3], 16)))
            i += 3
        elif nxt.isdigit():
            j = i
            while j < len(body) and body[j].isdigit() and j - i < 3:
                j += 1
            out.append(chr(int(body[i:j])))
            i = j
        else:
            out.append(nxt)
            i += 1
    return "".join(out)


def tokenize(text: str):
    tokens, pos, end = [], 0, len(text)
    while pos < end:
        m = TOKEN_RE.match(text, pos)
        if not m:
            line = text.count("\n", 0, pos) + 1
            raise LuaSyntaxError(f"unexpected character {text[pos]!r} on line {line}")
        pos = m.end()
        kind = m.lastgroup
        if kind in ("ws", "comment", "longcomment", "eq"):
            continue
        value = m.group()
        if kind == "string":
            tokens.append(("string", _unescape(value)))
        elif kind == "number":
            if value.lower().startswith(("0x", "-0x")):
                tokens.append(("number", int(value, 16)))
            elif re.fullmatch(r"-?\d+", value):
                tokens.append(("number", int(value)))
            else:
                tokens.append(("number", float(value)))
        elif kind == "name":
            if value == "true":
                tokens.append(("boolean", True))
            elif value == "false":
                tokens.append(("boolean", False))
            elif value == "nil":
                tokens.append(("nil", None))
            else:
                tokens.append(("name", value))
        else:
            tokens.append(("punct", value))
    return tokens


class Parser:
    def __init__(self, tokens):
        self.tokens, self.i = tokens, 0

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else (None, None)

    def next(self):
        tok = self.peek()
        self.i += 1
        return tok

    def expect(self, value):
        kind, got = self.next()
        if got != value:
            raise LuaSyntaxError(f"expected {value!r}, got {got!r} at token {self.i}")

    def parse_value(self):
        kind, value = self.peek()
        if kind == "punct" and value == "{":
            return self.parse_table()
        if kind in ("string", "number", "boolean", "nil"):
            self.next()
            return value
        raise LuaSyntaxError(f"unexpected token {value!r} at position {self.i}")

    def parse_table(self):
        self.expect("{")
        result, array_index = {}, 1
        while True:
            kind, value = self.peek()
            if kind is None:
                raise LuaSyntaxError("unterminated table")
            if kind == "punct" and value == "}":
                self.next()
                break
            if kind == "punct" and value in (",", ";"):
                self.next()
                continue

            if kind == "punct" and value == "[":
                self.next()
                key = self.parse_value()
                self.expect("]")
                self.expect("=")
                result[key] = self.parse_value()
            elif kind == "name" and self.tokens[self.i + 1][1] == "=":
                self.next()
                self.next()
                result[value] = self.parse_value()
            else:
                result[array_index] = self.parse_value()
                array_index += 1
        return result


def parse_savedvariables(text: str) -> dict:
    """Returns {globalName: value} for every top-level assignment in the file."""
    tokens = tokenize(text)
    parser, out = Parser(tokens), {}
    while parser.i < len(tokens):
        kind, name = parser.next()
        if kind != "name":
            raise LuaSyntaxError(f"expected a global name, got {name!r}")
        parser.expect("=")
        out[name] = parser.parse_value()
    return out


def as_list(table) -> list:
    """Lua array part -> Python list. Missing/short tables yield []."""
    if not isinstance(table, dict):
        return []
    items, i = [], 1
    while i in table:
        items.append(table[i])
        i += 1
    return items


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS drops (
    account       TEXT NOT NULL,
    uid           INTEGER NOT NULL,
    ts            INTEGER,
    iso_time      TEXT,
    encounter_id  INTEGER,
    loot_list_id  INTEGER,
    encounter     TEXT,
    instance      TEXT,
    difficulty    TEXT,
    difficulty_id INTEGER,
    item_id       INTEGER,
    item_name     TEXT,
    item_link     TEXT,
    winner        TEXT,
    all_passed    INTEGER,
    tradeable     INTEGER,
    drop_key      TEXT,
    PRIMARY KEY (account, uid)
);

CREATE TABLE IF NOT EXISTS drop_rolls (
    account    TEXT NOT NULL,
    drop_uid   INTEGER NOT NULL,
    seq        INTEGER NOT NULL,
    roll_key   TEXT,
    player     TEXT,
    realm      TEXT,
    class      TEXT,
    guid       TEXT,
    roll_type  TEXT,
    roll       INTEGER,
    is_winner  INTEGER,
    PRIMARY KEY (account, drop_uid, seq),
    FOREIGN KEY (account, drop_uid) REFERENCES drops (account, uid)
);

CREATE TABLE IF NOT EXISTS manual_rolls (
    account   TEXT NOT NULL,
    uid       INTEGER NOT NULL,
    ts        INTEGER,
    iso_time  TEXT,
    player    TEXT,
    realm     TEXT,
    roll      INTEGER,
    low       INTEGER,
    high      INTEGER,
    encounter TEXT,
    instance  TEXT,
    difficulty TEXT,
    PRIMARY KEY (account, uid)
);

CREATE TABLE IF NOT EXISTS loot_events (
    account   TEXT NOT NULL,
    uid       INTEGER NOT NULL,
    ts        INTEGER,
    iso_time  TEXT,
    player    TEXT,
    realm     TEXT,
    item_id   INTEGER,
    item_name TEXT,
    item_link TEXT,
    quantity  INTEGER,
    encounter TEXT,
    instance  TEXT,
    difficulty TEXT,
    PRIMARY KEY (account, uid)
);

"""

# Applied after migration, because these reference columns an older database
# does not have until the ALTER statements have run.
INDEXES = """
CREATE INDEX IF NOT EXISTS idx_rolls_player ON drop_rolls (player);
-- The content key is what lets several raiders' exports merge into one set of
-- rows instead of one set per person. Partial where the addon predates keys,
-- so the index is not UNIQUE; de-duplication is done explicitly on import.
CREATE INDEX IF NOT EXISTS idx_rolls_key    ON drop_rolls (roll_key);
CREATE INDEX IF NOT EXISTS idx_drops_key    ON drops (drop_key);
CREATE INDEX IF NOT EXISTS idx_drops_item   ON drops (item_id);
CREATE INDEX IF NOT EXISTS idx_drops_ts     ON drops (ts);

CREATE VIEW IF NOT EXISTS v_rolls AS
SELECT d.iso_time, d.instance, d.difficulty, d.encounter,
       d.item_name, d.item_id, r.player, r.realm, r.class,
       r.roll_type, r.roll, r.is_winner
FROM drop_rolls r
JOIN drops d ON d.account = r.account AND d.uid = r.drop_uid;
"""


def migrate(conn: sqlite3.Connection) -> None:
    """Adds the key columns to a database created before they existed."""
    for table, column in (("drops", "drop_key"), ("drop_rolls", "roll_key")):
        cols = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
        if not cols:
            continue                      # table not created yet; nothing to alter
        if column not in cols:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} TEXT")
    conn.commit()


def dedupe_by_key(conn: sqlite3.Connection) -> int:
    """Collapses rows that several raiders recorded of the same roll.

    Keeps the row with the most information rather than an arbitrary one: a
    client that saw the player's name and class is a better record than one
    that only caught the roll value.
    """
    removed = conn.execute(
        """
        DELETE FROM drop_rolls
        WHERE roll_key IS NOT NULL
          AND rowid NOT IN (
              SELECT rowid FROM (
                  SELECT rowid,
                         ROW_NUMBER() OVER (
                             PARTITION BY roll_key
                             ORDER BY (player IS NOT NULL) DESC,
                                      (class  IS NOT NULL) DESC,
                                      (guid   IS NOT NULL) DESC,
                                      rowid
                         ) AS rank
                  FROM drop_rolls
                  WHERE roll_key IS NOT NULL
              )
              WHERE rank = 1
          )
        """
    ).rowcount
    conn.commit()
    return removed


def iso(ts):
    if not isinstance(ts, (int, float)):
        return None
    return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def account_from_path(path: str) -> str:
    parts = os.path.normpath(os.path.abspath(path)).split(os.sep)
    for i, part in enumerate(parts):
        if part.lower() == "account" and i + 1 < len(parts):
            return parts[i + 1]
    return os.path.basename(os.path.dirname(path)) or "unknown"


def flag(v):
    if v is None:
        return None
    return 1 if v else 0


def import_file(conn: sqlite3.Connection, path: str, verbose: bool = True) -> dict:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()

    globals_ = parse_savedvariables(text)
    # RollLedgerDB is the pre-rename global; still read it so old files import.
    db = globals_.get("LunRollHistoryDB") or globals_.get("RollLedgerDB")
    if not isinstance(db, dict):
        raise SystemExit(f"{path}: no LunRollHistoryDB table found")

    account = account_from_path(path)
    log = as_list(db.get("log"))
    counts = {"drop": 0, "roll": 0, "manualroll": 0, "loot": 0, "skipped": 0}
    cur = conn.cursor()

    for entry in log:
        if not isinstance(entry, dict):
            continue
        kind = entry.get("t")
        uid = entry.get("uid")
        if uid is None:
            counts["skipped"] += 1
            continue

        if kind == "drop":
            cur.execute(
                """INSERT OR REPLACE INTO drops VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (account, uid, entry.get("ts"), iso(entry.get("ts")),
                 entry.get("enc"), entry.get("list"), entry.get("encName"),
                 entry.get("inst"), entry.get("diff"), entry.get("diffID"),
                 entry.get("itemID"), entry.get("item"), entry.get("link"),
                 entry.get("winner"), flag(entry.get("allPassed")),
                 flag(entry.get("tradeable")), entry.get("key")),
            )
            counts["drop"] += 1
            cur.execute("DELETE FROM drop_rolls WHERE account=? AND drop_uid=?", (account, uid))
            for seq, roll in enumerate(as_list(entry.get("rolls")), start=1):
                if not isinstance(roll, dict):
                    continue
                cur.execute(
                    "INSERT OR REPLACE INTO drop_rolls VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    (account, uid, seq, roll.get("key"), roll.get("name"),
                     roll.get("realm"), roll.get("class"), roll.get("guid"),
                     roll.get("state"), roll.get("roll"), flag(roll.get("winner"))),
                )
                counts["roll"] += 1

        elif kind == "manualroll":
            cur.execute(
                "INSERT OR REPLACE INTO manual_rolls VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (account, uid, entry.get("ts"), iso(entry.get("ts")),
                 entry.get("name"), entry.get("realm"), entry.get("roll"),
                 entry.get("low"), entry.get("high"), entry.get("encName"),
                 entry.get("inst"), entry.get("diff")),
            )
            counts["manualroll"] += 1

        elif kind == "loot":
            cur.execute(
                "INSERT OR REPLACE INTO loot_events VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (account, uid, entry.get("ts"), iso(entry.get("ts")),
                 entry.get("name"), entry.get("realm"), entry.get("itemID"),
                 entry.get("item"), entry.get("link"), entry.get("qty"),
                 entry.get("encName"), entry.get("inst"), entry.get("diff")),
            )
            counts["loot"] += 1
        else:
            counts["skipped"] += 1

    conn.commit()
    if verbose:
        print(f"{path}\n  account={account}  drops={counts['drop']} "
              f"rolls={counts['roll']} manual={counts['manualroll']} "
              f"loot={counts['loot']} other={counts['skipped']}")
    return counts


def export_csv(conn: sqlite3.Connection, path: str) -> int:
    cur = conn.execute("SELECT * FROM v_rolls ORDER BY iso_time, item_name, roll DESC")
    rows = cur.fetchall()
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow([d[0] for d in cur.description])
        writer.writerows(rows)
    return len(rows)


def summarize(conn: sqlite3.Connection) -> None:
    q = conn.execute
    total_drops = q("SELECT COUNT(*) FROM drops").fetchone()[0]
    total_rolls = q("SELECT COUNT(*) FROM drop_rolls").fetchone()[0]
    manual = q("SELECT COUNT(*) FROM manual_rolls").fetchone()[0]
    print(f"\n{total_drops} drops, {total_rolls} rolls, {manual} manual rolls\n")

    rows = q("""
        SELECT player,
               COUNT(*) AS rolls,
               SUM(is_winner) AS wins,
               ROUND(AVG(roll), 1) AS avg_roll
        FROM drop_rolls
        WHERE player IS NOT NULL AND roll_type NOT IN ('Pass', 'NoRoll')
        GROUP BY player
        ORDER BY wins DESC, rolls DESC
        LIMIT 20
    """).fetchall()
    if rows:
        print(f"{'player':<20}{'rolls':>7}{'wins':>6}{'avg':>8}")
        print("-" * 41)
        for player, rolls, wins, avg in rows:
            print(f"{player:<20}{rolls:>7}{wins or 0:>6}{avg if avg is not None else '-':>8}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="LunRollHistory.lua SavedVariables file(s); globs allowed")
    ap.add_argument("--db", default="lunrollhistory.sqlite", help="SQLite file to write (default: %(default)s)")
    ap.add_argument("--csv", help="also write a flat CSV of every roll")
    ap.add_argument("--summary", action="store_true", help="print per-player roll statistics")
    ap.add_argument("--no-merge", action="store_true",
                    help="keep every raider's copy of a roll instead of merging on the content key")
    args = ap.parse_args(argv)

    paths = []
    for pattern in args.files:
        expanded = glob.glob(os.path.expanduser(pattern))
        paths.extend(expanded or ([pattern] if os.path.exists(pattern) else []))
    if args.files and not paths:
        print("no matching files", file=sys.stderr)
        return 1

    conn = sqlite3.connect(args.db)
    conn.executescript(SCHEMA)
    migrate(conn)
    conn.executescript(INDEXES)

    for path in paths:
        try:
            import_file(conn, path)
        except LuaSyntaxError as exc:
            print(f"{path}: could not parse ({exc})", file=sys.stderr)

    if paths and not args.no_merge:
        merged = dedupe_by_key(conn)
        if merged:
            print(f"merged {merged} duplicate rolls recorded by more than one raider")

    if args.csv:
        print(f"wrote {export_csv(conn, args.csv)} rows to {args.csv}")
    if args.summary or not paths:
        summarize(conn)

    conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
