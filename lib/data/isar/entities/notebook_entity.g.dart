// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'notebook_entity.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetNotebookEntityCollection on Isar {
  IsarCollection<NotebookEntity> get notebookEntitys => this.collection();
}

const NotebookEntitySchema = CollectionSchema(
  name: r'NotebookEntity',
  id: -429147861698866060,
  properties: {
    r'createdAt': PropertySchema(
      id: 0,
      name: r'createdAt',
      type: IsarType.dateTime,
    ),
    r'folder': PropertySchema(id: 1, name: r'folder', type: IsarType.string),
    r'kindIndex': PropertySchema(
      id: 2,
      name: r'kindIndex',
      type: IsarType.long,
    ),
    r'pages': PropertySchema(
      id: 3,
      name: r'pages',
      type: IsarType.objectList,
      target: r'NotePageEntity',
    ),
    r'title': PropertySchema(id: 4, name: r'title', type: IsarType.string),
    r'uid': PropertySchema(id: 5, name: r'uid', type: IsarType.string),
    r'updatedAt': PropertySchema(
      id: 6,
      name: r'updatedAt',
      type: IsarType.dateTime,
    ),
  },
  estimateSize: _notebookEntityEstimateSize,
  serialize: _notebookEntitySerialize,
  deserialize: _notebookEntityDeserialize,
  deserializeProp: _notebookEntityDeserializeProp,
  idName: r'id',
  indexes: {},
  links: {},
  embeddedSchemas: {
    r'NotePageEntity': NotePageEntitySchema,
    r'IndexTabEntity': IndexTabEntitySchema,
    r'TextBlockEntity': TextBlockEntitySchema,
    r'ImageBlockEntity': ImageBlockEntitySchema,
    r'InkStrokeEntity': InkStrokeEntitySchema,
    r'InkPointEntity': InkPointEntitySchema,
  },
  getId: _notebookEntityGetId,
  getLinks: _notebookEntityGetLinks,
  attach: _notebookEntityAttach,
  version: '3.1.0+1',
);

int _notebookEntityEstimateSize(
  NotebookEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.folder.length * 3;
  bytesCount += 3 + object.pages.length * 3;
  {
    final offsets = allOffsets[NotePageEntity]!;
    for (var i = 0; i < object.pages.length; i++) {
      final value = object.pages[i];
      bytesCount += NotePageEntitySchema.estimateSize(
        value,
        offsets,
        allOffsets,
      );
    }
  }
  bytesCount += 3 + object.title.length * 3;
  bytesCount += 3 + object.uid.length * 3;
  return bytesCount;
}

void _notebookEntitySerialize(
  NotebookEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeDateTime(offsets[0], object.createdAt);
  writer.writeString(offsets[1], object.folder);
  writer.writeLong(offsets[2], object.kindIndex);
  writer.writeObjectList<NotePageEntity>(
    offsets[3],
    allOffsets,
    NotePageEntitySchema.serialize,
    object.pages,
  );
  writer.writeString(offsets[4], object.title);
  writer.writeString(offsets[5], object.uid);
  writer.writeDateTime(offsets[6], object.updatedAt);
}

NotebookEntity _notebookEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = NotebookEntity();
  object.createdAt = reader.readDateTime(offsets[0]);
  object.folder = reader.readString(offsets[1]);
  object.id = id;
  object.kindIndex = reader.readLong(offsets[2]);
  object.pages =
      reader.readObjectList<NotePageEntity>(
        offsets[3],
        NotePageEntitySchema.deserialize,
        allOffsets,
        NotePageEntity(),
      ) ??
      [];
  object.title = reader.readString(offsets[4]);
  object.uid = reader.readString(offsets[5]);
  object.updatedAt = reader.readDateTime(offsets[6]);
  return object;
}

P _notebookEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readDateTime(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readLong(offset)) as P;
    case 3:
      return (reader.readObjectList<NotePageEntity>(
                offset,
                NotePageEntitySchema.deserialize,
                allOffsets,
                NotePageEntity(),
              ) ??
              [])
          as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readString(offset)) as P;
    case 6:
      return (reader.readDateTime(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _notebookEntityGetId(NotebookEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _notebookEntityGetLinks(NotebookEntity object) {
  return [];
}

void _notebookEntityAttach(
  IsarCollection<dynamic> col,
  Id id,
  NotebookEntity object,
) {
  object.id = id;
}

extension NotebookEntityQueryWhereSort
    on QueryBuilder<NotebookEntity, NotebookEntity, QWhere> {
  QueryBuilder<NotebookEntity, NotebookEntity, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension NotebookEntityQueryWhere
    on QueryBuilder<NotebookEntity, NotebookEntity, QWhereClause> {
  QueryBuilder<NotebookEntity, NotebookEntity, QAfterWhereClause> idEqualTo(
    Id id,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(lower: id, upper: id));
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterWhereClause> idNotEqualTo(
    Id id,
  ) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterWhereClause> idGreaterThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterWhereClause> idLessThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.between(
          lower: lowerId,
          includeLower: includeLower,
          upper: upperId,
          includeUpper: includeUpper,
        ),
      );
    });
  }
}

