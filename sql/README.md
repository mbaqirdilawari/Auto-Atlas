# AutoAtlas database (PostgreSQL)

Owners: Annemarie + Luel · v0.3 · due Sun Nov 29

## Files
| File | What it does |
|---|---|
| `sql/ERD.md` | Up-to-date ERD diagram (Mermaid, which GitHub renders) |
| `sql/00_reset.sql` | **Development only.** Deletes the whole `autoatlas` schema. Never run from Prefect. |
| `sql/01_schema.sql` | Creates the tables, keys, constraints and indexes. Safe to re-run, never deletes data, and runs as one transaction. |
| `sql/02_queries.sql` | Views and functions for fuel cost, recalls, complaints, comparison and data quality. Safe to re-run, and runs as one transaction: if anything fails, the old versions stay. It never uses CASCADE, so if you build a view on top of these, the rebuild stops with an error instead of deleting your view. Drop your view first, then re-create it afterwards. |
| `tests/sample_data.sql` | Made-up rows, each one built to test one rule (not real data) |
| `tests/test_db.sql` | 35 automated SQL assertions. Any failure stops the run with an error. |
| `tests/run_tests.sh` | Full test run: reset → build → load → re-run check (setup must keep the data) → the 35 assertions |

## Run
```bash
# Set up or update the real database (keeps existing data)
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/01_schema.sql -f sql/02_queries.sql

# Run the tests (EMPTY test database only; this deletes the schema first)
DATABASE_URL=postgresql://user:pass@localhost:5432/autoatlas_test tests/run_tests.sh
```
For CI, Luel can add a Postgres 16 service container to GitHub Actions and run `tests/run_tests.sh`. The script exits non-zero if any check fails.

## Load order (for the Prefect flow)
1. `vehicles` (`fuel_product_map` is filled in by the schema script)
2. `vehicle_name_map`, `epa_variants`, `recalls`, `complaints`, `gas_prices`
3. `recall_vehicles`, `recall_risk_scores`

## What the database expects from the cleaning step (Nada)
- `vehicle_id = MAKE|MODEL|YEAR`, uppercase and trimmed. Names can't be empty or contain `|`, and the database rejects IDs that don't match their parts. Every loader should use the same cleaning function and the same `aliases.csv`, because correcting a canonical name later changes the ID.
- NHTSA `Y`/`N` flags become booleans, and `YYYYMMDD` strings become `DATE`.
- EPA writes `0` when a value doesn't apply (for example `combA08`, `combE` or `combinedUF` on an ordinary gasoline car). Convert those zeros to NULL during cleaning. The database rejects zero MPG values.
- Keep vehicle rows only (`PROD_TYPE` / `RCLTYPECD = 'V'`).
- Rows that can't be matched to a car go to `quarantine_rows` with `reason = 'no_matching_vehicle'` and the keys `source_make`, `source_model` and `model_year` in `raw_record`. `v_match_rate` relies on this. A row with an unknown year (`9999`) gets `reason = 'missing_year'`.
- EPA columns to keep: `id, make, model, year, baseModel, displ, cylinders, trany, drive, fuelType1, fuelType2, atvType, VClass, city08, highway08, comb08, combA08, combE, combinedUF, fuelCost08`.

## Queries for the dashboard (Shahad)
```sql
-- Comparison screen: one row per car, in the order you pass them
SELECT * FROM autoatlas.compare_vehicles(ARRAY['HONDA|CR-V|2019','TOYOTA|RAV4|2019'], 'NUS', 12000);
-- Detail: each EPA version of the car, with a note explaining any missing cost
SELECT * FROM autoatlas.fuel_cost_by_variant('NUS', 12000) WHERE vehicle_id = 'HONDA|CR-V|2019';
-- Recall timeline
SELECT * FROM autoatlas.v_recall_history WHERE vehicle_id = 'HONDA|CR-V|2019' ORDER BY report_date DESC;
```
All objects carry the `autoatlas.` prefix, so they work from any connection with no `search_path` setup (this is tested).

