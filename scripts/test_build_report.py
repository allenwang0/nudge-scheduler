"""Checks that the published report and README say what the committed simulator
output says, because readers take those numbers as-is.

Expected values are recomputed here from site/results.json, independently of
scripts/build_report.py, so a generator bug (wrong scenario, wrong window,
pooled vs single-seed mix-up, counting violations from the wrong run) fails a
test instead of reaching the page.

Run: python3 -m unittest discover -s scripts -p 'test_*.py'
"""

import html
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESULTS = json.loads((ROOT / "site" / "results.json").read_text())
CAP = RESULTS["defaultCap"]


def text_of(page):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", page)))


def build(*extra):
    out = pathlib.Path(tempfile.mkdtemp()) / "index.html"
    subprocess.run([sys.executable, str(ROOT / "scripts" / "build_report.py"), "--out", str(out), *extra],
                   check=True, cwd=ROOT)
    return out.read_text()


def inside(run):
    """Deliveries inside the run's quiet window, recomputed from minute of day."""
    s, e = run["quietStartMinute"], run["quietEndMinute"]
    hit = (lambda m: m >= s or m < e) if s > e else (lambda m: s <= m < e)
    return sum(1 for d in run["deliveries"] if hit(d["minuteOfDay"]))


class ReportNumbers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.page = build()
        cls.text = text_of(cls.page)

    def test_hero_counts_every_delivery_in_both_named_windows(self):
        # The hero is the 5-second takeaway: it must count both windows' runs at
        # the default cap and may only claim "all outside" if none is inside.
        runs = [RESULTS["sweep"][CAP - 1], RESULTS["nightShift"]]
        total = sum(len(r["deliveries"]) for r in runs)
        bad = sum(inside(r) for r in runs)
        self.assertEqual(bad, 0, "owner rule: the hero states a positive result; it changes if any delivery is inside")
        hero = re.search(r'<p class="hero-metric"><span class="value">([^<]+)</span>', self.page).group(1)
        self.assertEqual(hero, f"{total - bad:,} of {total:,}")
        hm = lambda m: f"{m // 60:02d}:{m % 60:02d}"
        win = [f"{hm(r['quietStartMinute'])}–{hm(r['quietEndMinute'])}" for r in runs]
        self.assertEqual(win, ["22:00–08:00", "01:00–07:00"], "hero must name the default and night-shift windows")
        self.assertIn(f"{len(runs[0]['deliveries'])} with quiet hours {win[0]} and {len(runs[1]['deliveries'])} with {win[1]}",
                      self.text)

    def test_pooled_sweep_numbers(self):
        pooled = RESULTS["pooledSweep"]
        total = sum(p["deliveries"] for p in pooled)
        bad = sum(p["quietHourViolations"] for p in pooled)
        self.assertIn(f"{bad:,} of {total:,}", self.text)
        at = pooled[CAP - 1]
        seed_max = [s["maxWait"] for s in at["perSeed"]]
        self.assertEqual(len(seed_max), RESULTS["sweepSeeds"], "spread must come from every seed")
        self.assertIn(f"p90 wait {at['allDrift']['p90Wait']} day", self.text.replace("days", "day"))
        self.assertIn(f"per-seed longest {min(seed_max)}–{max(seed_max)} days", self.text)
        # The pooled max over all drift rings equals the largest per-ring pooled max.
        self.assertEqual(at["allDrift"]["maxWait"], max(r["maxWait"] for r in at["rings"]))

    def test_legacy_comparison_names_both_windows_and_volume(self):
        # The old README compared windows without naming them and ignored that
        # the package sends more reminders; both must stay visible.
        nl, lg, night = RESULTS["nightShiftLegacy"], RESULTS["legacy"], RESULTS["nightShift"]
        self.assertIn(f"{inside(nl)} of {len(nl['deliveries'])} deliveries inside quiet hours 01:00–07:00", self.text)
        self.assertIn(f"{inside(lg)} of {len(lg['deliveries'])} inside 22:00–08:00", self.text)
        ratio = night["meanNudgesPerDay"] / nl["meanNudgesPerDay"]
        self.assertIn(f"{ratio:.1f}× as many reminders per day", self.text)
        self.assertIn("re-implemented from a description", self.text)

    def test_dst_pair_count_comes_from_the_property_test(self):
        src = (ROOT / "Tests" / "NudgeSchedulerTests" / "PropertyTests.swift").read_text()
        starts = int(re.search(r"arguments: 0\.\.<(\d+)\)\n\s+func deliveryInvariants", src).group(1))
        ends = int(re.search(r"for endHour in 0\.\.<(\d+)", src).group(1))
        self.assertIn(f"all {starts * ends} quiet-hour start/end pairs", self.text)

    def test_old_unconditioned_claims_are_gone(self):
        readme = (ROOT / "README.md").read_text()
        for where, text in (("page", self.text), ("README", readme)):
            self.assertNotIn("48 / 80 / 54", text, f"{where}: censored single-seed legacy waits")
            self.assertNotIn("2 / 3 / 4 days", text, f"{where}: single-seed waits presented as the result")
            self.assertNotRegex(text, r"Zero quiet-hour violations in \d", f"{where}: zero result as a headline")

    def test_every_evidence_reference_resolves(self):
        refs = set(re.findall(r'href="#evidence-(e\d+)"', self.page))
        rows = set(re.findall(r'id="evidence-(e\d+)"', self.page))
        self.assertTrue(refs)
        self.assertLessEqual(refs, rows)
        self.assertNotIn("/blob/main/", self.page, "evidence links must point at a commit")

    def test_no_banned_words(self):
        for word in ("proves", "optimal", "production-ready", "guarantees", "state-of-the-art", "real-time",
                     "blazing", "seamless", "leverages"):
            self.assertNotIn(word, self.text.lower())

    def test_committed_page_and_readme_are_current(self):
        self.assertEqual(self.page, (ROOT / "site" / "index.html").read_text(),
                         "site/index.html is stale: run python3 scripts/build_report.py --readme README.md")
        tmp = pathlib.Path(tempfile.mkdtemp()) / "README.md"
        tmp.write_text((ROOT / "README.md").read_text())
        build("--readme", str(tmp))
        self.assertEqual(tmp.read_text(), (ROOT / "README.md").read_text(), "README results block is stale")


if __name__ == "__main__":
    unittest.main()
