#!/usr/bin/env bash
# Builds the database from scratch in an EMPTY test database, loads the sample
# rows, checks that re-running the setup scripts keeps the data, then runs the
# assertions. Usage:
#   DATABASE_URL=postgresql://user:pass@localhost:5432/autoatlas_test tests/run_tests.sh
# Never point this at a database with real data: step 1 deletes the schema.
set -euo pipefail
cd "$(dirname "$0")/.."
PSQL=(psql "${DATABASE_URL:?set DATABASE_URL to an empty test database}" -q -v ON_ERROR_STOP=1)

"${PSQL[@]}" -f sql/00_reset.sql
"${PSQL[@]}" -f sql/01_schema.sql -f sql/02_queries.sql
"${PSQL[@]}" -f tests/sample_data.sql

# Re-running setup must not drop or duplicate anything
before=$("${PSQL[@]}" -At -c "SELECT count(*) FROM autoatlas.complaints")
"${PSQL[@]}" -f sql/01_schema.sql -f sql/02_queries.sql
after=$("${PSQL[@]}" -At -c "SELECT count(*) FROM autoatlas.complaints")
[ "$before" = "$after" ] || { echo "FAIL re-running setup changed the data ($before -> $after rows)"; exit 1; }
echo "ok  re-running setup scripts keeps existing data"

"${PSQL[@]}" -f tests/test_db.sql
