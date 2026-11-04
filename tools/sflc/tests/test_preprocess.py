#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Regression tests for SFL+ preprocessor."""
import sys
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIR))

import sflp_parse  # noqa: E402


class PreprocessTests(unittest.TestCase):
    def test_basic_comments_and_lines(self):
        src = (
            "// line comment\n"
            "circuit test {\n"
            "    /* block comment\n"
            "       spanning lines */\n"
            "    input a<8>;\n"
            "}"
        )
        lines, includes, macros = sflp_parse.preprocess(src, set())
        self.assertEqual(len(lines), 6)
        self.assertEqual(lines[0].strip(), "")
        self.assertEqual(lines[1], "circuit test {")
        self.assertEqual(lines[2].strip(), "")
        self.assertEqual(lines[3].strip(), "")
        self.assertEqual(lines[4], "    input a<8>;")
        self.assertEqual(lines[5], "}")
        self.assertEqual(includes, [])
        self.assertEqual(macros, {})

    def test_defines_and_conditionals(self):
        src = (
            "#define FOO\n"
            "#ifdef FOO\n"
            "line_foo\n"
            "#else\n"
            "line_not_foo\n"
            "#endif\n"
            "#ifndef BAR\n"
            "line_not_bar\n"
            "#endif\n"
        )
        defines = set()
        lines, includes, macros = sflp_parse.preprocess(src, defines)
        self.assertIn("FOO", defines)
        self.assertEqual(lines[2], "line_foo")
        self.assertEqual(lines[4], "")
        self.assertEqual(lines[7], "line_not_bar")

    def test_macros_and_includes(self):
        src = (
            '%i "header.h"\n'
            "%d WIDTH 16\n"
            "input data<WIDTH>;\n"
        )
        lines, includes, macros = sflp_parse.preprocess(src, set())
        self.assertEqual(includes, ["header.h"])
        self.assertEqual(macros.get("WIDTH"), "16")
        self.assertEqual(lines[2], "input data<16>;")

    def test_unknown_directive_raises(self):
        src = "#invalid_directive"
        with self.assertRaises(SyntaxError):
            sflp_parse.preprocess(src, set())


if __name__ == '__main__':
    unittest.main()
