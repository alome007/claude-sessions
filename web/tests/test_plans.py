from __future__ import annotations

from .support import Workspace


class PlanTests(Workspace):
    def setUp(self) -> None:
        super().setUp()
        self.add_plans()
        self.app.index.refresh()

    def plans(self) -> dict:
        return {plan["id"]: plan for plan in self.app.plan_list()}

    def test_the_earliest_session_to_write_a_plan_owns_it(self) -> None:
        plans = self.plans()
        self.assertEqual(plans["alpha"]["project"], "/tmp/demo")
        self.assertEqual(plans["alpha"]["title"], "Alpha plan")
        self.assertEqual((plans["beta"]["project"], plans["beta"]["title"]), ("", "beta"))

    def test_edits_are_saved(self) -> None:
        self.app.edit_plan("beta", {"pinned": True, "tags": [" spike ", ""], "status": "active"})
        self.assertEqual(self.app.plan_list()[0]["id"], "beta")
        self.assertEqual(self.plans()["beta"]["tags"], ["spike"])
        self.assertEqual(self.plans()["beta"]["status"], "active")
        self.app.edit_plan("alpha", {"project": "/other", "progress": 0.5})
        self.assertEqual(self.plans()["alpha"]["project"], "/other")
        self.assertEqual(self.plans()["alpha"]["progress"], 0.5)
        self.app.edit_plan("alpha", {"body": "# Renamed\n"})
        self.assertEqual(self.plans()["alpha"]["title"], "Renamed")

    def test_bad_edits_are_refused(self) -> None:
        refused = [
            ("../alpha", {}), (None, {}), ("alpha", {"status": "done"}), ("alpha", {"progress": 2}),
            ("alpha", {"progress": True}), ("alpha", {"project": "/nowhere"}), ("alpha", {"pinned": "yes"}),
            ("alpha", {"tags": "spike"}), ("alpha", {"colour": "red"}),
        ]
        for plan_id, change in refused:
            with self.subTest(plan_id=plan_id, change=change), self.assertRaises(ValueError):
                self.app.edit_plan(plan_id, change)

    def test_deleting_removes_the_file_and_its_settings(self) -> None:
        self.app.edit_plan("beta", {"pinned": True})
        self.app.delete_plan("beta")
        self.assertEqual(set(self.plans()), {"alpha"})
        self.assertNotIn("beta", self.app.plans.sidecar.read()["plans"])
        with self.assertRaises(ValueError):
            self.app.delete_plan("beta")
