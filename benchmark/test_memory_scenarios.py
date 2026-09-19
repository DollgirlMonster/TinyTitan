"""The three added worlds stay internally consistent.

`memory_scenarios.py` authors facts, the sessions that change them, and the
questions whose answer is in the store. A typo there produces a case whose
ground truth is wrong, which no model run can reveal -- it just looks like a
judge failure. These check the shape before anything runs.

    cd benchmark && python3 -m unittest test_memory_scenarios -v
"""
from __future__ import annotations

import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scenarios = _load("memory_scenarios", "benchmark/memory_scenarios.py")


class ScenarioTests(unittest.TestCase):
    def test_there_are_three_worlds_with_facts(self):
        self.assertEqual(len(scenarios.SCENARIOS), 3)
        for name, world in scenarios.SCENARIOS.items():
            self.assertGreaterEqual(len(world["facts"]), 4, name)
            self.assertTrue(world["narration"], name)

    def test_every_change_names_a_fact_that_exists(self):
        for name, world in scenarios.SCENARIOS.items():
            for session, changes in world["changed"].items():
                self.assertIsInstance(session, int, name)
                for key, value, line in changes:
                    self.assertIn(key, world["facts"], f"{name}: {key}")
                    self.assertTrue(value and line, f"{name}: {key}")

    def test_every_question_targets_a_fact_and_has_a_distractor(self):
        for name, world in scenarios.SCENARIOS.items():
            for question, target, distractor in world["questions"]:
                self.assertIn(target, world["facts"], f"{name}: {target}")
                self.assertIn(distractor, world["facts"], f"{name}: {distractor}")
                self.assertNotEqual(target, distractor, name)

    def test_every_duplicate_conflict_and_update_pair_is_complete(self):
        for name, world in scenarios.SCENARIOS.items():
            for field in ("duplicate", "not_duplicate", "disagree", "agree",
                          "rule_conflict", "rule_update"):
                self.assertEqual(len(world[field]), 5, f"{name}: {field}")
            self.assertEqual(world["rule_conflict"][4], "CONFLICT", name)
            self.assertEqual(world["rule_update"][4], "UPDATE", name)
            self.assertIn(world["rule_conflict"][0], world["facts"], name)
            self.assertIn(world["rule_update"][0], world["facts"], name)
            # UPDATE carries an *irrelevant* rule, as the harness's cases do:
            # the model must see that the rule governs another attribute.
            self.assertTrue(world["rule_update"][3], name)
            self.assertNotIn(world["rule_update"][0].split("/")[-1],
                             world["rule_update"][3], name)

    def test_cases_are_one_decision_jobs_with_both_halves(self):
        jobs = scenarios.cases()
        self.assertGreater(len(jobs), 30)
        for job in jobs:
            self.assertEqual(job["max"], 8)
            self.assertIn(job["truth"], ("YES", "NO", "UPDATE", "CONFLICT"))
            self.assertTrue(job["authored"], "every added case is authored")
        # Every retrieval question must be asked both ways, or a judge that
        # always says yes and one that always says no both score well.
        halves: dict[str, set] = {}
        for job in jobs:
            if job["task"] == "T7":
                question = job["prompt"].split("QUESTION: ")[1].split("\n")[0]
                halves.setdefault(question, set()).add(job["truth"])
        for question, truths in halves.items():
            self.assertEqual(truths, {"YES", "NO"}, question)

    def test_a_contradiction_is_the_same_key_with_an_incompatible_value(self):
        # The harness's T3 convention: YES is one key with two incompatible
        # values. Two *different* keys are a NO even when the values differ,
        # which is why the ops world's first version was a wrong ground truth.
        for name, world in scenarios.SCENARIOS.items():
            key, value, other_key, other_value, truth = world["disagree"]
            self.assertEqual(key, other_key, name)
            self.assertNotEqual(value, other_value, name)
            self.assertEqual(truth, "YES", name)
            a_key, _, b_key, _, truth = world["agree"]
            self.assertNotEqual(a_key, b_key, name)
            self.assertEqual(truth, "NO", name)

    def test_a_non_duplicate_differs_in_both_key_and_value(self):
        # Two different facts, not one fact under two keys: a same-value pair
        # makes "same fact?" a coin toss rather than a test.
        for name, world in scenarios.SCENARIOS.items():
            a_key, a_value, b_key, b_value, truth = world["not_duplicate"]
            self.assertNotEqual(a_key, b_key, name)
            self.assertNotEqual(a_value, b_value, name)
            self.assertEqual(truth, "NO", name)


if __name__ == "__main__":
    unittest.main()
