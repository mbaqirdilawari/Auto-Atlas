from pathlib import Path
import polars as pl

RAW_FILE = Path("data/raw/vehicles.csv")
OUTPUT_FILE = Path("data/processed/vehicles_clean.csv")

MANUFACTURERS = [
    "BMW",
    "Mercedes-Benz",
    "Porsche",
    "Toyota",
    "Honda",
    "Audi",
    "Lexus",
]


def clean_epa():
    # 1. Read EPA vehicle data
    df = pl.read_csv(
        RAW_FILE,
        columns=[
            "id",
            "make",
            "model",
            "year",
            "comb08",
            "city08",
            "highway08",
            "fuelType1",
            "fuelType2",
        ],
        infer_schema_length=0,
    )

    print(f"Original EPA records: {df.height:,}")

    # 2. Standardize column names and data types
    df = df.select(
        pl.col("id").cast(pl.Int64, strict=False).alias("vehicle_id"),
        pl.col("make").str.strip_chars().alias("make"),
        pl.col("model").str.strip_chars().alias("model"),
        pl.col("year").cast(pl.Int32, strict=False).alias("year"),
        pl.col("comb08").cast(pl.Float64, strict=False).alias("combined_mpg"),
        pl.col("city08").cast(pl.Float64, strict=False).alias("city_mpg"),
        pl.col("highway08").cast(pl.Float64, strict=False).alias("highway_mpg"),
        pl.col("fuelType1").str.strip_chars().alias("fuel_type"),
        pl.col("fuelType2").str.strip_chars().alias("secondary_fuel"),
    )

    # 3. Filter manufacturers, years, and fuel types
    df = df.filter(
        pl.col("make").is_in(MANUFACTURERS)
        & pl.col("year").is_between(2020, 2025)
        & pl.col("fuel_type").str.contains("Gasoline")
        & (pl.col("secondary_fuel").fill_null("").str.strip_chars() == "")
    )

    # 4. Remove invalid records and duplicate vehicle IDs
    df = (
        df.drop_nulls(["vehicle_id", "make", "model", "year", "combined_mpg"])
        .filter(pl.col("combined_mpg") > 0)
        .unique(subset=["vehicle_id"])
        .drop("secondary_fuel")
        .sort(["make", "model", "year"])
    )

    # 5. Validate cleaned dataset
    assert df["vehicle_id"].n_unique() == df.height
    assert df["combined_mpg"].min() > 0
    assert df["year"].is_between(2020, 2025).all()

    # 6. Export cleaned vehicle data
    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    df.write_csv(OUTPUT_FILE)

    print(f"\nCleaned EPA records: {df.height:,}")
    print(f"Saved to: {OUTPUT_FILE}")

    print("\nVehicles by manufacturer:")
    print(df.group_by("make").len().sort("make"))

    print("\nSample records:")
    print(df.head(10))

    return df


if __name__ == "__main__":
    clean_epa()
