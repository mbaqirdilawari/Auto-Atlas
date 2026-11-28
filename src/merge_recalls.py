from pathlib import Path
import shutil

import polars as pl

DATA_DIR = Path("data/processed")

PILOT_FILE = DATA_DIR / "recalls_pilot.csv"
EXPANDED_FILE = DATA_DIR / "recalls_expanded.csv"
OUTPUT_FILE = DATA_DIR / "recalls_clean.csv"

COLUMNS = [
    "campaign_number",
    "make",
    "model",
    "year",
    "component",
    "summary",
    "consequence",
    "remedy",
    "report_date",
]


def load_recalls(path, source):
    """Load and standardize a recall dataset."""
    return (
        pl.read_csv(path)
        .select(COLUMNS)
        .with_columns(
            pl.col("year").cast(pl.Int32),
            pl.col("report_date")
            .cast(pl.String)
            .str.strptime(
                pl.Date,
                format="%Y-%m-%d",
                strict=False,
            ),
            pl.lit(source).alias("source"),
        )
    )


def merge_recalls():
    # Back up the original 101-record pilot.
    if not PILOT_FILE.exists():
        shutil.copy2(OUTPUT_FILE, PILOT_FILE)
        print(f"Pilot backup created: {PILOT_FILE}")

    pilot = load_recalls(PILOT_FILE, "pilot")
    expanded = load_recalls(EXPANDED_FILE, "expanded")

    print(f"Original pilot records: {pilot.height:,}")
    print(f"Expanded records: {expanded.height:,}")

    # Combine datasets, prioritizing expanded records.
    df = pl.concat(
        [expanded, pilot],
        how="vertical_relaxed",
    )

    # Normalize names without changing original labels.
    df = df.with_columns(
        pl.col("make").str.strip_chars(),
        pl.col("model").str.strip_chars(),
        pl.col("model")
        .str.to_uppercase()
        .str.replace_all(r"[^A-Z0-9]", "")
        .alias("model_key"),
    )

    # Remove duplicate campaign/model/year records.
    before = df.height

    df = df.unique(
        subset=[
            "campaign_number",
            "make",
            "model_key",
            "year",
        ],
        keep="first",
        maintain_order=True,
    )

    duplicates_removed = before - df.height

    # Validate
    assert df["campaign_number"].null_count() == 0
    assert df["report_date"].null_count() == 0
    assert df["year"].is_between(2020, 2025).all()

    # Export
    df = df.sort(["make", "model", "year"])
    df.write_csv(OUTPUT_FILE)

    print("\nRECALL MERGE COMPLETE")
    print(f"Combined records: {before:,}")
    print(f"Duplicates removed: {duplicates_removed:,}")
    print(f"Final recall records: {df.height:,}")
    print(f"Saved to: {OUTPUT_FILE}")

    print("\nRecalls by manufacturer:")
    print(df.group_by("make").len().sort("make"))

    print("\nLexus records:")
    print(
        df.filter(pl.col("make") == "Lexus").select(
            [
                "campaign_number",
                "model",
                "year",
                "model_key",
            ]
        )
    )

    return df


if __name__ == "__main__":
    merge_recalls()
