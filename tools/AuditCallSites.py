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

  3. DUPLICATES — the same signature declared twice in the same file:

        func handleBackground() { ... }
        func handleBackground() { ... }        // error: invalid redeclaration

  4. UNKNOWN MEMBERS — `.status.isCompleted` where `TaskStatus` has no `isCompleted`:

        for task in openTasks where task.status.isCompleted { }   // no such member

     The member checks resolve names to *project* types: a static access (`TaskStatus.x`)
     or a property whose declared type is one of ours (`var status: TaskStatus`). Anything
     belonging to a framework type is left alone.

  5. ISOLATION — a `@MainActor` type constructed in a default argument:

        init(notifications: NotificationScheduler = NotificationScheduler())
        // error: call to main actor-isolated initializer in a sync nonisolated context

     A default argument is evaluated at the call site, which is not the actor's
     context; construct it inside the initialiser body instead.

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


TYPE_DECL = re.compile(
    r"^\s*(?:@[A-Za-z]+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+)*"
    r"(class|struct|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)",
)


def scope_of_each_line(text: str) -> list[str]:
    """The enclosing type path for every line, e.g. 'AppGroupCaptureQueue' or 'A.B'.

    The duplicate check needs this: four App Intents in one file may each declare
    `perform()`, and that is four separate types, not a redeclaration. Brace depth is
    enough to track nesting here because a type's braces enclose its members.
    """
    scopes: list[str] = []
    stack: list[tuple[int, str]] = []      # (brace depth inside the type, type name)
    depth = 0
    lines = text.splitlines()
    pending: str | None = None

    for line in lines:
        # a type declared on this line opens a scope at the depth this line reaches
        match = TYPE_DECL.match(line)
        if match:
            pending = match.group(2)
        opens = line.count("{")
        closes = line.count("}")
        depth += opens - closes
        if pending and opens:
            stack.append((depth, pending))
            pending = None
        while stack and depth < stack[-1][0]:
            stack.pop()
        scopes.append(".".join(name for _, name in stack))
    return scopes


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
    scope: str = ""

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
    r"(?:\{\s*\(?\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\)?\s+in\b"  # closure params
    r"|\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b"                    # for x in xs
    r"|\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:[:=])"        # let x = / let x: T
    r"|\bif\s+let\s+([A-Za-z_][A-Za-z0-9_]*)"                      # if let x
    r"|\bguard\s+let\s+([A-Za-z_][A-Za-z0-9_]*)"                   # guard let x
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
    scopes = scope_of_each_line(text)

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
        line_start = text.rfind("\n", 0, match.start()) + 1
        lead = text[line_start:match.start()]
        indent = len(lead) - len(lead.lstrip())
        line_number = line_of(match.start())
        declarations.append(
            Declaration(name, labels, relative, line_number, merged,
                        scopes[line_number - 1] if line_number - 1 < len(scopes) else ""))

    for match in BINDING.finditer(text):
        found = next((g for g in match.groups() if g), None)
        if not found:
            continue
        # a closure can bind several names:  { (a, b) in ... }
        for name in (part.strip() for part in found.split(",")):
            if name and name not in SKIP_NAMES and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
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

    # ---- check 3: the same signature declared twice in one file
    #
    # Same type (same file + same enclosing scope) + same name + same labels is a
    # redeclaration. Overloads that differ only by argument labels remain legal, and so do
    # same-named methods on different types.
    seen: dict[tuple, Declaration] = {}
    duplicates: list[str] = []
    for declaration in declarations:
        # scoped per enclosing type: `X.perform()` and `Y.perform()` are not duplicates
        key = (declaration.file, declaration.scope, declaration.name, tuple(declaration.labels))
        if key in seen:
            duplicates.append(
                f"  {declaration.file}:{declaration.line}  {declaration.name}"
                f"({', '.join('_' if l is None else l for l in declaration.labels)})"
                f"\n        already declared at line {seen[key].line}"
            )
        else:
            seen[key] = declaration

    # ---- check 4: members that don't exist on project types
    #
    # Two shapes carry enough information to check without a type checker:
    #   • a static access on a type we declared            -> `TaskStatus.completed`
    #   • a property whose declared type is one of ours    -> `task.status.isCompleted`
    # Protocol-provided members are allow-listed; framework types are ignored entirely.
        # Members this auditor cannot see: framework properties reached through a local
    # variable whose type is not knowable from the source (the rest are caught by the
    # "no project type has this member" rule). Extend this list when a report is noise.
    FRAMEWORK_MEMBERS = {
        "expirationHandler", "isCancelled", "taskIdentifier", "priority",
    }
    PROTOCOL_MEMBERS = {
        "rawValue", "init", "hashValue", "description", "debugDescription", "self",
        "allCases", "id", "label", "isEmpty", "count", "hash", "value",
        "comparisonResult", "isKnownUniquelyReferenced",
    }
    TYPE_DECL_BODY = re.compile(
        r"(?:class|struct|enum|actor)\s+([A-Za-z_][A-Za-z0-9_]*)[^{]*\{")

    type_members: dict[str, set[str]] = {}
    for path, text in every_file:
        for match in TYPE_DECL_BODY.finditer(text):
            name = match.group(1)
            open_brace = text.index("{", match.end() - 1)
            close_brace = match_paren(text, open_brace)
            if close_brace == -1:
                continue
            body = text[open_brace + 1:close_brace]
            members = set(PROTOCOL_MEMBERS)
            members |= set(re.findall(r"\b(?:var|let|func)\s+([A-Za-z_][A-Za-z0-9_]*)", body))
            members |= set(re.findall(r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)", body, re.M))
            for group in re.findall(r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)+)",
                                    body, re.M):
                members |= {n.strip() for n in group.split(",")}
            type_members.setdefault(name, set()).update(members)

    # property name -> the project types it is declared with
    property_types: dict[str, set[str]] = {}
    for path, text in every_file:
        for match in re.finditer(
                r"\b(?:var|let)\s+([a-z][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\?|!)?\s*(?:=|\{|$)",
                text, re.M):
            prop, declared = match.group(1), match.group(2)
            if declared in type_members:
                property_types.setdefault(prop, set()).add(declared)

    # Which names are used as local variables? `snapshot.start` and `entry.taskTitle`
    # are locals of uninferrable type, so the owner being a local disqualifies the
    # access — scoped PER FILE, because a local in one file says nothing about a
    # property of the same name in another (that mistake hid `status` here once already).
    # `task.status.isCompleted` survives because the OWNER is `status` — a real property
    # — not `task`, the loop variable.
    local_names_by_file: dict[str, set[str]] = {}
    for binding in bindings:
        local_names_by_file.setdefault(binding.file, set()).add(binding.name)

    unknown_members: list[str] = []
    checked = 0
    for path, text in every_file:
        relative = os.path.relpath(path, ROOT)
        # Every adjacent pair in a chain, not just the first — a lookahead lets matches
        # overlap, so `task.status.isCompleted` yields both (task, status) and
        # (status, isCompleted). The second pair is the checkable one: `task` is a loop
        # variable of unknown type, but `status` is a declared property with a known type.
        # Property-like accesses only: `actions.append(` is skipped because a method's
        # existence cannot be judged from its call site alone.
        for match in re.finditer(
                # The lookbehind must exclude LETTERS too, or the scan starts mid-word
                # ("schedulingMode.explanation" was read as "Mode.explanation").
                r"(?<![A-Za-z0-9_])(?=([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*([a-z][A-Za-z0-9_]*)\b(?!\s*\())",
                text):
            owner, member = match.group(1), match.group(2)
            if member in FRAMEWORK_MEMBERS:
                continue

            candidates: set[str] = set()
            if owner in type_members:                     # static access on our type
                candidates = {owner}
            elif owner in property_types and owner not in local_names_by_file.get(relative, set()):
                candidates = property_types[owner]         # a real property; type is known
            else:
                continue                                   # local variable: type unknown

            # Report only when no candidate type has the member — a name with several
            # declared types (e.g. `suggestion` on two different structs) is resolved by
            # whichever one actually declares it.
            checked += 1
            if not any(member in type_members[candidate] for candidate in candidates):
                line = text.count("\n", 0, match.start()) + 1
                shown = " or ".join(sorted(candidates))
                unknown_members.append(
                    f"  {relative}:{line}  '{owner}.{member}' — {shown} has no "
                    f"member '{member}'")

    # ---- check 5: @MainActor types constructed as a default argument
    isolated_types = set()
    for path, text in every_file:
        for match in re.finditer(
                r"@MainActor[\s\n]*(?:@[A-Za-z]+[\s\n]*)*(?:final\s+)?(?:class|struct|actor)\s+([A-Za-z_][A-Za-z0-9_]*)",
                text):
            isolated_types.add(match.group(1))
    isolation: list[str] = []
    for path, text in every_file:
        relative = os.path.relpath(path, ROOT)
        for match in re.finditer(
                r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\2\s*\(",
                text):
            if match.group(2) not in isolated_types:
                continue
            line = text.count("\n", 0, match.start()) + 1
            isolation.append(
                f"  {relative}:{line}  default argument constructs @MainActor type "
                f"{match.group(2)}\n        build it inside the initialiser body "
                f"(`= nil`, then `?? {match.group(2)}()`)"
            )

    print(f"scanned {len(every_file)} Swift files · {len(declarations)} declarations · {len(bindings)} bindings")
    if duplicates:
        print(f"\nDUPLICATES — the same signature declared twice in one file ({len(duplicates)}):")
        print("\n".join(duplicates))
    if isolation:
        print(f"\nISOLATION — @MainActor type built in a default argument ({len(isolation)}):")
        print("\n".join(isolation))
    if shadowing:
        print(f"\nSHADOWING — a local binding hides a function of the same name ({len(shadowing)}):")
        print("\n".join(shadowing))
    if mismatches:
        print(f"\nCALL SITES — labels match no declaration ({len(mismatches)}):")
        print("\n".join(mismatches))
    if unknown_members:
        print(f"\nUNKNOWN MEMBERS — no such member on a project type ({len(unknown_members)}):")
        print("\n".join(unknown_members))

    if not shadowing and not mismatches and not duplicates and not isolation and not unknown_members:
        print(f"\nno shadowing, no label mismatches, no duplicate signatures, "
              f"no unknown members ({checked} member accesses resolved), no isolation traps ✓")
        return 0
    if not quiet:
        print("\n(these are candidates: confirm each before changing code)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
