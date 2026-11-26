-- =====================================================================
-- AutoAtlas — views and query functions (v0.3)
-- Every object is schema-qualified, so these work from any connection
-- (e.g. Streamlit) regardless of its search_path.
-- Safe to re-run: views/functions hold no data and are rebuilt each time.
--
-- Dashboard entry point:
--   SELECT * FROM autoatlas.compare_vehicles(
--       ARRAY['HONDA|CR-V|2019','TOYOTA|RAV4|2019'], 'NUS', 12000);
-- =====================================================================

-- One transaction: if any statement fails, nothing changes and the old
-- views/functions stay in place (run psql with -v ON_ERROR_STOP=1).
BEGIN;

-- Rebuild from scratch (needed when a function's output columns change).
-- No CASCADE: if a teammate has built a view on top of these, this fails
-- loudly instead of silently deleting their view.
DROP FUNCTION IF EXISTS autoatlas.compare_vehicles(TEXT[], TEXT, INTEGER, TEXT);
DROP FUNCTION IF EXISTS autoatlas.compare_vehicles(TEXT[], TEXT, INTEGER);
DROP FUNCTION IF EXISTS autoatlas.fuel_cost_by_vehicle(TEXT, INTEGER);
DROP FUNCTION IF EXISTS autoatlas.fuel_cost_by_variant(TEXT, INTEGER);
DROP FUNCTION IF EXISTS autoatlas.valid_miles(INTEGER);
-- Dependent views first, then the views they read from.
DROP VIEW IF EXISTS autoatlas.v_unmatched_nhtsa;
DROP VIEW IF EXISTS autoatlas.v_complaint_summary;
DROP VIEW IF EXISTS autoatlas.v_complaints_dedup;
DROP VIEW IF EXISTS autoatlas.v_recall_summary;
DROP VIEW IF EXISTS autoatlas.v_recall_history;
DROP VIEW IF EXISTS autoatlas.v_latest_gas_price;
DROP VIEW IF EXISTS autoatlas.v_match_method_distribution;
DROP VIEW IF EXISTS autoatlas.v_match_rate;
DROP VIEW IF EXISTS autoatlas.v_source_coverage;

-- ---------------------------------------------------------------------
-- Input guard: annual miles must be present and non-negative
-- ---------------------------------------------------------------------
CREATE FUNCTION autoatlas.valid_miles(p_miles INTEGER)
RETURNS INTEGER LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_miles IS NULL OR p_miles < 0 THEN
        RAISE EXCEPTION 'annual miles must be a non-negative number, got %', p_miles
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    RETURN p_miles;
END $$;

-- ---------------------------------------------------------------------
-- A. Latest weekly price per region and fuel product
-- ---------------------------------------------------------------------
CREATE VIEW autoatlas.v_latest_gas_price AS
SELECT DISTINCT ON (region_code, product_code)
       region_code, region_name, product_code, product_name,
       week_date, price_usd_per_gal
FROM   autoatlas.gas_prices
ORDER  BY region_code, product_code, week_date DESC;

-- ---------------------------------------------------------------------
-- B. Estimated annual fuel cost for every EPA configuration
--    cost = annual miles / combined MPG * latest regional price for that fuel
--    - EVs: no cost (electricity prices are out of scope); efficiency is MPGe.
--    - Plug-in hybrids: annual_fuel_cost is NULL because electric driving isn't
--      costed. all_gasoline_scenario_cost assumes EVERY mile is driven on
--      gasoline — a worst case, not the expected gasoline spend.
--    - Flex-fuel: priced on gasoline (fuelType1), and the note says so.
-- ---------------------------------------------------------------------
CREATE FUNCTION autoatlas.fuel_cost_by_variant(
    p_region_code  TEXT    DEFAULT 'NUS',      -- 'NUS' = U.S. average
    p_annual_miles INTEGER DEFAULT 15000)
RETURNS TABLE (
    vehicle_id          TEXT,
    epa_id              INTEGER,
    variant             TEXT,
    fuel_type           TEXT,
    powertrain          TEXT,
    combined_efficiency NUMERIC,
    efficiency_unit     TEXT,      -- 'MPG' or 'MPGe' — never compare across units
    price_week          DATE,
    price_usd_per_gal   NUMERIC,
    annual_fuel_cost    NUMERIC,   -- complete estimate only; NULL otherwise
    all_gasoline_scenario_cost NUMERIC,   -- plug-in hybrids only
    cost_note           TEXT)
LANGUAGE sql STABLE AS $$
    WITH input AS (SELECT autoatlas.valid_miles(p_annual_miles) AS miles),
    base AS (
        SELECT e.*,
               (e.fuel_type = 'Electricity')                              AS is_ev,
               coalesce(e.powertrain = 'Plug-in Hybrid'
                        OR e.fuel_type_2 = 'Electricity', FALSE)          AS is_phev,
               m.epa_fuel_type IS NOT NULL                                AS fuel_mapped,
               m.eia_product_code,
               p.week_date, p.price_usd_per_gal,
               i.miles / e.combined_mpg * p.price_usd_per_gal             AS raw_cost
        FROM   autoatlas.epa_variants e
        CROSS  JOIN input i
        LEFT   JOIN autoatlas.fuel_product_map m ON m.epa_fuel_type = e.fuel_type
        LEFT   JOIN autoatlas.v_latest_gas_price p
               ON  p.product_code = m.eia_product_code
               AND p.region_code  = p_region_code
    )
    SELECT b.vehicle_id,
           b.epa_id,
           concat_ws(' / ', b.engine_displ_l || 'L', b.cylinders || ' cyl',
                     b.transmission, b.drive),
           b.fuel_type,
           b.powertrain,
           b.combined_mpg,
           CASE WHEN b.is_ev THEN 'MPGe' ELSE 'MPG' END,
           b.week_date,
           b.price_usd_per_gal,
           CASE WHEN b.is_ev OR b.is_phev THEN NULL ELSE round(b.raw_cost, 2) END,
           CASE WHEN b.is_phev THEN round(b.raw_cost, 2) END,
           CASE
               WHEN b.is_ev                      THEN 'electric vehicle: electricity cost not estimated'
               WHEN b.combined_mpg IS NULL       THEN 'missing combined MPG in EPA data'
               WHEN NOT b.fuel_mapped            THEN 'fuel type not mapped to an EIA price'
               WHEN b.eia_product_code IS NULL   THEN 'no EIA gasoline price for this fuel type'
               WHEN b.price_usd_per_gal IS NULL  THEN 'no price for this fuel in this region'
               WHEN b.is_phev                    THEN 'plug-in hybrid: all-gasoline driving scenario only; electric driving not costed'
               WHEN b.fuel_type_2 = 'E85'        THEN 'flex-fuel: priced on gasoline'
           END
    FROM base b;
$$;

-- ---------------------------------------------------------------------
-- C. Fuel cost rolled up to one row per car (make + model + year).
--    avg is an UNWEIGHTED average of the priced configurations' costs
--    (not sales-weighted). Variant costs are in cents; min/avg/max are then
--    rounded to whole dollars. MPG and MPGe are reported separately.
-- ---------------------------------------------------------------------
CREATE FUNCTION autoatlas.fuel_cost_by_vehicle(
    p_region_code  TEXT    DEFAULT 'NUS',
    p_annual_miles INTEGER DEFAULT 15000)
RETURNS TABLE (
    vehicle_id            TEXT,
    n_variants            BIGINT,
    n_priced_variants     BIGINT,
    best_combined_mpg     NUMERIC,
    best_combined_mpge    NUMERIC,
    min_annual_fuel_cost  NUMERIC,
    avg_annual_fuel_cost  NUMERIC,
    max_annual_fuel_cost  NUMERIC,
    price_week            DATE)
LANGUAGE sql STABLE AS $$
    SELECT f.vehicle_id,
           count(*),
           count(f.annual_fuel_cost),
           max(f.combined_efficiency) FILTER (WHERE f.efficiency_unit = 'MPG'),
           max(f.combined_efficiency) FILTER (WHERE f.efficiency_unit = 'MPGe'),
           round(min(f.annual_fuel_cost), 0),
           round(avg(f.annual_fuel_cost), 0),
           round(max(f.annual_fuel_cost), 0),
           max(f.price_week) FILTER (WHERE f.annual_fuel_cost IS NOT NULL)
    FROM   autoatlas.fuel_cost_by_variant(p_region_code, p_annual_miles) f
    GROUP  BY f.vehicle_id;
$$;

-- ---------------------------------------------------------------------
-- D. Recall history summary — one row per car.
--    A recall_count of 0 means "no recalls found in the available data",
--    not "never recalled".
--    associated_campaign_units sums each campaign's POTAFF. POTAFF is a
--    campaign-wide total across all models it covers, and one vehicle can be
--    in several campaigns — so this is NOT a count of affected units of this
--    model. Keep it off the comparison screen.
-- ---------------------------------------------------------------------
CREATE VIEW autoatlas.v_recall_summary AS
WITH per_campaign AS (            -- collapse the component rows first
    SELECT rv.vehicle_id, r.campaign_number, r.report_date, r.vehicles_affected,
           r.influenced_by,
           string_agg(DISTINCT rv.component, '; ') AS components
    FROM   autoatlas.recall_vehicles rv
    JOIN   autoatlas.recalls r USING (campaign_number)
    GROUP  BY rv.vehicle_id, r.campaign_number, r.report_date,
              r.vehicles_affected, r.influenced_by
)
SELECT v.vehicle_id,
       count(pc.campaign_number)                               AS recall_count,
       count(pc.campaign_number) FILTER (WHERE pc.influenced_by = 'ODI')
                                                               AS nhtsa_influenced_count,
       min(pc.report_date)                                     AS first_recall_date,
       max(pc.report_date)                                     AS latest_recall_date,
       sum(pc.vehicles_affected)                               AS associated_campaign_units,
       string_agg(pc.components, '; ' ORDER BY pc.report_date) AS components_recalled
FROM   autoatlas.vehicles v
LEFT   JOIN per_campaign pc USING (vehicle_id)
GROUP  BY v.vehicle_id;

-- Recall timeline for one car (dashboard detail table)
CREATE VIEW autoatlas.v_recall_history AS
SELECT rv.vehicle_id, r.campaign_number, r.report_date,
       string_agg(rv.component, '; ' ORDER BY rv.component) AS components,
       r.vehicles_affected AS campaign_units_affected,
       r.influenced_by, r.summary, r.remedy
FROM   autoatlas.recall_vehicles rv
JOIN   autoatlas.recalls r USING (campaign_number)
GROUP  BY rv.vehicle_id, r.campaign_number, r.report_date,
          r.vehicles_affected, r.influenced_by, r.summary, r.remedy;

-- ---------------------------------------------------------------------
-- E. Complaints, de-duplicated to one row per vehicle + ODI complaint.
--    Shared definition for the dashboard AND the Recall Radar features.
--    Crash/fire/injury/death values repeat on each component row, so take
--    BOOL_OR / MAX (verify against the real file — see README checklist).
-- ---------------------------------------------------------------------
CREATE VIEW autoatlas.v_complaints_dedup AS
SELECT vehicle_id,
       odi_number,
       min(received_date)                         AS received_date,
       bool_or(crash)                             AS crash,
       bool_or(fire)                              AS fire,
       max(injuries)                              AS injuries,
       max(deaths)                                AS deaths,
       max(miles)                                 AS miles,
       count(*)                                   AS component_rows,
       string_agg(DISTINCT component, '; ')       AS components
FROM   autoatlas.complaints
GROUP  BY vehicle_id, odi_number;

-- Last-12-month window is relative to the newest complaint in the table,
-- returned as complaints_data_as_of so stale data is visible.
CREATE VIEW autoatlas.v_complaint_summary AS
WITH ref AS (SELECT max(received_date) AS as_of FROM autoatlas.complaints)
SELECT v.vehicle_id,
       count(c.odi_number)                                        AS complaints_total,
       count(c.odi_number) FILTER (
           WHERE c.received_date > ref.as_of - INTERVAL '12 months') AS complaints_12m,
       count(c.odi_number) FILTER (WHERE c.crash)                 AS crash_complaints,
       count(c.odi_number) FILTER (WHERE c.fire)                  AS fire_complaints,
       coalesce(sum(c.injuries), 0)                               AS injuries,
       coalesce(sum(c.deaths), 0)                                 AS deaths,
       ref.as_of                                                  AS complaints_data_as_of
FROM   autoatlas.vehicles v
CROSS  JOIN ref
LEFT   JOIN autoatlas.v_complaints_dedup c USING (vehicle_id)
GROUP  BY v.vehicle_id, ref.as_of;

-- ---------------------------------------------------------------------
-- F. The comparison query the dashboard needs: one row per selected car.
--    Risk score: latest as_of_date for the given model version. If no version
--    is given and several versions scored the same date, the one written most
--    recently (created_at) wins — no reliance on how versions are named.
-- ---------------------------------------------------------------------
CREATE FUNCTION autoatlas.compare_vehicles(
    p_vehicle_ids   TEXT[],
    p_region_code   TEXT    DEFAULT 'NUS',
    p_annual_miles  INTEGER DEFAULT 15000,
    p_model_version TEXT    DEFAULT NULL)
RETURNS TABLE (
    vehicle_id             TEXT,
    make                   TEXT,
    model                  TEXT,
    model_year             SMALLINT,
    n_variants             BIGINT,
    n_priced_variants      BIGINT,
    best_combined_mpg      NUMERIC,
    best_combined_mpge     NUMERIC,
    min_annual_fuel_cost   NUMERIC,
    avg_annual_fuel_cost   NUMERIC,
    max_annual_fuel_cost   NUMERIC,
    gas_price_week         DATE,
    recall_count           BIGINT,
    latest_recall_date     DATE,
    complaints_12m         BIGINT,
    complaints_data_as_of  DATE,
    risk_score             NUMERIC,
    risk_as_of_date        DATE,
    risk_model_version     TEXT)
LANGUAGE sql STABLE AS $$
    SELECT v.vehicle_id, v.make, v.model, v.model_year,
           f.n_variants, f.n_priced_variants,
           f.best_combined_mpg, f.best_combined_mpge,
           f.min_annual_fuel_cost, f.avg_annual_fuel_cost, f.max_annual_fuel_cost,
           f.price_week,
           r.recall_count, r.latest_recall_date,
           c.complaints_12m, c.complaints_data_as_of,
           s.risk_score, s.as_of_date, s.model_version
    FROM   autoatlas.vehicles v
    LEFT   JOIN autoatlas.fuel_cost_by_vehicle(p_region_code, p_annual_miles) f
           ON f.vehicle_id = v.vehicle_id
    LEFT   JOIN autoatlas.v_recall_summary    r ON r.vehicle_id = v.vehicle_id
    LEFT   JOIN autoatlas.v_complaint_summary c ON c.vehicle_id = v.vehicle_id
    LEFT   JOIN LATERAL (
               SELECT rs.risk_score, rs.as_of_date, rs.model_version
               FROM   autoatlas.recall_risk_scores rs
               WHERE  rs.vehicle_id = v.vehicle_id
               AND    (p_model_version IS NULL OR rs.model_version = p_model_version)
               ORDER  BY rs.as_of_date DESC, rs.created_at DESC, rs.model_version DESC
               LIMIT  1) s ON TRUE
    WHERE  v.vehicle_id = ANY (p_vehicle_ids)
    ORDER  BY array_position(p_vehicle_ids, v.vehicle_id);
$$;

-- ---------------------------------------------------------------------
-- G. Data-quality views (README / data-health page)
-- ---------------------------------------------------------------------
-- How successful matches were made (denominator = matched names only)
CREATE VIEW autoatlas.v_match_method_distribution AS
SELECT source, match_method, count(*) AS names,
       round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY source), 1) AS pct_of_matched