extension NotebookEntityQueryFilter
    on QueryBuilder<NotebookEntity, NotebookEntity, QFilterCondition> {
  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  createdAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'createdAt', value: value),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  createdAtGreaterThan(DateTime value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'createdAt',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  createdAtLessThan(DateTime value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'createdAt',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  createdAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'createdAt',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  folderEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'folder',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  folderGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'folder',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  folderLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'folder',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  folderBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'folder',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  folderStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'folder',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  folderEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'folder',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  folderContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'folder',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  folderMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'folder',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  folderIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'folder', value: ''),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  folderIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'folder', value: ''),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition> idEqualTo(
    Id value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'id', value: value),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  idGreaterThan(Id value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  idLessThan(Id value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'id',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  kindIndexEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'kindIndex', value: value),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  kindIndexGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'kindIndex',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  kindIndexLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'kindIndex',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  kindIndexBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'kindIndex',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  pagesLengthEqualTo(int length) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'pages', length, true, length, true);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  pagesIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'pages', 0, true, 0, true);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  pagesIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'pages', 0, false, 999999, true);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  pagesLengthLessThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'pages', 0, true, length, include);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  pagesLengthGreaterThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'pages', length, include, 999999, true);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  pagesLengthBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'pages',
        lower,
        includeLower,
        upper,
        includeUpper,
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  titleEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  titleGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  titleLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  titleBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'title',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  titleStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  titleEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  titleContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  titleMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'title',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  titleIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'title', value: ''),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  titleIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'title', value: ''),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  uidEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  uidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  uidLessThan(String value, {bool include = false, bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  uidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'uid',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  uidStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  uidEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  uidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  uidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'uid',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  uidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'uid', value: ''),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  uidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'uid', value: ''),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  updatedAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'updatedAt', value: value),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  updatedAtGreaterThan(DateTime value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'updatedAt',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  updatedAtLessThan(DateTime value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'updatedAt',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  updatedAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'updatedAt',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }
}

extension NotebookEntityQueryObject
    on QueryBuilder<NotebookEntity, NotebookEntity, QFilterCondition> {
  QueryBuilder<NotebookEntity, NotebookEntity, QAfterFilterCondition>
  pagesElement(FilterQuery<NotePageEntity> q) {
    return QueryBuilder.apply(this, (query) {
      return query.object(q, r'pages');
    });
  }
}

extension NotebookEntityQueryLinks
    on QueryBuilder<NotebookEntity, NotebookEntity, QFilterCondition> {}

extension NotebookEntityQuerySortBy
    on QueryBuilder<NotebookEntity, NotebookEntity, QSortBy> {
  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> sortByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy>
  sortByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> sortByFolder() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'folder', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy>
  sortByFolderDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'folder', Sort.desc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> sortByKindIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'kindIndex', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy>
  sortByKindIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'kindIndex', Sort.desc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> sortByTitle() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> sortByTitleDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.desc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> sortByUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> sortByUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.desc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> sortByUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'updatedAt', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy>
  sortByUpdatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'updatedAt', Sort.desc);
    });
  }
}

extension NotebookEntityQuerySortThenBy
    on QueryBuilder<NotebookEntity, NotebookEntity, QSortThenBy> {
  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> thenByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy>
  thenByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> thenByFolder() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'folder', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy>
  thenByFolderDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'folder', Sort.desc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> thenByKindIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'kindIndex', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy>
  thenByKindIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'kindIndex', Sort.desc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> thenByTitle() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> thenByTitleDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.desc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> thenByUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> thenByUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.desc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy> thenByUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'updatedAt', Sort.asc);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QAfterSortBy>
  thenByUpdatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'updatedAt', Sort.desc);
    });
  }
}

extension NotebookEntityQueryWhereDistinct
    on QueryBuilder<NotebookEntity, NotebookEntity, QDistinct> {
  QueryBuilder<NotebookEntity, NotebookEntity, QDistinct>
  distinctByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'createdAt');
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QDistinct> distinctByFolder({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'folder', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QDistinct>
  distinctByKindIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'kindIndex');
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QDistinct> distinctByTitle({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'title', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QDistinct> distinctByUid({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'uid', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<NotebookEntity, NotebookEntity, QDistinct>
  distinctByUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'updatedAt');
    });
  }
}

extension NotebookEntityQueryProperty
    on QueryBuilder<NotebookEntity, NotebookEntity, QQueryProperty> {
  QueryBuilder<NotebookEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<NotebookEntity, DateTime, QQueryOperations> createdAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'createdAt');
    });
  }

  QueryBuilder<NotebookEntity, String, QQueryOperations> folderProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'folder');
    });
  }

  QueryBuilder<NotebookEntity, int, QQueryOperations> kindIndexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'kindIndex');
    });
  }

  QueryBuilder<NotebookEntity, List<NotePageEntity>, QQueryOperations>
  pagesProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'pages');
    });
  }

  QueryBuilder<NotebookEntity, String, QQueryOperations> titleProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'title');
    });
  }

  QueryBuilder<NotebookEntity, String, QQueryOperations> uidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'uid');
    });
  }

  QueryBuilder<NotebookEntity, DateTime, QQueryOperations> updatedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'updatedAt');
    });
  }
}

// **************************************************************************
// IsarEmbeddedGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

