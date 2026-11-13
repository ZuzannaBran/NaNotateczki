#!/usr/bin/env python3
"""Check the Python reducer against the same semantic fixtures as SQLite.

Only storage representation is normalized: SQL columns vs JSON properties,
the Quill terminal newline, and page-scoped asset references. Operation IDs,
delivery orders and receipts are identical in both runtimes.
"""
import copy
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server/api"))

from app.operation_projection import apply_operation, page_move_tombstones  # noqa: E402
from app.operation_protocol import OperationEnvelope  # noqa: E402

CORPUS = ROOT / "test/fixtures/v2_projection_corpus.json"
STROKE = ("colorValue", "width", "toolIndex", "sortIndex", "points")
TEXT = ("fontSize", "colorValue", "width", "rotation", "dx", "dy", "sortIndex")


def normalize(state, deleted):
    document = None
    if state is not None:
        document = {k: state["properties"][k] for k in ("title", "folder", "kindIndex")}
        pages = {}
        for page_id, page in state["pages"].items():
            objects = {}
            for uid, node in page["objects"].items():
                props = node["properties"]
                text = props.get("objectType") == "text"
                fields = {k: props[k] for k in (TEXT if text else STROKE)}
                fields["objectType"] = "text" if text else "stroke"
                if text:
                    rendered = props.get("text", "")
                    fields["text"] = rendered[:-1] if rendered.endswith("\n") else rendered
                    fields["delta"] = props.get("delta")
                    fields["assets"] = node.get("assets", {})
                objects[uid] = fields
            pages[page_id] = {
                "title": page["properties"]["title"],
                "isBookmarked": page["properties"]["isBookmarked"],
                "objects": objects,
                "order": sorted(objects, key=lambda uid: (objects[uid]["sortIndex"], uid)),
            }
        document["pages"] = pages
    return {"document": document, "tombstones": sorted([list(t) for t in deleted])}


def project(case):
    state, deleted = None, set()
    verified = frozenset(a["receipt"]["sha256"] for a in case.get("assets", []))
    for raw in case["operations"]:
        operation = OperationEnvelope.from_dict(raw)
        extra = page_move_tombstones(state, operation)
        state, marker = apply_operation(
            copy.deepcopy(state), operation, deleted,
            verified_assets=verified,
        )
        deleted.update(extra)
        if marker is not None:
            deleted.add(marker)
    return normalize(state, deleted)


def main():
    corpus = json.loads(CORPUS.read_text())
    for case in corpus:
        actual = project(case)
        if actual != case["expected"]:
            raise AssertionError(f"Python projection differs: {case['name']}\n{actual}")
    print(f"Python projection: {len(corpus)} shared delivery cases passed.")


if __name__ == "__main__":
    main()
