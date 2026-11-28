from pathlib import Path
from hashlib import sha256
import json
import time

import polars as pl
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

API_URL = "https://api.nhtsa.gov/recalls/recallsByVehicle"

TARGETS_FILE = Path("data/processed/recall_targets.csv")
OUTPUT_FILE = Path("data/processed/recalls_expanded.csv")
AUDIT_FILE = Path("data/processed/nhtsa_expanded_lookup_status.csv")
CACHE_DIR = Path("data/raw/nhtsa_cache")


def fetch_recalls(session, make, model, year):
    """Fetch recalls and cache successful or empty responses."""

    key = f"{make}|{model}|{year}"
    filename = sha256(key.encode()).hexdigest() + ".json"
    cache_file = CACHE_DIR / filename

    if cache_file.exists():
        return json.loads(cache_file.read_text()), True

    response = session.get(
        API_URL,
        params={
            "make": make,
            "model": model,
            "modelYear": year,
        },
        timeout=30,
    )

    try:
        payload = response.json()
    except ValueError:
        response.raise_for_status()
        raise ValueError(f"Invalid JSON response for {key}")

    if not isinstance(payload, dict):
        raise ValueError(f"Unexpected response for {key}")

    results = payload.get("results", payload.get("Results"))
    count = payload.get("Count", payload.get("count"))

    # The API can return HTTP 400 for an empty lookup.
    if response.status_code == 400:
        if not (results == [] and str(count) == "0"):
            response.raise_for_status()
    else:
        response.raise_for_status()

    if not isinstance(results, list):
        raise ValueError(f"Invalid recall results for {key}")

    status = "returned_records" if results else "empty_or_unmatched"

    cached_data = {
        "lookup_status": status,
        "results": results,
    }

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps(cached_data))

    time.sleep(0.2)

    return cached_data, False


def ingest_nhtsa_targets():
    """Retrieve recall records for our mapped vehicle targets."""

    targets = (
        pl.read_csv(TARGETS_FILE)
        .select(["make", "model", "year"])
        .unique()
        .sort(["make", "model", "year"])
    )

    records = []
    audit = []
    cache_hits = 0

    print(f"Starting {targets.height} NHTSA lookups")

    # Retry temporary server errors and rate limits.
    retry_policy = Retry(
        total=3,
        backoff_factor=1,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET"],
    )

    adapter = HTTPAdapter(max_retries=retry_policy)

    with requests.Session() as session:
        session.mount("https://", adapter)

        for index, target in enumerate(targets.iter_rows(named=True), start=1):
            make = target["make"]
            model = target["model"]
            year = int(target["year"])

            data, from_cache = fetch_recalls(session, make, model, year)

            if from_cache:
                cache_hits += 1

            results = data["results"]

            audit.append(
                {
                    "make": make,
                    "model": model,
                    "year": year,
                    "records_returned": len(results),
                    "lookup_status": data["lookup_status"],
                    "from_cache": from_cache,
                }
            )

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

            if index % 25 == 0 or index == targets.height:
                print(
                    f"Completed {index}/{targets.height} "
                    f"lookups; records collected: {len(records)}"
                )

    # Save lookup audit
    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)

    audit_df = pl.DataFrame(audit)
    audit_df.write_csv(AUDIT_FILE)

    if not records:
        raise ValueError("No recalls retrieved. Check lookup status file.")

    # Transform records using Polars
    df = pl.DataFrame(records)

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

    # Data validation
    assert df.height > 0
    assert df["campaign_number"].null_count() == 0
    assert df["year"].is_between(2020, 2025).all()

    df.write_csv(OUTPUT_FILE)

    print("\nNHTSA EXPANDED INGESTION COMPLETE")
    print(f"Lookup targets: {targets.height:,}")
    print(f"Successful cached lookups: {cache_hits:,}")
    print(f"Cleaned recall records: {df.height:,}")
    print(f"Missing report dates: {df['report_date'].null_count():,}")

    print("\nRecalls by manufacturer:")
    print(df.group_by("make").len().sort("make"))

    print("\nLookup statuses:")
    print(audit_df.group_by("lookup_status").len().sort("lookup_status"))

    print(f"\nSaved recalls: {OUTPUT_FILE}")
    print(f"Saved audit: {AUDIT_FILE}")

    return df


if __name__ == "__main__":
    ingest_nhtsa_targets()
