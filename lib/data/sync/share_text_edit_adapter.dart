import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'operation_protocol.dart';
import 'operation_text_sequence.dart';

typedef _DesiredAtom = ({
  String character,
  Map<String, dynamic> attributes,
  Map<String, dynamic>? embed,
});

/// One client-side intent. SyncEngine assigns actorSeq and operationId.
class ShareTextIntent {
  const ShareTextIntent(this.kind, this.payload);

  final OperationKind kind;
  final Map<String, dynamic> payload;
}

/// Converts committed plain-text or Quill snapshot changes into CRDT intents.
///
/// Formatting uses stable atom IDs. Embeds use content-addressed, pre-attached
/// image/PDF assets; the projector rejects missing or mismatched references.
class ShareTextEditAdapter {
  ShareTextEditAdapter({String Function()? createAtomId})
    : _createAtomId = createAtomId ?? const Uuid().v4;

  static const maxCodePoints = 50000;
  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  final String Function() _createAtomId;

  List<ShareTextIntent> plan({
    required Map<String, dynamic> atoms,
    required String newText,
    String? changedDeltaJson,
  }) {
    final desired = changedDeltaJson == null
        ? [
            for (final rune in newText.runes)
              (
                character: String.fromCharCode(rune),
                attributes: <String, dynamic>{},
                embed: null,
              ),
          ]
        : _parseQuillDelta(changedDeltaJson);
    final nextCharacters = [for (final item in desired) item.character];
    if (nextCharacters.join() != newText) {
      throw const FormatException('Quill delta differs from edited text.');
    }
    if (nextCharacters.length > maxCodePoints) {
      throw StateError('Text edit exceeds the safe operation budget.');
    }

    final oldIds = OperationTextSequence.visibleIds(atoms);
    final oldCharacters = <String>[];
    final oldEmbeds = <Map<String, dynamic>?>[];
    for (final id in oldIds) {
      final atom = atoms[id] as Map;
      final text = atom['text'] as String;
      if (text.runes.length != 1) {
        throw StateError('Text must be migrated to one atom per code point.');
      }
      oldCharacters.add(text);
      oldEmbeds.add(
        atom['embed'] is Map
            ? Map<String, dynamic>.from(atom['embed'] as Map)
            : null,
      );
    }

    bool sameAtom(int oldIndex, int newIndex) {
      final before = oldEmbeds[oldIndex];
      final after = desired[newIndex].embed;
      return oldCharacters[oldIndex] == desired[newIndex].character &&
          (before == null && after == null ||
              before != null &&
                  after != null &&
                  _sameAttributes(before, after));
    }

    var prefix = 0;
    while (prefix < oldCharacters.length &&
        prefix < nextCharacters.length &&
        sameAtom(prefix, prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < oldCharacters.length - prefix &&
        suffix < nextCharacters.length - prefix &&
        sameAtom(
          oldCharacters.length - 1 - suffix,
          nextCharacters.length - 1 - suffix,
        )) {
      suffix++;
    }

    final deletedIds = oldIds.sublist(prefix, oldIds.length - suffix);
    final inserted = desired.sublist(prefix, desired.length - suffix);
    final result = <ShareTextIntent>[];

    for (
      var offset = 0;
      offset < deletedIds.length;
      offset += OperationTextSequence.maxAtomsPerOperation
    ) {
      final requested = offset + OperationTextSequence.maxAtomsPerOperation;
      final end = requested < deletedIds.length ? requested : deletedIds.length;
      result.add(
        ShareTextIntent(OperationKind.textDelete, {
          'atomIds': deletedIds.sublist(offset, end),
        }),
      );
    }

    var anchor = prefix == 0 ? null : oldIds[prefix - 1];
    final used = {...atoms.keys};
    for (
      var offset = 0;
      offset < inserted.length;
      offset += OperationTextSequence.maxAtomsPerOperation
    ) {
      final requested = offset + OperationTextSequence.maxAtomsPerOperation;
      final end = requested < inserted.length ? requested : inserted.length;
      final batch = <Map<String, dynamic>>[];
      for (final item in inserted.sublist(offset, end)) {
        final atomId = _createAtomId();
        if (!_uuidPattern.hasMatch(atomId) || !used.add(atomId)) {
          throw StateError(
            'Atom generator produced a duplicate or invalid ID.',
          );
        }
        batch.add({
          'id': atomId,
          'text': item.character,
          if (item.attributes.isNotEmpty) 'attributes': item.attributes,
          if (item.embed != null) 'embed': item.embed,
        });
      }
      result.add(
        ShareTextIntent(OperationKind.textInsert, {
          'afterAtomId': anchor,
          'atoms': batch,
        }),
      );
      anchor = batch.last['id'] as String;
    }

    if (changedDeltaJson != null) {
      final matched = <int, int>{
        for (var i = 0; i < prefix; i++) i: i,
        for (var i = 0; i < suffix; i++)
          desired.length - suffix + i: oldIds.length - suffix + i,
      };
      Map<String, dynamic>? groupedChanges;
      final groupedIds = <String>[];

      void flush() {
        if (groupedIds.isEmpty) {
          return;
        }
        result.add(
          ShareTextIntent(OperationKind.textFormat, {
            'atomIds': List<String>.of(groupedIds),
            'attributes': Map<String, dynamic>.of(groupedChanges!),
          }),
        );
        groupedIds.clear();
      }

      for (final pair in matched.entries) {
        final id = oldIds[pair.value];
        final before = Map<String, dynamic>.from(
          (atoms[id] as Map)['attributes'] as Map? ?? const {},
        );
        final after = desired[pair.key].attributes;
        final changes = <String, dynamic>{};
        for (final key in {...before.keys, ...after.keys}) {
          if (!after.containsKey(key)) {
            changes[key] = null;
          } else if (!before.containsKey(key) || before[key] != after[key]) {
            changes[key] = after[key];
          }
        }
        if (changes.isEmpty) {
          flush();
          groupedChanges = null;
          continue;
        }
        if (groupedChanges != null &&
            (!_sameAttributes(changes, groupedChanges) ||
                groupedIds.length >=
                    OperationTextSequence.maxAtomsPerOperation)) {
          flush();
          groupedChanges = null;
        }
        groupedChanges ??= changes;
        groupedIds.add(id);
      }
      flush();
    }
    return result;
  }

  static bool _sameAttributes(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a.length == b.length &&
      a.entries.every(
        (entry) => b.containsKey(entry.key) && b[entry.key] == entry.value,
      );

  static List<_DesiredAtom> _parseQuillDelta(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! List) {
      throw const FormatException('Quill snapshot must be a Delta list.');
    }
    final result = <_DesiredAtom>[];
    for (final raw in decoded) {
      if (raw is! Map ||
          !raw.containsKey('insert') ||
          raw.keys.any((key) => key != 'insert' && key != 'attributes')) {
        throw const FormatException('Quill snapshot needs insert operations.');
      }
      final insert = raw['insert'];
      if (insert is! String && insert is! Map) {
        throw const FormatException('Invalid Quill Delta insertion.');
      }
      if (insert is Map) {
        OperationEnvelope.embedAssetId(insert);
      }
      final attrs = raw['attributes'] ?? const <String, dynamic>{};
      if (attrs is! Map || attrs.length > 32) {
        throw const FormatException('Invalid Quill attributes.');
      }
      final attributes = <String, dynamic>{};
      for (final entry in attrs.entries) {
        final key = entry.key;
        final item = entry.value;
        if (key is! String ||
            key.isEmpty ||
            key.length > 64 ||
            (item is! String && item is! bool && item is! num) ||
            (item is String && item.length > 2048) ||
            (item is num && !item.isFinite)) {
          throw const FormatException('Invalid Quill attributes.');
        }
        attributes[key] = item;
      }
      if (insert is Map) {
        result.add((
          character: '\uFFFC',
          attributes: attributes,
          embed: Map<String, dynamic>.from(insert),
        ));
      } else {
        for (final rune in (insert as String).runes) {
          result.add((
            character: String.fromCharCode(rune),
            attributes: attributes,
            embed: null,
          ));
        }
      }
    }
    return result;
  }
}
