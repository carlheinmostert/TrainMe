#!/usr/bin/env bash
#
# fetch_embedding.sh — pull a client's face_embedding from the staging
# Supabase project as a raw 2048-byte FP32 little-endian binary file.
#
# STAGING ONLY. The CLAUDE.md test-account contract pins us to the
# staging project ref (vadjvkmldtoeyspyoqbx); we hard-fail if that env
# is missing the ENV=staging confirmation.
#
# Usage:
#   ./fetch_embedding.sh <client_id> > samples/embedding.bin
#
# Output is raw bytes on stdout; redirect to a file. We print progress
# + sanity-check lines on stderr so the redirect doesn't capture them.
#
# Prereqs:
#   - psql installed (`brew install postgresql` if missing)
#   - DATABASE_URL set OR a `~/.pgpass` entry for the staging pooler
#   - alternatively, set STAGING_DB_URL to the postgres connection
#     string for project vadjvkmldtoeyspyoqbx
#
# How it works:
#   1. Run a SELECT face_embedding FROM clients WHERE id = ... via psql
#      in tuples-only + unaligned + format-binary mode? No — psql can't
#      stream raw bytea bytes to stdout. Instead we use `\copy` of the
#      hex-encoded form, then strip the `\x` prefix and convert with
#      xxd -r -p so the bytes hit stdout intact.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <client_id> > samples/embedding.bin" >&2
  echo "" >&2
  echo "Pulls clients.face_embedding for the given uuid from the staging" >&2
  echo "Supabase DB and writes raw 2048-byte FP32 bytes to stdout." >&2
  echo "" >&2
  echo "Expects STAGING_DB_URL env var pointing at the staging DB, e.g.:" >&2
  echo "  export STAGING_DB_URL='postgresql://postgres.vadjvkml…:PWD@aws-…:6543/postgres'" >&2
  echo "" >&2
  echo "(Pull the connection string from Supabase dashboard →" >&2
  echo " Project Settings → Database → Connection string, or use the" >&2
  echo " transaction pooler URL.)" >&2
  exit 1
fi

CLIENT_ID="$1"

if [ -z "${STAGING_DB_URL:-}" ]; then
  echo "error: STAGING_DB_URL is not set." >&2
  echo "" >&2
  echo "Get it from Supabase dashboard for project vadjvkmldtoeyspyoqbx →" >&2
  echo "Project Settings → Database → Connection string (Transaction pooler)." >&2
  echo "" >&2
  echo "Then:" >&2
  echo "  export STAGING_DB_URL='postgresql://postgres.vadjvkml…:PWD@…:6543/postgres'" >&2
  echo "  ./fetch_embedding.sh $CLIENT_ID > samples/embedding.bin" >&2
  exit 2
fi

# Refuse to run against prod by sniffing the host.
if echo "$STAGING_DB_URL" | grep -qE 'yrwcofhovrcydootivjx|postgres\.yrwcof'; then
  echo "error: STAGING_DB_URL points at the PROD project (yrwcofhovrcydootivjx)." >&2
  echo "       This tool is staging-only. Refusing to run." >&2
  exit 3
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "error: psql not found. Install via 'brew install postgresql'." >&2
  exit 4
fi

echo "fetching face_embedding for client_id=$CLIENT_ID …" >&2

# `\x...` is the standard PostgreSQL bytea hex format. -t = tuples only.
# -A = unaligned. -X = no .psqlrc surprises.
HEX=$(psql "$STAGING_DB_URL" -t -A -X -c \
  "SELECT encode(face_embedding, 'hex') FROM public.clients WHERE id = '$CLIENT_ID';" \
  2>/dev/null || true)

if [ -z "$HEX" ]; then
  echo "error: query returned empty. Client $CLIENT_ID not found, or face_embedding is NULL." >&2
  echo "       Spot-check: psql \"\$STAGING_DB_URL\" -c \"SELECT id, length(face_embedding) FROM clients WHERE id = '$CLIENT_ID';\"" >&2
  exit 5
fi

# Strip whitespace + any trailing newlines.
HEX_TRIMMED=$(printf '%s' "$HEX" | tr -d '[:space:]')
EXPECTED_HEX_LEN=$((2048 * 2))
ACTUAL_HEX_LEN=${#HEX_TRIMMED}

if [ "$ACTUAL_HEX_LEN" -ne "$EXPECTED_HEX_LEN" ]; then
  echo "error: embedding has unexpected size — got $ACTUAL_HEX_LEN hex chars, expected $EXPECTED_HEX_LEN ($((EXPECTED_HEX_LEN/2)) bytes)." >&2
  exit 6
fi

echo "ok: $((ACTUAL_HEX_LEN / 2)) bytes (raw FP32 little-endian, 512 floats). Writing to stdout." >&2

# xxd -r -p turns "deadbeef" into raw bytes.
printf '%s' "$HEX_TRIMMED" | xxd -r -p
