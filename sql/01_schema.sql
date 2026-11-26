-- =====================================================================
-- AutoAtlas — PostgreSQL schema (v0.3)
-- Safe to re-run: creates only what doesn't exist yet and never deletes data.
-- For a clean slate during development, run 00_reset.sql first.
-- Changes after the first install should be made as ALTER TABLE scripts (migrations).
--
-- Load order (foreign keys require it):
--   1. vehicles, fuel_product_map
--   2. vehicle_name_map, epa_variants, recalls, complaints, gas_prices
--   3. recall_vehicles, recall_risk_scores
--   quarantine_rows / pipeline_runs can be written at any time.
-- =====================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS autoatlas;

-- ---------------------------------------------------------------------
-- 1. vehicles — the hub. One row per cleaned (make, model, model_year).
--    vehicle_id is built in Polars as MAKE|MODEL|YEAR, e.g. 'HONDA|CR-V|2019'.
--    Note: correcting a canonical name later changes the ID, so all loaders
--    must share one normalization function and one aliases.csv.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoatlas.vehicles (
    vehicle_id     TEXT     PRIMARY KEY,
    make           TEXT     NOT NULL,
    model          TEXT     NOT NULL,
    model_year     SMALLINT NOT NULL CHECK (model_year BETWEEN 1984 AND 2100),
    vehicle_class  TEXT,                         -- most common EPA VClass, NULL if not in EPA
    in_epa         BOOLEAN  NOT NULL DEFAULT FALSE,
    in_nhtsa       BOOLEAN  NOT NULL DEFAULT FALSE,
    CONSTRAINT vehicle_id_matches_parts
        CHECK (vehicle_id = make || '|' || model || '|' || model_year::TEXT),
    CONSTRAINT names_are_clean
        CHECK (make = upper(btrim(make)) AND model = upper(btrim(model))),
    CONSTRAINT names_not_empty
        CHECK (make <> '' AND model <> ''),
    CONSTRAINT names_have_no_delimiter
        CHECK (position('|' IN make) = 0 AND position('|' IN model) = 0)
);

-- ---------------------------------------------------------------------
-- 2. vehicle_name_map — the "translator": how each source spelled a car.
--    Only successful matches live here; failures go to quarantine_rows
--    with reason = 'no_matching_vehicle' (see v_match_rate).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoatlas.vehicle_name_map (
    source        TEXT     NOT NULL CHECK (source IN ('EPA', 'NHTSA_RECALLS', 'NHTSA_COMPLAINTS')),
    source_make   TEXT     NOT NULL,
    source_model  TEXT     NOT NULL,
    model_year    SMALLINT NOT NULL,
    vehicle_id    TEXT     NOT NULL REFERENCES autoatlas.vehicles (vehicle_id),
    match_method  TEXT     NOT NULL CHECK (match_method IN ('exact', 'cleaned_exact', 'alias', 'fuzzy')),
    confidence    NUMERIC(4, 3) NOT NULL DEFAULT 1.000 CHECK (confidence BETWEEN 0 AND 1),
    PRIMARY KEY (source, source_make, source_model, model_year)
);
CREATE INDEX IF NOT EXISTS idx_name_map_vehicle ON autoatlas.vehicle_name_map (vehicle_id);

