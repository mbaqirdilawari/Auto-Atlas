from datetime import datetime
from pathlib import Path
import re
import argparse

import polars as pl
import requests
import xlrd

EIA_URL = "https://www.eia.gov/petroleum/gasdiesel/" "xls/pswrgvwall.xls"

RAW_FILE = Path("data/raw/eia_gas_prices.xls")
OUTPUT_FILE = Path("data/processed/gas_prices_clean.csv")

SHEETS = {
    "Data 3": "Regular",
    "Data 9": "Premium",
}


def parse_excel_date(cell, workbook):
    """Convert Excel dates into Python dates."""

    if cell.ctype in (
        xlrd.XL_CELL_DATE,
        xlrd.XL_CELL_NUMBER,
    ):
        try:
            return xlrd.xldate_as_datetime(cell.value, workbook.datemode).date()
        except (ValueError, OverflowError):
            return None

    if cell.ctype == xlrd.XL_CELL_TEXT:
        for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y"):
            try:
                return datetime.strptime(cell.value.strip(), fmt).date()
            except ValueError:
                continue

    return None


def extract_prices(workbook, sheet_name, fuel_grade):
    """Extract weekly prices for one gasoline grade."""

    sheet = workbook.sheet_by_name(sheet_name)

    headers = [str(sheet.cell_value(2, col)).strip() for col in range(sheet.ncols)]

    keyword = f"{fuel_grade} All Formulations"

    price_columns = [
        col for col in range(1, sheet.ncols) if keyword.lower() in headers[col].lower()
    ]

    if not price_columns:
        raise ValueError(f"No {fuel_grade} price columns found " f"in {sheet_name}")

    records = []

    for row_idx in range(3, sheet.nrows):
        date = parse_excel_date(sheet.cell(row_idx, 0), workbook)

        if date is None or date.year < 2020:
            continue

        for col_idx in price_columns:
            price = sheet.cell_value(row_idx, col_idx)

            if not isinstance(price, (int, float)):
                continue

            if price <= 0:
                continue

            header = headers[col_idx]

            region = re.sub(
                r"^Weekly\s+",
                "",
                header,
                flags=re.IGNORECASE,
            )

            region = re.sub(
                rf"\s+{fuel_grade}\s+All Formulations.*$",
                "",
                region,
                flags=re.IGNORECASE,
            ).strip()

            if not region:
                continue

            records.append(
                {
                    "date": date,
                    "region": region,
                    "fuel_grade": fuel_grade,
                    "price_per_gallon": float(price),
                }
            )

    return records


def ingest_eia(refresh=False):
    """Ingest and clean regular and premium gasoline prices."""

    RAW_FILE.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)

    # Reuse the existing workbook unless refreshing.
    if refresh or not RAW_FILE.exists():
        response = requests.get(EIA_URL, timeout=120)
        response.raise_for_status()
        RAW_FILE.write_bytes(response.content)
        print("Downloaded EIA workbook.")
    else:
        print("Using existing EIA workbook.")

    workbook = xlrd.open_workbook(str(RAW_FILE))

    # Extract both fuel grades.
    records = []

    for sheet_name, fuel_grade in SHEETS.items():
        extracted = extract_prices(workbook, sheet_name, fuel_grade)

        records.extend(extracted)

        print(f"{fuel_grade}: " f"{len(extracted):,} records extracted")

    if not records:
        raise ValueError("No gasoline price records found.")

    # Clean and standardize using Polars.
    df = (
        pl.DataFrame(records)
        .with_columns(
            pl.col("date").cast(pl.Date),
            pl.col("region").str.strip_chars(),
            pl.col("price_per_gallon").cast(pl.Float64),
        )
        .unique(subset=["date", "region", "fuel_grade"])
        .sort(["date", "region", "fuel_grade"])
    )

    # Validation
    assert df.height > 0
    assert df["price_per_gallon"].min() > 0
    assert set(df["fuel_grade"].unique().to_list()) == {
        "Regular",
        "Premium",
    }

    assert (
        df.select(pl.struct(["date", "region", "fuel_grade"]).n_unique()).item()
        == df.height
    )

    # Export PostgreSQL-ready data.
    df.write_csv(OUTPUT_FILE)

    print("\nEIA INGESTION COMPLETE")
    print(f"Total records: {df.height:,}")
    print(f"Regions: {df['region'].n_unique()}")
    print(f"Date range: {df['date'].min()} " f"to {df['date'].max()}")

    print("\nRecords by fuel grade:")
    print(
        df.group_by("fuel_grade")
        .agg(
            pl.len().alias("records"),
            pl.col("region").n_unique().alias("regions"),
        )
        .sort("fuel_grade")
    )

    print("\nMost recent U.S. fuel prices:")
    print(df.filter(pl.col("region") == "U.S.").sort("date", descending=True).head(8))

    print(f"\nSaved to: {OUTPUT_FILE}")
    return df


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="Download the latest EIA workbook",
    )
    args = parser.parse_args()

    ingest_eia(refresh=args.refresh)
