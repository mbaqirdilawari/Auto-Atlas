
# AutoAtlas
### Automotive Comparison and Ownership Cost Analytics Platform

## Project Overview

AutoAtlas is a data engineering project that integrates automotive information from multiple public sources to support vehicle comparisons.

The platform is designed to help users compare vehicles based on fuel efficiency, estimated annual fuel expenses, and historical safety recalls.

This repository contains a modular Python data pipeline that ingests, transforms, validates, and prepares automotive datasets for PostgreSQL and downstream analytics.

## Data Sources

1. **EPA Fuel Economy Data**
   - Source: https://www.fueleconomy.gov/feg/download.shtml
   - Vehicle specifications, model years, fuel types, and MPG ratings.

2. **NHTSA Vehicle Recalls API**
   - Source: https://www.nhtsa.gov/nhtsa-datasets-and-apis
   - Historical recall campaigns, affected vehicle models, and recall descriptions.

3. **U.S. Energy Information Administration (EIA)**
   - Source: https://www.eia.gov/petroleum/gasdiesel/
   - Weekly regional gasoline prices for regular and premium fuel.

## Technology Stack

- Python
- Polars
- Requests
- PostgreSQL (downstream integration)
- Pytest
- Git/GitHub

## Data Pipeline Architecture

The ingestion and transformation pipeline consists of the following modules:

- `ingest_epa.py`: Downloads EPA vehicle data.
- `transform.py`: Cleans and standardizes vehicle specifications.
- `inspect_nhtsa_models.py`: Retrieves NHTSA model catalogs.
- `build_model_mapping.py`: Identifies potential EPA-NHTSA model matches.
- `prepare_recall_targets.py`: Generates recall lookup targets.
- `ingest_nhtsa.py`: Retrieves initial recall records.
- `ingest_nhtsa_targets.py`: Retrieves expanded recall records.
- `merge_recalls.py`: Combines and deduplicates recall records.
- `ingest_eia.py`: Downloads and cleans gasoline prices.
- `validate_handoff.py`: Validates datasets and produces matching audit files.
- `pipeline.py`: Runs the complete workflow.

## Setup Instructions

Create and activate a virtual environment:

    python3 -m venv .venv
    source .venv/bin/activate

Install dependencies:

    python -m pip install -r requirements.txt

Run the complete pipeline:

    python -m src.pipeline

Validate existing outputs without downloading again:

    python -m src.pipeline --check

Run automated tests:

    python -m pytest tests/ -v

## Processed Datasets

The pipeline generates three primary datasets in `data/processed/`.

### vehicles_clean.csv

EPA vehicle specifications.

Key columns:
- vehicle_id: Unique EPA vehicle configuration identifier
- make: Manufacturer
- model: EPA model name
- year: Model year
- combined_mpg: Combined fuel efficiency
- city_mpg: City fuel efficiency
- highway_mpg: Highway fuel efficiency
- fuel_type: Regular or premium gasoline

Current scope: 2,390 configurations across seven manufacturers, model years 2020-2025.

### recalls_clean.csv

NHTSA historical recall records.

Key columns:
- campaign_number: NHTSA recall campaign identifier
- make: Manufacturer
- model: NHTSA lookup model name
- year: Vehicle model year
- component: Affected vehicle component
- summary: Recall description
- consequence: Potential safety consequence
- remedy: Manufacturer's proposed remedy
- report_date: Recall report date
- model_key: Normalized model name
- source: Pilot or expanded ingestion source

Current output: 600 campaign-model-year records.

### gas_prices_clean.csv

EIA weekly gasoline prices.

Key columns:
- date: Weekly observation date
- region: Geographic region
- fuel_grade: Regular or Premium
- price_per_gallon: Retail price in USD

Current output: 20,157 observations across 28 geographic areas, covering January 2020 through November 2026.

## Additional Integration Files

- `vehicle_model_mapping.csv`: EPA-NHTSA model-name matching candidates and review statuses.
- `vehicle_recall_candidates.csv`: Candidate vehicle-recall links based on exact normalized model names.
- `unmatched_vehicles.csv`: EPA vehicles without exact-name recall candidates.
- `nhtsa_lookup_status.csv`: Pilot recall lookup audit.
- `nhtsa_expanded_lookup_status.csv`: Expanded recall lookup audit.
- `recall_targets.csv`: Make/model/year combinations selected for expanded API retrieval.

## PostgreSQL Handoff

The three primary cleaned datasets are intended for relational database integration.

Suggested tables:

- vehicles
- recalls
- gas_prices

EPA vehicle_id uniquely identifies vehicle configurations.

NHTSA campaign_number identifies recall campaigns but is not unique across vehicle models and model years. A composite key or separate recall relationship table is needed.

Gasoline prices can be identified by date, region, and fuel grade.

The downstream team will design the relational schema, implement SQL queries, and calculate estimated annual fuel expenses.

## Data Quality and Limitations

The pipeline includes:

- Missing-value and data-type validation
- Duplicate removal
- Unique vehicle identifier checks
- Fuel efficiency and gasoline-price validation
- Model-name standardization
- Recall lookup auditing
- Automated Pytest tests

EPA and NHTSA do not consistently use identical model names.

Current validation identified 662 candidate vehicle-recall links involving 228 EPA vehicle configurations.

The remaining 2,162 configurations lack an exact-name recall candidate in the collected data. This does not mean they have zero recalls.

Candidate matches are not verified trim- or VIN-specific recall applicability.

Historical recall counts should not be interpreted as definitive vehicle safety ratings.

Fuel expenses are estimates based on vehicle MPG, gasoline grade, regional prices, and assumed annual mileage. They do not represent complete ownership costs.

## Data Engineering Principles

**Modularity:** Separate ingestion, transformation, mapping, and validation modules.

**Reusability:** Functions can be reused when datasets are updated.

**Reliability:** Automated assertions, duplicate checks, API error handling, and Pytest tests.

**Observability:** Pipeline progress messages, API lookup audits, and summary statistics.

**Efficiency:** Targeted EPA filtering, deduplicated API lookup targets, and cached NHTSA responses.

**Scalability:** Additional manufacturers and vehicle models can be incorporated by extending the existing pipeline.

**Data Governance:** Source attribution, documented schemas, explicit matching limitations, and preservation of original model identifiers.

**Security:** Public government data sources, isolated Python environments, and separation of raw and processed data.

## Testing

Six automated tests currently validate vehicle specifications, recall records, gasoline prices, model normalization, candidate links, and unmatched-vehicle coverage.

Latest result: 6 tests passed.

## Project Collaboration

This ingestion and transformation pipeline is designed for integration into the shared AutoAtlas project repository.

Subsequent development includes PostgreSQL integration, SQL analytics, orchestration, dashboard development, Docker, and CI/CD.
