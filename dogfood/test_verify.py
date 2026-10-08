"""python3 -I dogfood/test_verify.py"""
import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(__file__))
import verify


def write_run(d, run, answer, appearance="light"):
    with open(os.path.join(d, run + ".jsonl"), "w") as f:
        f.write(json.dumps({"type": "result", "subtype": "success", "result": answer}) + "\n")
    with open(os.path.join(d, run + ".appearance"), "w") as f:
        f.write(appearance + "\n")


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.tasks = {"F3": "claim:row 48", "S2": "appearance:dark", "F6": "hand"}

    def test_claim_check_matches_the_final_answer(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "F3.chauffeur.opus.1", "Row 48 comes right after Row 47.")
            write_run(d, "F3.xcode.opus.1", "It is Row 46.")
            v = verify.verdicts(d, self.tasks)
            self.assertEqual(v["F3.chauffeur.opus.1"][0], "pass")
            self.assertEqual(v["F3.xcode.opus.1"][0], "fail")

    def test_appearance_check_reads_the_end_state_not_the_claim(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "S2.chauffeur.sonnet.2", "Dark Mode is on.", appearance="light")
            self.assertEqual(verify.verdicts(d, self.tasks)["S2.chauffeur.sonnet.2"][0], "fail")

    def test_hand_tasks_and_unknown_tasks_go_to_a_person(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "F6.chauffeur.opus.1", "Allowed.")
            write_run(d, "Z9.chauffeur.opus.1", "?")
            v = verify.verdicts(d, self.tasks)
            self.assertEqual(v["F6.chauffeur.opus.1"][0], "hand")
            self.assertEqual(v["Z9.chauffeur.opus.1"][0], "hand")

    def test_a_run_with_no_final_answer_fails(self):
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, "F3.chauffeur.opus.3.jsonl"), "w").close()
            self.assertEqual(verify.verdicts(d, self.tasks)["F3.chauffeur.opus.3"][0], "fail")

    def test_tasks_file_parses_the_check_column(self):
        with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as f:
            f.write("F3\tfixture\tWhich row?\tclaim:row 48\nS1\tsettings\tVersion?\n")
        t = verify.load_tasks(f.name)
        os.unlink(f.name)
        self.assertEqual(t, {"F3": "claim:row 48", "S1": "hand"})


if __name__ == "__main__":
    unittest.main()
