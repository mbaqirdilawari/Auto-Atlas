-- Made-up test rows (NOT real EPA/NHTSA/EIA values). Each row exists to
-- exercise one rule; the expected results are asserted in test_db.sql.

INSERT INTO autoatlas.vehicles VALUES
  ('HONDA|CR-V|2019',        'HONDA',  'CR-V',        2019, 'Small Sport Utility Vehicle', TRUE,  TRUE),
  ('TOYOTA|RAV4|2019',       'TOYOTA', 'RAV4',        2019, 'Small Sport Utility Vehicle', TRUE,  TRUE),
  ('TESLA|MODEL 3|2019',     'TESLA',  'MODEL 3',     2019, 'Midsize Cars',                TRUE,  FALSE),
  ('TOYOTA|PRIUS PRIME|2019','TOYOTA', 'PRIUS PRIME', 2019, 'Midsize Cars',                TRUE,  FALSE),
  ('FORD|F-150|2019',        'FORD',   'F-150',       2019, 'Standard Pickup Trucks',      TRUE,  FALSE),
  ('FORD|F-250|2019',        'FORD',   'F-250',       2019, NULL,                          FALSE, TRUE);

INSERT INTO autoatlas.vehicle_name_map VALUES
  ('EPA',              'Honda',  'CR-V AWD',    2019, 'HONDA|CR-V|2019',         'cleaned_exact', 1),
  ('EPA',              'Honda',  'CR-V FWD',    2019, 'HONDA|CR-V|2019',         'cleaned_exact', 1),
  ('EPA',              'Toyota', 'RAV4 AWD',    2019, 'TOYOTA|RAV4|2019',        'cleaned_exact', 1),
  ('EPA',              'Tesla',  'Model 3',     2019, 'TESLA|MODEL 3|2019',      'exact',         1),
  ('NHTSA_COMPLAINTS', 'HONDA',  'CR-V',        2019, 'HONDA|CR-V|2019',         'exact',         1),
  ('NHTSA_COMPLAINTS', 'TOYOTA', 'RAV-4',       2019, 'TOYOTA|RAV4|2019',        'fuzzy',         0.93),
  ('NHTSA_COMPLAINTS', 'FORD',   'F-250 SD',    2019, 'FORD|F-250|2019',         'cleaned_exact', 1),
  ('NHTSA_RECALLS',    'HONDA',  'CRV',         2019, 'HONDA|CR-V|2019',         'alias',         1);

INSERT INTO autoatlas.epa_variants
  (epa_id, vehicle_id, base_model, engine_displ_l, cylinders, transmission, drive,
   fuel_type, fuel_type_2, powertrain, vehicle_class, city_mpg, highway_mpg, combined_mpg,
   combined_mpg_alt, combined_kwh_100mi, electric_utility_factor, epa_annual_fuel_cost)
VALUES
  -- ordinary gasoline (CR-V); third CR-V row has missing MPG
  (40001, 'HONDA|CR-V|2019', 'CR-V', 1.5, 4, 'Automatic (AV)', 'All-Wheel Drive',   'Regular Gasoline', NULL, NULL, 'SUV 4WD', 27, 32, 29, NULL, NULL, NULL, 1550),
  (40002, 'HONDA|CR-V|2019', 'CR-V', 2.4, 4, 'Automatic (AV)', 'Front-Wheel Drive', 'Regular Gasoline', NULL, NULL, 'SUV 2WD', 26, 32, 28, NULL, NULL, NULL, 1600),
  (40007, 'HONDA|CR-V|2019', 'CR-V', 2.0, 4, 'Manual 6-spd',   'Front-Wheel Drive', 'Regular Gasoline', NULL, NULL, 'SUV 2WD', NULL, NULL, NULL, NULL, NULL, NULL, NULL),
  -- hybrid on regular, and a premium-fuel variant (RAV4)
  (40003, 'TOYOTA|RAV4|2019', 'RAV4', 2.5, 4, 'Automatic (AV)', 'All-Wheel Drive', 'Regular Gasoline', NULL, 'Hybrid', 'SUV 4WD', 41, 37, 39, NULL, NULL, NULL, 1150),
  (40004, 'TOYOTA|RAV4|2019', 'RAV4', 2.5, 4, 'Automatic (S8)', 'All-Wheel Drive', 'Premium Gasoline', NULL, NULL,     'SUV 4WD', 25, 33, 28, NULL, NULL, NULL, 1950),
  -- EV (MPGe)
  (40005, 'TESLA|MODEL 3|2019', 'Model 3', NULL, NULL, 'Automatic (A1)', 'Rear-Wheel Drive', 'Electricity', NULL, 'EV', 'Midsize', 136, 123, 130, NULL, 26, NULL, 550),
  -- plug-in hybrid
  (40006, 'TOYOTA|PRIUS PRIME|2019', 'Prius Prime', 1.8, 4, 'Automatic (AV)', 'Front-Wheel Drive', 'Regular Gasoline', 'Electricity', 'Plug-in Hybrid', 'Midsize', 55, 53, 54, 133, 25, 0.29, 700),
  -- flex-fuel
  (40008, 'FORD|F-150|2019', 'F150', 3.3, 6, 'Automatic (S6)', '4-Wheel Drive', 'Regular Gasoline', 'E85', 'FFV', 'Pickup 4WD', 18, 23, 20, 15, NULL, NULL, 2300);

