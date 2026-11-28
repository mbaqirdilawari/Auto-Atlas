from pathlib import Path
import polars as pl

MAPPING_FILE = Path("data/processed/vehicle_model_mapping.csv")
OUTPUT_FILE = Path("data/processed/recall_targets.csv")


def prepare_recall_targets():
    mapping = pl.read_csv(MAPPING_FILE)

    targets = (
        mapping.filter(pl.col("match_status") == "exact_name_candidate")
        .select(
            "make",
            pl.col("nhtsa_model").alias("model"),
            "year",
        )
        .drop_nulls()
        .unique()
        .sort(["make", "model", "year"])
    )

    assert targets.height > 0
    assert targets["year"].is_between(2020, 2025).all()

    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    targets.write_csv(OUTPUT_FILE)

    print(f"Prepared {targets.height} NHTSA lookup targets")
    print(f"Saved to: {OUTPUT_FILE}")

    print("\nTargets by manufacturer:")
    print(targets.group_by("make").len().sort("make"))

    return targets


if __name__ == "__main__":
    prepare_recall_targets()