const NotePageEntitySchema = Schema(
  name: r'NotePageEntity',
  id: -1574053810509456390,
  properties: {
    r'imageBlocks': PropertySchema(
      id: 0,
      name: r'imageBlocks',
      type: IsarType.objectList,
      target: r'ImageBlockEntity',
    ),
    r'index': PropertySchema(id: 1, name: r'index', type: IsarType.long),
    r'indexTabColorValue': PropertySchema(
      id: 2,
      name: r'indexTabColorValue',
      type: IsarType.long,
    ),
    r'indexTabPosition': PropertySchema(
      id: 3,
      name: r'indexTabPosition',
      type: IsarType.double,
    ),
    r'indexTabs': PropertySchema(
      id: 4,
      name: r'indexTabs',
      type: IsarType.objectList,
      target: r'IndexTabEntity',
    ),
    r'inkStrokes': PropertySchema(
      id: 5,
      name: r'inkStrokes',
      type: IsarType.objectList,
      target: r'InkStrokeEntity',
    ),
    r'isBookmarked': PropertySchema(
      id: 6,
      name: r'isBookmarked',
      type: IsarType.bool,
    ),
    r'textBlocks': PropertySchema(
      id: 7,
      name: r'textBlocks',
      type: IsarType.objectList,
      target: r'TextBlockEntity',
    ),
    r'title': PropertySchema(id: 8, name: r'title', type: IsarType.string),
    r'uid': PropertySchema(id: 9, name: r'uid', type: IsarType.string),
  },
  estimateSize: _notePageEntityEstimateSize,
  serialize: _notePageEntitySerialize,
  deserialize: _notePageEntityDeserialize,
  deserializeProp: _notePageEntityDeserializeProp,
);

int _notePageEntityEstimateSize(
  NotePageEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.imageBlocks.length * 3;
  {
    final offsets = allOffsets[ImageBlockEntity]!;
    for (var i = 0; i < object.imageBlocks.length; i++) {
      final value = object.imageBlocks[i];
      bytesCount += ImageBlockEntitySchema.estimateSize(
        value,
        offsets,
        allOffsets,
      );
    }
  }
  bytesCount += 3 + object.indexTabs.length * 3;
  {
    final offsets = allOffsets[IndexTabEntity]!;
    for (var i = 0; i < object.indexTabs.length; i++) {
      final value = object.indexTabs[i];
      bytesCount += IndexTabEntitySchema.estimateSize(
        value,
        offsets,
        allOffsets,
      );
    }
  }
  bytesCount += 3 + object.inkStrokes.length * 3;
  {
    final offsets = allOffsets[InkStrokeEntity]!;
    for (var i = 0; i < object.inkStrokes.length; i++) {
      final value = object.inkStrokes[i];
      bytesCount += InkStrokeEntitySchema.estimateSize(
        value,
        offsets,
        allOffsets,
      );
    }
  }
  bytesCount += 3 + object.textBlocks.length * 3;
  {
    final offsets = allOffsets[TextBlockEntity]!;
    for (var i = 0; i < object.textBlocks.length; i++) {
      final value = object.textBlocks[i];
      bytesCount += TextBlockEntitySchema.estimateSize(
        value,
        offsets,
        allOffsets,
      );
    }
  }
  bytesCount += 3 + object.title.length * 3;
  bytesCount += 3 + object.uid.length * 3;
  return bytesCount;
}

void _notePageEntitySerialize(
  NotePageEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeObjectList<ImageBlockEntity>(
    offsets[0],
    allOffsets,
    ImageBlockEntitySchema.serialize,
    object.imageBlocks,
  );
  writer.writeLong(offsets[1], object.index);
  writer.writeLong(offsets[2], object.indexTabColorValue);
  writer.writeDouble(offsets[3], object.indexTabPosition);
  writer.writeObjectList<IndexTabEntity>(
    offsets[4],
    allOffsets,
    IndexTabEntitySchema.serialize,
    object.indexTabs,
  );
  writer.writeObjectList<InkStrokeEntity>(
    offsets[5],
    allOffsets,
    InkStrokeEntitySchema.serialize,
    object.inkStrokes,
  );
  writer.writeBool(offsets[6], object.isBookmarked);
  writer.writeObjectList<TextBlockEntity>(
    offsets[7],
    allOffsets,
    TextBlockEntitySchema.serialize,
    object.textBlocks,
  );
  writer.writeString(offsets[8], object.title);
  writer.writeString(offsets[9], object.uid);
}

NotePageEntity _notePageEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = NotePageEntity();
  object.imageBlocks =
      reader.readObjectList<ImageBlockEntity>(
        offsets[0],
        ImageBlockEntitySchema.deserialize,
        allOffsets,
        ImageBlockEntity(),
      ) ??
      [];
  object.index = reader.readLong(offsets[1]);
  object.indexTabColorValue = reader.readLongOrNull(offsets[2]);
  object.indexTabPosition = reader.readDoubleOrNull(offsets[3]);
  object.indexTabs =
      reader.readObjectList<IndexTabEntity>(
        offsets[4],
        IndexTabEntitySchema.deserialize,
        allOffsets,
        IndexTabEntity(),
      ) ??
      [];
  object.inkStrokes =
      reader.readObjectList<InkStrokeEntity>(
        offsets[5],
        InkStrokeEntitySchema.deserialize,
        allOffsets,
        InkStrokeEntity(),
      ) ??
      [];
  object.isBookmarked = reader.readBool(offsets[6]);
  object.textBlocks =
      reader.readObjectList<TextBlockEntity>(
        offsets[7],
        TextBlockEntitySchema.deserialize,
        allOffsets,
        TextBlockEntity(),
      ) ??
      [];
  object.title = reader.readString(offsets[8]);
  object.uid = reader.readString(offsets[9]);
  return object;
}