INSERT INTO autoatlas.recalls VALUES
  ('19V500000', '2019-07-01', 120000, 'MFR', 'Fuel pump may fail.',  'Engine stall.',       'Replace pump.'),
  ('20V100000', '2020-02-15',  45000, 'ODI', 'Rear camera blank.',   'Reduced visibility.', 'Update software.'),
  ('21V200000', '2021-05-10', 300000, 'MFR', 'Seat belt anchor.',    'Injury risk.',        'Inspect and repair.');

INSERT INTO autoatlas.recall_vehicles VALUES
  ('19V500000', 'HONDA|CR-V|2019',  'FUEL SYSTEM, GASOLINE'),
  ('20V100000', 'HONDA|CR-V|2019',  'BACK OVER PREVENTION'),
  ('20V100000', 'HONDA|CR-V|2019',  'ELECTRICAL SYSTEM'),        -- same campaign, 2nd component
  ('21V200000', 'TOYOTA|RAV4|2019', 'SEAT BELTS'),
  ('21V200000', 'FORD|F-250|2019',  'SEAT BELTS');               -- campaign covers 2 models

INSERT INTO autoatlas.complaints VALUES
  -- ODI 11000001: one complaint, two component rows, injuries repeated (2 each)
  (1, 11000001, 'HONDA|CR-V|2019',  'ENGINE',      '2025-12-01', FALSE, FALSE, 2, 0, 40000),
  (2, 11000001, 'HONDA|CR-V|2019',  'FUEL SYSTEM', '2025-12-01', FALSE, FALSE, 2, 0, 40000),
  (3, 11000002, 'HONDA|CR-V|2019',  'ENGINE',      '2026-06-01', TRUE,  FALSE, 1, 0, 52000),
  (4, 11000003, 'HONDA|CR-V|2019',  'ELECTRICAL',  '2023-01-01', FALSE, TRUE,  0, 0, 15000),
  (5, 11000004, 'TOYOTA|RAV4|2019', 'BRAKES',      '2026-09-01', FALSE, FALSE, 0, 0, 30000);

INSERT INTO autoatlas.gas_prices VALUES
  ('2026-11-09', 'NUS', 'U.S.',        'EPMR', 'Regular Gasoline', 3.100),
  ('2026-11-16', 'NUS', 'U.S.',        'EPMR', 'Regular Gasoline', 3.000),  -- latest
  ('2026-11-16', 'NUS', 'U.S.',        'EPMP', 'Premium Gasoline', 3.900),
  ('2026-11-16', 'TST', 'Test region', 'EPMR', 'Regular Gasoline', 2.900);  -- no premium price here

INSERT INTO autoatlas.recall_risk_scores (vehicle_id, as_of_date, risk_score, model_version) VALUES
  ('HONDA|CR-V|2019', '2026-10-01', 0.610, 'v10'),
  ('HONDA|CR-V|2019', '2026-11-01', 0.780, 'v10');
-- Written later, same date. 'v9' sorts BEFORE 'v10' alphabetically, so this
-- checks that "newest" comes from created_at, not from the version name.
INSERT INTO autoatlas.recall_risk_scores (vehicle_id, as_of_date, risk_score, model_version) VALUES
  ('HONDA|CR-V|2019', '2026-11-01', 0.700, 'v9');

INSERT INTO autoatlas.quarantine_rows (source, reason, raw_record) VALUES
  ('NHTSA_COMPLAINTS', 'no_matching_vehicle', '{"source_make":"KIA","source_model":"SOREN TO","model_year":"2019"}'),
  ('NHTSA_COMPLAINTS', 'no_matching_vehicle', '{"source_make":"KIA","source_model":"SOREN TO","model_year":"2019"}'), -- same name twice
  ('NHTSA_COMPLAINTS', 'no_matching_vehicle', '{"source_make":"MAZDA","source_model":"CX5","model_year":"2019"}'),
  -- quarantined in an earlier run, resolved since (it's in vehicle_name_map) -> not unmatched
  ('NHTSA_COMPLAINTS', 'no_matching_vehicle', '{"source_make":"TOYOTA","source_model":"RAV-4","model_year":"2019"}'),
  ('NHTSA_COMPLAINTS', 'missing_year',        '{"source_make":"HONDA","source_model":"CIVIC","model_year":"9999"}');
