#!/usr/bin/env python3
"""Assert that a SANITISED republication of a Python asset still behaves identically.

WHY THIS EXISTS. The drift sweep asks "does this copy contain every canonical line". That
is the right question for a consumer, which receives the asset verbatim. It is the wrong
question for the public mirror, which republishes the same assets with citations
generalised -- private repository slugs and pull-request numbers cannot be published, so
the mirror's comments and docstrings differ from canonical BY DESIGN and permanently.

Left in the textual sweep the mirror is drifted forever, and a scheduled check that can
never go green is one nobody reads -- which is the sweep script's own stated reason for
classifying rather than throwing. Removing it from the sweep with nothing in its place
would be worse: silence bought by deletion is indistinguishable from coverage.

So the mirror leaves the textual check and arrives here. The question asked of it is the
one that actually matters for a published copy of a CHECKER: does it still do the same
thing? Comments and docstrings are ignored; every definition and every definition body is
compared.

ORDER IS IGNORED ONLY FOR SIMPLE FUNCTIONS matched by name. Decorators, defaults,
annotations, class bases and class bodies execute while a definition is created, so those
definitions stay position-sensitive. The mirror's history has only swapped simple
functions; reporting those swaps would reintroduce the permanently-red signal this script
exists to remove.

Bare module-level statements -- imports, constants, the `if __name__` block -- are matched
by POSITION instead, because they have no name to match on and their order genuinely can
matter. The consequence is worth knowing before reading a report: moving one of those is
reported as a MISSING plus an ADDED `<module N:Kind>` pair rather than as a move. That is
noisy but never wrong in the dangerous direction, and the mirror does not do it today.

A definition that is MISSING, ADDED, or whose BODY differs is reported and fails.

WHAT THIS DOES NOT COVER, stated so a pass is not read as more than it is: a docstring
carries no behaviour, but it does carry instruction to a human, and this script cannot
tell a sanitised citation from a deleted warning. The sanitisation map in
sync-public-skills is what governs that, and its leak gates are what enforce it.

Exit 0: every definition matches. Exit 1: a definition is missing, added, or differs.
Exit 2: a file is absent or does not parse -- the control is broken, which must never read
as "equivalent".
"""
import ast
import sys
from pathlib import Path


def strip_docstrings(node):
    """Drop the docstring from every scope in `node`, in place."""
    for scope in ast.walk(node):
        if not isinstance(scope, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        body = scope.body
        if (
            body
            and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)
        ):
            # A scope whose only statement is its docstring still needs a body.
            scope.body = body[1:] or [ast.Pass()]
    return node


def definitions(path):
    """Top-level definitions, name -> normalised dump. Comments never reach the AST."""
    try:
        source = Path(path).read_text(encoding="utf-8-sig")
    except OSError as exc:
        print(f"ERROR: cannot read {path}: {exc}")
        raise SystemExit(2)
    try:
        tree = ast.parse(source)
    except SyntaxError as exc:
        print(f"ERROR: {path} does not parse: {exc}")
        raise SystemExit(2)

    strip_docstrings(tree)
    found = {}
    definition_names = set()
    for index, node in enumerate(tree.body):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node.name in definition_names:
                print(f"ERROR: {path} has duplicate top-level definition {node.name!r}")
                raise SystemExit(1)
            definition_names.add(node.name)
            sensitive = isinstance(node, ast.ClassDef) or bool(node.decorator_list)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                sensitive = sensitive or bool(node.args.defaults) or any(
                    default is not None for default in node.args.kw_defaults
                ) or any(arg.annotation is not None for arg in node.args.posonlyargs + node.args.args + node.args.kwonlyargs) or node.returns is not None
            name = f"<module {index}:{type(node).__name__}>" if sensitive else node.name
        else:
            # Module-level statements are keyed by position and kind. A constant or an
            # import IS behaviour, so they are compared too -- only their order is not.
            name = f"<module {index}:{type(node).__name__}>"
        if name in found:
            print(f"ERROR: {path} has duplicate top-level definition {name!r}")
            raise SystemExit(1)
        found[name] = ast.dump(node, include_attributes=False)
    return found


def main():
    if len(sys.argv) != 3:
        print("usage: compare-asset-semantics.py <canonical.py> <republished.py>")
        return 2

    canonical_path, mirror_path = sys.argv[1], sys.argv[2]
    canonical = definitions(canonical_path)
    mirror = definitions(mirror_path)

    missing = sorted(set(canonical) - set(mirror))
    added = sorted(set(mirror) - set(canonical))
    differing = sorted(name for name in set(canonical) & set(mirror) if canonical[name] != mirror[name])

    for name in missing:
        print(f"MISSING   {name}  (in canonical, absent from the republication)")
    for name in added:
        print(f"ADDED     {name}  (in the republication, absent from canonical)")
    for name in differing:
        print(f"DIFFERS   {name}  (same name, different body)")

    if missing or added or differing:
        print()
        print("The republication is NOT behaviourally identical to canonical. Sanitisation")
        print("may only change comments and docstrings; anything here is a real divergence.")
        print("Re-port the file from canonical and re-apply the sanitisation map.")
        return 1

    print(
        f"semantics OK - {len(canonical)} definition(s) identical "
        f"(comments, docstrings and ordering ignored)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