P _notePageEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readObjectList<ImageBlockEntity>(
                offset,
                ImageBlockEntitySchema.deserialize,
                allOffsets,
                ImageBlockEntity(),
              ) ??
              [])
          as P;
    case 1:
      return (reader.readLong(offset)) as P;
    case 2:
      return (reader.readLongOrNull(offset)) as P;
    case 3:
      return (reader.readDoubleOrNull(offset)) as P;
    case 4:
      return (reader.readObjectList<IndexTabEntity>(
                offset,
                IndexTabEntitySchema.deserialize,
                allOffsets,
                IndexTabEntity(),
              ) ??
              [])
          as P;
    case 5:
      return (reader.readObjectList<InkStrokeEntity>(
                offset,
                InkStrokeEntitySchema.deserialize,
                allOffsets,
                InkStrokeEntity(),
              ) ??
              [])
          as P;
    case 6:
      return (reader.readBool(offset)) as P;
    case 7:
      return (reader.readObjectList<TextBlockEntity>(
                offset,
                TextBlockEntitySchema.deserialize,
                allOffsets,
                TextBlockEntity(),
              ) ??
              [])
          as P;
    case 8:
      return (reader.readString(offset)) as P;
    case 9:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

extension NotePageEntityQueryFilter
    on QueryBuilder<NotePageEntity, NotePageEntity, QFilterCondition> {
  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  imageBlocksLengthEqualTo(int length) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'imageBlocks', length, true, length, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  imageBlocksIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'imageBlocks', 0, true, 0, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  imageBlocksIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'imageBlocks', 0, false, 999999, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  imageBlocksLengthLessThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'imageBlocks', 0, true, length, include);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  imageBlocksLengthGreaterThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'imageBlocks', length, include, 999999, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  imageBlocksLengthBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'imageBlocks',
        lower,
        includeLower,
        upper,
        includeUpper,
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'index', value: value),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'index',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'index',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'index',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabColorValueIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'indexTabColorValue'),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabColorValueIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'indexTabColorValue'),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabColorValueEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'indexTabColorValue', value: value),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabColorValueGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'indexTabColorValue',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabColorValueLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'indexTabColorValue',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabColorValueBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'indexTabColorValue',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabPositionIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'indexTabPosition'),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabPositionIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'indexTabPosition'),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabPositionEqualTo(double? value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'indexTabPosition',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabPositionGreaterThan(
    double? value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'indexTabPosition',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabPositionLessThan(
    double? value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'indexTabPosition',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabPositionBetween(
    double? lower,
    double? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'indexTabPosition',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabsLengthEqualTo(int length) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'indexTabs', length, true, length, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabsIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'indexTabs', 0, true, 0, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabsIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'indexTabs', 0, false, 999999, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabsLengthLessThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'indexTabs', 0, true, length, include);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabsLengthGreaterThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'indexTabs', length, include, 999999, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabsLengthBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'indexTabs',
        lower,
        includeLower,
        upper,
        includeUpper,
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  inkStrokesLengthEqualTo(int length) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'inkStrokes', length, true, length, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  inkStrokesIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'inkStrokes', 0, true, 0, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  inkStrokesIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'inkStrokes', 0, false, 999999, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  inkStrokesLengthLessThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'inkStrokes', 0, true, length, include);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  inkStrokesLengthGreaterThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'inkStrokes', length, include, 999999, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  inkStrokesLengthBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'inkStrokes',
        lower,
        includeLower,
        upper,
        includeUpper,
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  isBookmarkedEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'isBookmarked', value: value),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  textBlocksLengthEqualTo(int length) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'textBlocks', length, true, length, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  textBlocksIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'textBlocks', 0, true, 0, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  textBlocksIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'textBlocks', 0, false, 999999, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  textBlocksLengthLessThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'textBlocks', 0, true, length, include);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  textBlocksLengthGreaterThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'textBlocks', length, include, 999999, true);
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  textBlocksLengthBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'textBlocks',
        lower,
        includeLower,
        upper,
        includeUpper,
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  titleEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  titleGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  titleLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  titleBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'title',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  titleStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  titleEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  titleContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  titleMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'title',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  titleIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'title', value: ''),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  titleIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'title', value: ''),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  uidEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  uidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  uidLessThan(String value, {bool include = false, bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  uidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'uid',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  uidStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  uidEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  uidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  uidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'uid',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  uidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'uid', value: ''),
      );
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  uidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'uid', value: ''),
      );
    });
  }
}

