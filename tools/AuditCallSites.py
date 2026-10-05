#!/usr/bin/env python3
"""
AuditCallSites.py — catches the two Swift mistakes that a syntax check and a
regex-based validator both sail past, and that only showed up on a real compile:

  1. SHADOWING — a local binding whose name hides a method of the same name:

        for capture in captures {                       // 'capture' now means the Capture
            capture(title: capture.title, ...)          // error: cannot call value of
        }                                               // non-function type 'Capture'

     Ten seconds of parsing, an hour of CI round-trip.

  2. ARGUMENT LABELS — a call whose labels don't match any declaration:

        func place(task: TaskItem, at: Date)
        place(item, at: now)                            // error: missing argument label

This is a *heuristic auditor*, not a compiler: it reports candidates for human
review. It deliberately errs toward a few false positives over hiding a real bug,
and it only inspects names declared inside the project.

Usage:  python3 tools/AuditCallSites.py [--quiet]
Exit status is 0 when nothing is reported, 1 when candidates are found.
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass, field

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIRS = ["Cadence", "CadenceShared", "CadenceWidget", "CadenceCore"]

SKIP_NAMES = {
    # Swift/stdlib names that show up as locals and are never interesting here
    "description", "init", "self", "super", "body", "value", "count", "first",
    "min", "max", "abs", "print", "with", "where", "if", "for", "guard", "return",
}


def swift_files() -> list[str]:
    out: list[str] = []
    for directory in SOURCE_DIRS:
        for current, _, names in os.walk(os.path.join(ROOT, directory)):
            out.extend(os.path.join(current, n) for n in names if n.endswith(".swift"))
    return sorted(out)


def strip_noise(text: str) -> str:
    """Blank out comments and string literals so the scanners don't read prose."""
    out = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            end = text.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i))
            i = end
        elif two == "/*":
            end = text.find("*/", i + 2)
            end = n if end == -1 else end + 2
            out.append('"' + "".join("\n" if c == "\n" else " " for c in text[i + 3:end - 3]) + '"""')
            i = end
        elif text[i:i + 3] == '"""':
            end = text.find('"""', i + 3)
            end = n if end == -1 else end + 3
            out.append('"' + "".join("\n" if c == "\n" else " " for c in text[i + 3:end - 3]) + '"""')
            i = end
        elif text[i] == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"' or text[j] == "\n":
                    break
                j += 1
            # Consume the CLOSING quote too: stopping short of it made the next pass
            # treat that quote as an opening one, blanking whole lines of real code.
            # The quotes stay in place (only the contents are blanked) so that an
            # argument like `title: "Overdue"` is still visibly present — otherwise a
            # call can look as though it left a parameter out.
            end = min(j + 1, n)
            interior = "".join("\n" if c == "\n" else " " for c in text[i + 1:j])
            out.append('"' + interior + '"')
            i = end
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


# --------------------------------------------------------------------- scanning

@dataclass
class Declaration:
    name: str
    labels: list[str | None]
    file: str
    line: int
    chunks: list[str] = field(default_factory=list)

    def has_default(self, index: int) -> bool:
        return index < len(self.chunks) and "=" in self.chunks[index]


@dataclass
class Binding:
    name: str
    file: str
    line: int


@dataclass
class CallSite:
    name: str
    labels: list[str | None]
    file: str
    line: int
    context: str = ""
    trailing_closure: bool = False


