"""python3 -I demos/lib/test_events.py"""
import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(__file__))
import events

LINES = [
    {"t": 0.0, "type": "system", "subtype": "init"},
    {"t": 2.5, "type": "assistant", "message": {"content": [{"type": "tool_use", "name": "mcp__chauffeur__act",
        "input": {"action": "tap", "target": "e4"}}], "usage": {"input_tokens": 1000, "output_tokens": 50}}},
    {"t": 4.0, "type": "user", "message": {"content": [{"type": "tool_result",
        "content": "tap e4 \"Submit\" → NO EFFECT · the accessibility tree did not change\nhint: e4 is disabled"}]}},
    {"t": 6.0, "type": "result", "result": "Submit is disabled.", "num_turns": 2, "total_cost_usd": 0.031},
]


class EventsTests(unittest.TestCase):
    def test_rows_carry_time_kind_text_and_running_counters(self):
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "s.jsonl"), os.path.join(d, "e.tsv")
            open(src, "w").write("\n".join(json.dumps(l) for l in LINES))
            events.main([src, out])
            rows = [r.split("\t") for r in open(out).read().splitlines()]
        self.assertEqual([r[1] for r in rows], ["call", "result", "detail", "answer"])
        self.assertEqual(rows[0][0], "2.5")
        self.assertIn("tap e4", rows[0][2])
        self.assertEqual(rows[1][2], "tap e4 \"Submit\" → NO EFFECT · the accessibility tree did not change")
        self.assertEqual(rows[0][3:], ["1", "1050", "0.000"])
        self.assertEqual(rows[2][2], "hint: e4 is disabled")
        self.assertEqual(rows[3][3:], ["2", "1050", "0.031"])

    def test_two_tool_calls_in_one_message_both_get_counters(self):
        two = [dict(LINES[1])]
        two[0]["message"] = {"content": [LINES[1]["message"]["content"][0]] * 2, "usage": {"input_tokens": 10, "output_tokens": 0}}
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "s.jsonl"), os.path.join(d, "e.tsv")
            open(src, "w").write(json.dumps(two[0]))
            events.main([src, out])
            rows = [r.split("\t") for r in open(out).read().splitlines()]
        self.assertEqual([r[3] for r in rows], ["1", "2"])

    def test_cached_input_counts_as_tokens_and_markdown_bold_is_dropped(self):
        line = {"t": 1, "type": "assistant", "message": {"content": [], "usage": {"input_tokens": 5, "output_tokens": 5,
                "cache_read_input_tokens": 900, "cache_creation_input_tokens": 90}}}
        done = {"t": 2, "type": "result", "result": "Dark Mode is **on**.", "num_turns": 1, "total_cost_usd": 0.01}
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "s.jsonl"), os.path.join(d, "e.tsv")
            open(src, "w").write(json.dumps(line) + "\n" + json.dumps(done))
            events.main([src, out])
            row = open(out).read().splitlines()[0].split("\t")
        self.assertEqual(row[2], "Dark Mode is on.")
        self.assertEqual(row[4], "1000")

    def test_the_home_directory_is_redacted(self):
        home = os.path.expanduser("~")
        line = {"t": 1, "type": "user", "message": {"content": [{"type": "tool_result", "content": f"wrote {home}/x.png"}]}}
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "s.jsonl"), os.path.join(d, "e.tsv")
            open(src, "w").write(json.dumps(line))
            events.main([src, out])
            self.assertIn("wrote ~/…", open(out).read())

    def test_a_path_under_home_shows_no_folder_names(self):
        home = os.path.expanduser("~")
        line = {"t": 1, "type": "user", "message": {"content": [{"type": "tool_result",
                "content": f"workspacePath: {home}/Developer/repos/Private-app/App.xcworkspace, name: App"}]}}
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "s.jsonl"), os.path.join(d, "e.tsv")
            open(src, "w").write(json.dumps(line))
            events.main([src, out])
            text = open(out).read()
        self.assertNotIn("Private-app", text)
        self.assertIn("workspacePath: ~/…, name: App", text)

    def test_temp_directories_are_redacted(self):
        line = {"t": 1, "type": "user", "message": {"content": [{"type": "tool_result",
                "content": "screenshot → /var/folders/ab/c_d/T/chauffeur/shot.jpg"}]}}
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "s.jsonl"), os.path.join(d, "e.tsv")
            open(src, "w").write(json.dumps(line))
            events.main([src, out])
            self.assertIn("screenshot → $TMPDIR/chauffeur/shot.jpg", open(out).read())

    def test_crash_lines_follow_the_outcome_line_three_at_most(self):
        text = ('tap e50 "Crash" → changed · rev 1→2\nAPP CRASHED: dev.chauffeur.fixture (pid 7)\n'
                'reason: "FixtureApp.swift:57: Fatal error: fixture crash"\nlogs: [fault] "crashing"\n'
                '+ text "a"\nhint: rebuild')
        line = {"t": 1, "type": "user", "message": {"content": [{"type": "tool_result", "content": text}]}}
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "s.jsonl"), os.path.join(d, "e.tsv")
            open(src, "w").write(json.dumps(line))
            events.main([src, out])
            rows = [r.split("\t") for r in open(out).read().splitlines()]
        self.assertEqual([r[1] for r in rows], ["result", "detail", "detail", "detail"])
        self.assertTrue(rows[1][2].startswith("APP CRASHED"))
        self.assertTrue(rows[2][2].startswith("reason:"))

    def test_a_path_is_redacted_before_the_line_is_shortened(self):
        line = {"t": 1, "type": "user", "message": {"content": [{"type": "tool_result",
                "content": "logs · " + "x" * 80 + " · full log: /var/folders/ab/c_d/T/chauffeur/logs.txt"}]}}
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "s.jsonl"), os.path.join(d, "e.tsv")
            open(src, "w").write(json.dumps(line))
            events.main([src, out])
            self.assertNotIn("/var/fo", open(out).read())


if __name__ == "__main__":
    unittest.main()
