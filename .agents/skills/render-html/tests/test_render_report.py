import importlib.util
import json
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "render_report.py"
SPEC = importlib.util.spec_from_file_location("render_report", SCRIPT_PATH)
assert SPEC and SPEC.loader
RENDER_REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RENDER_REPORT)


def minimal_report(**item_overrides):
    item = {
        "id": "candidate",
        "title": "Candidate",
        "impact": "The report shows the candidate impact.",
    }
    item.update(item_overrides)
    return {"title": "Impact report", "items": [item]}


class RenderReportTests(unittest.TestCase):
    def test_renders_flexible_comparison_in_neutral_order(self):
        fixture = Path(__file__).with_name("interactive-fixture.json")
        data = json.loads(fixture.read_text(encoding="utf-8"))

        rendered = RENDER_REPORT.render_report(data, fixture.parent)

        self.assertIn("Shared evidence", rendered)
        self.assertIn("Observed", rendered)
        self.assertIn("Prototype", rendered)
        self.assertIn("Option 1", rendered)
        self.assertIn('aria-labelledby="__report-item-heading-1"', rendered)
        self.assertIn("Before", rendered)
        self.assertIn("After", rendered)
        self.assertIn('aria-pressed="false"', rendered)
        self.assertIn("Pros", rendered)
        self.assertIn("Cons", rendered)
        self.assertIn("92.0/100", rendered)
        self.assertIn("Deep dive", rendered)
        self.assertIn("language-javascript", rendered)
        self.assertIn("Copy discussion prompt", rendered)
        self.assertIn('href="codex:thread/example"', rendered)
        self.assertIn('data-diagram-action="play"', rendered)
        self.assertLess(
            rendered.index("Remove legacy copy support"),
            rendered.index("Recommendation"),
        )

    def test_rejects_impact_over_300_characters(self):
        with self.assertRaisesRegex(ValueError, "exceeds 300 characters"):
            RENDER_REPORT.render_report(
                minimal_report(impact="x" * 301), Path.cwd()
            )

    def test_rejects_unsafe_deep_dive_url(self):
        with self.assertRaisesRegex(ValueError, "must use codex, http, https"):
            RENDER_REPORT.render_report(
                minimal_report(deepDiveUrl="javascript:alert(1)"), Path.cwd()
            )

    def test_rejects_unknown_fields(self):
        with self.assertRaisesRegex(ValueError, "unknown field changes"):
            RENDER_REPORT.render_report(
                {"title": "Impact report", "items": [{}], "changes": []},
                Path.cwd(),
            )

        with self.assertRaisesRegex(ValueError, "unknown field preferred"):
            RENDER_REPORT.render_report(
                minimal_report(preferred=True), Path.cwd()
            )

    def test_rejects_invalid_evidence_and_recommendations(self):
        report = minimal_report()
        report["evidence"] = [
            {
                "label": "Guess",
                "finding": "This is not classified evidence.",
                "classification": "assumed",
            }
        ]
        with self.assertRaisesRegex(
            ValueError, "observed, proposed, or prototype"
        ):
            RENDER_REPORT.render_report(report, Path.cwd())

        report.pop("evidence")
        report["recommendation"] = {
            "itemId": "missing",
            "rationale": "This item does not exist.",
        }
        with self.assertRaisesRegex(ValueError, "must reference an item id"):
            RENDER_REPORT.render_report(report, Path.cwd())

    def test_rejects_invalid_rubric_totals_and_scores(self):
        report = minimal_report(scores={"correctness": 5})
        report["rubric"] = [
            {"id": "correctness", "label": "Correctness", "weight": 90}
        ]
        with self.assertRaisesRegex(ValueError, "weights must total 100"):
            RENDER_REPORT.render_report(report, Path.cwd())

        report["rubric"][0]["weight"] = 100
        report["items"][0]["scores"]["correctness"] = 6
        with self.assertRaisesRegex(ValueError, "number from 0 to 5"):
            RENDER_REPORT.render_report(report, Path.cwd())

    def test_rejects_missing_or_unknown_score_criteria(self):
        report = minimal_report(scores={"correctness": 5})
        report["rubric"] = [
            {"id": "correctness", "label": "Correctness", "weight": 50},
            {"id": "scope", "label": "Scope", "weight": 50},
        ]
        with self.assertRaisesRegex(ValueError, "missing criterion scope"):
            RENDER_REPORT.render_report(report, Path.cwd())

        report["items"][0]["scores"] = {
            "correctness": 5,
            "scope": 4,
            "novelty": 1,
        }
        with self.assertRaisesRegex(ValueError, "unknown criterion novelty"):
            RENDER_REPORT.render_report(report, Path.cwd())

    def test_rejects_incompatible_state_fields(self):
        with self.assertRaisesRegex(ValueError, "text state cannot define"):
            RENDER_REPORT.render_report(
                minimal_report(
                    before={
                        "kind": "text",
                        "content": "Before",
                        "language": "text",
                    }
                ),
                Path.cwd(),
            )

    def test_rejects_diagram_with_fewer_than_three_nodes(self):
        diagram = {
            "title": "Too small",
            "nodes": [
                {"id": "one", "label": "One"},
                {"id": "two", "label": "Two"},
            ],
            "edges": [],
            "steps": [{"label": "One", "highlights": ["one"]}],
        }

        with self.assertRaisesRegex(ValueError, "at least three"):
            RENDER_REPORT.render_report(
                minimal_report(diagram=diagram), Path.cwd()
            )


if __name__ == "__main__":
    unittest.main()
