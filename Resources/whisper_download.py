#!/usr/bin/env python3

import argparse
import json

from huggingface_hub import snapshot_download


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--destination", required=True)
    args = parser.parse_args()

    downloaded_path = snapshot_download(
        repo_id=args.model,
        local_dir=args.destination,
    )
    print(json.dumps({"path": downloaded_path}, ensure_ascii=False))


if __name__ == "__main__":
    main()
