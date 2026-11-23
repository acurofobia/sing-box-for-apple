"""Validate the private build input, then copy only the revision and link."""
import json
import os
from pathlib import Path
import sys

def main():
    source, target = map(Path, sys.argv[1:3])
    value = json.loads(source.read_bytes())
    revision, link = value["revision"], value["link"]
    fields = link.removeprefix("wdtt://").split(":", 5)
    if (type(revision) is not int or revision < 1 or not link.startswith("wdtt://")
            or len(fields) != 6 or not all(fields) or not 1 <= int(fields[1]) <= 65535
            or len(link) >= 16000 or any(c.isspace() for c in link)
            or (os.environ.get("CONFIGURATION") == "Release" and fields[0].endswith(".invalid"))):
        raise ValueError()
    target.write_text(json.dumps({"revision": revision, "link": link}), encoding="utf-8")

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        sys.exit("Missing or invalid service WDTT build resource")
