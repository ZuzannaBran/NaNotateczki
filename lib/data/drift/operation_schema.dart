/// Additive SQLite schema for the durable operation journal.
///
/// These tables intentionally use Drift's low-level SQL API. They do not
/// replace existing notebook tables or alter the generated Drift mappings.
/// Generated code can remain unchanged until the projection migration.
const operationSchemaStatements = <String>[
  '''
  CREATE TABLE IF NOT EXISTS operations (
    operation_id TEXT NOT NULL PRIMARY KEY,
    actor_id TEXT NOT NULL,
    actor_seq INTEGER NOT NULL CHECK(actor_seq > 0),
    document_id TEXT NOT NULL,
    page_id TEXT,
    object_id TEXT,
    kind TEXT NOT NULL,
    envelope_json TEXT NOT NULL,
    logical_clock INTEGER NOT NULL CHECK(logical_clock > 0),
    schema_version INTEGER NOT NULL,
    source TEXT NOT NULL CHECK(source IN ('local', 'remote')),
    created_at INTEGER NOT NULL,
    UNIQUE(actor_id, actor_seq)
  )
  ''',
  '''
  CREATE INDEX IF NOT EXISTS operations_document_order
    ON operations(document_id, logical_clock, actor_id, actor_seq)
  ''',
  '''
  CREATE TABLE IF NOT EXISTS operation_outbox (
    operation_id TEXT NOT NULL PRIMARY KEY
      REFERENCES operations(operation_id) ON DELETE RESTRICT,
    queued_at INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
    retry_after INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'queued'
      CHECK(status IN ('queued', 'blocked')),
    last_error TEXT
  )
  ''',
  '''
  CREATE INDEX IF NOT EXISTS operation_outbox_retry
    ON operation_outbox(retry_after, queued_at)
  ''',
  '''
  CREATE TABLE IF NOT EXISTS operation_ack (
    operation_id TEXT NOT NULL PRIMARY KEY
      REFERENCES operations(operation_id) ON DELETE RESTRICT,
    server_sequence INTEGER NOT NULL CHECK(server_sequence > 0),
    acknowledged_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS object_tombstones (
    document_id TEXT NOT NULL,
    target_kind TEXT NOT NULL
      CHECK(target_kind IN ('document', 'page', 'object', 'folder', 'task')),
    page_id TEXT NOT NULL DEFAULT '',
    object_id TEXT NOT NULL,
    operation_id TEXT NOT NULL
      REFERENCES operations(operation_id) ON DELETE RESTRICT,
    PRIMARY KEY(document_id, target_kind, page_id, object_id)
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS sync_checkpoints (
    scope TEXT NOT NULL PRIMARY KEY,
    server_sequence INTEGER NOT NULL CHECK(server_sequence >= 0),
    updated_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS document_snapshots (
    document_id TEXT NOT NULL,
    server_sequence INTEGER NOT NULL CHECK(server_sequence >= 0),
    snapshot_json TEXT NOT NULL,
    checksum_sha256 TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(document_id, server_sequence)
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS asset_references (
    document_id TEXT NOT NULL,
    object_id TEXT NOT NULL,
    asset_id TEXT NOT NULL,
    storage_path TEXT NOT NULL,
    checksum_sha256 TEXT NOT NULL,
    byte_length INTEGER NOT NULL CHECK(byte_length > 0),
    PRIMARY KEY(document_id, object_id, asset_id)
  )
  ''',
  '''
  CREATE INDEX IF NOT EXISTS asset_references_asset
    ON asset_references(asset_id)
  ''',
  '''
  CREATE TABLE IF NOT EXISTS operation_asset_bytes (
    checksum_sha256 TEXT NOT NULL PRIMARY KEY,
    media_type TEXT NOT NULL,
    byte_length INTEGER NOT NULL CHECK(byte_length > 0),
    bytes BLOB NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS operation_actor_state (
    actor_id TEXT NOT NULL PRIMARY KEY,
    last_seq INTEGER NOT NULL CHECK(last_seq >= 0),
    last_clock INTEGER NOT NULL CHECK(last_clock >= 0),
    last_operation_id TEXT
  )
  ''',
  editorHistorySchema,
];

const editorHistorySchema = '''
  CREATE TABLE IF NOT EXISTS editor_history (
    document_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    head_operation_id TEXT NOT NULL
      REFERENCES operations(operation_id) ON DELETE RESTRICT,
    payload_json TEXT NOT NULL,
    checksum_sha256 TEXT NOT NULL,
    PRIMARY KEY(document_id, owner_id)
  )
''';

/// SQLite v3 used only objectId. Rebuild from the durable delete operation to
/// recover its pageId without discarding a single existing tombstone.
const operationTombstoneV4Migration = <String>[
  '''
  CREATE TABLE object_tombstones_v4 (
    document_id TEXT NOT NULL,
    target_kind TEXT NOT NULL
      CHECK(target_kind IN ('document', 'page', 'object', 'folder')),
    page_id TEXT NOT NULL DEFAULT '',
    object_id TEXT NOT NULL,
    operation_id TEXT NOT NULL
      REFERENCES operations(operation_id) ON DELETE RESTRICT,
    PRIMARY KEY(document_id, target_kind, page_id, object_id)
  )
  ''',
  '''
  INSERT INTO object_tombstones_v4
    (document_id, target_kind, page_id, object_id, operation_id)
  SELECT old.document_id, old.target_kind,
    CASE WHEN old.target_kind = 'object'
      THEN COALESCE(op.page_id, '') ELSE '' END,
    old.object_id, old.operation_id
  FROM object_tombstones old
  JOIN operations op ON op.operation_id = old.operation_id
  ''',
  'DROP TABLE object_tombstones',
  'ALTER TABLE object_tombstones_v4 RENAME TO object_tombstones',
];

/// v6 adds task tombstones without rewriting accepted operations or IDs.
const operationTombstoneV6Migration = <String>[
  '''
  CREATE TABLE object_tombstones_v6 (
    document_id TEXT NOT NULL,
    target_kind TEXT NOT NULL
      CHECK(target_kind IN ('document', 'page', 'object', 'folder', 'task')),
    page_id TEXT NOT NULL DEFAULT '',
    object_id TEXT NOT NULL,
    operation_id TEXT NOT NULL
      REFERENCES operations(operation_id) ON DELETE RESTRICT,
    PRIMARY KEY(document_id, target_kind, page_id, object_id)
  )
  ''',
  '''
  INSERT INTO object_tombstones_v6
    (document_id, target_kind, page_id, object_id, operation_id)
  SELECT document_id, target_kind, page_id, object_id, operation_id
  FROM object_tombstones
  ''',
  'DROP TABLE object_tombstones',
  'ALTER TABLE object_tombstones_v6 RENAME TO object_tombstones',
];
