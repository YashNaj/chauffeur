"""python3 -I scripts/tests/test_readme_numbers.py"""
import os, subprocess, sys, tempfile, unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "check-readme-numbers.py")
BENCH = "| Median cost per task | $0.061 | $0.402 |\n| Median turns | 5.5 | 15.0 |\n"


def run(readme):
    with tempfile.TemporaryDirectory() as d:
        r, b = os.path.join(d, "README.md"), os.path.join(d, "bench.md")
        open(r, "w").write(readme)
        open(b, "w").write(BENCH)
        return subprocess.run([sys.executable, "-I", SCRIPT, r, b], capture_output=True, text=True)


class ReadmeNumbersTests(unittest.TestCase):
    def test_matching_numbers_pass(self):
        p = run("# x\n## Benchmark\n| | chauffeur | Xcode |\n|---|---|---|\n| Cost | $0.061 | $0.402 |\n## Next\n| 9.9 |\n")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_a_drifted_number_fails_and_is_named(self):
        p = run("## Benchmark\n| Turns | 5.5 | 14.0 |\n")
        self.assertEqual(p.returncode, 1)
        self.assertIn("14.0", p.stdout)


if __name__ == "__main__":
    unittest.main()