FROM   autoatlas.vehicle_name_map
GROUP  BY source, match_method;

-- True match rate: matched names / (matched + still-unmatched) distinct names.
-- Depends on the loader writing unmatched names to quarantine_rows with
-- reason = 'no_matching_vehicle' and source_make/source_model/model_year keys.
-- A name quarantined in an earlier run but resolved since (e.g. a new alias)
-- is in vehicle_name_map now, so it is counted as matched only.
CREATE VIEW autoatlas.v_match_rate AS
WITH matched AS (
    SELECT source, count(*) AS n FROM autoatlas.vehicle_name_map GROUP BY source
), unmatched AS (
    SELECT q.source,
           count(DISTINCT (q.raw_record ->> 'source_make',
                           q.raw_record ->> 'source_model',
                           q.raw_record ->> 'model_year')) AS n
    FROM   autoatlas.quarantine_rows q
    WHERE  q.reason = 'no_matching_vehicle'
    AND    NOT EXISTS (
               SELECT 1 FROM autoatlas.vehicle_name_map nm
               WHERE  nm.source       = q.source
               AND    nm.source_make  = q.raw_record ->> 'source_make'
               AND    nm.source_model = q.raw_record ->> 'source_model'
               AND    nm.model_year::TEXT = q.raw_record ->> 'model_year')
    GROUP  BY q.source
)
SELECT coalesce(m.source, u.source)                  AS source,
       coalesce(m.n, 0)                              AS matched_names,
       coalesce(u.n, 0)                              AS unmatched_names,
       round(100.0 * coalesce(m.n, 0)
             / nullif(coalesce(m.n, 0) + coalesce(u.n, 0), 0), 1) AS match_rate_pct
FROM   matched m
FULL   JOIN unmatched u ON u.source = m.source;

-- Coverage: how many NHTSA cars also have EPA fuel data
CREATE VIEW autoatlas.v_source_coverage AS
SELECT count(*) FILTER (WHERE in_nhtsa)            AS nhtsa_vehicles,
       count(*) FILTER (WHERE in_nhtsa AND in_epa) AS nhtsa_with_epa,
       round(100.0 * count(*) FILTER (WHERE in_nhtsa AND in_epa)
             / nullif(count(*) FILTER (WHERE in_nhtsa), 0), 1) AS pct_nhtsa_with_epa
FROM   autoatlas.vehicles;

-- Candidates for the alias list: NHTSA cars with no EPA match
-- (heavy-duty trucks are expected here; real spelling misses are not)
CREATE VIEW autoatlas.v_unmatched_nhtsa AS
SELECT v.vehicle_id, v.make, v.model, v.model_year,
       (SELECT count(*) FROM autoatlas.v_complaints_dedup c
         WHERE c.vehicle_id = v.vehicle_id) AS complaints
FROM   autoatlas.vehicles v
WHERE  v.in_nhtsa AND NOT v.in_epa
ORDER  BY complaints DESC;

COMMIT;
