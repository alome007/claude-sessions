from __future__ import annotations

from .support import Workspace


class ArchiveTests(Workspace):
    def setUp(self) -> None:
        super().setUp()
        self.add_plans()
        self.app.index.refresh()
        self.app.plans.resolve_projects()

    def test_an_archived_project_leaves_the_full_list_until_unarchived(self) -> None:
        everyone = self.app.facets()["total"]
        self.app.set_archived("/other", True)
        self.assertEqual(self.app.facets()["archived"], ["/other"])
        self.assertEqual(self.app.facets()["total"], everyone - 1)
        self.assertEqual(self.ids(), {"aaa"})
        self.assertEqual(self.ids(q="kotlin"), {"aaa"})
        self.assertEqual(self.ids(project="/other"), {"bbb"})
        self.app.set_archived("/other", False)
        self.assertEqual(self.app.facets()["archived"], [])
        self.assertEqual(self.ids(), {"aaa", "bbb"})

    def test_bad_archive_requests_are_refused(self) -> None:
        with self.assertRaises(ValueError):
            self.app.set_archived("/nowhere", True)
        with self.assertRaises(ValueError):
            self.app.set_archived("/other", "yes")
