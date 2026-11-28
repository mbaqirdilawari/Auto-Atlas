from collections import defaultdict
from pathlib import Path
import re

import polars as pl

VEHICLES_FILE = Path("data/processed/vehicles_clean.csv")
CATALOG_FILE = Path("data/processed/nhtsa_model_catalog.csv")
OUTPUT_FILE = Path("data/processed/vehicle_model_mapping.csv")

# Initial vehicle families to match
TARGET_FAMILIES = {
    "Audi": "A3",
    "BMW": "X3",
    "Honda": "CIVIC",
    "Lexus": "RX",
    "Mercedes-Benz": "GLC",
    "Porsche": "MACAN",
    "Toyota": "CAMRY",
}


def normalize_model(name):
    """Standardize model names for comparison."""
    return re.sub(r"[^A-Z0-9]", "", name.upper())


def build_model_mapping():
    vehicles = pl.read_csv(VEHICLES_FILE)
    catalog = pl.read_csv(CATALOG_FILE)

    # Work with unique EPA make/model/year combinations.
    vehicles = vehicles.select(["make", "model", "year"]).unique()

    # Index NHTSA model names by manufacturer and year.
    catalog_lookup = defaultdict(set)

    for row in catalog.iter_rows(named=True):
        key = (row["make"], row["year"])
        catalog_lookup[key].add(row["nhtsa_model"])

    records = []

    for row in vehicles.iter_rows(named=True):
        make = row["make"]
        model = row["model"]
        year = row["year"]

        normalized_epa = normalize_model(model)
        nhtsa_models = sorted(catalog_lookup.get((make, year), []))

        # Look for exact normalized-name matches.
        exact = [
            name for name in nhtsa_models if normalize_model(name) == normalized_epa
        ]

        family = TARGET_FAMILIES.get(make)
        in_pilot = family is not None and normalized_epa.startswith(
            normalize_model(family)
        )

        if len(exact) == 1:
            status = "exact_name_candidate"
            matched_model = exact[0]
            candidates = exact

        elif len(exact) > 1:
            status = "ambiguous_exact_names"
            matched_model = None
            candidates = exact

        elif in_pilot:
            # Find related model-family names for review.
            normalized_family = normalize_model(family)

            candidates = [
                name
                for name in nhtsa_models
                if normalized_family in normalize_model(name)
            ]

            matched_model = None
            status = "review_required" if candidates else "no_catalog_candidate"

        else:
            status = "not_yet_mapped"
            matched_model = None
            candidates = []

        records.append(
            {
                "make": make,
                "epa_model": model,
                "year": year,
                "nhtsa_model": matched_model,
                "match_status": status,
                "candidate_count": len(candidates),
                "candidate_models": " | ".join(candidates),
            }
        )

    df = pl.DataFrame(records).sort(["make", "epa_model", "year"])

    # Validate that each EPA model/year occurs once.
    assert df.height == vehicles.height
    assert (
        df.select(pl.struct(["make", "epa_model", "year"]).n_unique()).item()
        == df.height
    )

    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    df.write_csv(OUTPUT_FILE)

    print("\nMODEL MAPPING COMPLETE")
    print(f"Total model/year combinations: {df.height:,}")
    print(f"Saved to: {OUTPUT_FILE}")

    print("\nMapping status:")
    print(df.group_by("match_status").len().sort("match_status"))

    print("\nExamples requiring review:")
    print(
        df.filter(pl.col("match_status") == "review_required")
        .select(
            [
                "make",
                "epa_model",
                "year",
                "candidate_count",
                "candidate_models",
            ]
        )
        .head(10)
    )

    return df


if __name__ == "__main__":
    build_model_mapping()
