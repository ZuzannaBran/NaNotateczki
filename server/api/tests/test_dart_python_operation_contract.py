"""Cross-language operation wire contract: inspect the real Flutter source.

This runs in the app repository, where both the canonical-backend mirror and
the Dart source are available. The Python operation model remains executable,
rather than substituting a mock for payload validation.
"""

import re
import uuid
from pathlib import Path

import pytest

from app.operation_protocol import (
    KINDS,
    LIBRARY_DOCUMENT_ID,
    MAX_DEPENDENCY_BYTES,
    MAX_SAFE_INTEGER,
    SCHEMA_VERSION,
    InvalidOperation,
    OperationEnvelope,
)


DART_PATH = (
    Path(__file__).resolve().parents[3]
    / "lib/data/sync/operation_protocol.dart"
)


def test_flutter_and_server_declare_exactly_the_same_operation_kinds():
    source = DART_PATH.read_text(encoding="utf-8")
    declarations = source.split("enum OperationKind {", 1)[1].split(
        "  const OperationKind(", 1
    )[0]
    dart_kinds = dict(re.findall(
        r"^\s+\w+\('([^']+)', OperationTarget\.(\w+)\)[,;]",
        declarations,
        flags=re.MULTILINE,
    ))
    assert dart_kinds == KINDS


def test_flutter_and_server_agree_on_wire_version_and_limits():
    source = DART_PATH.read_text(encoding="utf-8")
    assert re.search(
        rf"currentSchemaVersion\s*=\s*{SCHEMA_VERSION};", source
    )
    assert re.search(
        rf"maxSafeInteger\s*=\s*{MAX_SAFE_INTEGER};", source
    )
    assert f"libraryDocumentId = '{LIBRARY_DOCUMENT_ID}'" in source
    assert "dependencies.length * 39 > maxDependencyBytes" in source
    assert re.search(
        rf"maxDependencyBytes\\s*=\\s*{MAX_DEPENDENCY_BYTES // 1024}\\s*\\*\\s*1024;",
        source,
    )


@pytest.mark.parametrize("target", ["document", "page", "object", "folder", "task"])
def test_real_python_envelope_checks_each_dart_target_type(target):
    operation_type = next(kind for kind, declared in KINDS.items()
                          if declared == target)
    raw = {
        "schemaVersion": SCHEMA_VERSION,
        "operationId": str(uuid.uuid4()),
        "actorId": "contract-actor",
        "actorSeq": 1,
        "documentId": "@library" if target in ("folder", "task") else "doc-1",
        "type": operation_type,
        "payload": {"value": {}},
        "dependencies": [],
        "logicalClock": 1,
    }
    if target == "page":
        raw["objectId"] = "page-1"
    elif target == "object":
        raw.update({"objectId": "stroke-1", "pageId": "page-1"})
    elif target in ("folder", "task"):
        raw["objectId"] = "entity-1"

    operation = OperationEnvelope.from_dict(raw)
    assert KINDS[operation.kind] == target
    assert OperationEnvelope.from_dict(operation.to_dict()) == operation

    raw["documentId"] = "@library" if target not in ("folder", "task") else "doc-1"
    with pytest.raises(InvalidOperation):
        OperationEnvelope.from_dict(raw)
