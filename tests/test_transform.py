from pathlib import Path

import polars as pl

from src.build_model_mapping import normalize_model

DATA_DIR = Path(__file__).resolve().parents[1] / "data" / "processed"


def load_data(filename):
    """Load a processed CSV for validation."""
    return pl.read_csv(DATA_DIR / filename)


def test_vehicles():
    """Verify EPA vehicle identifiers and fuel efficiency."""
    df = load_data("vehicles_clean.csv")

    assert df.height > 0
    assert df["vehicle_id"].n_unique() == df.height
    assert df["vehicle_id"].null_count() == 0
    assert df["combined_mpg"].null_count() == 0
    assert df["combined_mpg"].min() > 0
    assert df["year"].is_between(2020, 2025).all()

    assert set(df["fuel_type"].unique().to_list()) == {
        "Regular Gasoline",
        "Premium Gasoline",
    }


def test_recalls():
    """Verify NHTSA recall records and duplicate removal."""
    df = load_data("recalls_clean.csv")

    assert df.height > 0
    assert df["campaign_number"].null_count() == 0
    assert df["report_date"].null_count() == 0

    unique_count = (
        df.select(["campaign_number", "make", "model_key", "year"]).unique().height
    )

    assert unique_count == df.height


def test_gas_prices():
    """Verify EIA gasoline prices and fuel grades."""
    df = load_data("gas_prices_clean.csv")

    assert df.height > 0
    assert df["price_per_gallon"].null_count() == 0
    assert df["price_per_gallon"].min() > 0

    assert set(df["fuel_grade"].unique().to_list()) == {
        "Regular",
        "Premium",
    }

    unique_count = df.select(["date", "region", "fuel_grade"]).unique().height

    assert unique_count == df.height


def test_model_normalization():
    """Verify consistent vehicle-model normalization."""
    assert normalize_model("RX 350") == "RX350"
    assert normalize_model("RX350") == "RX350"
    assert normalize_model("A3 quattro") == "A3QUATTRO"
    assert normalize_model("GLC300") == "GLC300"


def test_vehicle_recall_candidates():
    """Verify recall candidates reference existing records."""
    vehicles = load_data("vehicles_clean.csv")
    recalls = load_data("recalls_clean.csv")
    links = load_data("vehicle_recall_candidates.csv")

    assert links.height > 0

    vehicle_ids = set(vehicles["vehicle_id"].to_list())
    campaign_ids = set(recalls["campaign_number"].to_list())

    assert set(links["vehicle_id"].to_list()) <= vehicle_ids
    assert set(links["campaign_number"].to_list()) <= campaign_ids

    assert (links["match_status"] == "exact_name_candidate").all()


def test_unmatched_vehicle_audit():
    """Verify matched and unmatched vehicle coverage."""
    vehicles = load_data("vehicles_clean.csv")
    links = load_data("vehicle_recall_candidates.csv")
    unmatched = load_data("unmatched_vehicles.csv")

    all_ids = set(vehicles["vehicle_id"].to_list())
    matched_ids = set(links["vehicle_id"].to_list())
    unmatched_ids = set(unmatched["vehicle_id"].to_list())

    assert matched_ids.isdisjoint(unmatched_ids)
    assert matched_ids | unmatched_ids == all_ids
