"""Isolated checks for the failure modes listed in README.md (bootstrap).

Run: python3 -m unittest discover -s tools/work
"""
from __future__ import annotations

import unittest

from bootstrap import BootstrapError, plan_labels, plan_options

DECLARED = [
    {"name": "Ready", "color": "BLUE", "description": "Claimable"},
    {"name": "In progress", "color": "YELLOW", "description": "Claimed"},
    {"name": "Done", "color": "GREEN", "description": "Closed"},
]


def live(name, option_id, color="BLUE", description=""):
    return {"id": option_id, "name": name, "color": color, "description": description}


class OptionPlanTests(unittest.TestCase):
    # Failure mode 1: matched options must keep their IDs, even across a
    # case-only rename, or items that use them lose their values.
    def test_matched_options_keep_ids_across_case_rename(self):
        plan = plan_options(
            [live("Todo", "a"), live("In Progress", "b", "YELLOW"), live("Done", "c", "GREEN")],
            DECLARED,
            used_option_ids=set(),
        )
        by_name = {option["name"]: option for option in plan.options}
        self.assertEqual(by_name["In progress"]["id"], "b")
        self.assertEqual(by_name["Done"]["id"], "c")
        self.assertNotIn("id", by_name["Ready"])
        self.assertEqual(plan.removed, ["Todo"])

    # Failure mode 2: an undeclared option that items still use is never removed.
    def test_refuses_to_remove_option_in_use(self):
        with self.assertRaises(BootstrapError) as raised:
            plan_options([live("Todo", "a"), live("Done", "c", "GREEN")], DECLARED, used_option_ids={"a"})
        self.assertIn("Todo", str(raised.exception))

    # Failure mode 3: live state equal to the declaration plans as unchanged.
    def test_matching_live_state_is_unchanged(self):
        current = [
            live("Ready", "r", "BLUE", "Claimable"),
            live("In progress", "p", "YELLOW", "Claimed"),
            live("Done", "d", "GREEN", "Closed"),
        ]
        self.assertFalse(plan_options(current, DECLARED, used_option_ids=set()).changed)

    def test_reorder_is_a_change(self):
        current = [
            live("Done", "d", "GREEN", "Closed"),
            live("Ready", "r", "BLUE", "Claimable"),
            live("In progress", "p", "YELLOW", "Claimed"),
        ]
        plan = plan_options(current, DECLARED, used_option_ids=set())
        self.assertTrue(plan.changed)
        self.assertEqual([option["id"] for option in plan.options], ["r", "p", "d"])


class LabelPlanTests(unittest.TestCase):
    # Failure mode 3 for labels: GitHub treats label names case-insensitively
    # and may return colors in either case.
    def test_case_differences_do_not_plan_changes(self):
        declared = [{"name": "bug", "color": "d73a4a", "description": "Broken"}]
        current = [{"name": "Bug", "color": "D73A4A", "description": "Broken"}]
        creates, updates, undeclared = plan_labels(current, declared)
        self.assertEqual((creates, undeclared), ([], []))
        self.assertEqual(updates, [("Bug", declared[0])])  # name case differs

    def test_undeclared_labels_are_reported_not_deleted(self):
        declared = [{"name": "bug", "color": "d73a4a", "description": "Broken"}]
        current = [
            {"name": "bug", "color": "d73a4a", "description": "Broken"},
            {"name": "wontfix", "color": "ffffff", "description": ""},
        ]
        creates, updates, undeclared = plan_labels(current, declared)
        self.assertEqual((creates, updates, undeclared), ([], [], ["wontfix"]))


if __name__ == "__main__":
    unittest.main()