-- ---------------------------------------------------------------------
-- 3. epa_variants — one row per EPA configuration (engine/transmission/drive).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoatlas.epa_variants (
    epa_id                   INTEGER  PRIMARY KEY,         -- EPA "id"
    vehicle_id               TEXT     NOT NULL REFERENCES autoatlas.vehicles (vehicle_id),
    base_model               TEXT,                         -- "baseModel"
    engine_displ_l           NUMERIC(3, 1),                -- "displ"
    cylinders                SMALLINT,
    transmission             TEXT,                         -- "trany"
    drive                    TEXT,
    fuel_type                TEXT     NOT NULL,            -- "fuelType1", e.g. 'Regular Gasoline'
    fuel_type_2              TEXT,                         -- "fuelType2": 'Electricity' (PHEV), 'E85' (flex-fuel)
    powertrain               TEXT,                         -- "atvType": Hybrid, EV, Plug-in Hybrid, FFV, Diesel...
    vehicle_class            TEXT,                         -- "VClass"
    city_mpg                 NUMERIC(5, 1) CHECK (city_mpg     > 0),
    highway_mpg              NUMERIC(5, 1) CHECK (highway_mpg  > 0),
    -- EPA writes 0 for "not applicable" (e.g. combA08 on a non-flex car);
    -- cleaning must turn those zeros into NULL or the > 0 checks reject the row.
    combined_mpg             NUMERIC(5, 1) CHECK (combined_mpg > 0),  -- "comb08": MPG, or MPGe for EVs
    combined_mpg_alt         NUMERIC(5, 1) CHECK (combined_mpg_alt > 0), -- "combA08": fuelType2 economy
    combined_kwh_100mi       NUMERIC(5, 1) CHECK (combined_kwh_100mi > 0), -- "combE"
    electric_utility_factor  NUMERIC(4, 3) CHECK (electric_utility_factor BETWEEN 0 AND 1), -- "combinedUF"
    epa_annual_fuel_cost     INTEGER                       -- "fuelCost08" (national, 15k mi)
);
CREATE INDEX IF NOT EXISTS idx_epa_variants_vehicle ON autoatlas.epa_variants (vehicle_id);

-- ---------------------------------------------------------------------
-- 4. recalls — one row per recall campaign.
--    component lives in recall_vehicles (one CAMPNO can list several).
--    vehicles_affected (POTAFF) is a CAMPAIGN-wide total, not per model.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoatlas.recalls (
    campaign_number    TEXT    PRIMARY KEY,      -- CAMPNO, e.g. '13V454000'
    report_date        DATE    NOT NULL,         -- RCDATE
    vehicles_affected  INTEGER CHECK (vehicles_affected >= 0),  -- POTAFF (campaign total)
    influenced_by      TEXT,                     -- INFLUENCED_BY (e.g. 'ODI', 'MFR')
    summary            TEXT,                     -- DESC_DEFECT
    consequence        TEXT,                     -- CONEQUENCE_DEFECT
    remedy             TEXT                      -- CORRECTIVE_ACTION
);
CREATE INDEX IF NOT EXISTS idx_recalls_report_date ON autoatlas.recalls (report_date);

-- ---------------------------------------------------------------------
-- 5. recall_vehicles — link table: one recall x one car x one component.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoatlas.recall_vehicles (
    campaign_number  TEXT NOT NULL REFERENCES autoatlas.recalls  (campaign_number),
    vehicle_id       TEXT NOT NULL REFERENCES autoatlas.vehicles (vehicle_id),
    component        TEXT NOT NULL,              -- COMPNAME
    PRIMARY KEY (campaign_number, vehicle_id, component)
);
CREATE INDEX IF NOT EXISTS idx_recall_vehicles_vehicle ON autoatlas.recall_vehicles (vehicle_id);

-- ---------------------------------------------------------------------
-- 6. complaints — one row per complaint record (CMPLID).
--    One owner complaint (ODINO) can span several rows, one per component,
--    with crash/fire/injury/death values repeated on each row. Always
--    aggregate through v_complaints_dedup (one row per vehicle + ODINO).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoatlas.complaints (
    complaint_id   BIGINT   PRIMARY KEY,         -- CMPLID
    odi_number     BIGINT   NOT NULL,            -- ODINO
    vehicle_id     TEXT     NOT NULL REFERENCES autoatlas.vehicles (vehicle_id),
    component      TEXT,                         -- COMPDESC
    received_date  DATE     NOT NULL,            -- LDATE
    crash          BOOLEAN  NOT NULL DEFAULT FALSE,
    fire           BOOLEAN  NOT NULL DEFAULT FALSE,
    injuries       INTEGER  NOT NULL DEFAULT 0 CHECK (injuries >= 0),
    deaths         INTEGER  NOT NULL DEFAULT 0 CHECK (deaths   >= 0),
    miles          INTEGER  CHECK (miles >= 0)
);
CREATE INDEX IF NOT EXISTS idx_complaints_vehicle_date ON autoatlas.complaints (vehicle_id, received_date);
CREATE INDEX IF NOT EXISTS idx_complaints_received_date ON autoatlas.complaints (received_date);
CREATE INDEX IF NOT EXISTS idx_complaints_odi ON autoatlas.complaints (vehicle_id, odi_number);

