#!/usr/bin/env python3
"""Gate the graph-backed learning and population diagnostic JSON."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise AssertionError(message)


def finite(value, label: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError):
        fail(f"{label} is not numeric")
    if not math.isfinite(result):
        fail(f"{label} is not finite")
    return result


def check_learning(report: dict) -> None:
    if report.get("schemaVersion") != 1 or report.get("diagnostic") != "learning":
        fail("expected learning diagnostics schemaVersion=1")
    if report.get("brainReceivesCoordinates") is not False:
        fail("learning report must prove that coordinates do not enter the brain")

    training = report["training"]
    trained = report["trained"]
    untrained = report["untrained"]
    disabled = report["disabled"]
    persistence = report["persistence"]
    reversal = report["reversal"]

    consumed = finite(training["consumed"], "training consumed")
    rewarded = finite(training["finalMemory"]["rewardedIntake"], "rewarded intake")
    if consumed <= 0 or rewarded <= 0:
        fail("training did not produce actual physical consumption")
    if abs(consumed - rewarded) > 1e-6:
        fail("memory reward differs from world food-remaining delta")
    if finite(training["finalMemory"]["bananaGain"], "banana gain") <= 1.0001:
        fail("actual banana consumption did not increase banana gain")
    if abs(finite(trained["firstProbeNeuralDigest"], "trained digest") -
           finite(untrained["firstProbeNeuralDigest"], "untrained digest")) <= 0.001:
        fail("trained and untrained graph responses are indistinguishable")
    if abs(finite(trained["firstProbeMovement"], "trained movement") -
           finite(untrained["firstProbeMovement"], "untrained movement")) <= 0.5:
        fail("trained and untrained movement did not differ")
    if abs(finite(disabled["firstProbeNeuralDigest"], "disabled digest") -
           finite(untrained["firstProbeNeuralDigest"], "untrained digest")) > 0.001:
        fail("learning-disabled input is not neutral")
    if abs(finite(report["bananaCueProbe"]["firstProbeNeuralDigest"], "banana cue probe") -
           finite(report["berryCueProbe"]["firstProbeNeuralDigest"], "berry cue probe")) <= 0.001:
        fail("trained banana and berry cue probes are indistinguishable")
    two_food = report["twoFoodChoice"]
    baseline_food = report["twoFoodBaseline"]
    if finite(two_food["bananaConsumed"], "two-food banana consumption") + \
            finite(two_food["berryConsumed"], "two-food berry consumption") <= 0:
        fail("symmetric two-food trial consumed neither target")
    if not math.isclose(
        finite(two_food["bananaConsumed"], "two-food banana consumption") +
        finite(two_food["berryConsumed"], "two-food berry consumption") +
        finite(two_food["remainingFood"], "two-food remaining food"),
        1.0, abs_tol=1e-6,
    ):
        fail("two-food conservation accounting is inconsistent")
    if two_food.get("firstConsumedKind") not in ("banana", "berry"):
        fail("two-food trial did not identify the first consumed kind")
    if not two_food.get("rawSensoryPreserved") or not baseline_food.get("rawSensoryPreserved"):
        fail("two-food adapted input overwrote raw sensory state")
    if abs(finite(two_food["firstProbeNeuralDigest"], "two-food trained digest") -
           finite(baseline_food["firstProbeNeuralDigest"], "two-food baseline digest")) <= 0.001 and \
       abs(finite(two_food["pathDistance"], "two-food trained path") -
           finite(baseline_food["pathDistance"], "two-food baseline path")) <= 1.0:
        fail("two-food trial showed no measurable trained choice effect")
    if not persistence.get("equalAfterDecode"):
        fail("memory checkpoint did not round-trip")
    if finite(persistence["restoredProbeNeuralDelta"], "persistence delta") > 0.001:
        fail("restored memory changed the graph probe")
    if not all(report[name]["rawSensoryPreserved"] for name in
               ("training", "trained", "disabled")):
        fail("adapted neural input overwrote raw world sensory state")
    if finite(reversal["reversedValue"], "reversed value") >= finite(reversal["trainedValue"], "trained value"):
        fail("paired threat did not reverse the food association")
    if abs(finite(reversal["forgottenValue"], "forgotten value")) >= abs(finite(reversal["reversedValue"], "reversed value")):
        fail("forgetting did not reduce the reversed association")
    if finite(reversal["threatFrames"], "threat frames") <= 0:
        fail("reversal trial produced no world threat input")

    checks = report.get("checks", {})
    required = ("actualConsumption", "foodGain", "graphResponseChanged", "movementChanged",
                "disabledNeutral", "persistence", "rawSensoryPreserved",
                "twoFoodRawSensoryPreserved", "reversal", "forgetting")
    if any(checks.get(name) is not True for name in required):
        fail("one or more Swift learning checks failed")


def check_population(report: dict) -> None:
    if report.get("schemaVersion") != 1 or report.get("diagnostic") != "population":
        fail("expected population diagnostics schemaVersion=1")
    if report.get("brainReceivesCoordinates") is not False:
        fail("population report must prove that coordinates do not enter the brain")
    cases = report.get("cases", [])
    by_count = {int(case["individualCount"]): case for case in cases}
    if set(by_count) != {2, 4}:
        fail("population report must contain exactly 2 and 4 member cases")
    for count, case in by_count.items():
        if int(case["brainCount"]) != count:
            fail(f"{count}-member case did not use one brain per member")
        for field in ("foodConserved", "memoryIsolation", "independentBrains",
                      "rawSensoryPreserved", "selectedTouchIsolation",
                      "targetedAdvanceIsolation", "selectedMemoryIsolation",
                      "pausedFrozen"):
            if case.get(field) is not True:
                fail(f"{count}-member population check failed: {field}")
        if finite(case["realtimeFactor"], f"{count}-member realtime factor") <= 0:
            fail(f"{count}-member case has no runtime benchmark")
        remaining = finite(case["remainingFood"], f"{count}-member remaining food")
        if remaining < -1e-8:
            fail(f"{count}-member food remaining is negative")
        for key, value in case["consumedByIndividual"].items():
            if finite(value, f"consumed {key}") < -1e-8:
                fail(f"{count}-member consumption is negative")

    checks = report.get("checks", {})
    required = ("twoAgents", "fourAgents", "foodConservation", "memoryIsolation",
                "independentBrains", "selectedTouchIsolation", "targetedAdvanceIsolation",
                "selectedMemoryIsolation", "pausedFrozen",
                "rawSensoryPreserved")
    if any(checks.get(name) is not True for name in required):
        fail("one or more Swift population checks failed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", type=Path,
                        help="diagnostic JSON path; stdin when omitted")
    parser.add_argument("--learning", action="store_true",
                        help="require learning diagnostic output")
    parser.add_argument("--population", action="store_true",
                        help="require population diagnostic output")
    args = parser.parse_args()
    raw = args.path.read_text(encoding="utf-8") if args.path else sys.stdin.read()
    report = json.loads(raw)
    mode = "learning" if args.learning else "population" if args.population else report.get("diagnostic")
    if mode == "learning":
        check_learning(report)
    elif mode == "population":
        check_population(report)
    else:
        fail("choose --learning/--population or provide a report with diagnostic")
    print(f"verify-evolution: {mode} PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, json.JSONDecodeError) as error:
        print(f"verify-evolution: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
