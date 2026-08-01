#!/usr/bin/env python3
"""Emit the `supabase_migrations.schema_migrations` INSERT for one migration file.

WHY THIS EXISTS
---------------
The replay applies migration files with plain psql, which never writes the
migration ledger. That is fine until a migration *guards on the ledger* — the
pnbhs-crm cutover fence pattern refuses to apply unless its prerequisite is
registered with an exact body attestation:

    cardinality(sm.statements) = 3
    md5(array_to_string(sm.statements, E'\\n')) = '<expected>'

Without a ledger those migrations can never replay, so the gate reports a
failure that says nothing about the migrations themselves.

THE SPLITTING RULE — DERIVED, NOT GUESSED
-----------------------------------------
The attestation above is ground truth, so the rule was solved against it rather
than inferred from the CLI source. For the fence migration the only variant that
reproduces BOTH cardinality=3 and the expected md5 is:

  * split on top-level `;`, respecting '...' quotes and $tag$...$tag$ blocks
  * KEEP comments (they attach to the following statement)
  * DROP the trailing semicolon from each statement
  * strip surrounding whitespace per statement, discard empties

This matches `supabase db push` / the CLI. It deliberately does NOT match MCP
`apply_migration`, which strips comments — verified against two live prod rows,
where a 5-statement file was stored as 1 statement and an 11,888-byte body as
4,012. Migrations applied to prod via MCP therefore carry a DIFFERENT stored body
than this replay produces, so a ledger attestation can pass here and still fail
against prod. That divergence is a property of the two apply paths, not of this
script; see pnbhs-crm PNBHS-118.
"""
import hashlib
import os
import re
import sys


def split_statements(text):
    """Top-level `;` split, quote/dollar-quote aware. Comments preserved."""
    stmts, buf, i, n = [], [], 0, len(text)
    while i < n:
        ch = text[i]
        if text.startswith("--", i):                     # line comment: keep verbatim
            j = text.find("\n", i)
            j = n if j < 0 else j
            buf.append(text[i:j]); i = j; continue
        if text.startswith("/*", i):                     # block comment: keep verbatim
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            buf.append(text[i:j]); i = j; continue
        if ch == "'":                                    # string literal ('' escapes)
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2; continue
                    j += 1; break
                j += 1
            buf.append(text[i:j]); i = j; continue
        m = re.match(r"\$[A-Za-z_0-9]*\$", text[i:])     # dollar-quoted body
        if m:
            tag = m.group(0)
            j = text.find(tag, i + len(tag))
            j = n if j < 0 else j + len(tag)
            buf.append(text[i:j]); i = j; continue
        if ch == ";":
            stmts.append("".join(buf)); buf = []; i += 1; continue
        buf.append(ch); i += 1
    stmts.append("".join(buf))
    return [s.strip() for s in stmts if s.strip()]


def dollar_tag(body):
    """A $tag$ that cannot appear inside body."""
    tag = "$stmt$"
    k = 0
    while tag in body:
        k += 1
        tag = f"$stmt{k}$"
    return tag


def main():
    path = sys.argv[1]
    base = os.path.basename(path)
    m = re.match(r"^(\d+)_(.+)\.sql$", base)
    if not m:
        sys.stderr.write(f"register-migration: unparsable filename: {base}\n")
        return 1
    version, name = m.group(1), m.group(2)

    with open(path, "r", encoding="utf-8") as fh:
        stmts = split_statements(fh.read())
    if not stmts:
        return 0                                          # nothing to register

    parts = []
    for s in stmts:
        t = dollar_tag(s)
        parts.append(f"{t}{s}{t}")
    arr = ",\n  ".join(parts)

    # Idempotent: a re-registered version must not abort the replay.
    print("insert into supabase_migrations.schema_migrations (version, name, statements)")
    print(f"values ($v${version}$v$, $n${name}$n$, array[\n  {arr}\n]::text[])")
    print("on conflict (version) do nothing;")

    if os.environ.get("REGISTER_DEBUG"):
        joined = "\n".join(stmts)
        sys.stderr.write(
            f"  [ledger] {base}: n={len(stmts)} "
            f"md5={hashlib.md5(joined.encode()).hexdigest()}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