**How to label things on the dashboard**
- "Average fuel cost" is an **unweighted** average across the EPA versions that have a price (each version's cost is in cents, and the average is rounded to dollars). It isn't weighted by how many of each version were sold. `n_priced_variants` / `n_variants` shows how many versions were included.
- EVs show efficiency in **MPGe** (`best_combined_mpge`), never in the MPG column. Their fuel cost is blank because electricity prices are out of scope.
- Plug-in hybrids have no full-cost figure. `fuel_cost_by_variant.all_gasoline_scenario_cost` assumes every mile is driven on gasoline. Label it "if driven only on gas", not as expected spending.
- 0 recalls means **no recalls found in the available data**, not that the car has never been recalled.
- Show `gas_price_week` and `complaints_data_as_of` so users can see how recent the data is.
- `associated_campaign_units` (in `v_recall_summary`) adds up each campaign's total affected vehicles across **all** models it covers. It is **not** the number of this model affected, so keep it off the comparison screen.

## Design decisions (changes from the first-draft ERD; `ERD.md` shows the current schema)
1. **`component` lives in `recall_vehicles`.** One recall campaign can list several components.
2. **`complaints.odi_number`:** one owner complaint can span several rows (one per component), with injuries and deaths repeated on each row. **All complaint counts go through `v_complaints_dedup`** (one row per vehicle + complaint), and the Recall Radar features should use it too, so the dashboard and the model count complaints the same way.
3. **New tables:** `gas_prices` (missing from the ERD) and `fuel_product_map` (premium-fuel cars get premium prices).
4. **New `epa_variants` columns:** `fuel_type_2`, `combined_mpg_alt`, `combined_kwh_100mi` and `electric_utility_factor`. These keep plug-in hybrid, EV and flex-fuel cars distinct.
5. **Fuel cost formula:** `annual_miles / combined_mpg × latest regional price for that fuel`. The default is 15,000 miles (EPA's assumption). Negative or missing mileage is rejected. Each version's cost is computed in cents, and the per-car min, average and max are rounded to whole dollars.
6. **Text key** `MAKE|MODEL|YEAR` instead of an integer: any loader can build it on its own, and it's the same every time the pipeline runs.
7. **The risk score is deterministic:** it takes the latest `as_of_date` for the requested model version. If no version is requested and two versions scored the same date, the most recently written one (`created_at`) wins, so version names don't need to sort correctly (`v10` vs `v9`).
8. **Separate reset script:** `01_schema.sql` never deletes anything, and schema changes after the first install should be `ALTER TABLE` scripts.

## Open team decisions
- [ ] **`recall_features` (Recall Radar training table):** store it in Postgres or as Parquet? This is for the ML owner to decide, so it isn't created here yet.
- [ ] Nada: will recalls and complaints come from the bulk flat files or the per-car API? The flat files are needed for history.

## Checks to run once the real data is loaded
- [ ] Check that POTAFF is the same on every row of a campaign.
- [ ] Check that CMPLID is unique, and see how often ODINO repeats.
- [ ] Check that injuries, deaths, crash and fire are repeated identically on rows that share an ODINO. If not, revisit the MAX / BOOL_OR in `v_complaints_dedup`.
- [ ] Check the EIA product codes (`EPMR`, `EPMM`, `EPMP`, `EPD2D`) and region (`duoarea`) codes against a real API response. The test data uses made-up codes.
- [ ] List every distinct EPA `fuelType1`, `fuelType2` and `atvType` value, and add any missing ones to `fuel_product_map`.
- [ ] Find out how each source writes missing, unknown and zero values (blank, `9999`, `0`).
- [ ] Measure the match rate (`v_match_rate`) and cross-source coverage (`v_source_coverage`).
- [ ] Check the date range each source covers. Recalls start in 2010 (`FLAT_RCL_POST_2010`), so consider starting all sources there.
- [ ] Make sure incremental loads use `INSERT ... ON CONFLICT` on the primary keys, so re-runs don't create duplicates.
- [ ] Run `EXPLAIN ANALYZE` on `compare_vehicles` and save the output for the report.

## Undercurrents: examples from the database layer
For the team's "Undercurrents of Data Engineering" README section. **Implemented** means it exists and is tested in this folder. **Planned** depends on a teammate's component; move it to Implemented once it actually works.

| Principle | Implemented (database layer) | Planned / depends on integration |
|---|---|---|
| **Scalability** | Indexes on every foreign key and on the date and latest-price lookups. The text `vehicle_id` needs no shared counter, so loaders can build IDs on their own, in parallel. | Heavy cleaning and matching in Polars before loading, incremental loads (`INSERT ... ON CONFLICT`, only new rows) in the Prefect flow, and `EXPLAIN ANALYZE` on the full NHTSA history |
| **Modularity** | Schema, queries and tests live in separate files. The functions give the dashboard a defined interface, so it doesn't need to touch tables directly. | The Streamlit dashboard actually calling those functions; ingestion, orchestration and dashboard in their own folders |
| **Reusability** | Parameterized functions (region, miles, vehicles). One de-duplicated complaints view serves every consumer. | ML features built from `v_complaints_dedup` |
| **Observability** | `v_match_rate`, `v_source_coverage` and data-date columns in `compare_vehicles` | Prefect writing to `pipeline_runs`, and a data-health page in Streamlit |
| **Data governance** | Canonical `vehicle_id`, `vehicle_name_map` with match method and confidence, and `quarantine_rows` with reasons. Constraints enforce the ID format. | `aliases.csv` reviewed through pull requests |
| **Reliability** | Primary keys, foreign keys and CHECK constraints. Setup scripts are safe to re-run and run as transactions, and reset is a separate step. 35 automated assertions plus a re-run check. | Tests running in GitHub Actions on every push |
| **Efficiency** | Indexes on hot paths. Recalls and complaints are aggregated once per campaign or complaint before joining. | `EXPLAIN ANALYZE` evidence on real data |
| **Security** | No credentials in the SQL; the connection comes from `DATABASE_URL` | EIA API key and database password in `.env` / GitHub Secrets, and a read-only role for the dashboard |