extension NotePageEntityQueryObject
    on QueryBuilder<NotePageEntity, NotePageEntity, QFilterCondition> {
  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  imageBlocksElement(FilterQuery<ImageBlockEntity> q) {
    return QueryBuilder.apply(this, (query) {
      return query.object(q, r'imageBlocks');
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  indexTabsElement(FilterQuery<IndexTabEntity> q) {
    return QueryBuilder.apply(this, (query) {
      return query.object(q, r'indexTabs');
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  inkStrokesElement(FilterQuery<InkStrokeEntity> q) {
    return QueryBuilder.apply(this, (query) {
      return query.object(q, r'inkStrokes');
    });
  }

  QueryBuilder<NotePageEntity, NotePageEntity, QAfterFilterCondition>
  textBlocksElement(FilterQuery<TextBlockEntity> q) {
    return QueryBuilder.apply(this, (query) {
      return query.object(q, r'textBlocks');
    });
  }
}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

const IndexTabEntitySchema = Schema(
  name: r'IndexTabEntity',
  id: -6234637872862099452,
  properties: {
    r'colorValue': PropertySchema(
      id: 0,
      name: r'colorValue',
      type: IsarType.long,
    ),
    r'position': PropertySchema(
      id: 1,
      name: r'position',
      type: IsarType.double,
    ),
    r'uid': PropertySchema(id: 2, name: r'uid', type: IsarType.string),
  },
  estimateSize: _indexTabEntityEstimateSize,
  serialize: _indexTabEntitySerialize,
  deserialize: _indexTabEntityDeserialize,
  deserializeProp: _indexTabEntityDeserializeProp,
);

int _indexTabEntityEstimateSize(
  IndexTabEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.uid.length * 3;
  return bytesCount;
}

void _indexTabEntitySerialize(
  IndexTabEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLong(offsets[0], object.colorValue);
  writer.writeDouble(offsets[1], object.position);
  writer.writeString(offsets[2], object.uid);
}

IndexTabEntity _indexTabEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = IndexTabEntity();
  object.colorValue = reader.readLong(offsets[0]);
  object.position = reader.readDouble(offsets[1]);
  object.uid = reader.readString(offsets[2]);
  return object;
}

P _indexTabEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readLong(offset)) as P;
    case 1:
      return (reader.readDouble(offset)) as P;
    case 2:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

extension IndexTabEntityQueryFilter
    on QueryBuilder<IndexTabEntity, IndexTabEntity, QFilterCondition> {
  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  colorValueEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'colorValue', value: value),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  colorValueGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'colorValue',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  colorValueLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'colorValue',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  colorValueBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'colorValue',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  positionEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'position',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  positionGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'position',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  positionLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'position',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  positionBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'position',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  uidEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  uidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  uidLessThan(String value, {bool include = false, bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  uidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'uid',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  uidStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  uidEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  uidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  uidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'uid',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  uidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'uid', value: ''),
      );
    });
  }

  QueryBuilder<IndexTabEntity, IndexTabEntity, QAfterFilterCondition>
  uidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'uid', value: ''),
      );
    });
  }
}

extension IndexTabEntityQueryObject
    on QueryBuilder<IndexTabEntity, IndexTabEntity, QFilterCondition> {}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

const TextBlockEntitySchema = Schema(
  name: r'TextBlockEntity',
  id: -4112458558810260550,
  properties: {
    r'colorValue': PropertySchema(
      id: 0,
      name: r'colorValue',
      type: IsarType.long,
    ),
    r'deltaJson': PropertySchema(
      id: 1,
      name: r'deltaJson',
      type: IsarType.string,
    ),
    r'dx': PropertySchema(id: 2, name: r'dx', type: IsarType.double),
    r'dy': PropertySchema(id: 3, name: r'dy', type: IsarType.double),
    r'fontSize': PropertySchema(
      id: 4,
      name: r'fontSize',
      type: IsarType.double,
    ),
    r'rotation': PropertySchema(
      id: 5,
      name: r'rotation',
      type: IsarType.double,
    ),
    r'text': PropertySchema(id: 6, name: r'text', type: IsarType.string),
    r'uid': PropertySchema(id: 7, name: r'uid', type: IsarType.string),
    r'width': PropertySchema(id: 8, name: r'width', type: IsarType.double),
  },
  estimateSize: _textBlockEntityEstimateSize,
  serialize: _textBlockEntitySerialize,
  deserialize: _textBlockEntityDeserialize,
  deserializeProp: _textBlockEntityDeserializeProp,
);

int _textBlockEntityEstimateSize(
  TextBlockEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  {
    final value = object.deltaJson;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.text.length * 3;
  bytesCount += 3 + object.uid.length * 3;
  return bytesCount;
}

void _textBlockEntitySerialize(
  TextBlockEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLong(offsets[0], object.colorValue);
  writer.writeString(offsets[1], object.deltaJson);
  writer.writeDouble(offsets[2], object.dx);
  writer.writeDouble(offsets[3], object.dy);
  writer.writeDouble(offsets[4], object.fontSize);
  writer.writeDouble(offsets[5], object.rotation);
  writer.writeString(offsets[6], object.text);
  writer.writeString(offsets[7], object.uid);
  writer.writeDouble(offsets[8], object.width);
}

TextBlockEntity _textBlockEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = TextBlockEntity();
  object.colorValue = reader.readLong(offsets[0]);
  object.deltaJson = reader.readStringOrNull(offsets[1]);
  object.dx = reader.readDouble(offsets[2]);
  object.dy = reader.readDouble(offsets[3]);
  object.fontSize = reader.readDouble(offsets[4]);
  object.rotation = reader.readDouble(offsets[5]);
  object.text = reader.readString(offsets[6]);
  object.uid = reader.readString(offsets[7]);
  object.width = reader.readDouble(offsets[8]);
  return object;
}

P _textBlockEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readLong(offset)) as P;
    case 1:
      return (reader.readStringOrNull(offset)) as P;
    case 2:
      return (reader.readDouble(offset)) as P;
    case 3:
      return (reader.readDouble(offset)) as P;
    case 4:
      return (reader.readDouble(offset)) as P;
    case 5:
      return (reader.readDouble(offset)) as P;
    case 6:
      return (reader.readString(offset)) as P;
    case 7:
      return (reader.readString(offset)) as P;
    case 8:
      return (reader.readDouble(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

extension TextBlockEntityQueryFilter
    on QueryBuilder<TextBlockEntity, TextBlockEntity, QFilterCondition> {
  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  colorValueEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'colorValue', value: value),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  colorValueGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'colorValue',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  colorValueLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'colorValue',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  colorValueBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'colorValue',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'deltaJson'),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'deltaJson'),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'deltaJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'deltaJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'deltaJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'deltaJson',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'deltaJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'deltaJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'deltaJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'deltaJson',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'deltaJson', value: ''),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  deltaJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'deltaJson', value: ''),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  dxEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'dx',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  dxGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'dx',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  dxLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'dx',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  dxBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'dx',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  dyEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'dy',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  dyGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'dy',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  dyLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'dy',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  dyBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'dy',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  fontSizeEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'fontSize',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  fontSizeGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'fontSize',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  fontSizeLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'fontSize',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  fontSizeBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'fontSize',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  rotationEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'rotation',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  rotationGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'rotation',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  rotationLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'rotation',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  rotationBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'rotation',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  textEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'text',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  textGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'text',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  textLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'text',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  textBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'text',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  textStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'text',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  textEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'text',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  textContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'text',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  textMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'text',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  textIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'text', value: ''),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  textIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'text', value: ''),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  uidEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  uidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  uidLessThan(String value, {bool include = false, bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  uidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'uid',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  uidStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  uidEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  uidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  uidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'uid',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  uidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'uid', value: ''),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  uidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'uid', value: ''),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  widthEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'width',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  widthGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'width',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  widthLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'width',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<TextBlockEntity, TextBlockEntity, QAfterFilterCondition>
  widthBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'width',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }
}

