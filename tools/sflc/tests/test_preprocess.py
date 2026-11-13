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

    def test_macro_word_boundary_and_multiple_replacements(self):
        src = (
            "#define FOO 42\n"
            "%d BAR 99\n"
            "reg FOO_REG, REG_FOO, FOO;\n"
            "reg a = FOO + BAR;\n"
            "reg untouched_line;\n"
        )
        lines, _, macros = sflp_parse.preprocess(src, set())
        self.assertEqual(macros, {"FOO": "42", "BAR": "99"})
        # FOO_REG and REG_FOO should NOT be replaced because FOO is only a substring, not a distinct word
        self.assertEqual(lines[2], "reg FOO_REG, REG_FOO, 42;")
        # Both FOO and BAR on the same line should be replaced
        self.assertEqual(lines[3], "reg a = 42 + 99;")
        # Non-matching line remains intact
        self.assertEqual(lines[4], "reg untouched_line;")

    def test_unknown_directive_raises(self):
        src = "#invalid_directive"
        with self.assertRaises(SyntaxError):
            sflp_parse.preprocess(src, set())

    def test_lex_tokens_and_positions(self):
        lines = [
            "circuit test {",
            "    input a<8>;",
            "    a = 0x10;",
            "}",
        ]
        toks = sflp_parse.lex(lines)
        kinds = [(t.kind, t.val, t.line) for t in toks]
        self.assertEqual(kinds[0], ("kw", "circuit", 1))
        self.assertEqual(kinds[1], ("name", "test", 1))
        self.assertEqual(kinds[2], ("op", "{", 1))
        self.assertEqual(kinds[3], ("kw", "input", 2))
        self.assertEqual(kinds[4], ("name", "a", 2))
        self.assertEqual(kinds[5], ("op", "<", 2))
        self.assertEqual(kinds[6], ("num", "8", 2))
        self.assertEqual(kinds[7], ("op", ">", 2))
        self.assertEqual(kinds[8], ("op", ";", 2))
        self.assertEqual(kinds[-1], ("eof", None, 4))

    def test_lex_bad_character_raises(self):
        with self.assertRaisesRegex(SyntaxError, r"line 1: bad character '\$'"):
            sflp_parse.lex(["a = $10;"])

    def test_parser_helpers(self):
        toks = sflp_parse.lex(["circuit test { input a; }"])
        parser = sflp_parse.Parser(toks, "test.sflp")
        self.assertTrue(parser.at("circuit"))
        self.assertFalse(parser.at("module"))
        self.assertTrue(parser.at("circuit", "module"))
        self.assertTrue(parser.at("module", "circuit"))
        self.assertFalse(parser.at("foo", "bar"))
        self.assertEqual(parser.peek(1).val, "test")
        self.assertEqual(parser.peek(100).kind, "eof")
        self.assertTrue(parser.accept("circuit"))
        self.assertEqual(parser.cur.val, "test")
        self.assertEqual(parser.name(), "test")


if __name__ == '__main__':
    unittest.main()
