#!/usr/bin/env python3
"""Verify the deterministic two-meal hunger diagnostic report."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path


def number(value, name):
    assert isinstance(value, (int, float)) and math.isfinite(float(value)), f"{name}: not finite"
    return float(value)


def verify(report):
    assert isinstance(report, dict) and report.get("schemaVersion") == 1
    assert report.get("initialHunger") == 0.65
    assert report.get("initialFoodMotivated") is True
    assert report.get("brainReceivesCoordinates") is False
    assert report.get("cyclesCompleted") is True, "two-meal cycle did not complete"
    assert number(report.get("modelSeconds"), "modelSeconds") <= 360
    assert report.get("clearFoodBodyUnchanged") is True

    first = number(report.get("firstFoodConsumed"), "firstFoodConsumed")
    remaining = number(report.get("firstFoodRemainingAtClear"), "firstFoodRemainingAtClear")
    second = number(report.get("secondFoodConsumed"), "secondFoodConsumed")
    assert first > 0, "first meal was not consumed"
    assert remaining > 0, "first meal was fully depleted before clear"
    assert second > 0, "second meal was not consumed"
    assert math.isclose(first + remaining, 1, abs_tol=1e-6), "first meal accounting mismatch"
    assert math.isclose(number(report.get("totalConsumed"), "totalConsumed"),
                        first + second, abs_tol=1e-6), "intake accounting mismatch"
    assert number(report.get("maxPNDuringHungry"), "hungry PN") > 30
    assert number(report.get("maxPNDuringSettledFull"), "full PN") < 5
    assert number(report.get("recoveryDurationSeconds"), "recoveryDurationSeconds") > 100
    assert number(report.get("secondMealCompletionSeconds"), "secondMealCompletionSeconds") > 0

    milestones = report.get("milestones", [])
    names = {item.get("name") for item in milestones}
    for expected in ("initial", "firstFoodFull", "firstFoodClearedAfterFull",
                     "secondFoodPlacedAfterRecovery", "secondFoodFull"):
        assert expected in names, f"missing milestone: {expected}"
    for item in milestones + report.get("sparseTrace", []):
        hunger = number(item.get("hunger"), "hunger")
        assert 0 <= hunger <= 1, f"hunger outside [0,1]: {hunger}"

    print("PASS hunger cycle: first meal partial, recovery, second meal")
    print(f"INFO model={report['modelSeconds']:g}s first={first:.3f} "
          f"remaining={remaining:.3f} second={second:.3f}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", nargs="?", type=Path, default=Path("artifacts/hunger.json"))
    args = parser.parse_args()
    try:
        verify(json.loads(args.report.read_text()))
    except (OSError, json.JSONDecodeError, AssertionError) as error:
        print(f"FAIL hunger report: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
