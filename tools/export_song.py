"""Export the current through-composed score without rendering or playback.

This compatibility entry point shares arrange_v11.header(); it must never
silently restore the obsolete v10 score or omit the section/gain/synth lanes.
Use --check for a read-only comparison, or --output to export elsewhere.
"""
import argparse
from pathlib import Path

from arrange_v11 import header


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parent.parent / "song_data.h")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    expected = header()
    if args.check:
        if not args.output.exists() or args.output.read_text(encoding="utf-8") != expected:
            print(f"{args.output}: missing or stale; export the current arrangement")
            return 1
        print(f"{args.output}: current arrangement verified")
        return 0
    args.output.write_text(expected, encoding="utf-8")
    print(f"{args.output}: current arrangement exported")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
