# AutoAtlas ERD (matches `sql/01_schema.sql` v0.3)

Solid lines are enforced foreign keys. Dotted lines are lookups the queries join on, with no FK constraint. GitHub renders this diagram automatically. To export a PNG for the report, paste the block into https://mermaid.live.

```mermaid
erDiagram
    vehicles ||--o{ vehicle_name_map   : "spelled as"
    vehicles ||--o{ epa_variants       : "has versions"
    vehicles ||--o{ recall_vehicles    : "covered by"
    recalls  ||--|{ recall_vehicles    : "applies to"
    vehicles ||--o{ complaints         : "reported for"
    vehicles ||--o{ recall_risk_scores : "scored"
    epa_variants }o..o| fuel_product_map : "fuel_type (lookup, no FK)"
    fuel_product_map |o..o{ gas_prices  : "product_code (lookup, no FK)"
    pipeline_runs |o--o{ quarantine_rows : "rejected in run"

    vehicles {
        text vehicle_id PK "MAKE|MODEL|YEAR"
        text make
        text model
        smallint model_year
        text vehicle_class
        boolean in_epa
        boolean in_nhtsa
    }
    vehicle_name_map {
        text source PK "EPA / NHTSA_RECALLS / NHTSA_COMPLAINTS"
        text source_make PK
        text source_model PK
        smallint model_year PK
        text vehicle_id FK
        text match_method "exact / cleaned_exact / alias / fuzzy"
        numeric confidence
    }
    epa_variants {
        int epa_id PK
        text vehicle_id FK
        text fuel_type "fuelType1, looked up in fuel_product_map"
        text fuel_type_2 "fuelType2"
        text powertrain "atvType"
        numeric engine_displ_l
        text transmission
        text drive
        numeric combined_mpg "MPG, or MPGe for EVs"
        numeric combined_mpg_alt
        numeric combined_kwh_100mi
        numeric electric_utility_factor
    }
    recalls {
        text campaign_number PK "CAMPNO"
        date report_date
        int vehicles_affected "POTAFF, campaign-wide"
        text influenced_by
        text summary
        text remedy
    }
    recall_vehicles {
        text campaign_number PK,FK
        text vehicle_id PK,FK
        text component PK "COMPNAME"
    }
    complaints {
        bigint complaint_id PK "CMPLID"
        bigint odi_number "ODINO, can repeat"
        text vehicle_id FK
        text component
        date received_date
        boolean crash
        boolean fire
        int injuries
        int deaths
        int miles
    }
    gas_prices {
        date week_date PK
        text region_code PK "EIA duoarea"
        text product_code PK "EIA product"
        text region_name
        numeric price_usd_per_gal
    }
    fuel_product_map {
        text epa_fuel_type PK
        text eia_product_code "NULL = no gasoline price"
    }
    recall_risk_scores {
        text vehicle_id PK,FK
        date as_of_date PK
        text model_version PK
        numeric risk_score
        timestamptz created_at
    }
    pipeline_runs {
        bigint run_id PK
        text flow_name
        text status
        int rows_loaded
        int rows_rejected
    }
    quarantine_rows {
        bigint quarantine_id PK
        bigint run_id FK
        text source
        text reason
        jsonb raw_record
    }
```

**Changes from the first-draft ERD:** `component` moved from `recalls` to `recall_vehicles`. `complaints` gained `odi_number`. The EPA fuel columns were added. Four tables are new: `gas_prices`, `fuel_product_map`, `pipeline_runs` and `quarantine_rows`. `recall_features` is still undecided (ML owner).
