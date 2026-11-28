import argparse
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"


def run_module(module):
    """Run a pipeline module and stop if it fails."""
    print(f"\n{'=' * 55}", flush=True)
    print(f"Running {module}", flush=True)
    print(f"{'=' * 55}", flush=True)

    subprocess.run(
        [sys.executable, "-m", module],
        cwd=PROJECT_ROOT,
        check=True,
    )


def run_pipeline(check_only=False):
    if check_only:
        # Validate existing outputs without downloading again.
        run_module("src.validate_handoff")
        print("\nExisting datasets validated successfully.")
        return

    # 1. EPA ingestion and transformation
    run_module("src.ingest_epa")
    run_module("src.transform")

    # 2. Prepare NHTSA model mappings
    run_module("src.inspect_nhtsa_models")
    run_module("src.build_model_mapping")
    run_module("src.prepare_recall_targets")

    # 3. Collect recalls from pilot and expanded lookups
    run_module("src.ingest_nhtsa")

    # Preserve the current pilot before merging.
    shutil.copy2(
        PROCESSED_DIR / "recalls_clean.csv",
        PROCESSED_DIR / "recalls_pilot.csv",
    )

    run_module("src.ingest_nhtsa_targets")
    run_module("src.merge_recalls")

    # 4. EIA gasoline prices
    run_module("src.ingest_eia")

    # 5. Validate and prepare files for handoff
    run_module("src.validate_handoff")

    print("\nAUTOATLAS PIPELINE COMPLETE")
    print("All ingestion and transformation stages succeeded.")
    print(f"Processed files: {PROCESSED_DIR}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate existing data without rerunning ingestion",
    )

    args = parser.parse_args()

    run_pipeline(check_only=args.check)