-- ---------------------------------------------------------------------
-- 7. gas_prices — one row per week x region x fuel product (EIA).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoatlas.gas_prices (
    week_date          DATE          NOT NULL,   -- EIA "period"
    region_code        TEXT          NOT NULL,   -- EIA "duoarea" (verify codes against the API)
    region_name        TEXT          NOT NULL,   -- EIA "area-name"
    product_code       TEXT          NOT NULL,   -- EIA "product"
    product_name       TEXT          NOT NULL,
    price_usd_per_gal  NUMERIC(5, 3) NOT NULL CHECK (price_usd_per_gal > 0),
    PRIMARY KEY (week_date, region_code, product_code)
);
CREATE INDEX IF NOT EXISTS idx_gas_prices_latest
    ON autoatlas.gas_prices (region_code, product_code, week_date DESC);

-- ---------------------------------------------------------------------
-- 8. fuel_product_map — which EIA price applies to which EPA fuel type.
--    NULL product = no gasoline price applies (EVs, CNG...).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoatlas.fuel_product_map (
    epa_fuel_type     TEXT PRIMARY KEY,
    eia_product_code  TEXT
);
INSERT INTO autoatlas.fuel_product_map VALUES
    ('Regular Gasoline',  'EPMR'),
    ('Midgrade Gasoline', 'EPMM'),
    ('Premium Gasoline',  'EPMP'),
    ('Diesel',            'EPD2D'),
    ('Electricity',       NULL),
    ('Natural Gas',       NULL),
    ('E85',               NULL)
ON CONFLICT (epa_fuel_type) DO NOTHING;

-- ---------------------------------------------------------------------
-- 9. recall_risk_scores — ML output (Recall Radar).
--    recall_features (training table) is NOT created here: whether it lives
--    in Postgres or Parquet is a decision for the ML owner.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoatlas.recall_risk_scores (
    vehicle_id     TEXT          NOT NULL REFERENCES autoatlas.vehicles (vehicle_id),
    as_of_date     DATE          NOT NULL,
    risk_score     NUMERIC(4, 3) NOT NULL CHECK (risk_score BETWEEN 0 AND 1),
    model_version  TEXT          NOT NULL,
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT clock_timestamp(),  -- tie-breaker for "newest"
    PRIMARY KEY (vehicle_id, as_of_date, model_version)
);

-- ---------------------------------------------------------------------
-- 10. Data-quality / ops tables.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoatlas.pipeline_runs (
    run_id        BIGSERIAL   PRIMARY KEY,
    flow_name     TEXT        NOT NULL,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ,
    status        TEXT        NOT NULL CHECK (status IN ('running', 'success', 'failed')),
    rows_loaded   INTEGER     DEFAULT 0,
    rows_rejected INTEGER     DEFAULT 0
);

-- For unmatched vehicle names use reason = 'no_matching_vehicle' and put
-- source_make, source_model and model_year as keys in raw_record.
CREATE TABLE IF NOT EXISTS autoatlas.quarantine_rows (
    quarantine_id  BIGSERIAL   PRIMARY KEY,
    run_id         BIGINT      REFERENCES autoatlas.pipeline_runs (run_id),
    source         TEXT        NOT NULL,
    reason         TEXT        NOT NULL,
    raw_record     JSONB       NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_quarantine_source_reason ON autoatlas.quarantine_rows (source, reason);
CREATE INDEX IF NOT EXISTS idx_quarantine_run ON autoatlas.quarantine_rows (run_id);

COMMIT;
