import 'package:uuid/uuid.dart';

import 'operation_protocol.dart';
import 'operation_text_sequence.dart';

/// One client-side intent. SyncEngine assigns actorSeq, Lamport and operationId.
class ShareTextIntent {
  const ShareTextIntent(this.kind, this.payload);

  final OperationKind kind;
  final Map<String, dynamic> payload;
}

/// Converts a completed plain-text edit into character-level CRDT operations.
///
/// This plans only: the caller must commit every returned intent through
/// OperationStore, in order, before acknowledging a completed local edit.
/// Rich-text Quill deltas require a separate attribute CRDT: fail closed.
class ShareTextEditAdapter {
  ShareTextEditAdapter({String Function()? createAtomId})
      : _createAtomId = createAtomId ?? const Uuid().v4;

  static const maxCodePoints = 50000;
  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}
  final String Function() _createAtomId;

  List<ShareTextIntent> plan({
    required Map<String, dynamic> atoms,
    required String newText,
    String? changedDeltaJson,
  }) {
    if (changedDeltaJson != null) {
      throw UnsupportedError('Rich text requires an attribute CRDT.');
    }
    final oldIds = OperationTextSequence.visibleIds(atoms);
    final oldCharacters = <String>[];
    for (final id in oldIds) {
      final atom = atoms[id] as Map;
      final text = atom['text'] as String;
      if (text.runes.length != 1) {
        throw StateError('Text must be migrated to one atom per code point.');
      }
      oldCharacters.add(text);
    }
    final nextCharacters = newText.runes
        .map((rune) => String.fromCharCode(rune))
        .toList();
    if (nextCharacters.length > maxCodePoints) {
      throw StateError('Text edit exceeds the safe operation budget.');
    }
    var prefix = 0;
    while (prefix < oldCharacters.length &&
        prefix < nextCharacters.length &&
        oldCharacters[prefix] == nextCharacters[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < oldCharacters.length - prefix &&
        suffix < nextCharacters.length - prefix &&
        oldCharacters[oldCharacters.length - 1 - suffix] ==
            nextCharacters[nextCharacters.length - 1 - suffix]) {
      suffix++;
    }
    final deletedIds = oldIds.sublist(prefix, oldIds.length - suffix);
    final inserted = nextCharacters.sublist(
      prefix, nextCharacters.length - suffix,
    );
    if (deletedIds.isEmpty && inserted.isEmpty) {
      return const [];
    }
    final result = <ShareTextIntent>[];
    for (var offset = 0; offset < deletedIds.length;
        offset += OperationTextSequence.maxAtomsPerOperation) {
      final requested = offset + OperationTextSequence.maxAtomsPerOperation;
      final end = requested < deletedIds.length
          ? requested
          : deletedIds.length;
      result.add(ShareTextIntent(OperationKind.textDelete, {
        'atomIds': deletedIds.sublist(offset, end),
      }));
    }
    var anchor = prefix == 0 ? null : oldIds[prefix - 1];
    final used = {...atoms.keys};
    for (var offset = 0; offset < inserted.length;
        offset += OperationTextSequence.maxAtomsPerOperation) {
      final requested = offset + OperationTextSequence.maxAtomsPerOperation;
      final end = requested < inserted.length ? requested : inserted.length;
      final batch = <Map<String, dynamic>>[];
      for (final character in inserted.sublist(offset, end)) {
        final atomId = _createAtomId();
        if (!_uuidPattern.hasMatch(atomId) || !used.add(atomId)) {
          throw StateError('Atom generator produced a duplicate or invalid ID.');
        }
        batch.add({'id': atomId, 'text': character});
      }
      result.add(ShareTextIntent(OperationKind.textInsert, {
        'afterAtomId': anchor,
        'atoms': batch,
      }));
      anchor = batch.last['id'] as String;
    }
    return result;
  }
}
,
  );
  final String Function() _createAtomId;

  List<ShareTextIntent> plan({
    required Map<String, dynamic> atoms,
    required String newText,
    String? changedDeltaJson,
  }) {
    if (changedDeltaJson != null) {
      throw UnsupportedError('Rich text requires an attribute CRDT.');
    }
    final oldIds = OperationTextSequence.visibleIds(atoms);
    final oldCharacters = <String>[];
    for (final id in oldIds) {
      final atom = atoms[id] as Map;
      final text = atom['text'] as String;
      if (text.runes.length != 1) {
        throw StateError('Text must be migrated to one atom per code point.');
      }
      oldCharacters.add(text);
    }
    final nextCharacters = newText.runes
        .map((rune) => String.fromCharCode(rune))
        .toList();
    if (nextCharacters.length > maxCodePoints) {
      throw StateError('Text edit exceeds the safe operation budget.');
    }
    var prefix = 0;
    while (prefix < oldCharacters.length &&
        prefix < nextCharacters.length &&
        oldCharacters[prefix] == nextCharacters[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < oldCharacters.length - prefix &&
        suffix < nextCharacters.length - prefix &&
        oldCharacters[oldCharacters.length - 1 - suffix] ==
            nextCharacters[nextCharacters.length - 1 - suffix]) {
      suffix++;
    }
    final deletedIds = oldIds.sublist(prefix, oldIds.length - suffix);
    final inserted = nextCharacters.sublist(
      prefix, nextCharacters.length - suffix,
    );
    if (deletedIds.isEmpty && inserted.isEmpty) {
      return const [];
    }
    final result = <ShareTextIntent>[];
    for (var offset = 0; offset < deletedIds.length;
        offset += OperationTextSequence.maxAtomsPerOperation) {
      final end = (offset + OperationTextSequence.maxAtomsPerOperation)
          .clamp(0, deletedIds.length);
      result.add(ShareTextIntent(OperationKind.textDelete, {
        'atomIds': deletedIds.sublist(offset, end),
      }));
    }
    var anchor = prefix == 0 ? null : oldIds[prefix - 1];
    final used = {...atoms.keys};
    for (var offset = 0; offset < inserted.length;
        offset += OperationTextSequence.maxAtomsPerOperation) {
      final end = (offset + OperationTextSequence.maxAtomsPerOperation)
          .clamp(0, inserted.length);
      final batch = <Map<String, dynamic>>[];
      for (final character in inserted.sublist(offset, end)) {
        final atomId = _createAtomId();
        if (!RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
          r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(atomId) || !used.add(atomId)) {
          throw StateError('Atom generator produced a duplicate or invalid ID.');
        }
        batch.add({'id': atomId, 'text': character});
      }
      result.add(ShareTextIntent(OperationKind.textInsert, {
        'afterAtomId': anchor,
        'atoms': batch,
      }));
      anchor = batch.last['id'] as String;
    }
    return result;
  }
}
