#!/usr/bin/env python3
"""Validate a real-connectome closed-loop foraging diagnostic report.

The checker deliberately does not require the engineered decoder to find every
food location. It verifies that the requested trials ran, that contact and
consumption fields are internally consistent, and that sensory-blocked food
trials reproduce the no-food neural/body trajectory.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any


def finite(value: Any, label: str) -> float:
    if not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        raise AssertionError(f"{label}: expected a finite number")
    return float(value)


def verify(
    report: dict[str, Any],
    require_full_grid: bool = False,
    require_contact: bool = False,
) -> None:
    assert isinstance(report, dict), "report root must be an object"
    assert report.get("schemaVersion") == 1, "unsupported or missing schemaVersion"
    assert isinstance(report.get("calibration"), dict), "calibration is missing"
    world = report.get("world")
    assert isinstance(world, dict), "world description is missing"
    width = finite(world.get("width"), "world.width")
    height = finite(world.get("height"), "world.height")
    assert width == 2560 and height == 1400, "diagnostic must use the wide desktop world"

    model_seconds = finite(report.get("modelSeconds"), "modelSeconds")
    assert model_seconds > 0, "modelSeconds must be positive"
    food_trials = report.get("foodTrials")
    assert isinstance(food_trials, list), "foodTrials is missing"
    if require_full_grid:
        expected = {
            (distance, bearing)
            for distance in (120.0, 220.0, 360.0)
            for bearing in (0.0, 45.0, -45.0, 90.0, -90.0, 180.0)
        }
        actual = {
            (
                round(finite(trial.get("distancePixels"), "distancePixels"), 6),
                round(finite(trial.get("bearingDegrees"), "bearingDegrees"), 6),
            )
            for trial in food_trials
        }
        assert len(food_trials) == len(expected), f"expected 18 food trials, got {len(food_trials)}"
        assert actual == expected, f"expected exact 3x6 grid, got {sorted(actual)}"

    no_food = report.get("noFood")
    blocked = report.get("blockedControls")
    assert isinstance(no_food, dict), "noFood control is missing"
    assert isinstance(blocked, list) and len(blocked) == 3, "expected three blocked controls"
    assert report.get("blockedControlEqual") is True, "blocked controls diverged from noFood"

    no_food_digest = no_food.get("trajectoryDigest")
    assert isinstance(no_food_digest, str) and no_food_digest, "noFood digest is missing"
    assert no_food.get("category") == "noFood"

    # Older reports predate BodyState. New reports must account for appetite
    # and actual intake without changing the existing contact/consumption gate.
    for trial in [no_food, *blocked, *food_trials]:
        trace = trial.get("trace", [])
        if trace and "body" in trace[0]:
            for point in trace:
                body = point["body"]
                assert 0 <= finite(body["hunger"], "body.hunger") <= 1
                assert isinstance(body["isFoodMotivated"], bool)
                assert finite(body["consumedFood"], "body.consumedFood") >= 0
            assert math.isclose(trace[-1]["body"]["consumedFood"],
                                trial["consumedFraction"], abs_tol=1e-6), "intake differs from consumed food"

    for trial in blocked:
        assert trial.get("category") == "blocked", f"unexpected blocked category: {trial.get('category')}"
        assert trial.get("sensoryEnabled") is False, f"{trial.get('id')}: sensory gate is enabled"
        assert trial.get("controlEqualToNoFood") is True, f"{trial.get('id')}: control mismatch"
        assert trial.get("trajectoryDigest") == no_food_digest, f"{trial.get('id')}: digest mismatch"
        assert finite(trial.get("consumedFraction"), f"{trial.get('id')}.consumedFraction") == 0
        assert trial.get("contactTimeSeconds") is None, f"{trial.get('id')}: blocked trial made contact"

    for trial in food_trials:
        trial_id = trial.get("id", "food trial")
        assert trial.get("category") == "food", f"{trial_id}: unexpected category"
        assert trial.get("sensoryEnabled") is True, f"{trial_id}: sensory gate is disabled"
        distance = finite(trial.get("distancePixels"), f"{trial_id}.distancePixels")
        bearing = finite(trial.get("bearingDegrees"), f"{trial_id}.bearingDegrees")
        assert distance > 0, f"{trial_id}: distance must be positive"
        assert math.isfinite(bearing), f"{trial_id}: bearing must be finite"
        consumed = finite(trial.get("consumedFraction"), f"{trial_id}.consumedFraction")
        assert 0 <= consumed <= 1, f"{trial_id}: consumedFraction outside [0, 1]"
        min_distance = finite(trial.get("minDistancePixels"), f"{trial_id}.minDistancePixels")
        assert min_distance >= 0, f"{trial_id}: minDistancePixels is negative"
        total_distance = finite(trial.get("totalDistancePixels"), f"{trial_id}.totalDistancePixels")
        assert total_distance >= 0, f"{trial_id}: totalDistancePixels is negative"
        trace = trial.get("trace")
        assert isinstance(trace, list) and trace, f"{trial_id}: sparse trace is missing"
        pn = trial.get("pnActivity")
        assert isinstance(pn, dict), f"{trial_id}: pnActivity is missing"
        active = finite(pn.get("activeFraction"), f"{trial_id}.pnActivity.activeFraction")
        assert 0 <= active <= 1, f"{trial_id}: PN active fraction outside [0, 1]"

        contact = trial.get("contactTimeSeconds")
        if contact is not None:
            contact_value = finite(contact, f"{trial_id}.contactTimeSeconds")
            assert 0 <= contact_value <= model_seconds, f"{trial_id}: contact time outside run"
            assert consumed >= 0, f"{trial_id}: invalid consumption after contact"
        if require_contact:
            assert contact is not None, f"{trial_id}: no contact"
            assert consumed > 0, f"{trial_id}: no consumption"

    print(
        f"PASS foraging report: {len(food_trials)} food trials, "
        f"3 blocked controls, model={model_seconds:g}s"
    )
    print("PASS blocked controls: body and neural trajectory digests match noFood")
    contacted = sum(1 for trial in food_trials if trial.get("contactTimeSeconds") is not None)
    consumed = sum(1 for trial in food_trials if finite(trial.get("consumedFraction"), "consumedFraction") > 0)
    print(f"INFO food contact={contacted}/{len(food_trials)}, consumption={consumed}/{len(food_trials)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", nargs="?", type=Path, default=Path("artifacts/foraging.json"))
    parser.add_argument(
        "--require-full-grid",
        action="store_true",
        help="require the default 18 food trials in addition to the three controls",
    )
    parser.add_argument(
        "--require-contact",
        action="store_true",
        help="require every food trial to make contact and consume food",
    )
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text())
        verify(
            report,
            require_full_grid=args.require_full_grid,
            require_contact=args.require_contact,
        )
    except (OSError, json.JSONDecodeError, AssertionError) as error:
        print(f"FAIL foraging report: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
