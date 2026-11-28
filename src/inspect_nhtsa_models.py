from pathlib import Path
import time

import polars as pl
import requests

API_URL = "https://api.nhtsa.gov/products/vehicle/models"
OUTPUT = Path("data/processed/nhtsa_model_catalog.csv")

TARGET_MODELS = {
    "Audi": "A3",
    "BMW": "X3",
    "Honda": "CIVIC",
    "Lexus": "RX",
    "Mercedes-Benz": "GLC",
    "Porsche": "MACAN",
    "Toyota": "CAMRY",
}


def inspect_nhtsa_models():
    records = []

    with requests.Session() as session:
        for make in TARGET_MODELS:
            for year in range(2020, 2026):
                response = session.get(
                    API_URL,
                    params={
                        "make": make,
                        "modelYear": year,
                        "issueType": "r",
                        "max": 1000,
                    },
                    timeout=30,
                )

                response.raise_for_status()
                data = response.json()
                results = data.get("results")

                if not isinstance(results, list):
                    raise ValueError(f"Unexpected API response for {make} {year}")

                for item in results:
                    model = str(item.get("model") or "").strip()

                    if model:
                        records.append(
                            {
                                "make": make,
                                "year": year,
                                "nhtsa_model": model,
                            }
                        )

                print(f"{make} {year}: {len(results)} models")
                time.sleep(0.2)

    if not records:
        raise ValueError("No NHTSA models retrieved.")

    df = (
        pl.DataFrame(records)
        .unique(subset=["make", "year", "nhtsa_model"])
        .sort(["make", "year", "nhtsa_model"])
    )

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    df.write_csv(OUTPUT)

    print("\nPOTENTIAL MODEL MATCHES")

    for make, keyword in TARGET_MODELS.items():
        matches = (
            df.filter(
                (pl.col("make") == make)
                & pl.col("nhtsa_model")
                .str.to_uppercase()
                .str.contains(keyword, literal=True)
            )
            .select("nhtsa_model")
            .unique()
            .sort("nhtsa_model")
        )

        print(f"\n{make}: {matches['nhtsa_model'].to_list()}")

    print(f"\nModel catalog saved to: {OUTPUT}")


if __name__ == "__main__":
    inspect_nhtsa_models()
