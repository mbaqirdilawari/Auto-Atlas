from pathlib import Path
from zipfile import ZipFile
import io
import requests

EPA_URL = "https://www.fueleconomy.gov/feg/epadata/vehicles.csv.zip"

RAW_DIR = Path("data/raw")


def ingest_epa():
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    output = RAW_DIR / "vehicles.csv"

    if output.exists():
        print("EPA dataset already downloaded.")
        return output

    response = requests.get(EPA_URL, timeout=120)
    response.raise_for_status()

    with ZipFile(io.BytesIO(response.content)) as archive:
        with archive.open("vehicles.csv") as source:
            output.write_bytes(source.read())

    print(f"EPA dataset downloaded: {output}")
    return output


if __name__ == "__main__":
    ingest_epa()