extension TextBlockEntityQueryObject
    on QueryBuilder<TextBlockEntity, TextBlockEntity, QFilterCondition> {}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

const ImageBlockEntitySchema = Schema(
  name: r'ImageBlockEntity',
  id: -5828569072254127974,
  properties: {
    r'bytes': PropertySchema(id: 0, name: r'bytes', type: IsarType.longList),
    r'cropBottom': PropertySchema(
      id: 1,
      name: r'cropBottom',
      type: IsarType.double,
    ),
    r'cropLeft': PropertySchema(
      id: 2,
      name: r'cropLeft',
      type: IsarType.double,
    ),
    r'cropRight': PropertySchema(
      id: 3,
      name: r'cropRight',
      type: IsarType.double,
    ),
    r'cropTop': PropertySchema(id: 4, name: r'cropTop', type: IsarType.double),
    r'dx': PropertySchema(id: 5, name: r'dx', type: IsarType.double),
    r'dy': PropertySchema(id: 6, name: r'dy', type: IsarType.double),
    r'height': PropertySchema(id: 7, name: r'height', type: IsarType.double),
    r'imageExt': PropertySchema(
      id: 8,
      name: r'imageExt',
      type: IsarType.string,
    ),
    r'imageMime': PropertySchema(
      id: 9,
      name: r'imageMime',
      type: IsarType.string,
    ),
    r'ocrText': PropertySchema(id: 10, name: r'ocrText', type: IsarType.string),
    r'path': PropertySchema(id: 11, name: r'path', type: IsarType.string),
    r'rotation': PropertySchema(
      id: 12,
      name: r'rotation',
      type: IsarType.double,
    ),
    r'uid': PropertySchema(id: 13, name: r'uid', type: IsarType.string),
    r'width': PropertySchema(id: 14, name: r'width', type: IsarType.double),
  },
  estimateSize: _imageBlockEntityEstimateSize,
  serialize: _imageBlockEntitySerialize,
  deserialize: _imageBlockEntityDeserialize,
  deserializeProp: _imageBlockEntityDeserializeProp,
);

int _imageBlockEntityEstimateSize(
  ImageBlockEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  {
    final value = object.bytes;
    if (value != null) {
      bytesCount += 3 + value.length * 8;
    }
  }
  {
    final value = object.imageExt;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.imageMime;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.ocrText.length * 3;
  bytesCount += 3 + object.path.length * 3;
  bytesCount += 3 + object.uid.length * 3;
  return bytesCount;
}

void _imageBlockEntitySerialize(
  ImageBlockEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLongList(offsets[0], object.bytes);
  writer.writeDouble(offsets[1], object.cropBottom);
  writer.writeDouble(offsets[2], object.cropLeft);
  writer.writeDouble(offsets[3], object.cropRight);
  writer.writeDouble(offsets[4], object.cropTop);
  writer.writeDouble(offsets[5], object.dx);
  writer.writeDouble(offsets[6], object.dy);
  writer.writeDouble(offsets[7], object.height);
  writer.writeString(offsets[8], object.imageExt);
  writer.writeString(offsets[9], object.imageMime);
  writer.writeString(offsets[10], object.ocrText);
  writer.writeString(offsets[11], object.path);
  writer.writeDouble(offsets[12], object.rotation);
  writer.writeString(offsets[13], object.uid);
  writer.writeDouble(offsets[14], object.width);
}

ImageBlockEntity _imageBlockEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = ImageBlockEntity();
  object.bytes = reader.readLongList(offsets[0]);
  object.cropBottom = reader.readDouble(offsets[1]);
  object.cropLeft = reader.readDouble(offsets[2]);
  object.cropRight = reader.readDouble(offsets[3]);
  object.cropTop = reader.readDouble(offsets[4]);
  object.dx = reader.readDouble(offsets[5]);
  object.dy = reader.readDouble(offsets[6]);
  object.height = reader.readDouble(offsets[7]);
  object.imageExt = reader.readStringOrNull(offsets[8]);
  object.imageMime = reader.readStringOrNull(offsets[9]);
  object.ocrText = reader.readString(offsets[10]);
  object.path = reader.readString(offsets[11]);
  object.rotation = reader.readDouble(offsets[12]);
  object.uid = reader.readString(offsets[13]);
  object.width = reader.readDouble(offsets[14]);
  return object;
}

