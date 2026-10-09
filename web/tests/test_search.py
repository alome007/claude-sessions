from __future__ import annotations

from .support import Workspace


class SearchTests(Workspace):
    def test_only_spoken_text_is_searchable(self) -> None:
        self.assertEqual(self.ids(q="pangolin"), {"aaa"})
        self.assertEqual(self.ids(q="hidden memo"), set())
        self.assertEqual(self.ids(q="buried"), set())
        self.assertEqual(self.ids(q="unspoken output"), set())

    def test_every_word_must_appear_somewhere_in_the_session(self) -> None:
        self.assertEqual(self.ids(q="kotlin"), {"aaa", "bbb"})
        self.assertEqual(self.ids(q="kotlin debugger"), {"aaa"})
        self.assertEqual(self.ids(q="attach JDI"), {"aaa"})
        self.assertEqual(self.ids(q="attach pangolin"), {"aaa"})
        self.assertEqual(self.ids(q="attach nonexistentword"), set())

    def test_phrases_and_prefixes(self) -> None:
        self.assertEqual(self.ids(q='"attach the kotlin"'), {"aaa"})
        self.assertEqual(self.ids(q='"kotlin attach"'), set())
        self.assertEqual(self.ids(q="debug*"), {"aaa"})
        self.assertEqual(self.ids(q='"unbalanced AND NOT ('), set())

    def test_who_said_it(self) -> None:
        self.assertEqual(self.ids(q="kotlin", role="user"), {"aaa", "bbb"})
        self.assertEqual(self.ids(q="JDI", role="user"), set())

    def test_dates_filter_by_when_the_session_was_active(self) -> None:
        self.assertEqual(self.ids(q="kotlin", since="2026-09-15", until="2026-09-15"), {"bbb"})
        self.assertEqual(self.ids(q="debugger", since="2026-09-16", until="2026-09-16"), {"aaa"})
        self.assertEqual(self.ids(since="2026-09-16", until="2026-09-16"), {"aaa"})
        self.assertEqual(self.ids(since="2026-09-14", until="2026-09-15"), {"aaa", "bbb"})
        self.assertEqual(self.ids(since="nonsense"), {"aaa", "bbb"})

    def test_project_and_branch_filters(self) -> None:
        self.assertEqual(self.ids(project="/other"), {"bbb"})
        self.assertEqual(self.ids(branch="stage"), {"aaa"})
        self.assertEqual(self.ids(q="kotlin", branch="main"), {"bbb"})

    def test_results_carry_a_highlighted_snippet(self) -> None:
        self.app.index.refresh()
        hit = next(row for row in self.app.search({"q": "debugger"})["rows"] if row["id"] == "aaa")
        self.assertEqual((hit["title"], hit["branch"], hit["turns"]), ("Kotlin debugger spike", "stage", 4))
        self.assertIn("\x01debugger\x02", hit["snip"])

    def test_worktrees_are_grouped_under_their_repo(self) -> None:
        self.add_worktree_session()
        self.app.index.refresh()
        self.assertEqual(sorted(self.app.facets()["projects"]), ["/other", "/tmp/demo"])
        self.assertEqual(self.ids(project="/tmp/demo"), {"aaa", "ccc"})
