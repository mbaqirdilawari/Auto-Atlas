from pathlib import Path

import polars as pl

DATA_DIR = Path("data/processed")


def add_match_keys(df):
    """Create standardized vehicle matching fields."""
    return df.with_columns(
        pl.col("make").str.strip_chars().str.to_uppercase().alias("make_key"),
        pl.col("model")
        .str.to_uppercase()
        .str.replace_all(r"[^A-Z0-9]", "")
        .alias("model_key"),
        pl.col("year").cast(pl.Int32),
    )


def validate_handoff():
    # Load our three cleaned datasets
    vehicles = pl.read_csv(DATA_DIR / "vehicles_clean.csv")
    recalls = pl.read_csv(DATA_DIR / "recalls_clean.csv")
    prices = pl.read_csv(DATA_DIR / "gas_prices_clean.csv")

    # Validate primary fields
    assert vehicles["vehicle_id"].n_unique() == vehicles.height
    assert vehicles["combined_mpg"].min() > 0
    assert recalls["campaign_number"].null_count() == 0
    assert prices["price_per_gallon"].min() > 0

    # Standardize vehicle identifiers for matching
    vehicles = add_match_keys(vehicles)
    recalls = add_match_keys(recalls)

    # Build candidate links using exact normalized names
    recall_lookup = recalls.select(
        "make_key",
        "model_key",
        "year",
        "campaign_number",
        pl.col("model").alias("nhtsa_model"),
    ).unique()

    links = (
        vehicles.join(
            recall_lookup,
            on=["make_key", "model_key", "year"],
            how="inner",
        )
        .sort(["vehicle_id", "campaign_number"])
        .unique(
            subset=["vehicle_id", "campaign_number"],
            maintain_order=True,
        )
        .select(
            "vehicle_id",
            "make",
            "model",
            "year",
            "nhtsa_model",
            "campaign_number",
            pl.lit("exact_name_candidate").alias("match_status"),
        )
    )

    # Vehicles with no exact-name candidate
    unmatched = vehicles.join(
        links.select("vehicle_id").unique(),
        on="vehicle_id",
        how="anti",
    ).select("vehicle_id", "make", "model", "year")

    # Export audit files
    links.write_csv(DATA_DIR / "vehicle_recall_candidates.csv")
    unmatched.write_csv(DATA_DIR / "unmatched_vehicles.csv")

    print("\nAUTOATLAS DATA VALIDATION")
    print(f"EPA vehicle configurations: {vehicles.height:,}")
    print(f"NHTSA recall records: {recalls.height:,}")
    print(f"EIA gasoline price records: {prices.height:,}")

    print("\nVEHICLE MATCHING")
    print(f"Candidate vehicle-recall links: {links.height:,}")
    print(
        "Vehicles with an exact-name recall candidate: "
        f"{links['vehicle_id'].n_unique():,}"
    )
    print(f"Vehicles without an exact-name candidate: " f"{unmatched.height:,}")

    print("\nValidation complete.")
    print("Audit files saved to data/processed/")


if __name__ == "__main__":
    validate_handoff()