P _imageBlockEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readLongList(offset)) as P;
    case 1:
      return (reader.readDouble(offset)) as P;
    case 2:
      return (reader.readDouble(offset)) as P;
    case 3:
      return (reader.readDouble(offset)) as P;
    case 4:
      return (reader.readDouble(offset)) as P;
    case 5:
      return (reader.readDouble(offset)) as P;
    case 6:
      return (reader.readDouble(offset)) as P;
    case 7:
      return (reader.readDouble(offset)) as P;
    case 8:
      return (reader.readStringOrNull(offset)) as P;
    case 9:
      return (reader.readStringOrNull(offset)) as P;
    case 10:
      return (reader.readString(offset)) as P;
    case 11:
      return (reader.readString(offset)) as P;
    case 12:
      return (reader.readDouble(offset)) as P;
    case 13:
      return (reader.readString(offset)) as P;
    case 14:
      return (reader.readDouble(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

extension ImageBlockEntityQueryFilter
    on QueryBuilder<ImageBlockEntity, ImageBlockEntity, QFilterCondition> {
  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'bytes'),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'bytes'),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesElementEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'bytes', value: value),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesElementGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'bytes',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesElementLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'bytes',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesElementBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'bytes',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesLengthEqualTo(int length) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'bytes', length, true, length, true);
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'bytes', 0, true, 0, true);
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'bytes', 0, false, 999999, true);
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesLengthLessThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'bytes', 0, true, length, include);
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesLengthGreaterThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'bytes', length, include, 999999, true);
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  bytesLengthBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'bytes',
        lower,
        includeLower,
        upper,
        includeUpper,
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropBottomEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'cropBottom',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropBottomGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'cropBottom',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropBottomLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'cropBottom',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropBottomBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'cropBottom',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropLeftEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'cropLeft',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropLeftGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'cropLeft',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropLeftLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'cropLeft',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropLeftBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'cropLeft',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropRightEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'cropRight',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropRightGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'cropRight',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropRightLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'cropRight',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropRightBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'cropRight',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropTopEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'cropTop',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropTopGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'cropTop',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropTopLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'cropTop',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  cropTopBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'cropTop',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  dxEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'dx',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  dxGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'dx',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  dxLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'dx',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  dxBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'dx',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  dyEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'dy',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  dyGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'dy',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  dyLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'dy',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  dyBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'dy',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  heightEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'height',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  heightGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'height',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  heightLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'height',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  heightBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'height',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'imageExt'),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'imageExt'),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'imageExt',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'imageExt',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'imageExt',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'imageExt',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'imageExt',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'imageExt',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'imageExt',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'imageExt',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'imageExt', value: ''),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageExtIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'imageExt', value: ''),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'imageMime'),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'imageMime'),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'imageMime',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'imageMime',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'imageMime',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'imageMime',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'imageMime',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'imageMime',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'imageMime',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'imageMime',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'imageMime', value: ''),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  imageMimeIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'imageMime', value: ''),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  ocrTextEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'ocrText',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  ocrTextGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'ocrText',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  ocrTextLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'ocrText',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  ocrTextBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'ocrText',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  ocrTextStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'ocrText',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  ocrTextEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'ocrText',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  ocrTextContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'ocrText',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  ocrTextMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'ocrText',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  ocrTextIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'ocrText', value: ''),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  ocrTextIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'ocrText', value: ''),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  pathEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'path',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  pathGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'path',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  pathLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'path',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  pathBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'path',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  pathStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'path',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  pathEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'path',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  pathContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'path',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  pathMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'path',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  pathIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'path', value: ''),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  pathIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'path', value: ''),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  rotationEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'rotation',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  rotationGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'rotation',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  rotationLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'rotation',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  rotationBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'rotation',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  uidEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  uidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  uidLessThan(String value, {bool include = false, bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  uidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'uid',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  uidStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  uidEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  uidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  uidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'uid',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  uidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'uid', value: ''),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  uidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'uid', value: ''),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  widthEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'width',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  widthGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'width',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  widthLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'width',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<ImageBlockEntity, ImageBlockEntity, QAfterFilterCondition>
  widthBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'width',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }
}

extension ImageBlockEntityQueryObject
    on QueryBuilder<ImageBlockEntity, ImageBlockEntity, QFilterCondition> {}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

const InkStrokeEntitySchema = Schema(
  name: r'InkStrokeEntity',
  id: -3118898537458629589,
  properties: {
    r'colorValue': PropertySchema(
      id: 0,
      name: r'colorValue',
      type: IsarType.long,
    ),
    r'points': PropertySchema(
      id: 1,
      name: r'points',
      type: IsarType.objectList,
      target: r'InkPointEntity',
    ),
    r'toolIndex': PropertySchema(
      id: 2,
      name: r'toolIndex',
      type: IsarType.long,
    ),
    r'uid': PropertySchema(id: 3, name: r'uid', type: IsarType.string),
    r'width': PropertySchema(id: 4, name: r'width', type: IsarType.double),
  },
  estimateSize: _inkStrokeEntityEstimateSize,
  serialize: _inkStrokeEntitySerialize,
  deserialize: _inkStrokeEntityDeserialize,
  deserializeProp: _inkStrokeEntityDeserializeProp,
);

int _inkStrokeEntityEstimateSize(
  InkStrokeEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.points.length * 3;
  {
    final offsets = allOffsets[InkPointEntity]!;
    for (var i = 0; i < object.points.length; i++) {
      final value = object.points[i];
      bytesCount += InkPointEntitySchema.estimateSize(
        value,
        offsets,
        allOffsets,
      );
    }
  }
  bytesCount += 3 + object.uid.length * 3;
  return bytesCount;
}

