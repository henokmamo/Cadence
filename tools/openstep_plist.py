#!/usr/bin/env python3
"""
openstep_plist.py — a strict, dependency-free reader for the old-style (OpenStep)
property-list grammar that Xcode uses for project.pbxproj.

Why this exists
---------------
Xcode parses .pbxproj with the OpenStep plist parser, not JSON or XML. That grammar
is strict about separators: dictionary entries end with ';' and array elements are
separated by ','. Get one of those wrong and Xcode reports

    The project 'Cadence' is damaged and cannot be opened due to a parse error.
    xcodebuild ... exited with code 74      (74 = EX_IOERR)

which tells you nothing about where the problem is. This module points at the exact
byte offset instead.

It also matters for hand-written or generated project files: regex-based checks
("is every object id defined?") pass happily on a file Xcode refuses to open.

Grammar (the subset Xcode writes)
--------------------------------
    value   := dict | array | quoted-string | unquoted-string
    dict    := '{' ( value '=' value ';' )* '}'
    array   := '(' ( value (',' value)* ','? )? ')'      # Xcode itself writes (X, )
    comment := '/*' ... '*/'  |  '//' ... end-of-line    # skipped anywhere whitespace is

Unquoted strings may contain only  A-Z a-z 0-9 _ $ + / : . -   — anything else
(spaces, '@', parentheses, unicode) must be inside double quotes.

Usage
-----
    python3 tools/openstep_plist.py path/to/project.pbxproj
    from openstep_plist import parse_file           # returns nested dicts/lists

Exit status is 0 when the file parses, 1 when it does not.
"""

from __future__ import annotations

import sys

__all__ = ["parse", "parse_file", "PlistSyntaxError"]

# Characters Xcode's writer leaves unquoted.
TOKEN_CHARS = frozenset(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789"
    "_$+/:.-"
)
WHITESPACE = " \t\r\n"


class PlistSyntaxError(Exception):
    """Raised with a byte offset and a snippet of the offending text."""


class _Parser:
    def __init__(self, text: str) -> None:
        self.text = text
        self.index = 0
        self.length = len(text)
        self.line_starts = self._line_index(text)

    @staticmethod
    def _line_index(text: str) -> list[int]:
        starts = [0]
        for i, ch in enumerate(text):
            if ch == "\n":
                starts.append(i + 1)
        return starts

    def line_of(self, offset: int) -> int:
        lo, hi = 0, len(self.line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.line_starts[mid] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def fail(self, message: str, offset: int | None = None) -> None:
        at = self.index if offset is None else offset
        start = max(0, at - 60)
        end = min(self.length, at + 60)
        snippet = self.text[start:end].replace("\n", "\\n").replace("\t", "\\t")
        raise PlistSyntaxError(
            f"{message}\n"
            f"    at offset {at} (line {self.line_of(at)})\n"
            f"    ...{snippet}...\n"
            f"    {' ' * min(60, at)}{'^' if at >= 60 else '^'}"
        )

    # ---------------------------------------------------------------- helpers
    def skip(self) -> None:
        while self.index < self.length:
            char = self.text[self.index]
            if char in WHITESPACE:
                self.index += 1
            elif self.text.startswith("/*", self.index):
                closing = self.text.find("*/", self.index + 2)
                if closing == -1:
                    self.fail("unterminated /* comment */")
                self.index = closing + 2
            elif self.text.startswith("//", self.index):
                newline = self.text.find("\n", self.index + 2)
                if newline == -1:
                    self.index = self.length
                else:
                    self.index = newline + 1
            else:
                return

    # ------------------------------------------------------------- the parser
    def parse_root(self):
        self.skip()
        value = self.parse_value()
        self.skip()
        if self.index != self.length:
            self.fail("content after the root dictionary ended")
        return value

    def parse_value(self):
        self.skip()
        if self.index >= self.length:
            self.fail("unexpected end of file, expected a value")
        char = self.text[self.index]
        if char == "{":
            return self.parse_dict()
        if char == "(":
            return self.parse_array()
        if char == '"':
            return self.parse_quoted()
        return self.parse_token()

    def parse_dict(self) -> dict:
        self.index += 1  # '{'
        result: dict = {}
        while True:
            self.skip()
            if self.index >= self.length:
                self.fail("unterminated dictionary, expected '}'")
            if self.text[self.index] == "}":
                self.index += 1
                return result
            key = self.parse_value()
            self.skip()
            if self.index >= self.length or self.text[self.index] != "=":
                self.fail(f"expected '=' after dictionary key {key!r}")
            self.index += 1
            value = self.parse_value()
            self.skip()
            if self.index >= self.length or self.text[self.index] != ";":
                self.fail(f"expected ';' after the value of {key!r}")
            self.index += 1
            result[key] = value

    def parse_array(self) -> list:
        self.index += 1  # '('
        items: list = []
        self.skip()
        if self.index < self.length and self.text[self.index] == ")":
            self.index += 1
            return items
        while True:
            items.append(self.parse_value())
            self.skip()
            if self.index >= self.length:
                self.fail("unterminated array, expected ')'")
            char = self.text[self.index]
            if char == ",":
                self.index += 1
                self.skip()
                if self.index < self.length and self.text[self.index] == ")":
                    self.index += 1  # Xcode writes single-element arrays as (X, )
                    return items
                continue
            if char == ")":
                self.index += 1
                return items
            self.fail(
                f"expected ',' or ')' between array elements, found {char!r} "
                f"— this is the classic 'array written without commas' error"
            )

    def parse_quoted(self) -> str:
        self.index += 1  # opening quote
        out: list[str] = []
        escapes = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}
        while self.index < self.length:
            char = self.text[self.index]
            if char == "\\":
                if self.index + 1 >= self.length:
                    self.fail("unterminated escape sequence")
                following = self.text[self.index + 1]
                out.append(escapes.get(following, following))
                self.index += 2
                continue
            if char == '"':
                self.index += 1
                return "".join(out)
            out.append(char)
            self.index += 1
        self.fail("unterminated quoted string")

    def parse_token(self) -> str:
        start = self.index
        while self.index < self.length and self.text[self.index] in TOKEN_CHARS:
            self.index += 1
        if self.index == start:
            self.fail(
                f"unexpected character {self.text[start]!r} — unquoted strings may "
                f"contain only letters, digits and _ $ + / : . -"
            )
        return self.text[start:self.index]


def parse(text: str):
    """Parse pbxproj text. Raises PlistSyntaxError with a byte offset on failure."""
    if text.startswith("\ufeff"):
        text = text.lstrip("\ufeff")
    return _Parser(text).parse_root()


def parse_file(path: str):
    """Parse a .pbxproj file from disk."""
    with open(path, "r", encoding="utf-8") as handle:
        return parse(handle.read())


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.split("Usage")[-1].strip())
        raise SystemExit(2)
    target = sys.argv[1]
    try:
        tree = parse_file(target)
    except PlistSyntaxError as error:
        print(f"{target}: NOT A VALID OpenStep plist — Xcode would refuse to open it.\n")
        print(error)
        raise SystemExit(1)
    print(f"{target}: parses as a valid OpenStep plist ✓")
    print(f"  top-level keys : {', '.join(sorted(tree)[:8])}")
    objects = tree.get("objects", {})
    print(f"  objects        : {len(objects)}")
    print(f"  rootObject     : {'yes' if 'rootObject' in tree else 'MISSING'}")