FUNC_DEF = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>)?\s*\(")
BINDING = re.compile(
    r"\b(?:for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b"          # for x in xs
    r"|(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:[:=])"    # let x = / let x: T =
    r"|if\s+let\s+([A-Za-z_][A-Za-z0-9_]*)|guard\s+let\s+([A-Za-z_][A-Za-z0-9_]*)"
    r")"
)


def match_paren(text: str, open_index: int) -> int:
    depth, i, n = 0, open_index, len(text)
    while i < n:
        char = text[i]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def top_level_labels(text: str, start: int, end: int) -> list[str | None]:
    """Argument labels at nesting depth 0 of an argument list body."""
    labels: list[str | None] = []
    depth = 0
    i = start
    chunk_start = start
    first = True
    while i < end:
        char = text[i]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            chunk = text[chunk_start:i].strip()
            labels.append(chunk)
            chunk_start = i + 1
            first = False
        i += 1
    tail = text[chunk_start:end].strip()
    if tail or not first:
        labels.append(tail)
    return [l for l in labels if l != ""]


def call_label_of(chunk: str) -> str | None:
    """At a call site: `title: "x"` -> 'title'; `x` -> None (unlabelled first argument)."""
    match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:(?!:)", chunk)
    return match.group(1) if match else None


def declaration_label_of(chunk: str) -> str | None:
    """In a declaration: `for task: TaskItem` -> 'for'; `value: Int` -> 'value';
    `_ id: UUID` -> None. Swift separates the argument label from the parameter name,
    which is why a call site and its declaration do not always look alike."""
    left = chunk.split(":", 1)[0].strip()
    if not left or left.startswith("("):
        return None
    tokens = left.split()
    if not tokens:
        return None
    if tokens[0] == "_":
        return None
    return tokens[0]


def scan(path: str, text: str):
    relative = os.path.relpath(path, ROOT)
    line_of = lambda index: text.count("\n", 0, index) + 1  # noqa: E731

    declarations: list[Declaration] = []
    bindings: list[Binding] = []

    for match in FUNC_DEF.finditer(text):
        name = match.group(1)
        if name in ("init", "subscript"):
            continue
        open_index = text.index("(", match.end() - 1)
        close_index = match_paren(text, open_index)
        if close_index == -1:
            continue
        chunks = top_level_labels(text, open_index + 1, close_index)
        merged: list[str] = []
        for chunk in chunks:
            # Generic types contain commas at what looks like top level
            # (`WritableKeyPath<WorkingWindow, Int>`), so a fragment without a colon is
            # the continuation of the parameter before it, not a parameter of its own.
            if merged and ":" not in chunk:
                merged[-1] = merged[-1] + ", " + chunk
            else:
                merged.append(chunk)
        labels = [declaration_label_of(c) for c in merged]
        declarations.append(Declaration(name, labels, relative, line_of(match.start()), merged))

    for match in BINDING.finditer(text):
        name = next((g for g in match.groups() if g), None)
        if not name or name in SKIP_NAMES:
            continue
        bindings.append(Binding(name, relative, line_of(match.start())))

    return declarations, bindings


def scan_calls(path: str, text: str, names: set[str]) -> list[CallSite]:
    relative = os.path.relpath(path, ROOT)
    calls: list[CallSite] = []
    for match in re.finditer(r"(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)\s*\(", text):
        name = match.group(1)
        if name not in names:
            continue
        # A declaration is not a call: `func foo(`, `case bar(`, `init(` — and multi-line
        # declarations put the `(` far from the `func`, so look just before the name.
        prefix = text[max(0, match.start() - 12):match.start()]
        if re.search(r"\b(func|case|init|subscript|macro)\s*$", prefix):
            continue
        open_index = text.index("(", match.end() - 1)
        close_index = match_paren(text, open_index)
        if close_index == -1:
            continue
        chunks = top_level_labels(text, open_index + 1, close_index)
        labels = [call_label_of(c) for c in chunks if c]
        rest = text[close_index + 1:]
        trailing = bool(re.match(r"\s*\{", rest))
        context = text[match.start():min(close_index + 1, match.start() + 90)].replace("\n", " ")
        calls.append(CallSite(name, labels, relative,
                              text.count("\n", 0, match.start()) + 1, context, trailing))
    return calls


# ------------------------------------------------------------------------ main

def main() -> int:
    quiet = "--quiet" in sys.argv

    declarations: list[Declaration] = []
    bindings: list[Binding] = []
    every_file: list[tuple[str, str]] = []

    for path in swift_files():
        raw = open(path, encoding="utf-8").read()
        text = strip_noise(raw)
        every_file.append((path, text))
        d, b = scan(path, text)
        declarations.extend(d)
        bindings.extend(b)

    by_name: dict[str, list[Declaration]] = {}
    for declaration in declarations:
        by_name.setdefault(declaration.name, []).append(declaration)

    # ---- check 1: a local binding that shadows a declared function of the same name
    shadowing: list[str] = []
    declared_names = set(by_name)
    file_text = dict(every_file)
    for binding in bindings:
        if binding.name not in declared_names:
            continue
        text = file_text.get(os.path.join(ROOT, binding.file), "")
        if not text:
            continue
        lines = text.splitlines()
        binding_index = binding.line - 1
        binding_line = lines[binding_index]
        # `let short = { (n: Int) -> String in ... }` then `short(1)` is a closure being
        # called — legal and clearer than most alternatives. Only a NON-closure binding
        # (a value, a model object) makes a later call to the same name impossible.
        if re.search(r"\b(?:let|var)\s+" + re.escape(binding.name) + r"\s*(?::[^=\n]*=\s*\{|=\s*\{)", binding_line):
            continue
        # `if let x = x`, `guard let x = x` — unwrapping into the same name is idiomatic
        indent = len(binding_line) - len(binding_line.lstrip())
        call_pattern = re.compile(r"(?<![A-Za-z0-9_.])" + re.escape(binding.name) + r"\s*\(")
        # `let task = task(withID:)` is idiomatic and legal: the call is on the binding's
        # own line, before the new name is in scope. Only a call on a LATER line, inside
        # the same block (same-or-deeper indent, within a screenful), is the real hazard.
        for offset in range(1, 21):
            index = binding_index + offset
            if index >= len(lines):
                break
            line = lines[index]
            if not line.strip():
                continue
            if len(line) - len(line.lstrip()) < indent:
                break  # left the block
            if call_pattern.search(line):
                shapes = {", ".join("_" if l is None else l for l in d.labels)
                          for d in by_name[binding.name]}
                shadowing.append(
                    f"  {binding.file}:{index + 1}  call to {binding.name}(...) but "
                    f"'{binding.name}' is a local binding from line {binding.line}"
                    f"\n        (func {binding.name}({'; '.join(sorted(shapes))}))"
                )
                break

    # ---- check 2: call sites whose labels match no declaration of that name
    mismatches: list[str] = []
    unique_names = {name for name, decls in by_name.items()
                    if len({tuple(d.labels) for d in decls}) == 1}
    for path, text in every_file:
        for call in scan_calls(path, text, unique_names):
            labels = call.labels
            ok = False
            for declaration in by_name[call.name]:
                expected = declaration.labels
                # Swift lets a call skip any parameter that has a default, as long as
                # the labels it does pass keep their relative order. The last parameter
                # may also be satisfied by a trailing closure instead of an argument.
                cursor = 0
                matched = True
                for label in labels:
                    while cursor < len(expected) and expected[cursor] != label:
                        if not declaration.has_default(cursor):
                            matched = False
                            break
                        cursor += 1
                    if not matched or cursor >= len(expected):
                        matched = False
                        break
                    cursor += 1
                if matched:
                    # everything still unvisited must be defaulted, or be the trailing
                    # parameter supplied as a trailing closure
                    for index in range(cursor, len(expected)):
                        if declaration.has_default(index):
                            continue
                        if index == len(expected) - 1 and call.trailing_closure:
                            continue
                        matched = False
                        break
                if matched:
                    ok = True
                    break
            if not ok:
                expected = {", ".join("_" if l is None else l for l in d.labels)
                            for d in by_name[call.name]}
                shown = ", ".join("_" if l is None else l for l in labels)
                mismatches.append(
                    f"  {call.file}:{call.line}  {call.name}({shown})"
                    f"\n        declared: {call.name}({'; '.join(sorted(expected))})"
                )

    print(f"scanned {len(every_file)} Swift files · {len(declarations)} declarations · {len(bindings)} bindings")
    if shadowing:
        print(f"\nSHADOWING — a local binding hides a function of the same name ({len(shadowing)}):")
        print("\n".join(shadowing))
    if mismatches:
        print(f"\nCALL SITES — labels match no declaration ({len(mismatches)}):")
        print("\n".join(mismatches))
    if not shadowing and not mismatches:
        print("\nno shadowing and no label mismatches found ✓")
        return 0
    if not quiet:
        print("\n(these are candidates: confirm each before changing code)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
