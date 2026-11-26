-- =====================================================================
-- Automated assertions. Any failure raises an error, so
--   psql -v ON_ERROR_STOP=1 -f tests/test_db.sql
-- exits non-zero and GitHub Actions fails the build.
-- Requires tests/sample_data.sql to be loaded first.
-- =====================================================================

-- Run as a default connection would (like Streamlit): no autoatlas on the path
SET search_path TO public;

CREATE FUNCTION pg_temp.assert_eq(label TEXT, got ANYELEMENT, expected ANYELEMENT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF got IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'FAIL %: expected %, got %', label, expected, got;
    END IF;
    RAISE NOTICE 'ok  %', label;
END $$;

-- Expects the statement to fail with the given SQLSTATE
CREATE FUNCTION pg_temp.assert_fails(label TEXT, stmt TEXT, expected_state TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = expected_state THEN
            RAISE NOTICE 'ok  % (rejected: %)', label, SQLERRM;
            RETURN;
        END IF;
        RAISE EXCEPTION 'FAIL %: wrong error % (%)', label, SQLSTATE, SQLERRM;
    END;
    RAISE EXCEPTION 'FAIL %: statement was accepted but should have been rejected', label;
END $$;

-- ---------------------------------------------------------------- fuel cost
SELECT pg_temp.assert_eq('ordinary gasoline car is_phev is FALSE, not NULL (gets a full cost)',
    (SELECT annual_fuel_cost IS NOT NULL AND all_gasoline_scenario_cost IS NULL
     FROM autoatlas.fuel_cost_by_variant() WHERE epa_id = 40001), TRUE);
SELECT pg_temp.assert_eq('regular gas variant cost (15000/29*3.00)',
    (SELECT annual_fuel_cost FROM autoatlas.fuel_cost_by_variant() WHERE epa_id = 40001), 1551.72);
SELECT pg_temp.assert_eq('premium car priced with premium gas (15000/28*3.90)',
    (SELECT annual_fuel_cost FROM autoatlas.fuel_cost_by_variant() WHERE epa_id = 40004), 2089.29);
SELECT pg_temp.assert_eq('EV has no fuel cost',
    (SELECT annual_fuel_cost FROM autoatlas.fuel_cost_by_variant() WHERE epa_id = 40005), NULL::NUMERIC);
SELECT pg_temp.assert_eq('EV efficiency unit is MPGe',
    (SELECT efficiency_unit FROM autoatlas.fuel_cost_by_variant() WHERE epa_id = 40005), 'MPGe');
SELECT pg_temp.assert_eq('EV note',
    (SELECT cost_note FROM autoatlas.fuel_cost_by_variant() WHERE epa_id = 40005),
    'electric vehicle: electricity cost not estimated');
SELECT pg_temp.assert_eq('PHEV has no complete cost',
    (SELECT annual_fuel_cost FROM autoatlas.fuel_cost_by_variant() WHERE epa_id = 40006), NULL::NUMERIC);
SELECT pg_temp.assert_eq('PHEV all-gasoline scenario cost (15000/54*3.00)',
    (SELECT all_gasoline_scenario_cost FROM autoatlas.fuel_cost_by_variant() WHERE epa_id = 40006), 833.33);
SELECT pg_temp.assert_eq('missing MPG explained',
    (SELECT cost_note FROM autoatlas.fuel_cost_by_variant() WHERE epa_id = 40007),
    'missing combined MPG in EPA data');
SELECT pg_temp.assert_eq('flex-fuel priced on gasoline',
    (SELECT cost_note FROM autoatlas.fuel_cost_by_variant() WHERE epa_id = 40008),
    'flex-fuel: priced on gasoline');
SELECT pg_temp.assert_eq('missing regional price explained',
    (SELECT cost_note FROM autoatlas.fuel_cost_by_variant('TST', 12000) WHERE epa_id = 40004),
    'no price for this fuel in this region');
SELECT pg_temp.assert_fails('negative annual miles rejected',
    $q$SELECT * FROM autoatlas.fuel_cost_by_variant('NUS', -100)$q$, '22023');
SELECT pg_temp.assert_fails('NULL annual miles rejected',
    $q$SELECT * FROM autoatlas.fuel_cost_by_variant('NUS', NULL)$q$, '22023');

SELECT pg_temp.assert_eq('CR-V: 3 variants, 2 priced',
    (SELECT (n_variants, n_priced_variants)::TEXT FROM autoatlas.fuel_cost_by_vehicle()
     WHERE vehicle_id = 'HONDA|CR-V|2019'), '(3,2)');
SELECT pg_temp.assert_eq('CR-V avg of variant costs, rounded to dollars only at the end (1579, not 1580)',
    (SELECT avg_annual_fuel_cost FROM autoatlas.fuel_cost_by_vehicle()
     WHERE vehicle_id = 'HONDA|CR-V|2019'), 1579::NUMERIC);
SELECT pg_temp.assert_eq('MPGe never reported as MPG',
    (SELECT best_combined_mpg FROM autoatlas.fuel_cost_by_vehicle()
     WHERE vehicle_id = 'TESLA|MODEL 3|2019'), NULL::NUMERIC);
SELECT pg_temp.assert_eq('regional price used (12000/29*2.90 and 12000/28*2.90)',
    (SELECT avg_annual_fuel_cost FROM autoatlas.fuel_cost_by_vehicle('TST', 12000)
     WHERE vehicle_id = 'HONDA|CR-V|2019'), 1221::NUMERIC);

-- ---------------------------------------------------------------- recalls
SELECT pg_temp.assert_eq('multi-component recall counted once (CR-V = 2 recalls)',
    (SELECT recall_count FROM autoatlas.v_recall_summary WHERE vehicle_id = 'HONDA|CR-V|2019'), 2::BIGINT);
SELECT pg_temp.assert_eq('car with no recalls shows 0',
    (SELECT recall_count FROM autoatlas.v_recall_summary WHERE vehicle_id = 'TESLA|MODEL 3|2019'), 0::BIGINT);
SELECT pg_temp.assert_eq('campaign units summed per campaign, not per component row',
    (SELECT associated_campaign_units FROM autoatlas.v_recall_summary WHERE vehicle_id = 'HONDA|CR-V|2019'), 165000::BIGINT);

-- ---------------------------------------------------------------- complaints
SELECT pg_temp.assert_eq('multi-row ODI complaint counted once (CR-V = 3)',
    (SELECT complaints_total FROM autoatlas.v_complaint_summary WHERE vehicle_id = 'HONDA|CR-V|2019'), 3::BIGINT);
SELECT pg_temp.assert_eq('repeated injuries not double-counted (2 + 1 = 3, not 5)',
    (SELECT injuries FROM autoatlas.v_complaint_summary WHERE vehicle_id = 'HONDA|CR-V|2019'), 3::BIGINT);
SELECT pg_temp.assert_eq('12-month window relative to newest complaint',
    (SELECT complaints_12m FROM autoatlas.v_complaint_summary WHERE vehicle_id = 'HONDA|CR-V|2019'), 2::BIGINT);

-- ---------------------------------------------------------------- comparison
SELECT pg_temp.assert_eq('compare_vehicles keeps the requested order',
    (SELECT string_agg(vehicle_id, ',') FROM autoatlas.compare_vehicles(
        ARRAY['TOYOTA|RAV4|2019','HONDA|CR-V|2019','FORD|F-250|2019'])),
    'TOYOTA|RAV4|2019,HONDA|CR-V|2019,FORD|F-250|2019');
SELECT pg_temp.assert_eq('risk score: same-date tie goes to most recently written (v9, not alphabetical v10)',
    (SELECT risk_model_version FROM autoatlas.compare_vehicles(ARRAY['HONDA|CR-V|2019'])), 'v9');
SELECT pg_temp.assert_eq('risk score: specific model version honoured',
    (SELECT risk_score FROM autoatlas.compare_vehicles(ARRAY['HONDA|CR-V|2019'], 'NUS', 15000, 'v10')), 0.780);
SELECT pg_temp.assert_eq('comparison exposes data dates',
    (SELECT (gas_price_week, complaints_data_as_of)::TEXT
     FROM autoatlas.compare_vehicles(ARRAY['HONDA|CR-V|2019'])), '(2026-11-16,2026-09-01)');

-- ---------------------------------------------------------------- data quality
SELECT pg_temp.assert_eq('match rate: unmatched counted once, resolved names not counted (3 / (3+2))',
    (SELECT match_rate_pct FROM autoatlas.v_match_rate WHERE source = 'NHTSA_COMPLAINTS'), 60.0);
SELECT pg_temp.assert_eq('coverage: 2 of 3 NHTSA cars have EPA data',
    (SELECT pct_nhtsa_with_epa FROM autoatlas.v_source_coverage), 66.7);

-- ---------------------------------------------------------------- constraints
SELECT pg_temp.assert_fails('lowercase make rejected',
    $q$INSERT INTO autoatlas.vehicles VALUES ('Honda|CR-V|2020','Honda','CR-V',2020,NULL,TRUE,FALSE)$q$, '23514');
SELECT pg_temp.assert_fails('ID not matching its parts rejected',
    $q$INSERT INTO autoatlas.vehicles VALUES ('HONDA|CRV|2020','HONDA','CR-V',2020,NULL,TRUE,FALSE)$q$, '23514');
SELECT pg_temp.assert_fails('empty model rejected',
    $q$INSERT INTO autoatlas.vehicles VALUES ('HONDA||2020','HONDA','',2020,NULL,TRUE,FALSE)$q$, '23514');
SELECT pg_temp.assert_fails('delimiter inside a name rejected',
    $q$INSERT INTO autoatlas.vehicles VALUES ('HONDA|CR|V|2020','HONDA','CR|V',2020,NULL,TRUE,FALSE)$q$, '23514');
SELECT pg_temp.assert_fails('complaint for unknown vehicle rejected',
    $q$INSERT INTO autoatlas.complaints VALUES (99,1,'NOPE|X|2019','X','2026-01-01',FALSE,FALSE,0,0,1)$q$, '23503');
SELECT pg_temp.assert_fails('duplicate complaint record rejected',
    $q$INSERT INTO autoatlas.complaints VALUES (1,11000001,'HONDA|CR-V|2019','ENGINE','2025-12-01',FALSE,FALSE,2,0,40000)$q$, '23505');

\echo 'ALL TESTS PASSED'