void _inkStrokeEntitySerialize(
  InkStrokeEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLong(offsets[0], object.colorValue);
  writer.writeObjectList<InkPointEntity>(
    offsets[1],
    allOffsets,
    InkPointEntitySchema.serialize,
    object.points,
  );
  writer.writeLong(offsets[2], object.toolIndex);
  writer.writeString(offsets[3], object.uid);
  writer.writeDouble(offsets[4], object.width);
}

InkStrokeEntity _inkStrokeEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = InkStrokeEntity();
  object.colorValue = reader.readLong(offsets[0]);
  object.points =
      reader.readObjectList<InkPointEntity>(
        offsets[1],
        InkPointEntitySchema.deserialize,
        allOffsets,
        InkPointEntity(),
      ) ??
      [];
  object.toolIndex = reader.readLong(offsets[2]);
  object.uid = reader.readString(offsets[3]);
  object.width = reader.readDouble(offsets[4]);
  return object;
}

P _inkStrokeEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readLong(offset)) as P;
    case 1:
      return (reader.readObjectList<InkPointEntity>(
                offset,
                InkPointEntitySchema.deserialize,
                allOffsets,
                InkPointEntity(),
              ) ??
              [])
          as P;
    case 2:
      return (reader.readLong(offset)) as P;
    case 3:
      return (reader.readString(offset)) as P;
    case 4:
      return (reader.readDouble(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

extension InkStrokeEntityQueryFilter
    on QueryBuilder<InkStrokeEntity, InkStrokeEntity, QFilterCondition> {
  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  colorValueEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'colorValue', value: value),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  colorValueGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'colorValue',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  colorValueLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'colorValue',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  colorValueBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'colorValue',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  pointsLengthEqualTo(int length) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'points', length, true, length, true);
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  pointsIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'points', 0, true, 0, true);
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  pointsIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'points', 0, false, 999999, true);
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  pointsLengthLessThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'points', 0, true, length, include);
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  pointsLengthGreaterThan(int length, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(r'points', length, include, 999999, true);
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  pointsLengthBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'points',
        lower,
        includeLower,
        upper,
        includeUpper,
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  toolIndexEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'toolIndex', value: value),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  toolIndexGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'toolIndex',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  toolIndexLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'toolIndex',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  toolIndexBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'toolIndex',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  uidEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  uidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  uidLessThan(String value, {bool include = false, bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  uidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'uid',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  uidStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  uidEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  uidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'uid',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  uidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'uid',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  uidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'uid', value: ''),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  uidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'uid', value: ''),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  widthEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'width',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  widthGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'width',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  widthLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'width',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  widthBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'width',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }
}

extension InkStrokeEntityQueryObject
    on QueryBuilder<InkStrokeEntity, InkStrokeEntity, QFilterCondition> {
  QueryBuilder<InkStrokeEntity, InkStrokeEntity, QAfterFilterCondition>
  pointsElement(FilterQuery<InkPointEntity> q) {
    return QueryBuilder.apply(this, (query) {
      return query.object(q, r'points');
    });
  }
}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

const InkPointEntitySchema = Schema(
  name: r'InkPointEntity',
  id: -2068597980036642517,
  properties: {
    r'dx': PropertySchema(id: 0, name: r'dx', type: IsarType.double),
    r'dy': PropertySchema(id: 1, name: r'dy', type: IsarType.double),
    r'pressure': PropertySchema(
      id: 2,
      name: r'pressure',
      type: IsarType.double,
    ),
  },
  estimateSize: _inkPointEntityEstimateSize,
  serialize: _inkPointEntitySerialize,
  deserialize: _inkPointEntityDeserialize,
  deserializeProp: _inkPointEntityDeserializeProp,
);

int _inkPointEntityEstimateSize(
  InkPointEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  return bytesCount;
}

void _inkPointEntitySerialize(
  InkPointEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeDouble(offsets[0], object.dx);
  writer.writeDouble(offsets[1], object.dy);
  writer.writeDouble(offsets[2], object.pressure);
}

InkPointEntity _inkPointEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = InkPointEntity();
  object.dx = reader.readDouble(offsets[0]);
  object.dy = reader.readDouble(offsets[1]);
  object.pressure = reader.readDouble(offsets[2]);
  return object;
}

P _inkPointEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readDouble(offset)) as P;
    case 1:
      return (reader.readDouble(offset)) as P;
    case 2:
      return (reader.readDouble(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

extension InkPointEntityQueryFilter
    on QueryBuilder<InkPointEntity, InkPointEntity, QFilterCondition> {
  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition> dxEqualTo(
    double value, {
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'dx',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition>
  dxGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'dx',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition>
  dxLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'dx',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition> dxBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'dx',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition> dyEqualTo(
    double value, {
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'dy',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition>
  dyGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'dy',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition>
  dyLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'dy',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition> dyBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'dy',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition>
  pressureEqualTo(double value, {double epsilon = Query.epsilon}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'pressure',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition>
  pressureGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'pressure',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition>
  pressureLessThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'pressure',
          value: value,
          epsilon: epsilon,
        ),
      );
    });
  }

  QueryBuilder<InkPointEntity, InkPointEntity, QAfterFilterCondition>
  pressureBetween(
    double lower,
    double upper, {
    bool includeLower = true,
    bool includeUpper = true,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'pressure',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          epsilon: epsilon,
        ),
      );
    });
  }
}

extension InkPointEntityQueryObject
    on QueryBuilder<InkPointEntity, InkPointEntity, QFilterCondition> {}
