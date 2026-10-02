#!/usr/bin/env python3
"""Check the recorded real-connectome closed-loop experiment, not a mock trace."""
import json
import sys
from pathlib import Path


def verify(path: Path) -> None:
    results = json.loads(path.read_text())
    for condition in ("foodLeft", "foodCenter", "foodRight"):
        trial = results[condition]
        assert trial["tasteFrames"] > 0, f"{condition}: no physical food contact"
        assert trial["feedingFrames"] > 0, f"{condition}: no neural feeding response"
        remaining = sum(food["remaining"] for food in trial["trace"][-1]["foods"])
        assert remaining < 0.95, f"{condition}: food was not consumed"
        print(f"PASS {condition}: food consumed {1 - remaining:.1%}")
    control = results["noFood"]["trace"]
    blocked = results["foodBlocked"]["trace"]
    assert len(control) == len(blocked)
    for baseline, gated in zip(control, blocked):
        assert baseline["fly"] == gated["fly"], "Input gate did not restore baseline trajectory"
        for key in baseline["neural"]:
            if key != "computationMilliseconds":
                assert baseline["neural"][key] == gated["neural"][key], f"Gated neural output differs: {key}"
    assert blocked[-1]["foods"][0]["remaining"] == 1, "Gated food was consumed"
    print("PASS sensory gate: neural outputs and trajectory exactly match no-food control")


if __name__ == "__main__":
    verify(Path(sys.argv[1]) if len(sys.argv) > 1 else Path("artifacts/world-experiment.json"))
