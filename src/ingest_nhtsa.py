from pathlib import Path
import time

import polars as pl
import requests

# NHTSA API
API_URL = "https://api.nhtsa.gov/recalls/recallsByVehicle"

# Output files
OUTPUT = Path("data/processed/recalls_clean.csv")
AUDIT_OUTPUT = Path("data/processed/nhtsa_lookup_status.csv")

# Initial models to retrieve recalls for
MODELS = {
    "Audi": ["A3"],
    "BMW": ["X3"],
    "Honda": ["Civic"],
    "Lexus": ["RX350"],
    "Mercedes-Benz": ["GLC300"],
    "Porsche": ["Macan"],
    "Toyota": ["Camry"],
}


def ingest_nhtsa():
    records = []
    audit = []

    with requests.Session() as session:

        for make, models in MODELS.items():
            for model in models:
                for year in range(2020, 2026):

                    response = session.get(
                        API_URL,
                        params={
                            "make": make,
                            "model": model,
                            "modelYear": year,
                        },
                        timeout=30,
                    )

                    # Parse the response
                    response.raise_for_status() if response.status_code != 400 else None

                    try:
                        payload = response.json()
                    except ValueError:
                        response.raise_for_status()
                        raise ValueError(f"Invalid JSON: {make} {model} {year}")

                    results = payload.get("results", payload.get("Results"))
                    count = payload.get("Count", payload.get("count"))

                    # Handle NHTSA HTTP 400 empty results
                    if response.status_code == 400:
                        if results == [] and str(count) == "0":
                            print(f"{make} {model} {year}: " "No matching records")

                            audit.append(
                                {
                                    "make": make,
                                    "model": model,
                                    "year": year,
                                    "records_returned": 0,
                                    "lookup_status": "empty_or_unmatched",
                                }
                            )

                            time.sleep(0.2)
                            continue

                        # Raise genuine HTTP 400 errors
                        response.raise_for_status()

                    if not isinstance(results, list):
                        raise ValueError(f"Invalid response: {make} {model} {year}")

                    # Record successful lookups
                    audit.append(
                        {
                            "make": make,
                            "model": model,
                            "year": year,
                            "records_returned": len(results),
                            "lookup_status": (
                                "success" if results else "empty_or_unmatched"
                            ),
                        }
                    )

                    # Extract recall information
                    for recall in results:
                        records.append(
                            {
                                "campaign_number": recall.get("NHTSACampaignNumber"),
                                "make": make,
                                "model": model,
                                "year": year,
                                "component": recall.get("Component"),
                                "summary": recall.get("Summary"),
                                "consequence": recall.get("Consequence"),
                                "remedy": recall.get("Remedy"),
                                "report_date_raw": recall.get("ReportReceivedDate"),
                            }
                        )

                    print(f"{make} {model} {year}: " f"{len(results)} recalls")

                    time.sleep(0.2)

    # Create output directory
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    # Export lookup audit
    pl.DataFrame(audit).write_csv(AUDIT_OUTPUT)

    # Build recall dataset
    if not records:
        raise ValueError(
            "No recalls were retrieved. Check model names "
            "against NHTSA before interpreting empty results."
        )

    df = pl.DataFrame(records)

    # Standardize dates and remove duplicate campaigns
    df = (
        df.with_columns(
            pl.col("report_date_raw")
            .str.strptime(
                pl.Date,
                format="%d/%m/%Y",
                strict=False,
            )
            .alias("report_date")
        )
        .drop("report_date_raw")
        .unique(
            subset=[
                "campaign_number",
                "make",
                "model",
                "year",
            ]
        )
        .sort(["make", "model", "year"])
    )

    # Validate and export
    assert df.height > 0
    assert df["campaign_number"].null_count() == 0

    df.write_csv(OUTPUT)

    print("\nNHTSA INGESTION COMPLETE")
    print(f"Total cleaned recall records: {df.height:,}")
    print(f"Saved to: {OUTPUT}")
    print(f"Lookup audit saved to: {AUDIT_OUTPUT}")

    print("\nRecalls by manufacturer:")
    print(df.group_by("make").len().sort("make"))

    print("\nSample records:")
    print(df.head(5))

    return df


if __name__ == "__main__":
    ingest_nhtsa()
