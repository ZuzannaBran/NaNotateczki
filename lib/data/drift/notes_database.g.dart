// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'notes_database.dart';

// ignore_for_file: type=lint
class $NotebookRowsTable extends NotebookRows
    with TableInfo<$NotebookRowsTable, NotebookRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotebookRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
    'uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindIndexMeta = const VerificationMeta(
    'kindIndex',
  );
  @override
  late final GeneratedColumn<int> kindIndex = GeneratedColumn<int>(
    'kind_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _folderMeta = const VerificationMeta('folder');
  @override
  late final GeneratedColumn<String> folder = GeneratedColumn<String>(
    'folder',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    uid,
    title,
    kindIndex,
    folder,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'notebook_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<NotebookRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('kind_index')) {
      context.handle(
        _kindIndexMeta,
        kindIndex.isAcceptableOrUnknown(data['kind_index']!, _kindIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_kindIndexMeta);
    }
    if (data.containsKey('folder')) {
      context.handle(
        _folderMeta,
        folder.isAcceptableOrUnknown(data['folder']!, _folderMeta),
      );
    } else if (isInserting) {
      context.missing(_folderMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uid};
  @override
  NotebookRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return NotebookRow(
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uid'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      kindIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}kind_index'],
      )!,
      folder: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}folder'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $NotebookRowsTable createAlias(String alias) {
    return $NotebookRowsTable(attachedDatabase, alias);
  }
}

class NotebookRow extends DataClass implements Insertable<NotebookRow> {
  final String uid;
  final String title;
  final int kindIndex;
  final String folder;
  final DateTime createdAt;
  final DateTime updatedAt;
  const NotebookRow({
    required this.uid,
    required this.title,
    required this.kindIndex,
    required this.folder,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['uid'] = Variable<String>(uid);
    map['title'] = Variable<String>(title);
    map['kind_index'] = Variable<int>(kindIndex);
    map['folder'] = Variable<String>(folder);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  NotebookRowsCompanion toCompanion(bool nullToAbsent) {
    return NotebookRowsCompanion(
      uid: Value(uid),
      title: Value(title),
      kindIndex: Value(kindIndex),
      folder: Value(folder),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory NotebookRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NotebookRow(
      uid: serializer.fromJson<String>(json['uid']),
      title: serializer.fromJson<String>(json['title']),
      kindIndex: serializer.fromJson<int>(json['kindIndex']),
      folder: serializer.fromJson<String>(json['folder']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'uid': serializer.toJson<String>(uid),
      'title': serializer.toJson<String>(title),
      'kindIndex': serializer.toJson<int>(kindIndex),
      'folder': serializer.toJson<String>(folder),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  NotebookRow copyWith({
    String? uid,
    String? title,
    int? kindIndex,
    String? folder,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => NotebookRow(
    uid: uid ?? this.uid,
    title: title ?? this.title,
    kindIndex: kindIndex ?? this.kindIndex,
    folder: folder ?? this.folder,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  NotebookRow copyWithCompanion(NotebookRowsCompanion data) {
    return NotebookRow(
      uid: data.uid.present ? data.uid.value : this.uid,
      title: data.title.present ? data.title.value : this.title,
      kindIndex: data.kindIndex.present ? data.kindIndex.value : this.kindIndex,
      folder: data.folder.present ? data.folder.value : this.folder,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NotebookRow(')
          ..write('uid: $uid, ')
          ..write('title: $title, ')
          ..write('kindIndex: $kindIndex, ')
          ..write('folder: $folder, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(uid, title, kindIndex, folder, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NotebookRow &&
          other.uid == this.uid &&
          other.title == this.title &&
          other.kindIndex == this.kindIndex &&
          other.folder == this.folder &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class NotebookRowsCompanion extends UpdateCompanion<NotebookRow> {
  final Value<String> uid;
  final Value<String> title;
  final Value<int> kindIndex;
  final Value<String> folder;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const NotebookRowsCompanion({
    this.uid = const Value.absent(),
    this.title = const Value.absent(),
    this.kindIndex = const Value.absent(),
    this.folder = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotebookRowsCompanion.insert({
    required String uid,
    required String title,
    required int kindIndex,
    required String folder,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : uid = Value(uid),
       title = Value(title),
       kindIndex = Value(kindIndex),
       folder = Value(folder),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<NotebookRow> custom({
    Expression<String>? uid,
    Expression<String>? title,
    Expression<int>? kindIndex,
    Expression<String>? folder,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (uid != null) 'uid': uid,
      if (title != null) 'title': title,
      if (kindIndex != null) 'kind_index': kindIndex,
      if (folder != null) 'folder': folder,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotebookRowsCompanion copyWith({
    Value<String>? uid,
    Value<String>? title,
    Value<int>? kindIndex,
    Value<String>? folder,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return NotebookRowsCompanion(
      uid: uid ?? this.uid,
      title: title ?? this.title,
      kindIndex: kindIndex ?? this.kindIndex,
      folder: folder ?? this.folder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (kindIndex.present) {
      map['kind_index'] = Variable<int>(kindIndex.value);
    }
    if (folder.present) {
      map['folder'] = Variable<String>(folder.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NotebookRowsCompanion(')
          ..write('uid: $uid, ')
          ..write('title: $title, ')
          ..write('kindIndex: $kindIndex, ')
          ..write('folder: $folder, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PageRowsTable extends PageRows with TableInfo<$PageRowsTable, PageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PageRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
    'uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _notebookUidMeta = const VerificationMeta(
    'notebookUid',
  );
  @override
  late final GeneratedColumn<String> notebookUid = GeneratedColumn<String>(
    'notebook_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES notebook_rows (uid)',
    ),
  );
  static const VerificationMeta _pageIndexMeta = const VerificationMeta(
    'pageIndex',
  );
  @override
  late final GeneratedColumn<int> pageIndex = GeneratedColumn<int>(
    'page_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isBookmarkedMeta = const VerificationMeta(
    'isBookmarked',
  );
  @override
  late final GeneratedColumn<bool> isBookmarked = GeneratedColumn<bool>(
    'is_bookmarked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_bookmarked" IN (0, 1))',
    ),
  );
  static const VerificationMeta _legacyIndexTabColorValueMeta =
      const VerificationMeta('legacyIndexTabColorValue');
  @override
  late final GeneratedColumn<int> legacyIndexTabColorValue =
      GeneratedColumn<int>(
        'legacy_index_tab_color_value',
        aliasedName,
        true,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _legacyIndexTabPositionMeta =
      const VerificationMeta('legacyIndexTabPosition');
  @override
  late final GeneratedColumn<double> legacyIndexTabPosition =
      GeneratedColumn<double>(
        'legacy_index_tab_position',
        aliasedName,
        true,
        type: DriftSqlType.double,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    uid,
    notebookUid,
    pageIndex,
    title,
    isBookmarked,
    legacyIndexTabColorValue,
    legacyIndexTabPosition,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'page_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<PageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('notebook_uid')) {
      context.handle(
        _notebookUidMeta,
        notebookUid.isAcceptableOrUnknown(
          data['notebook_uid']!,
          _notebookUidMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_notebookUidMeta);
    }
    if (data.containsKey('page_index')) {
      context.handle(
        _pageIndexMeta,
        pageIndex.isAcceptableOrUnknown(data['page_index']!, _pageIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_pageIndexMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('is_bookmarked')) {
      context.handle(
        _isBookmarkedMeta,
        isBookmarked.isAcceptableOrUnknown(
          data['is_bookmarked']!,
          _isBookmarkedMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_isBookmarkedMeta);
    }
    if (data.containsKey('legacy_index_tab_color_value')) {
      context.handle(
        _legacyIndexTabColorValueMeta,
        legacyIndexTabColorValue.isAcceptableOrUnknown(
          data['legacy_index_tab_color_value']!,
          _legacyIndexTabColorValueMeta,
        ),
      );
    }
    if (data.containsKey('legacy_index_tab_position')) {
      context.handle(
        _legacyIndexTabPositionMeta,
        legacyIndexTabPosition.isAcceptableOrUnknown(
          data['legacy_index_tab_position']!,
          _legacyIndexTabPositionMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uid};
  @override
  PageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PageRow(
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uid'],
      )!,
      notebookUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notebook_uid'],
      )!,
      pageIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_index'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      isBookmarked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_bookmarked'],
      )!,
      legacyIndexTabColorValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}legacy_index_tab_color_value'],
      ),
      legacyIndexTabPosition: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}legacy_index_tab_position'],
      ),
    );
  }

  @override
  $PageRowsTable createAlias(String alias) {
    return $PageRowsTable(attachedDatabase, alias);
  }
}

class PageRow extends DataClass implements Insertable<PageRow> {
  final String uid;
  final String notebookUid;
  final int pageIndex;
  final String title;
  final bool isBookmarked;
  final int? legacyIndexTabColorValue;
  final double? legacyIndexTabPosition;
  const PageRow({
    required this.uid,
    required this.notebookUid,
    required this.pageIndex,
    required this.title,
    required this.isBookmarked,
    this.legacyIndexTabColorValue,
    this.legacyIndexTabPosition,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['uid'] = Variable<String>(uid);
    map['notebook_uid'] = Variable<String>(notebookUid);
    map['page_index'] = Variable<int>(pageIndex);
    map['title'] = Variable<String>(title);
    map['is_bookmarked'] = Variable<bool>(isBookmarked);
    if (!nullToAbsent || legacyIndexTabColorValue != null) {
      map['legacy_index_tab_color_value'] = Variable<int>(
        legacyIndexTabColorValue,
      );
    }
    if (!nullToAbsent || legacyIndexTabPosition != null) {
      map['legacy_index_tab_position'] = Variable<double>(
        legacyIndexTabPosition,
      );
    }
    return map;
  }

  PageRowsCompanion toCompanion(bool nullToAbsent) {
    return PageRowsCompanion(
      uid: Value(uid),
      notebookUid: Value(notebookUid),
      pageIndex: Value(pageIndex),
      title: Value(title),
      isBookmarked: Value(isBookmarked),
      legacyIndexTabColorValue: legacyIndexTabColorValue == null && nullToAbsent
          ? const Value.absent()
          : Value(legacyIndexTabColorValue),
      legacyIndexTabPosition: legacyIndexTabPosition == null && nullToAbsent
          ? const Value.absent()
          : Value(legacyIndexTabPosition),
    );
  }

  factory PageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PageRow(
      uid: serializer.fromJson<String>(json['uid']),
      notebookUid: serializer.fromJson<String>(json['notebookUid']),
      pageIndex: serializer.fromJson<int>(json['pageIndex']),
      title: serializer.fromJson<String>(json['title']),
      isBookmarked: serializer.fromJson<bool>(json['isBookmarked']),
      legacyIndexTabColorValue: serializer.fromJson<int?>(
        json['legacyIndexTabColorValue'],
      ),
      legacyIndexTabPosition: serializer.fromJson<double?>(
        json['legacyIndexTabPosition'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'uid': serializer.toJson<String>(uid),
      'notebookUid': serializer.toJson<String>(notebookUid),
      'pageIndex': serializer.toJson<int>(pageIndex),
      'title': serializer.toJson<String>(title),
      'isBookmarked': serializer.toJson<bool>(isBookmarked),
      'legacyIndexTabColorValue': serializer.toJson<int?>(
        legacyIndexTabColorValue,
      ),
      'legacyIndexTabPosition': serializer.toJson<double?>(
        legacyIndexTabPosition,
      ),
    };
  }

  PageRow copyWith({
    String? uid,
    String? notebookUid,
    int? pageIndex,
    String? title,
    bool? isBookmarked,
    Value<int?> legacyIndexTabColorValue = const Value.absent(),
    Value<double?> legacyIndexTabPosition = const Value.absent(),
  }) => PageRow(
    uid: uid ?? this.uid,
    notebookUid: notebookUid ?? this.notebookUid,
    pageIndex: pageIndex ?? this.pageIndex,
    title: title ?? this.title,
    isBookmarked: isBookmarked ?? this.isBookmarked,
    legacyIndexTabColorValue: legacyIndexTabColorValue.present
        ? legacyIndexTabColorValue.value
        : this.legacyIndexTabColorValue,
    legacyIndexTabPosition: legacyIndexTabPosition.present
        ? legacyIndexTabPosition.value
        : this.legacyIndexTabPosition,
  );
  PageRow copyWithCompanion(PageRowsCompanion data) {
    return PageRow(
      uid: data.uid.present ? data.uid.value : this.uid,
      notebookUid: data.notebookUid.present
          ? data.notebookUid.value
          : this.notebookUid,
      pageIndex: data.pageIndex.present ? data.pageIndex.value : this.pageIndex,
      title: data.title.present ? data.title.value : this.title,
      isBookmarked: data.isBookmarked.present
          ? data.isBookmarked.value
          : this.isBookmarked,
      legacyIndexTabColorValue: data.legacyIndexTabColorValue.present
          ? data.legacyIndexTabColorValue.value
          : this.legacyIndexTabColorValue,
      legacyIndexTabPosition: data.legacyIndexTabPosition.present
          ? data.legacyIndexTabPosition.value
          : this.legacyIndexTabPosition,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PageRow(')
          ..write('uid: $uid, ')
          ..write('notebookUid: $notebookUid, ')
          ..write('pageIndex: $pageIndex, ')
          ..write('title: $title, ')
          ..write('isBookmarked: $isBookmarked, ')
          ..write('legacyIndexTabColorValue: $legacyIndexTabColorValue, ')
          ..write('legacyIndexTabPosition: $legacyIndexTabPosition')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    uid,
    notebookUid,
    pageIndex,
    title,
    isBookmarked,
    legacyIndexTabColorValue,
    legacyIndexTabPosition,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PageRow &&
          other.uid == this.uid &&
          other.notebookUid == this.notebookUid &&
          other.pageIndex == this.pageIndex &&
          other.title == this.title &&
          other.isBookmarked == this.isBookmarked &&
          other.legacyIndexTabColorValue == this.legacyIndexTabColorValue &&
          other.legacyIndexTabPosition == this.legacyIndexTabPosition);
}

class PageRowsCompanion extends UpdateCompanion<PageRow> {
  final Value<String> uid;
  final Value<String> notebookUid;
  final Value<int> pageIndex;
  final Value<String> title;
  final Value<bool> isBookmarked;
  final Value<int?> legacyIndexTabColorValue;
  final Value<double?> legacyIndexTabPosition;
  final Value<int> rowid;
  const PageRowsCompanion({
    this.uid = const Value.absent(),
    this.notebookUid = const Value.absent(),
    this.pageIndex = const Value.absent(),
    this.title = const Value.absent(),
    this.isBookmarked = const Value.absent(),
    this.legacyIndexTabColorValue = const Value.absent(),
    this.legacyIndexTabPosition = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PageRowsCompanion.insert({
    required String uid,
    required String notebookUid,
    required int pageIndex,
    required String title,
    required bool isBookmarked,
    this.legacyIndexTabColorValue = const Value.absent(),
    this.legacyIndexTabPosition = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : uid = Value(uid),
       notebookUid = Value(notebookUid),
       pageIndex = Value(pageIndex),
       title = Value(title),
       isBookmarked = Value(isBookmarked);
  static Insertable<PageRow> custom({
    Expression<String>? uid,
    Expression<String>? notebookUid,
    Expression<int>? pageIndex,
    Expression<String>? title,
    Expression<bool>? isBookmarked,
    Expression<int>? legacyIndexTabColorValue,
    Expression<double>? legacyIndexTabPosition,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (uid != null) 'uid': uid,
      if (notebookUid != null) 'notebook_uid': notebookUid,
      if (pageIndex != null) 'page_index': pageIndex,
      if (title != null) 'title': title,
      if (isBookmarked != null) 'is_bookmarked': isBookmarked,
      if (legacyIndexTabColorValue != null)
        'legacy_index_tab_color_value': legacyIndexTabColorValue,
      if (legacyIndexTabPosition != null)
        'legacy_index_tab_position': legacyIndexTabPosition,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PageRowsCompanion copyWith({
    Value<String>? uid,
    Value<String>? notebookUid,
    Value<int>? pageIndex,
    Value<String>? title,
    Value<bool>? isBookmarked,
    Value<int?>? legacyIndexTabColorValue,
    Value<double?>? legacyIndexTabPosition,
    Value<int>? rowid,
  }) {
    return PageRowsCompanion(
      uid: uid ?? this.uid,
      notebookUid: notebookUid ?? this.notebookUid,
      pageIndex: pageIndex ?? this.pageIndex,
      title: title ?? this.title,
      isBookmarked: isBookmarked ?? this.isBookmarked,
      legacyIndexTabColorValue:
          legacyIndexTabColorValue ?? this.legacyIndexTabColorValue,
      legacyIndexTabPosition:
          legacyIndexTabPosition ?? this.legacyIndexTabPosition,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (notebookUid.present) {
      map['notebook_uid'] = Variable<String>(notebookUid.value);
    }
    if (pageIndex.present) {
      map['page_index'] = Variable<int>(pageIndex.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (isBookmarked.present) {
      map['is_bookmarked'] = Variable<bool>(isBookmarked.value);
    }
    if (legacyIndexTabColorValue.present) {
      map['legacy_index_tab_color_value'] = Variable<int>(
        legacyIndexTabColorValue.value,
      );
    }
    if (legacyIndexTabPosition.present) {
      map['legacy_index_tab_position'] = Variable<double>(
        legacyIndexTabPosition.value,
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PageRowsCompanion(')
          ..write('uid: $uid, ')
          ..write('notebookUid: $notebookUid, ')
          ..write('pageIndex: $pageIndex, ')
          ..write('title: $title, ')
          ..write('isBookmarked: $isBookmarked, ')
          ..write('legacyIndexTabColorValue: $legacyIndexTabColorValue, ')
          ..write('legacyIndexTabPosition: $legacyIndexTabPosition, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $IndexTabRowsTable extends IndexTabRows
    with TableInfo<$IndexTabRowsTable, IndexTabRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $IndexTabRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
    'uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageUidMeta = const VerificationMeta(
    'pageUid',
  );
  @override
  late final GeneratedColumn<String> pageUid = GeneratedColumn<String>(
    'page_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES page_rows (uid)',
    ),
  );
  static const VerificationMeta _colorValueMeta = const VerificationMeta(
    'colorValue',
  );
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
    'color_value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<double> position = GeneratedColumn<double>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [uid, pageUid, colorValue, position];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'index_tab_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<IndexTabRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('page_uid')) {
      context.handle(
        _pageUidMeta,
        pageUid.isAcceptableOrUnknown(data['page_uid']!, _pageUidMeta),
      );
    } else if (isInserting) {
      context.missing(_pageUidMeta);
    }
    if (data.containsKey('color_value')) {
      context.handle(
        _colorValueMeta,
        colorValue.isAcceptableOrUnknown(data['color_value']!, _colorValueMeta),
      );
    } else if (isInserting) {
      context.missing(_colorValueMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uid};
  @override
  IndexTabRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return IndexTabRow(
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uid'],
      )!,
      pageUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}page_uid'],
      )!,
      colorValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_value'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}position'],
      )!,
    );
  }

  @override
  $IndexTabRowsTable createAlias(String alias) {
    return $IndexTabRowsTable(attachedDatabase, alias);
  }
}

class IndexTabRow extends DataClass implements Insertable<IndexTabRow> {
  final String uid;
  final String pageUid;
  final int colorValue;
  final double position;
  const IndexTabRow({
    required this.uid,
    required this.pageUid,
    required this.colorValue,
    required this.position,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['uid'] = Variable<String>(uid);
    map['page_uid'] = Variable<String>(pageUid);
    map['color_value'] = Variable<int>(colorValue);
    map['position'] = Variable<double>(position);
    return map;
  }

  IndexTabRowsCompanion toCompanion(bool nullToAbsent) {
    return IndexTabRowsCompanion(
      uid: Value(uid),
      pageUid: Value(pageUid),
      colorValue: Value(colorValue),
      position: Value(position),
    );
  }

  factory IndexTabRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return IndexTabRow(
      uid: serializer.fromJson<String>(json['uid']),
      pageUid: serializer.fromJson<String>(json['pageUid']),
      colorValue: serializer.fromJson<int>(json['colorValue']),
      position: serializer.fromJson<double>(json['position']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'uid': serializer.toJson<String>(uid),
      'pageUid': serializer.toJson<String>(pageUid),
      'colorValue': serializer.toJson<int>(colorValue),
      'position': serializer.toJson<double>(position),
    };
  }

  IndexTabRow copyWith({
    String? uid,
    String? pageUid,
    int? colorValue,
    double? position,
  }) => IndexTabRow(
    uid: uid ?? this.uid,
    pageUid: pageUid ?? this.pageUid,
    colorValue: colorValue ?? this.colorValue,
    position: position ?? this.position,
  );
  IndexTabRow copyWithCompanion(IndexTabRowsCompanion data) {
    return IndexTabRow(
      uid: data.uid.present ? data.uid.value : this.uid,
      pageUid: data.pageUid.present ? data.pageUid.value : this.pageUid,
      colorValue: data.colorValue.present
          ? data.colorValue.value
          : this.colorValue,
      position: data.position.present ? data.position.value : this.position,
    );
  }

  @override
  String toString() {
    return (StringBuffer('IndexTabRow(')
          ..write('uid: $uid, ')
          ..write('pageUid: $pageUid, ')
          ..write('colorValue: $colorValue, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(uid, pageUid, colorValue, position);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is IndexTabRow &&
          other.uid == this.uid &&
          other.pageUid == this.pageUid &&
          other.colorValue == this.colorValue &&
          other.position == this.position);
}

class IndexTabRowsCompanion extends UpdateCompanion<IndexTabRow> {
  final Value<String> uid;
  final Value<String> pageUid;
  final Value<int> colorValue;
  final Value<double> position;
  final Value<int> rowid;
  const IndexTabRowsCompanion({
    this.uid = const Value.absent(),
    this.pageUid = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.position = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  IndexTabRowsCompanion.insert({
    required String uid,
    required String pageUid,
    required int colorValue,
    required double position,
    this.rowid = const Value.absent(),
  }) : uid = Value(uid),
       pageUid = Value(pageUid),
       colorValue = Value(colorValue),
       position = Value(position);
  static Insertable<IndexTabRow> custom({
    Expression<String>? uid,
    Expression<String>? pageUid,
    Expression<int>? colorValue,
    Expression<double>? position,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (uid != null) 'uid': uid,
      if (pageUid != null) 'page_uid': pageUid,
      if (colorValue != null) 'color_value': colorValue,
      if (position != null) 'position': position,
      if (rowid != null) 'rowid': rowid,
    });
  }

  IndexTabRowsCompanion copyWith({
    Value<String>? uid,
    Value<String>? pageUid,
    Value<int>? colorValue,
    Value<double>? position,
    Value<int>? rowid,
  }) {
    return IndexTabRowsCompanion(
      uid: uid ?? this.uid,
      pageUid: pageUid ?? this.pageUid,
      colorValue: colorValue ?? this.colorValue,
      position: position ?? this.position,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (pageUid.present) {
      map['page_uid'] = Variable<String>(pageUid.value);
    }
    if (colorValue.present) {
      map['color_value'] = Variable<int>(colorValue.value);
    }
    if (position.present) {
      map['position'] = Variable<double>(position.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('IndexTabRowsCompanion(')
          ..write('uid: $uid, ')
          ..write('pageUid: $pageUid, ')
          ..write('colorValue: $colorValue, ')
          ..write('position: $position, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TextBlockRowsTable extends TextBlockRows
    with TableInfo<$TextBlockRowsTable, TextBlockRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TextBlockRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
    'uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageUidMeta = const VerificationMeta(
    'pageUid',
  );
  @override
  late final GeneratedColumn<String> pageUid = GeneratedColumn<String>(
    'page_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES page_rows (uid)',
    ),
  );
  static const VerificationMeta _plainTextMeta = const VerificationMeta(
    'plainText',
  );
  @override
  late final GeneratedColumn<String> plainText = GeneratedColumn<String>(
    'text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deltaJsonMeta = const VerificationMeta(
    'deltaJson',
  );
  @override
  late final GeneratedColumn<String> deltaJson = GeneratedColumn<String>(
    'delta_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fontSizeMeta = const VerificationMeta(
    'fontSize',
  );
  @override
  late final GeneratedColumn<double> fontSize = GeneratedColumn<double>(
    'font_size',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _colorValueMeta = const VerificationMeta(
    'colorValue',
  );
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
    'color_value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<double> width = GeneratedColumn<double>(
    'width',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rotationMeta = const VerificationMeta(
    'rotation',
  );
  @override
  late final GeneratedColumn<double> rotation = GeneratedColumn<double>(
    'rotation',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dxMeta = const VerificationMeta('dx');
  @override
  late final GeneratedColumn<double> dx = GeneratedColumn<double>(
    'dx',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dyMeta = const VerificationMeta('dy');
  @override
  late final GeneratedColumn<double> dy = GeneratedColumn<double>(
    'dy',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortIndexMeta = const VerificationMeta(
    'sortIndex',
  );
  @override
  late final GeneratedColumn<int> sortIndex = GeneratedColumn<int>(
    'sort_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    uid,
    pageUid,
    plainText,
    deltaJson,
    fontSize,
    colorValue,
    width,
    rotation,
    dx,
    dy,
    sortIndex,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'text_block_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<TextBlockRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('page_uid')) {
      context.handle(
        _pageUidMeta,
        pageUid.isAcceptableOrUnknown(data['page_uid']!, _pageUidMeta),
      );
    } else if (isInserting) {
      context.missing(_pageUidMeta);
    }
    if (data.containsKey('text')) {
      context.handle(
        _plainTextMeta,
        plainText.isAcceptableOrUnknown(data['text']!, _plainTextMeta),
      );
    } else if (isInserting) {
      context.missing(_plainTextMeta);
    }
    if (data.containsKey('delta_json')) {
      context.handle(
        _deltaJsonMeta,
        deltaJson.isAcceptableOrUnknown(data['delta_json']!, _deltaJsonMeta),
      );
    }
    if (data.containsKey('font_size')) {
      context.handle(
        _fontSizeMeta,
        fontSize.isAcceptableOrUnknown(data['font_size']!, _fontSizeMeta),
      );
    } else if (isInserting) {
      context.missing(_fontSizeMeta);
    }
    if (data.containsKey('color_value')) {
      context.handle(
        _colorValueMeta,
        colorValue.isAcceptableOrUnknown(data['color_value']!, _colorValueMeta),
      );
    } else if (isInserting) {
      context.missing(_colorValueMeta);
    }
    if (data.containsKey('width')) {
      context.handle(
        _widthMeta,
        width.isAcceptableOrUnknown(data['width']!, _widthMeta),
      );
    } else if (isInserting) {
      context.missing(_widthMeta);
    }
    if (data.containsKey('rotation')) {
      context.handle(
        _rotationMeta,
        rotation.isAcceptableOrUnknown(data['rotation']!, _rotationMeta),
      );
    } else if (isInserting) {
      context.missing(_rotationMeta);
    }
    if (data.containsKey('dx')) {
      context.handle(_dxMeta, dx.isAcceptableOrUnknown(data['dx']!, _dxMeta));
    } else if (isInserting) {
      context.missing(_dxMeta);
    }
    if (data.containsKey('dy')) {
      context.handle(_dyMeta, dy.isAcceptableOrUnknown(data['dy']!, _dyMeta));
    } else if (isInserting) {
      context.missing(_dyMeta);
    }
    if (data.containsKey('sort_index')) {
      context.handle(
        _sortIndexMeta,
        sortIndex.isAcceptableOrUnknown(data['sort_index']!, _sortIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_sortIndexMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uid};
  @override
  TextBlockRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TextBlockRow(
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uid'],
      )!,
      pageUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}page_uid'],
      )!,
      plainText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}text'],
      )!,
      deltaJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}delta_json'],
      ),
      fontSize: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}font_size'],
      )!,
      colorValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_value'],
      )!,
      width: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}width'],
      )!,
      rotation: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}rotation'],
      )!,
      dx: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}dx'],
      )!,
      dy: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}dy'],
      )!,
      sortIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_index'],
      )!,
    );
  }

  @override
  $TextBlockRowsTable createAlias(String alias) {
    return $TextBlockRowsTable(attachedDatabase, alias);
  }
}

class TextBlockRow extends DataClass implements Insertable<TextBlockRow> {
  final String uid;
  final String pageUid;
  final String plainText;
  final String? deltaJson;
  final double fontSize;
  final int colorValue;
  final double width;
  final double rotation;
  final double dx;
  final double dy;
  final int sortIndex;
  const TextBlockRow({
    required this.uid,
    required this.pageUid,
    required this.plainText,
    this.deltaJson,
    required this.fontSize,
    required this.colorValue,
    required this.width,
    required this.rotation,
    required this.dx,
    required this.dy,
    required this.sortIndex,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['uid'] = Variable<String>(uid);
    map['page_uid'] = Variable<String>(pageUid);
    map['text'] = Variable<String>(plainText);
    if (!nullToAbsent || deltaJson != null) {
      map['delta_json'] = Variable<String>(deltaJson);
    }
    map['font_size'] = Variable<double>(fontSize);
    map['color_value'] = Variable<int>(colorValue);
    map['width'] = Variable<double>(width);
    map['rotation'] = Variable<double>(rotation);
    map['dx'] = Variable<double>(dx);
    map['dy'] = Variable<double>(dy);
    map['sort_index'] = Variable<int>(sortIndex);
    return map;
  }

  TextBlockRowsCompanion toCompanion(bool nullToAbsent) {
    return TextBlockRowsCompanion(
      uid: Value(uid),
      pageUid: Value(pageUid),
      plainText: Value(plainText),
      deltaJson: deltaJson == null && nullToAbsent
          ? const Value.absent()
          : Value(deltaJson),
      fontSize: Value(fontSize),
      colorValue: Value(colorValue),
      width: Value(width),
      rotation: Value(rotation),
      dx: Value(dx),
      dy: Value(dy),
      sortIndex: Value(sortIndex),
    );
  }

  factory TextBlockRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TextBlockRow(
      uid: serializer.fromJson<String>(json['uid']),
      pageUid: serializer.fromJson<String>(json['pageUid']),
      plainText: serializer.fromJson<String>(json['plainText']),
      deltaJson: serializer.fromJson<String?>(json['deltaJson']),
      fontSize: serializer.fromJson<double>(json['fontSize']),
      colorValue: serializer.fromJson<int>(json['colorValue']),
      width: serializer.fromJson<double>(json['width']),
      rotation: serializer.fromJson<double>(json['rotation']),
      dx: serializer.fromJson<double>(json['dx']),
      dy: serializer.fromJson<double>(json['dy']),
      sortIndex: serializer.fromJson<int>(json['sortIndex']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'uid': serializer.toJson<String>(uid),
      'pageUid': serializer.toJson<String>(pageUid),
      'plainText': serializer.toJson<String>(plainText),
      'deltaJson': serializer.toJson<String?>(deltaJson),
      'fontSize': serializer.toJson<double>(fontSize),
      'colorValue': serializer.toJson<int>(colorValue),
      'width': serializer.toJson<double>(width),
      'rotation': serializer.toJson<double>(rotation),
      'dx': serializer.toJson<double>(dx),
      'dy': serializer.toJson<double>(dy),
      'sortIndex': serializer.toJson<int>(sortIndex),
    };
  }

  TextBlockRow copyWith({
    String? uid,
    String? pageUid,
    String? plainText,
    Value<String?> deltaJson = const Value.absent(),
    double? fontSize,
    int? colorValue,
    double? width,
    double? rotation,
    double? dx,
    double? dy,
    int? sortIndex,
  }) => TextBlockRow(
    uid: uid ?? this.uid,
    pageUid: pageUid ?? this.pageUid,
    plainText: plainText ?? this.plainText,
    deltaJson: deltaJson.present ? deltaJson.value : this.deltaJson,
    fontSize: fontSize ?? this.fontSize,
    colorValue: colorValue ?? this.colorValue,
    width: width ?? this.width,
    rotation: rotation ?? this.rotation,
    dx: dx ?? this.dx,
    dy: dy ?? this.dy,
    sortIndex: sortIndex ?? this.sortIndex,
  );
  TextBlockRow copyWithCompanion(TextBlockRowsCompanion data) {
    return TextBlockRow(
      uid: data.uid.present ? data.uid.value : this.uid,
      pageUid: data.pageUid.present ? data.pageUid.value : this.pageUid,
      plainText: data.plainText.present ? data.plainText.value : this.plainText,
      deltaJson: data.deltaJson.present ? data.deltaJson.value : this.deltaJson,
      fontSize: data.fontSize.present ? data.fontSize.value : this.fontSize,
      colorValue: data.colorValue.present
          ? data.colorValue.value
          : this.colorValue,
      width: data.width.present ? data.width.value : this.width,
      rotation: data.rotation.present ? data.rotation.value : this.rotation,
      dx: data.dx.present ? data.dx.value : this.dx,
      dy: data.dy.present ? data.dy.value : this.dy,
      sortIndex: data.sortIndex.present ? data.sortIndex.value : this.sortIndex,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TextBlockRow(')
          ..write('uid: $uid, ')
          ..write('pageUid: $pageUid, ')
          ..write('plainText: $plainText, ')
          ..write('deltaJson: $deltaJson, ')
          ..write('fontSize: $fontSize, ')
          ..write('colorValue: $colorValue, ')
          ..write('width: $width, ')
          ..write('rotation: $rotation, ')
          ..write('dx: $dx, ')
          ..write('dy: $dy, ')
          ..write('sortIndex: $sortIndex')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    uid,
    pageUid,
    plainText,
    deltaJson,
    fontSize,
    colorValue,
    width,
    rotation,
    dx,
    dy,
    sortIndex,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TextBlockRow &&
          other.uid == this.uid &&
          other.pageUid == this.pageUid &&
          other.plainText == this.plainText &&
          other.deltaJson == this.deltaJson &&
          other.fontSize == this.fontSize &&
          other.colorValue == this.colorValue &&
          other.width == this.width &&
          other.rotation == this.rotation &&
          other.dx == this.dx &&
          other.dy == this.dy &&
          other.sortIndex == this.sortIndex);
}

class TextBlockRowsCompanion extends UpdateCompanion<TextBlockRow> {
  final Value<String> uid;
  final Value<String> pageUid;
  final Value<String> plainText;
  final Value<String?> deltaJson;
  final Value<double> fontSize;
  final Value<int> colorValue;
  final Value<double> width;
  final Value<double> rotation;
  final Value<double> dx;
  final Value<double> dy;
  final Value<int> sortIndex;
  final Value<int> rowid;
  const TextBlockRowsCompanion({
    this.uid = const Value.absent(),
    this.pageUid = const Value.absent(),
    this.plainText = const Value.absent(),
    this.deltaJson = const Value.absent(),
    this.fontSize = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.width = const Value.absent(),
    this.rotation = const Value.absent(),
    this.dx = const Value.absent(),
    this.dy = const Value.absent(),
    this.sortIndex = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TextBlockRowsCompanion.insert({
    required String uid,
    required String pageUid,
    required String plainText,
    this.deltaJson = const Value.absent(),
    required double fontSize,
    required int colorValue,
    required double width,
    required double rotation,
    required double dx,
    required double dy,
    required int sortIndex,
    this.rowid = const Value.absent(),
  }) : uid = Value(uid),
       pageUid = Value(pageUid),
       plainText = Value(plainText),
       fontSize = Value(fontSize),
       colorValue = Value(colorValue),
       width = Value(width),
       rotation = Value(rotation),
       dx = Value(dx),
       dy = Value(dy),
       sortIndex = Value(sortIndex);
  static Insertable<TextBlockRow> custom({
    Expression<String>? uid,
    Expression<String>? pageUid,
    Expression<String>? plainText,
    Expression<String>? deltaJson,
    Expression<double>? fontSize,
    Expression<int>? colorValue,
    Expression<double>? width,
    Expression<double>? rotation,
    Expression<double>? dx,
    Expression<double>? dy,
    Expression<int>? sortIndex,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (uid != null) 'uid': uid,
      if (pageUid != null) 'page_uid': pageUid,
      if (plainText != null) 'text': plainText,
      if (deltaJson != null) 'delta_json': deltaJson,
      if (fontSize != null) 'font_size': fontSize,
      if (colorValue != null) 'color_value': colorValue,
      if (width != null) 'width': width,
      if (rotation != null) 'rotation': rotation,
      if (dx != null) 'dx': dx,
      if (dy != null) 'dy': dy,
      if (sortIndex != null) 'sort_index': sortIndex,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TextBlockRowsCompanion copyWith({
    Value<String>? uid,
    Value<String>? pageUid,
    Value<String>? plainText,
    Value<String?>? deltaJson,
    Value<double>? fontSize,
    Value<int>? colorValue,
    Value<double>? width,
    Value<double>? rotation,
    Value<double>? dx,
    Value<double>? dy,
    Value<int>? sortIndex,
    Value<int>? rowid,
  }) {
    return TextBlockRowsCompanion(
      uid: uid ?? this.uid,
      pageUid: pageUid ?? this.pageUid,
      plainText: plainText ?? this.plainText,
      deltaJson: deltaJson ?? this.deltaJson,
      fontSize: fontSize ?? this.fontSize,
      colorValue: colorValue ?? this.colorValue,
      width: width ?? this.width,
      rotation: rotation ?? this.rotation,
      dx: dx ?? this.dx,
      dy: dy ?? this.dy,
      sortIndex: sortIndex ?? this.sortIndex,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (pageUid.present) {
      map['page_uid'] = Variable<String>(pageUid.value);
    }
    if (plainText.present) {
      map['text'] = Variable<String>(plainText.value);
    }
    if (deltaJson.present) {
      map['delta_json'] = Variable<String>(deltaJson.value);
    }
    if (fontSize.present) {
      map['font_size'] = Variable<double>(fontSize.value);
    }
    if (colorValue.present) {
      map['color_value'] = Variable<int>(colorValue.value);
    }
    if (width.present) {
      map['width'] = Variable<double>(width.value);
    }
    if (rotation.present) {
      map['rotation'] = Variable<double>(rotation.value);
    }
    if (dx.present) {
      map['dx'] = Variable<double>(dx.value);
    }
    if (dy.present) {
      map['dy'] = Variable<double>(dy.value);
    }
    if (sortIndex.present) {
      map['sort_index'] = Variable<int>(sortIndex.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TextBlockRowsCompanion(')
          ..write('uid: $uid, ')
          ..write('pageUid: $pageUid, ')
          ..write('plainText: $plainText, ')
          ..write('deltaJson: $deltaJson, ')
          ..write('fontSize: $fontSize, ')
          ..write('colorValue: $colorValue, ')
          ..write('width: $width, ')
          ..write('rotation: $rotation, ')
          ..write('dx: $dx, ')
          ..write('dy: $dy, ')
          ..write('sortIndex: $sortIndex, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ImageBlockRowsTable extends ImageBlockRows
    with TableInfo<$ImageBlockRowsTable, ImageBlockRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ImageBlockRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
    'uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageUidMeta = const VerificationMeta(
    'pageUid',
  );
  @override
  late final GeneratedColumn<String> pageUid = GeneratedColumn<String>(
    'page_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES page_rows (uid)',
    ),
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ocrTextMeta = const VerificationMeta(
    'ocrText',
  );
  @override
  late final GeneratedColumn<String> ocrText = GeneratedColumn<String>(
    'ocr_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<Uint8List> bytes = GeneratedColumn<Uint8List>(
    'bytes',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _imageExtMeta = const VerificationMeta(
    'imageExt',
  );
  @override
  late final GeneratedColumn<String> imageExt = GeneratedColumn<String>(
    'image_ext',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _imageMimeMeta = const VerificationMeta(
    'imageMime',
  );
  @override
  late final GeneratedColumn<String> imageMime = GeneratedColumn<String>(
    'image_mime',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<double> width = GeneratedColumn<double>(
    'width',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _heightMeta = const VerificationMeta('height');
  @override
  late final GeneratedColumn<double> height = GeneratedColumn<double>(
    'height',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rotationMeta = const VerificationMeta(
    'rotation',
  );
  @override
  late final GeneratedColumn<double> rotation = GeneratedColumn<double>(
    'rotation',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dxMeta = const VerificationMeta('dx');
  @override
  late final GeneratedColumn<double> dx = GeneratedColumn<double>(
    'dx',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dyMeta = const VerificationMeta('dy');
  @override
  late final GeneratedColumn<double> dy = GeneratedColumn<double>(
    'dy',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cropLeftMeta = const VerificationMeta(
    'cropLeft',
  );
  @override
  late final GeneratedColumn<double> cropLeft = GeneratedColumn<double>(
    'crop_left',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cropTopMeta = const VerificationMeta(
    'cropTop',
  );
  @override
  late final GeneratedColumn<double> cropTop = GeneratedColumn<double>(
    'crop_top',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cropRightMeta = const VerificationMeta(
    'cropRight',
  );
  @override
  late final GeneratedColumn<double> cropRight = GeneratedColumn<double>(
    'crop_right',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cropBottomMeta = const VerificationMeta(
    'cropBottom',
  );
  @override
  late final GeneratedColumn<double> cropBottom = GeneratedColumn<double>(
    'crop_bottom',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortIndexMeta = const VerificationMeta(
    'sortIndex',
  );
  @override
  late final GeneratedColumn<int> sortIndex = GeneratedColumn<int>(
    'sort_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    uid,
    pageUid,
    path,
    ocrText,
    bytes,
    imageExt,
    imageMime,
    width,
    height,
    rotation,
    dx,
    dy,
    cropLeft,
    cropTop,
    cropRight,
    cropBottom,
    sortIndex,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'image_block_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<ImageBlockRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('page_uid')) {
      context.handle(
        _pageUidMeta,
        pageUid.isAcceptableOrUnknown(data['page_uid']!, _pageUidMeta),
      );
    } else if (isInserting) {
      context.missing(_pageUidMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('ocr_text')) {
      context.handle(
        _ocrTextMeta,
        ocrText.isAcceptableOrUnknown(data['ocr_text']!, _ocrTextMeta),
      );
    } else if (isInserting) {
      context.missing(_ocrTextMeta);
    }
    if (data.containsKey('bytes')) {
      context.handle(
        _bytesMeta,
        bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta),
      );
    }
    if (data.containsKey('image_ext')) {
      context.handle(
        _imageExtMeta,
        imageExt.isAcceptableOrUnknown(data['image_ext']!, _imageExtMeta),
      );
    }
    if (data.containsKey('image_mime')) {
      context.handle(
        _imageMimeMeta,
        imageMime.isAcceptableOrUnknown(data['image_mime']!, _imageMimeMeta),
      );
    }
    if (data.containsKey('width')) {
      context.handle(
        _widthMeta,
        width.isAcceptableOrUnknown(data['width']!, _widthMeta),
      );
    } else if (isInserting) {
      context.missing(_widthMeta);
    }
    if (data.containsKey('height')) {
      context.handle(
        _heightMeta,
        height.isAcceptableOrUnknown(data['height']!, _heightMeta),
      );
    } else if (isInserting) {
      context.missing(_heightMeta);
    }
    if (data.containsKey('rotation')) {
      context.handle(
        _rotationMeta,
        rotation.isAcceptableOrUnknown(data['rotation']!, _rotationMeta),
      );
    } else if (isInserting) {
      context.missing(_rotationMeta);
    }
    if (data.containsKey('dx')) {
      context.handle(_dxMeta, dx.isAcceptableOrUnknown(data['dx']!, _dxMeta));
    } else if (isInserting) {
      context.missing(_dxMeta);
    }
    if (data.containsKey('dy')) {
      context.handle(_dyMeta, dy.isAcceptableOrUnknown(data['dy']!, _dyMeta));
    } else if (isInserting) {
      context.missing(_dyMeta);
    }
    if (data.containsKey('crop_left')) {
      context.handle(
        _cropLeftMeta,
        cropLeft.isAcceptableOrUnknown(data['crop_left']!, _cropLeftMeta),
      );
    } else if (isInserting) {
      context.missing(_cropLeftMeta);
    }
    if (data.containsKey('crop_top')) {
      context.handle(
        _cropTopMeta,
        cropTop.isAcceptableOrUnknown(data['crop_top']!, _cropTopMeta),
      );
    } else if (isInserting) {
      context.missing(_cropTopMeta);
    }
    if (data.containsKey('crop_right')) {
      context.handle(
        _cropRightMeta,
        cropRight.isAcceptableOrUnknown(data['crop_right']!, _cropRightMeta),
      );
    } else if (isInserting) {
      context.missing(_cropRightMeta);
    }
    if (data.containsKey('crop_bottom')) {
      context.handle(
        _cropBottomMeta,
        cropBottom.isAcceptableOrUnknown(data['crop_bottom']!, _cropBottomMeta),
      );
    } else if (isInserting) {
      context.missing(_cropBottomMeta);
    }
    if (data.containsKey('sort_index')) {
      context.handle(
        _sortIndexMeta,
        sortIndex.isAcceptableOrUnknown(data['sort_index']!, _sortIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_sortIndexMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uid};
  @override
  ImageBlockRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ImageBlockRow(
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uid'],
      )!,
      pageUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}page_uid'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      ocrText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ocr_text'],
      )!,
      bytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}bytes'],
      ),
      imageExt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}image_ext'],
      ),
      imageMime: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}image_mime'],
      ),
      width: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}width'],
      )!,
      height: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}height'],
      )!,
      rotation: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}rotation'],
      )!,
      dx: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}dx'],
      )!,
      dy: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}dy'],
      )!,
      cropLeft: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}crop_left'],
      )!,
      cropTop: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}crop_top'],
      )!,
      cropRight: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}crop_right'],
      )!,
      cropBottom: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}crop_bottom'],
      )!,
      sortIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_index'],
      )!,
    );
  }

  @override
  $ImageBlockRowsTable createAlias(String alias) {
    return $ImageBlockRowsTable(attachedDatabase, alias);
  }
}

class ImageBlockRow extends DataClass implements Insertable<ImageBlockRow> {
  final String uid;
  final String pageUid;
  final String path;
  final String ocrText;
  final Uint8List? bytes;
  final String? imageExt;
  final String? imageMime;
  final double width;
  final double height;
  final double rotation;
  final double dx;
  final double dy;
  final double cropLeft;
  final double cropTop;
  final double cropRight;
  final double cropBottom;
  final int sortIndex;
  const ImageBlockRow({
    required this.uid,
    required this.pageUid,
    required this.path,
    required this.ocrText,
    this.bytes,
    this.imageExt,
    this.imageMime,
    required this.width,
    required this.height,
    required this.rotation,
    required this.dx,
    required this.dy,
    required this.cropLeft,
    required this.cropTop,
    required this.cropRight,
    required this.cropBottom,
    required this.sortIndex,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['uid'] = Variable<String>(uid);
    map['page_uid'] = Variable<String>(pageUid);
    map['path'] = Variable<String>(path);
    map['ocr_text'] = Variable<String>(ocrText);
    if (!nullToAbsent || bytes != null) {
      map['bytes'] = Variable<Uint8List>(bytes);
    }
    if (!nullToAbsent || imageExt != null) {
      map['image_ext'] = Variable<String>(imageExt);
    }
    if (!nullToAbsent || imageMime != null) {
      map['image_mime'] = Variable<String>(imageMime);
    }
    map['width'] = Variable<double>(width);
    map['height'] = Variable<double>(height);
    map['rotation'] = Variable<double>(rotation);
    map['dx'] = Variable<double>(dx);
    map['dy'] = Variable<double>(dy);
    map['crop_left'] = Variable<double>(cropLeft);
    map['crop_top'] = Variable<double>(cropTop);
    map['crop_right'] = Variable<double>(cropRight);
    map['crop_bottom'] = Variable<double>(cropBottom);
    map['sort_index'] = Variable<int>(sortIndex);
    return map;
  }

  ImageBlockRowsCompanion toCompanion(bool nullToAbsent) {
    return ImageBlockRowsCompanion(
      uid: Value(uid),
      pageUid: Value(pageUid),
      path: Value(path),
      ocrText: Value(ocrText),
      bytes: bytes == null && nullToAbsent
          ? const Value.absent()
          : Value(bytes),
      imageExt: imageExt == null && nullToAbsent
          ? const Value.absent()
          : Value(imageExt),
      imageMime: imageMime == null && nullToAbsent
          ? const Value.absent()
          : Value(imageMime),
      width: Value(width),
      height: Value(height),
      rotation: Value(rotation),
      dx: Value(dx),
      dy: Value(dy),
      cropLeft: Value(cropLeft),
      cropTop: Value(cropTop),
      cropRight: Value(cropRight),
      cropBottom: Value(cropBottom),
      sortIndex: Value(sortIndex),
    );
  }

  factory ImageBlockRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ImageBlockRow(
      uid: serializer.fromJson<String>(json['uid']),
      pageUid: serializer.fromJson<String>(json['pageUid']),
      path: serializer.fromJson<String>(json['path']),
      ocrText: serializer.fromJson<String>(json['ocrText']),
      bytes: serializer.fromJson<Uint8List?>(json['bytes']),
      imageExt: serializer.fromJson<String?>(json['imageExt']),
      imageMime: serializer.fromJson<String?>(json['imageMime']),
      width: serializer.fromJson<double>(json['width']),
      height: serializer.fromJson<double>(json['height']),
      rotation: serializer.fromJson<double>(json['rotation']),
      dx: serializer.fromJson<double>(json['dx']),
      dy: serializer.fromJson<double>(json['dy']),
      cropLeft: serializer.fromJson<double>(json['cropLeft']),
      cropTop: serializer.fromJson<double>(json['cropTop']),
      cropRight: serializer.fromJson<double>(json['cropRight']),
      cropBottom: serializer.fromJson<double>(json['cropBottom']),
      sortIndex: serializer.fromJson<int>(json['sortIndex']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'uid': serializer.toJson<String>(uid),
      'pageUid': serializer.toJson<String>(pageUid),
      'path': serializer.toJson<String>(path),
      'ocrText': serializer.toJson<String>(ocrText),
      'bytes': serializer.toJson<Uint8List?>(bytes),
      'imageExt': serializer.toJson<String?>(imageExt),
      'imageMime': serializer.toJson<String?>(imageMime),
      'width': serializer.toJson<double>(width),
      'height': serializer.toJson<double>(height),
      'rotation': serializer.toJson<double>(rotation),
      'dx': serializer.toJson<double>(dx),
      'dy': serializer.toJson<double>(dy),
      'cropLeft': serializer.toJson<double>(cropLeft),
      'cropTop': serializer.toJson<double>(cropTop),
      'cropRight': serializer.toJson<double>(cropRight),
      'cropBottom': serializer.toJson<double>(cropBottom),
      'sortIndex': serializer.toJson<int>(sortIndex),
    };
  }

  ImageBlockRow copyWith({
    String? uid,
    String? pageUid,
    String? path,
    String? ocrText,
    Value<Uint8List?> bytes = const Value.absent(),
    Value<String?> imageExt = const Value.absent(),
    Value<String?> imageMime = const Value.absent(),
    double? width,
    double? height,
    double? rotation,
    double? dx,
    double? dy,
    double? cropLeft,
    double? cropTop,
    double? cropRight,
    double? cropBottom,
    int? sortIndex,
  }) => ImageBlockRow(
    uid: uid ?? this.uid,
    pageUid: pageUid ?? this.pageUid,
    path: path ?? this.path,
    ocrText: ocrText ?? this.ocrText,
    bytes: bytes.present ? bytes.value : this.bytes,
    imageExt: imageExt.present ? imageExt.value : this.imageExt,
    imageMime: imageMime.present ? imageMime.value : this.imageMime,
    width: width ?? this.width,
    height: height ?? this.height,
    rotation: rotation ?? this.rotation,
    dx: dx ?? this.dx,
    dy: dy ?? this.dy,
    cropLeft: cropLeft ?? this.cropLeft,
    cropTop: cropTop ?? this.cropTop,
    cropRight: cropRight ?? this.cropRight,
    cropBottom: cropBottom ?? this.cropBottom,
    sortIndex: sortIndex ?? this.sortIndex,
  );
  ImageBlockRow copyWithCompanion(ImageBlockRowsCompanion data) {
    return ImageBlockRow(
      uid: data.uid.present ? data.uid.value : this.uid,
      pageUid: data.pageUid.present ? data.pageUid.value : this.pageUid,
      path: data.path.present ? data.path.value : this.path,
      ocrText: data.ocrText.present ? data.ocrText.value : this.ocrText,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      imageExt: data.imageExt.present ? data.imageExt.value : this.imageExt,
      imageMime: data.imageMime.present ? data.imageMime.value : this.imageMime,
      width: data.width.present ? data.width.value : this.width,
      height: data.height.present ? data.height.value : this.height,
      rotation: data.rotation.present ? data.rotation.value : this.rotation,
      dx: data.dx.present ? data.dx.value : this.dx,
      dy: data.dy.present ? data.dy.value : this.dy,
      cropLeft: data.cropLeft.present ? data.cropLeft.value : this.cropLeft,
      cropTop: data.cropTop.present ? data.cropTop.value : this.cropTop,
      cropRight: data.cropRight.present ? data.cropRight.value : this.cropRight,
      cropBottom: data.cropBottom.present
          ? data.cropBottom.value
          : this.cropBottom,
      sortIndex: data.sortIndex.present ? data.sortIndex.value : this.sortIndex,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ImageBlockRow(')
          ..write('uid: $uid, ')
          ..write('pageUid: $pageUid, ')
          ..write('path: $path, ')
          ..write('ocrText: $ocrText, ')
          ..write('bytes: $bytes, ')
          ..write('imageExt: $imageExt, ')
          ..write('imageMime: $imageMime, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('rotation: $rotation, ')
          ..write('dx: $dx, ')
          ..write('dy: $dy, ')
          ..write('cropLeft: $cropLeft, ')
          ..write('cropTop: $cropTop, ')
          ..write('cropRight: $cropRight, ')
          ..write('cropBottom: $cropBottom, ')
          ..write('sortIndex: $sortIndex')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    uid,
    pageUid,
    path,
    ocrText,
    $driftBlobEquality.hash(bytes),
    imageExt,
    imageMime,
    width,
    height,
    rotation,
    dx,
    dy,
    cropLeft,
    cropTop,
    cropRight,
    cropBottom,
    sortIndex,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ImageBlockRow &&
          other.uid == this.uid &&
          other.pageUid == this.pageUid &&
          other.path == this.path &&
          other.ocrText == this.ocrText &&
          $driftBlobEquality.equals(other.bytes, this.bytes) &&
          other.imageExt == this.imageExt &&
          other.imageMime == this.imageMime &&
          other.width == this.width &&
          other.height == this.height &&
          other.rotation == this.rotation &&
          other.dx == this.dx &&
          other.dy == this.dy &&
          other.cropLeft == this.cropLeft &&
          other.cropTop == this.cropTop &&
          other.cropRight == this.cropRight &&
          other.cropBottom == this.cropBottom &&
          other.sortIndex == this.sortIndex);
}

class ImageBlockRowsCompanion extends UpdateCompanion<ImageBlockRow> {
  final Value<String> uid;
  final Value<String> pageUid;
  final Value<String> path;
  final Value<String> ocrText;
  final Value<Uint8List?> bytes;
  final Value<String?> imageExt;
  final Value<String?> imageMime;
  final Value<double> width;
  final Value<double> height;
  final Value<double> rotation;
  final Value<double> dx;
  final Value<double> dy;
  final Value<double> cropLeft;
  final Value<double> cropTop;
  final Value<double> cropRight;
  final Value<double> cropBottom;
  final Value<int> sortIndex;
  final Value<int> rowid;
  const ImageBlockRowsCompanion({
    this.uid = const Value.absent(),
    this.pageUid = const Value.absent(),
    this.path = const Value.absent(),
    this.ocrText = const Value.absent(),
    this.bytes = const Value.absent(),
    this.imageExt = const Value.absent(),
    this.imageMime = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.rotation = const Value.absent(),
    this.dx = const Value.absent(),
    this.dy = const Value.absent(),
    this.cropLeft = const Value.absent(),
    this.cropTop = const Value.absent(),
    this.cropRight = const Value.absent(),
    this.cropBottom = const Value.absent(),
    this.sortIndex = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ImageBlockRowsCompanion.insert({
    required String uid,
    required String pageUid,
    required String path,
    required String ocrText,
    this.bytes = const Value.absent(),
    this.imageExt = const Value.absent(),
    this.imageMime = const Value.absent(),
    required double width,
    required double height,
    required double rotation,
    required double dx,
    required double dy,
    required double cropLeft,
    required double cropTop,
    required double cropRight,
    required double cropBottom,
    required int sortIndex,
    this.rowid = const Value.absent(),
  }) : uid = Value(uid),
       pageUid = Value(pageUid),
       path = Value(path),
       ocrText = Value(ocrText),
       width = Value(width),
       height = Value(height),
       rotation = Value(rotation),
       dx = Value(dx),
       dy = Value(dy),
       cropLeft = Value(cropLeft),
       cropTop = Value(cropTop),
       cropRight = Value(cropRight),
       cropBottom = Value(cropBottom),
       sortIndex = Value(sortIndex);
  static Insertable<ImageBlockRow> custom({
    Expression<String>? uid,
    Expression<String>? pageUid,
    Expression<String>? path,
    Expression<String>? ocrText,
    Expression<Uint8List>? bytes,
    Expression<String>? imageExt,
    Expression<String>? imageMime,
    Expression<double>? width,
    Expression<double>? height,
    Expression<double>? rotation,
    Expression<double>? dx,
    Expression<double>? dy,
    Expression<double>? cropLeft,
    Expression<double>? cropTop,
    Expression<double>? cropRight,
    Expression<double>? cropBottom,
    Expression<int>? sortIndex,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (uid != null) 'uid': uid,
      if (pageUid != null) 'page_uid': pageUid,
      if (path != null) 'path': path,
      if (ocrText != null) 'ocr_text': ocrText,
      if (bytes != null) 'bytes': bytes,
      if (imageExt != null) 'image_ext': imageExt,
      if (imageMime != null) 'image_mime': imageMime,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (rotation != null) 'rotation': rotation,
      if (dx != null) 'dx': dx,
      if (dy != null) 'dy': dy,
      if (cropLeft != null) 'crop_left': cropLeft,
      if (cropTop != null) 'crop_top': cropTop,
      if (cropRight != null) 'crop_right': cropRight,
      if (cropBottom != null) 'crop_bottom': cropBottom,
      if (sortIndex != null) 'sort_index': sortIndex,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ImageBlockRowsCompanion copyWith({
    Value<String>? uid,
    Value<String>? pageUid,
    Value<String>? path,
    Value<String>? ocrText,
    Value<Uint8List?>? bytes,
    Value<String?>? imageExt,
    Value<String?>? imageMime,
    Value<double>? width,
    Value<double>? height,
    Value<double>? rotation,
    Value<double>? dx,
    Value<double>? dy,
    Value<double>? cropLeft,
    Value<double>? cropTop,
    Value<double>? cropRight,
    Value<double>? cropBottom,
    Value<int>? sortIndex,
    Value<int>? rowid,
  }) {
    return ImageBlockRowsCompanion(
      uid: uid ?? this.uid,
      pageUid: pageUid ?? this.pageUid,
      path: path ?? this.path,
      ocrText: ocrText ?? this.ocrText,
      bytes: bytes ?? this.bytes,
      imageExt: imageExt ?? this.imageExt,
      imageMime: imageMime ?? this.imageMime,
      width: width ?? this.width,
      height: height ?? this.height,
      rotation: rotation ?? this.rotation,
      dx: dx ?? this.dx,
      dy: dy ?? this.dy,
      cropLeft: cropLeft ?? this.cropLeft,
      cropTop: cropTop ?? this.cropTop,
      cropRight: cropRight ?? this.cropRight,
      cropBottom: cropBottom ?? this.cropBottom,
      sortIndex: sortIndex ?? this.sortIndex,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (pageUid.present) {
      map['page_uid'] = Variable<String>(pageUid.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (ocrText.present) {
      map['ocr_text'] = Variable<String>(ocrText.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<Uint8List>(bytes.value);
    }
    if (imageExt.present) {
      map['image_ext'] = Variable<String>(imageExt.value);
    }
    if (imageMime.present) {
      map['image_mime'] = Variable<String>(imageMime.value);
    }
    if (width.present) {
      map['width'] = Variable<double>(width.value);
    }
    if (height.present) {
      map['height'] = Variable<double>(height.value);
    }
    if (rotation.present) {
      map['rotation'] = Variable<double>(rotation.value);
    }
    if (dx.present) {
      map['dx'] = Variable<double>(dx.value);
    }
    if (dy.present) {
      map['dy'] = Variable<double>(dy.value);
    }
    if (cropLeft.present) {
      map['crop_left'] = Variable<double>(cropLeft.value);
    }
    if (cropTop.present) {
      map['crop_top'] = Variable<double>(cropTop.value);
    }
    if (cropRight.present) {
      map['crop_right'] = Variable<double>(cropRight.value);
    }
    if (cropBottom.present) {
      map['crop_bottom'] = Variable<double>(cropBottom.value);
    }
    if (sortIndex.present) {
      map['sort_index'] = Variable<int>(sortIndex.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ImageBlockRowsCompanion(')
          ..write('uid: $uid, ')
          ..write('pageUid: $pageUid, ')
          ..write('path: $path, ')
          ..write('ocrText: $ocrText, ')
          ..write('bytes: $bytes, ')
          ..write('imageExt: $imageExt, ')
          ..write('imageMime: $imageMime, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('rotation: $rotation, ')
          ..write('dx: $dx, ')
          ..write('dy: $dy, ')
          ..write('cropLeft: $cropLeft, ')
          ..write('cropTop: $cropTop, ')
          ..write('cropRight: $cropRight, ')
          ..write('cropBottom: $cropBottom, ')
          ..write('sortIndex: $sortIndex, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $InkStrokeRowsTable extends InkStrokeRows
    with TableInfo<$InkStrokeRowsTable, InkStrokeRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $InkStrokeRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
    'uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageUidMeta = const VerificationMeta(
    'pageUid',
  );
  @override
  late final GeneratedColumn<String> pageUid = GeneratedColumn<String>(
    'page_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES page_rows (uid)',
    ),
  );
  static const VerificationMeta _colorValueMeta = const VerificationMeta(
    'colorValue',
  );
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
    'color_value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<double> width = GeneratedColumn<double>(
    'width',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _toolIndexMeta = const VerificationMeta(
    'toolIndex',
  );
  @override
  late final GeneratedColumn<int> toolIndex = GeneratedColumn<int>(
    'tool_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pointsJsonMeta = const VerificationMeta(
    'pointsJson',
  );
  @override
  late final GeneratedColumn<String> pointsJson = GeneratedColumn<String>(
    'points_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortIndexMeta = const VerificationMeta(
    'sortIndex',
  );
  @override
  late final GeneratedColumn<int> sortIndex = GeneratedColumn<int>(
    'sort_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    uid,
    pageUid,
    colorValue,
    width,
    toolIndex,
    pointsJson,
    sortIndex,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ink_stroke_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<InkStrokeRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('page_uid')) {
      context.handle(
        _pageUidMeta,
        pageUid.isAcceptableOrUnknown(data['page_uid']!, _pageUidMeta),
      );
    } else if (isInserting) {
      context.missing(_pageUidMeta);
    }
    if (data.containsKey('color_value')) {
      context.handle(
        _colorValueMeta,
        colorValue.isAcceptableOrUnknown(data['color_value']!, _colorValueMeta),
      );
    } else if (isInserting) {
      context.missing(_colorValueMeta);
    }
    if (data.containsKey('width')) {
      context.handle(
        _widthMeta,
        width.isAcceptableOrUnknown(data['width']!, _widthMeta),
      );
    } else if (isInserting) {
      context.missing(_widthMeta);
    }
    if (data.containsKey('tool_index')) {
      context.handle(
        _toolIndexMeta,
        toolIndex.isAcceptableOrUnknown(data['tool_index']!, _toolIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_toolIndexMeta);
    }
    if (data.containsKey('points_json')) {
      context.handle(
        _pointsJsonMeta,
        pointsJson.isAcceptableOrUnknown(data['points_json']!, _pointsJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_pointsJsonMeta);
    }
    if (data.containsKey('sort_index')) {
      context.handle(
        _sortIndexMeta,
        sortIndex.isAcceptableOrUnknown(data['sort_index']!, _sortIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_sortIndexMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uid};
  @override
  InkStrokeRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return InkStrokeRow(
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uid'],
      )!,
      pageUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}page_uid'],
      )!,
      colorValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_value'],
      )!,
      width: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}width'],
      )!,
      toolIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tool_index'],
      )!,
      pointsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}points_json'],
      )!,
      sortIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_index'],
      )!,
    );
  }

  @override
  $InkStrokeRowsTable createAlias(String alias) {
    return $InkStrokeRowsTable(attachedDatabase, alias);
  }
}

class InkStrokeRow extends DataClass implements Insertable<InkStrokeRow> {
  final String uid;
  final String pageUid;
  final int colorValue;
  final double width;
  final int toolIndex;
  final String pointsJson;
  final int sortIndex;
  const InkStrokeRow({
    required this.uid,
    required this.pageUid,
    required this.colorValue,
    required this.width,
    required this.toolIndex,
    required this.pointsJson,
    required this.sortIndex,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['uid'] = Variable<String>(uid);
    map['page_uid'] = Variable<String>(pageUid);
    map['color_value'] = Variable<int>(colorValue);
    map['width'] = Variable<double>(width);
    map['tool_index'] = Variable<int>(toolIndex);
    map['points_json'] = Variable<String>(pointsJson);
    map['sort_index'] = Variable<int>(sortIndex);
    return map;
  }

  InkStrokeRowsCompanion toCompanion(bool nullToAbsent) {
    return InkStrokeRowsCompanion(
      uid: Value(uid),
      pageUid: Value(pageUid),
      colorValue: Value(colorValue),
      width: Value(width),
      toolIndex: Value(toolIndex),
      pointsJson: Value(pointsJson),
      sortIndex: Value(sortIndex),
    );
  }

  factory InkStrokeRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return InkStrokeRow(
      uid: serializer.fromJson<String>(json['uid']),
      pageUid: serializer.fromJson<String>(json['pageUid']),
      colorValue: serializer.fromJson<int>(json['colorValue']),
      width: serializer.fromJson<double>(json['width']),
      toolIndex: serializer.fromJson<int>(json['toolIndex']),
      pointsJson: serializer.fromJson<String>(json['pointsJson']),
      sortIndex: serializer.fromJson<int>(json['sortIndex']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'uid': serializer.toJson<String>(uid),
      'pageUid': serializer.toJson<String>(pageUid),
      'colorValue': serializer.toJson<int>(colorValue),
      'width': serializer.toJson<double>(width),
      'toolIndex': serializer.toJson<int>(toolIndex),
      'pointsJson': serializer.toJson<String>(pointsJson),
      'sortIndex': serializer.toJson<int>(sortIndex),
    };
  }

  InkStrokeRow copyWith({
    String? uid,
    String? pageUid,
    int? colorValue,
    double? width,
    int? toolIndex,
    String? pointsJson,
    int? sortIndex,
  }) => InkStrokeRow(
    uid: uid ?? this.uid,
    pageUid: pageUid ?? this.pageUid,
    colorValue: colorValue ?? this.colorValue,
    width: width ?? this.width,
    toolIndex: toolIndex ?? this.toolIndex,
    pointsJson: pointsJson ?? this.pointsJson,
    sortIndex: sortIndex ?? this.sortIndex,
  );
  InkStrokeRow copyWithCompanion(InkStrokeRowsCompanion data) {
    return InkStrokeRow(
      uid: data.uid.present ? data.uid.value : this.uid,
      pageUid: data.pageUid.present ? data.pageUid.value : this.pageUid,
      colorValue: data.colorValue.present
          ? data.colorValue.value
          : this.colorValue,
      width: data.width.present ? data.width.value : this.width,
      toolIndex: data.toolIndex.present ? data.toolIndex.value : this.toolIndex,
      pointsJson: data.pointsJson.present
          ? data.pointsJson.value
          : this.pointsJson,
      sortIndex: data.sortIndex.present ? data.sortIndex.value : this.sortIndex,
    );
  }

  @override
  String toString() {
    return (StringBuffer('InkStrokeRow(')
          ..write('uid: $uid, ')
          ..write('pageUid: $pageUid, ')
          ..write('colorValue: $colorValue, ')
          ..write('width: $width, ')
          ..write('toolIndex: $toolIndex, ')
          ..write('pointsJson: $pointsJson, ')
          ..write('sortIndex: $sortIndex')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    uid,
    pageUid,
    colorValue,
    width,
    toolIndex,
    pointsJson,
    sortIndex,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is InkStrokeRow &&
          other.uid == this.uid &&
          other.pageUid == this.pageUid &&
          other.colorValue == this.colorValue &&
          other.width == this.width &&
          other.toolIndex == this.toolIndex &&
          other.pointsJson == this.pointsJson &&
          other.sortIndex == this.sortIndex);
}

class InkStrokeRowsCompanion extends UpdateCompanion<InkStrokeRow> {
  final Value<String> uid;
  final Value<String> pageUid;
  final Value<int> colorValue;
  final Value<double> width;
  final Value<int> toolIndex;
  final Value<String> pointsJson;
  final Value<int> sortIndex;
  final Value<int> rowid;
  const InkStrokeRowsCompanion({
    this.uid = const Value.absent(),
    this.pageUid = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.width = const Value.absent(),
    this.toolIndex = const Value.absent(),
    this.pointsJson = const Value.absent(),
    this.sortIndex = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  InkStrokeRowsCompanion.insert({
    required String uid,
    required String pageUid,
    required int colorValue,
    required double width,
    required int toolIndex,
    required String pointsJson,
    required int sortIndex,
    this.rowid = const Value.absent(),
  }) : uid = Value(uid),
       pageUid = Value(pageUid),
       colorValue = Value(colorValue),
       width = Value(width),
       toolIndex = Value(toolIndex),
       pointsJson = Value(pointsJson),
       sortIndex = Value(sortIndex);
  static Insertable<InkStrokeRow> custom({
    Expression<String>? uid,
    Expression<String>? pageUid,
    Expression<int>? colorValue,
    Expression<double>? width,
    Expression<int>? toolIndex,
    Expression<String>? pointsJson,
    Expression<int>? sortIndex,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (uid != null) 'uid': uid,
      if (pageUid != null) 'page_uid': pageUid,
      if (colorValue != null) 'color_value': colorValue,
      if (width != null) 'width': width,
      if (toolIndex != null) 'tool_index': toolIndex,
      if (pointsJson != null) 'points_json': pointsJson,
      if (sortIndex != null) 'sort_index': sortIndex,
      if (rowid != null) 'rowid': rowid,
    });
  }

  InkStrokeRowsCompanion copyWith({
    Value<String>? uid,
    Value<String>? pageUid,
    Value<int>? colorValue,
    Value<double>? width,
    Value<int>? toolIndex,
    Value<String>? pointsJson,
    Value<int>? sortIndex,
    Value<int>? rowid,
  }) {
    return InkStrokeRowsCompanion(
      uid: uid ?? this.uid,
      pageUid: pageUid ?? this.pageUid,
      colorValue: colorValue ?? this.colorValue,
      width: width ?? this.width,
      toolIndex: toolIndex ?? this.toolIndex,
      pointsJson: pointsJson ?? this.pointsJson,
      sortIndex: sortIndex ?? this.sortIndex,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (pageUid.present) {
      map['page_uid'] = Variable<String>(pageUid.value);
    }
    if (colorValue.present) {
      map['color_value'] = Variable<int>(colorValue.value);
    }
    if (width.present) {
      map['width'] = Variable<double>(width.value);
    }
    if (toolIndex.present) {
      map['tool_index'] = Variable<int>(toolIndex.value);
    }
    if (pointsJson.present) {
      map['points_json'] = Variable<String>(pointsJson.value);
    }
    if (sortIndex.present) {
      map['sort_index'] = Variable<int>(sortIndex.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('InkStrokeRowsCompanion(')
          ..write('uid: $uid, ')
          ..write('pageUid: $pageUid, ')
          ..write('colorValue: $colorValue, ')
          ..write('width: $width, ')
          ..write('toolIndex: $toolIndex, ')
          ..write('pointsJson: $pointsJson, ')
          ..write('sortIndex: $sortIndex, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$NotesDatabase extends GeneratedDatabase {
  _$NotesDatabase(QueryExecutor e) : super(e);
  $NotesDatabaseManager get managers => $NotesDatabaseManager(this);
  late final $NotebookRowsTable notebookRows = $NotebookRowsTable(this);
  late final $PageRowsTable pageRows = $PageRowsTable(this);
  late final $IndexTabRowsTable indexTabRows = $IndexTabRowsTable(this);
  late final $TextBlockRowsTable textBlockRows = $TextBlockRowsTable(this);
  late final $ImageBlockRowsTable imageBlockRows = $ImageBlockRowsTable(this);
  late final $InkStrokeRowsTable inkStrokeRows = $InkStrokeRowsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    notebookRows,
    pageRows,
    indexTabRows,
    textBlockRows,
    imageBlockRows,
    inkStrokeRows,
  ];
}

typedef $$NotebookRowsTableCreateCompanionBuilder =
    NotebookRowsCompanion Function({
      required String uid,
      required String title,
      required int kindIndex,
      required String folder,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$NotebookRowsTableUpdateCompanionBuilder =
    NotebookRowsCompanion Function({
      Value<String> uid,
      Value<String> title,
      Value<int> kindIndex,
      Value<String> folder,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

final class $$NotebookRowsTableReferences
    extends BaseReferences<_$NotesDatabase, $NotebookRowsTable, NotebookRow> {
  $$NotebookRowsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$PageRowsTable, List<PageRow>> _pageRowsRefsTable(
    _$NotesDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.pageRows,
    aliasName: 'notebook_rows__uid__page_rows__notebook_uid',
  );

  $$PageRowsTableProcessedTableManager get pageRowsRefs {
    final manager = $$PageRowsTableTableManager(
      $_db,
      $_db.pageRows,
    ).filter((f) => f.notebookUid.uid.sqlEquals($_itemColumn<String>('uid')!));

    final cache = $_typedResult.readTableOrNull(_pageRowsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$NotebookRowsTableFilterComposer
    extends Composer<_$NotesDatabase, $NotebookRowsTable> {
  $$NotebookRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get kindIndex => $composableBuilder(
    column: $table.kindIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get folder => $composableBuilder(
    column: $table.folder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> pageRowsRefs(
    Expression<bool> Function($$PageRowsTableFilterComposer f) f,
  ) {
    final $$PageRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.uid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.notebookUid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableFilterComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$NotebookRowsTableOrderingComposer
    extends Composer<_$NotesDatabase, $NotebookRowsTable> {
  $$NotebookRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get kindIndex => $composableBuilder(
    column: $table.kindIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folder => $composableBuilder(
    column: $table.folder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NotebookRowsTableAnnotationComposer
    extends Composer<_$NotesDatabase, $NotebookRowsTable> {
  $$NotebookRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get kindIndex =>
      $composableBuilder(column: $table.kindIndex, builder: (column) => column);

  GeneratedColumn<String> get folder =>
      $composableBuilder(column: $table.folder, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  Expression<T> pageRowsRefs<T extends Object>(
    Expression<T> Function($$PageRowsTableAnnotationComposer a) f,
  ) {
    final $$PageRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.uid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.notebookUid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$NotebookRowsTableTableManager
    extends
        RootTableManager<
          _$NotesDatabase,
          $NotebookRowsTable,
          NotebookRow,
          $$NotebookRowsTableFilterComposer,
          $$NotebookRowsTableOrderingComposer,
          $$NotebookRowsTableAnnotationComposer,
          $$NotebookRowsTableCreateCompanionBuilder,
          $$NotebookRowsTableUpdateCompanionBuilder,
          (NotebookRow, $$NotebookRowsTableReferences),
          NotebookRow,
          PrefetchHooks Function({bool pageRowsRefs})
        > {
  $$NotebookRowsTableTableManager(_$NotesDatabase db, $NotebookRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotebookRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NotebookRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NotebookRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> uid = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<int> kindIndex = const Value.absent(),
                Value<String> folder = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotebookRowsCompanion(
                uid: uid,
                title: title,
                kindIndex: kindIndex,
                folder: folder,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String uid,
                required String title,
                required int kindIndex,
                required String folder,
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => NotebookRowsCompanion.insert(
                uid: uid,
                title: title,
                kindIndex: kindIndex,
                folder: folder,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$NotebookRowsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({pageRowsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (pageRowsRefs) db.pageRows],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (pageRowsRefs)
                    await $_getPrefetchedData<
                      NotebookRow,
                      $NotebookRowsTable,
                      PageRow
                    >(
                      currentTable: table,
                      referencedTable: $$NotebookRowsTableReferences
                          ._pageRowsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$NotebookRowsTableReferences(
                            db,
                            table,
                            p0,
                          ).pageRowsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where(
                            (e) => e.notebookUid == item.uid,
                          ),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$NotebookRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$NotesDatabase,
      $NotebookRowsTable,
      NotebookRow,
      $$NotebookRowsTableFilterComposer,
      $$NotebookRowsTableOrderingComposer,
      $$NotebookRowsTableAnnotationComposer,
      $$NotebookRowsTableCreateCompanionBuilder,
      $$NotebookRowsTableUpdateCompanionBuilder,
      (NotebookRow, $$NotebookRowsTableReferences),
      NotebookRow,
      PrefetchHooks Function({bool pageRowsRefs})
    >;
typedef $$PageRowsTableCreateCompanionBuilder =
    PageRowsCompanion Function({
      required String uid,
      required String notebookUid,
      required int pageIndex,
      required String title,
      required bool isBookmarked,
      Value<int?> legacyIndexTabColorValue,
      Value<double?> legacyIndexTabPosition,
      Value<int> rowid,
    });
typedef $$PageRowsTableUpdateCompanionBuilder =
    PageRowsCompanion Function({
      Value<String> uid,
      Value<String> notebookUid,
      Value<int> pageIndex,
      Value<String> title,
      Value<bool> isBookmarked,
      Value<int?> legacyIndexTabColorValue,
      Value<double?> legacyIndexTabPosition,
      Value<int> rowid,
    });

final class $$PageRowsTableReferences
    extends BaseReferences<_$NotesDatabase, $PageRowsTable, PageRow> {
  $$PageRowsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $NotebookRowsTable _notebookUidTable(_$NotesDatabase db) => db
      .notebookRows
      .createAlias('page_rows__notebook_uid__notebook_rows__uid');

  $$NotebookRowsTableProcessedTableManager get notebookUid {
    final $_column = $_itemColumn<String>('notebook_uid')!;

    final manager = $$NotebookRowsTableTableManager(
      $_db,
      $_db.notebookRows,
    ).filter((f) => f.uid.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_notebookUidTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$IndexTabRowsTable, List<IndexTabRow>>
  _indexTabRowsRefsTable(_$NotesDatabase db) => MultiTypedResultKey.fromTable(
    db.indexTabRows,
    aliasName: 'page_rows__uid__index_tab_rows__page_uid',
  );

  $$IndexTabRowsTableProcessedTableManager get indexTabRowsRefs {
    final manager = $$IndexTabRowsTableTableManager(
      $_db,
      $_db.indexTabRows,
    ).filter((f) => f.pageUid.uid.sqlEquals($_itemColumn<String>('uid')!));

    final cache = $_typedResult.readTableOrNull(_indexTabRowsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$TextBlockRowsTable, List<TextBlockRow>>
  _textBlockRowsRefsTable(_$NotesDatabase db) => MultiTypedResultKey.fromTable(
    db.textBlockRows,
    aliasName: 'page_rows__uid__text_block_rows__page_uid',
  );

  $$TextBlockRowsTableProcessedTableManager get textBlockRowsRefs {
    final manager = $$TextBlockRowsTableTableManager(
      $_db,
      $_db.textBlockRows,
    ).filter((f) => f.pageUid.uid.sqlEquals($_itemColumn<String>('uid')!));

    final cache = $_typedResult.readTableOrNull(_textBlockRowsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ImageBlockRowsTable, List<ImageBlockRow>>
  _imageBlockRowsRefsTable(_$NotesDatabase db) => MultiTypedResultKey.fromTable(
    db.imageBlockRows,
    aliasName: 'page_rows__uid__image_block_rows__page_uid',
  );

  $$ImageBlockRowsTableProcessedTableManager get imageBlockRowsRefs {
    final manager = $$ImageBlockRowsTableTableManager(
      $_db,
      $_db.imageBlockRows,
    ).filter((f) => f.pageUid.uid.sqlEquals($_itemColumn<String>('uid')!));

    final cache = $_typedResult.readTableOrNull(_imageBlockRowsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$InkStrokeRowsTable, List<InkStrokeRow>>
  _inkStrokeRowsRefsTable(_$NotesDatabase db) => MultiTypedResultKey.fromTable(
    db.inkStrokeRows,
    aliasName: 'page_rows__uid__ink_stroke_rows__page_uid',
  );

  $$InkStrokeRowsTableProcessedTableManager get inkStrokeRowsRefs {
    final manager = $$InkStrokeRowsTableTableManager(
      $_db,
      $_db.inkStrokeRows,
    ).filter((f) => f.pageUid.uid.sqlEquals($_itemColumn<String>('uid')!));

    final cache = $_typedResult.readTableOrNull(_inkStrokeRowsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$PageRowsTableFilterComposer
    extends Composer<_$NotesDatabase, $PageRowsTable> {
  $$PageRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pageIndex => $composableBuilder(
    column: $table.pageIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isBookmarked => $composableBuilder(
    column: $table.isBookmarked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get legacyIndexTabColorValue => $composableBuilder(
    column: $table.legacyIndexTabColorValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get legacyIndexTabPosition => $composableBuilder(
    column: $table.legacyIndexTabPosition,
    builder: (column) => ColumnFilters(column),
  );

  $$NotebookRowsTableFilterComposer get notebookUid {
    final $$NotebookRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.notebookUid,
      referencedTable: $db.notebookRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$NotebookRowsTableFilterComposer(
            $db: $db,
            $table: $db.notebookRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> indexTabRowsRefs(
    Expression<bool> Function($$IndexTabRowsTableFilterComposer f) f,
  ) {
    final $$IndexTabRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.uid,
      referencedTable: $db.indexTabRows,
      getReferencedColumn: (t) => t.pageUid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$IndexTabRowsTableFilterComposer(
            $db: $db,
            $table: $db.indexTabRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> textBlockRowsRefs(
    Expression<bool> Function($$TextBlockRowsTableFilterComposer f) f,
  ) {
    final $$TextBlockRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.uid,
      referencedTable: $db.textBlockRows,
      getReferencedColumn: (t) => t.pageUid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TextBlockRowsTableFilterComposer(
            $db: $db,
            $table: $db.textBlockRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> imageBlockRowsRefs(
    Expression<bool> Function($$ImageBlockRowsTableFilterComposer f) f,
  ) {
    final $$ImageBlockRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.uid,
      referencedTable: $db.imageBlockRows,
      getReferencedColumn: (t) => t.pageUid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ImageBlockRowsTableFilterComposer(
            $db: $db,
            $table: $db.imageBlockRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> inkStrokeRowsRefs(
    Expression<bool> Function($$InkStrokeRowsTableFilterComposer f) f,
  ) {
    final $$InkStrokeRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.uid,
      referencedTable: $db.inkStrokeRows,
      getReferencedColumn: (t) => t.pageUid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$InkStrokeRowsTableFilterComposer(
            $db: $db,
            $table: $db.inkStrokeRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PageRowsTableOrderingComposer
    extends Composer<_$NotesDatabase, $PageRowsTable> {
  $$PageRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pageIndex => $composableBuilder(
    column: $table.pageIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isBookmarked => $composableBuilder(
    column: $table.isBookmarked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get legacyIndexTabColorValue => $composableBuilder(
    column: $table.legacyIndexTabColorValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get legacyIndexTabPosition => $composableBuilder(
    column: $table.legacyIndexTabPosition,
    builder: (column) => ColumnOrderings(column),
  );

  $$NotebookRowsTableOrderingComposer get notebookUid {
    final $$NotebookRowsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.notebookUid,
      referencedTable: $db.notebookRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$NotebookRowsTableOrderingComposer(
            $db: $db,
            $table: $db.notebookRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PageRowsTableAnnotationComposer
    extends Composer<_$NotesDatabase, $PageRowsTable> {
  $$PageRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<int> get pageIndex =>
      $composableBuilder(column: $table.pageIndex, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<bool> get isBookmarked => $composableBuilder(
    column: $table.isBookmarked,
    builder: (column) => column,
  );

  GeneratedColumn<int> get legacyIndexTabColorValue => $composableBuilder(
    column: $table.legacyIndexTabColorValue,
    builder: (column) => column,
  );

  GeneratedColumn<double> get legacyIndexTabPosition => $composableBuilder(
    column: $table.legacyIndexTabPosition,
    builder: (column) => column,
  );

  $$NotebookRowsTableAnnotationComposer get notebookUid {
    final $$NotebookRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.notebookUid,
      referencedTable: $db.notebookRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$NotebookRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.notebookRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> indexTabRowsRefs<T extends Object>(
    Expression<T> Function($$IndexTabRowsTableAnnotationComposer a) f,
  ) {
    final $$IndexTabRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.uid,
      referencedTable: $db.indexTabRows,
      getReferencedColumn: (t) => t.pageUid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$IndexTabRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.indexTabRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> textBlockRowsRefs<T extends Object>(
    Expression<T> Function($$TextBlockRowsTableAnnotationComposer a) f,
  ) {
    final $$TextBlockRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.uid,
      referencedTable: $db.textBlockRows,
      getReferencedColumn: (t) => t.pageUid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TextBlockRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.textBlockRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> imageBlockRowsRefs<T extends Object>(
    Expression<T> Function($$ImageBlockRowsTableAnnotationComposer a) f,
  ) {
    final $$ImageBlockRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.uid,
      referencedTable: $db.imageBlockRows,
      getReferencedColumn: (t) => t.pageUid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ImageBlockRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.imageBlockRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> inkStrokeRowsRefs<T extends Object>(
    Expression<T> Function($$InkStrokeRowsTableAnnotationComposer a) f,
  ) {
    final $$InkStrokeRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.uid,
      referencedTable: $db.inkStrokeRows,
      getReferencedColumn: (t) => t.pageUid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$InkStrokeRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.inkStrokeRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PageRowsTableTableManager
    extends
        RootTableManager<
          _$NotesDatabase,
          $PageRowsTable,
          PageRow,
          $$PageRowsTableFilterComposer,
          $$PageRowsTableOrderingComposer,
          $$PageRowsTableAnnotationComposer,
          $$PageRowsTableCreateCompanionBuilder,
          $$PageRowsTableUpdateCompanionBuilder,
          (PageRow, $$PageRowsTableReferences),
          PageRow,
          PrefetchHooks Function({
            bool notebookUid,
            bool indexTabRowsRefs,
            bool textBlockRowsRefs,
            bool imageBlockRowsRefs,
            bool inkStrokeRowsRefs,
          })
        > {
  $$PageRowsTableTableManager(_$NotesDatabase db, $PageRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PageRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PageRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PageRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> uid = const Value.absent(),
                Value<String> notebookUid = const Value.absent(),
                Value<int> pageIndex = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<bool> isBookmarked = const Value.absent(),
                Value<int?> legacyIndexTabColorValue = const Value.absent(),
                Value<double?> legacyIndexTabPosition = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PageRowsCompanion(
                uid: uid,
                notebookUid: notebookUid,
                pageIndex: pageIndex,
                title: title,
                isBookmarked: isBookmarked,
                legacyIndexTabColorValue: legacyIndexTabColorValue,
                legacyIndexTabPosition: legacyIndexTabPosition,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String uid,
                required String notebookUid,
                required int pageIndex,
                required String title,
                required bool isBookmarked,
                Value<int?> legacyIndexTabColorValue = const Value.absent(),
                Value<double?> legacyIndexTabPosition = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PageRowsCompanion.insert(
                uid: uid,
                notebookUid: notebookUid,
                pageIndex: pageIndex,
                title: title,
                isBookmarked: isBookmarked,
                legacyIndexTabColorValue: legacyIndexTabColorValue,
                legacyIndexTabPosition: legacyIndexTabPosition,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PageRowsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                notebookUid = false,
                indexTabRowsRefs = false,
                textBlockRowsRefs = false,
                imageBlockRowsRefs = false,
                inkStrokeRowsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (indexTabRowsRefs) db.indexTabRows,
                    if (textBlockRowsRefs) db.textBlockRows,
                    if (imageBlockRowsRefs) db.imageBlockRows,
                    if (inkStrokeRowsRefs) db.inkStrokeRows,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (notebookUid) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.notebookUid,
                                    referencedTable: $$PageRowsTableReferences
                                        ._notebookUidTable(db),
                                    referencedColumn: $$PageRowsTableReferences
                                        ._notebookUidTable(db)
                                        .uid,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (indexTabRowsRefs)
                        await $_getPrefetchedData<
                          PageRow,
                          $PageRowsTable,
                          IndexTabRow
                        >(
                          currentTable: table,
                          referencedTable: $$PageRowsTableReferences
                              ._indexTabRowsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PageRowsTableReferences(
                                db,
                                table,
                                p0,
                              ).indexTabRowsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.pageUid == item.uid,
                              ),
                          typedResults: items,
                        ),
                      if (textBlockRowsRefs)
                        await $_getPrefetchedData<
                          PageRow,
                          $PageRowsTable,
                          TextBlockRow
                        >(
                          currentTable: table,
                          referencedTable: $$PageRowsTableReferences
                              ._textBlockRowsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PageRowsTableReferences(
                                db,
                                table,
                                p0,
                              ).textBlockRowsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.pageUid == item.uid,
                              ),
                          typedResults: items,
                        ),
                      if (imageBlockRowsRefs)
                        await $_getPrefetchedData<
                          PageRow,
                          $PageRowsTable,
                          ImageBlockRow
                        >(
                          currentTable: table,
                          referencedTable: $$PageRowsTableReferences
                              ._imageBlockRowsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PageRowsTableReferences(
                                db,
                                table,
                                p0,
                              ).imageBlockRowsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.pageUid == item.uid,
                              ),
                          typedResults: items,
                        ),
                      if (inkStrokeRowsRefs)
                        await $_getPrefetchedData<
                          PageRow,
                          $PageRowsTable,
                          InkStrokeRow
                        >(
                          currentTable: table,
                          referencedTable: $$PageRowsTableReferences
                              ._inkStrokeRowsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PageRowsTableReferences(
                                db,
                                table,
                                p0,
                              ).inkStrokeRowsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.pageUid == item.uid,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$PageRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$NotesDatabase,
      $PageRowsTable,
      PageRow,
      $$PageRowsTableFilterComposer,
      $$PageRowsTableOrderingComposer,
      $$PageRowsTableAnnotationComposer,
      $$PageRowsTableCreateCompanionBuilder,
      $$PageRowsTableUpdateCompanionBuilder,
      (PageRow, $$PageRowsTableReferences),
      PageRow,
      PrefetchHooks Function({
        bool notebookUid,
        bool indexTabRowsRefs,
        bool textBlockRowsRefs,
        bool imageBlockRowsRefs,
        bool inkStrokeRowsRefs,
      })
    >;
typedef $$IndexTabRowsTableCreateCompanionBuilder =
    IndexTabRowsCompanion Function({
      required String uid,
      required String pageUid,
      required int colorValue,
      required double position,
      Value<int> rowid,
    });
typedef $$IndexTabRowsTableUpdateCompanionBuilder =
    IndexTabRowsCompanion Function({
      Value<String> uid,
      Value<String> pageUid,
      Value<int> colorValue,
      Value<double> position,
      Value<int> rowid,
    });

final class $$IndexTabRowsTableReferences
    extends BaseReferences<_$NotesDatabase, $IndexTabRowsTable, IndexTabRow> {
  $$IndexTabRowsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $PageRowsTable _pageUidTable(_$NotesDatabase db) =>
      db.pageRows.createAlias('index_tab_rows__page_uid__page_rows__uid');

  $$PageRowsTableProcessedTableManager get pageUid {
    final $_column = $_itemColumn<String>('page_uid')!;

    final manager = $$PageRowsTableTableManager(
      $_db,
      $_db.pageRows,
    ).filter((f) => f.uid.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_pageUidTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$IndexTabRowsTableFilterComposer
    extends Composer<_$NotesDatabase, $IndexTabRowsTable> {
  $$IndexTabRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  $$PageRowsTableFilterComposer get pageUid {
    final $$PageRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableFilterComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$IndexTabRowsTableOrderingComposer
    extends Composer<_$NotesDatabase, $IndexTabRowsTable> {
  $$IndexTabRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  $$PageRowsTableOrderingComposer get pageUid {
    final $$PageRowsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableOrderingComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$IndexTabRowsTableAnnotationComposer
    extends Composer<_$NotesDatabase, $IndexTabRowsTable> {
  $$IndexTabRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => column,
  );

  GeneratedColumn<double> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  $$PageRowsTableAnnotationComposer get pageUid {
    final $$PageRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$IndexTabRowsTableTableManager
    extends
        RootTableManager<
          _$NotesDatabase,
          $IndexTabRowsTable,
          IndexTabRow,
          $$IndexTabRowsTableFilterComposer,
          $$IndexTabRowsTableOrderingComposer,
          $$IndexTabRowsTableAnnotationComposer,
          $$IndexTabRowsTableCreateCompanionBuilder,
          $$IndexTabRowsTableUpdateCompanionBuilder,
          (IndexTabRow, $$IndexTabRowsTableReferences),
          IndexTabRow,
          PrefetchHooks Function({bool pageUid})
        > {
  $$IndexTabRowsTableTableManager(_$NotesDatabase db, $IndexTabRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$IndexTabRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$IndexTabRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$IndexTabRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> uid = const Value.absent(),
                Value<String> pageUid = const Value.absent(),
                Value<int> colorValue = const Value.absent(),
                Value<double> position = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => IndexTabRowsCompanion(
                uid: uid,
                pageUid: pageUid,
                colorValue: colorValue,
                position: position,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String uid,
                required String pageUid,
                required int colorValue,
                required double position,
                Value<int> rowid = const Value.absent(),
              }) => IndexTabRowsCompanion.insert(
                uid: uid,
                pageUid: pageUid,
                colorValue: colorValue,
                position: position,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$IndexTabRowsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({pageUid = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (pageUid) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.pageUid,
                                referencedTable: $$IndexTabRowsTableReferences
                                    ._pageUidTable(db),
                                referencedColumn: $$IndexTabRowsTableReferences
                                    ._pageUidTable(db)
                                    .uid,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$IndexTabRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$NotesDatabase,
      $IndexTabRowsTable,
      IndexTabRow,
      $$IndexTabRowsTableFilterComposer,
      $$IndexTabRowsTableOrderingComposer,
      $$IndexTabRowsTableAnnotationComposer,
      $$IndexTabRowsTableCreateCompanionBuilder,
      $$IndexTabRowsTableUpdateCompanionBuilder,
      (IndexTabRow, $$IndexTabRowsTableReferences),
      IndexTabRow,
      PrefetchHooks Function({bool pageUid})
    >;
typedef $$TextBlockRowsTableCreateCompanionBuilder =
    TextBlockRowsCompanion Function({
      required String uid,
      required String pageUid,
      required String plainText,
      Value<String?> deltaJson,
      required double fontSize,
      required int colorValue,
      required double width,
      required double rotation,
      required double dx,
      required double dy,
      required int sortIndex,
      Value<int> rowid,
    });
typedef $$TextBlockRowsTableUpdateCompanionBuilder =
    TextBlockRowsCompanion Function({
      Value<String> uid,
      Value<String> pageUid,
      Value<String> plainText,
      Value<String?> deltaJson,
      Value<double> fontSize,
      Value<int> colorValue,
      Value<double> width,
      Value<double> rotation,
      Value<double> dx,
      Value<double> dy,
      Value<int> sortIndex,
      Value<int> rowid,
    });

final class $$TextBlockRowsTableReferences
    extends BaseReferences<_$NotesDatabase, $TextBlockRowsTable, TextBlockRow> {
  $$TextBlockRowsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $PageRowsTable _pageUidTable(_$NotesDatabase db) =>
      db.pageRows.createAlias('text_block_rows__page_uid__page_rows__uid');

  $$PageRowsTableProcessedTableManager get pageUid {
    final $_column = $_itemColumn<String>('page_uid')!;

    final manager = $$PageRowsTableTableManager(
      $_db,
      $_db.pageRows,
    ).filter((f) => f.uid.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_pageUidTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$TextBlockRowsTableFilterComposer
    extends Composer<_$NotesDatabase, $TextBlockRowsTable> {
  $$TextBlockRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get plainText => $composableBuilder(
    column: $table.plainText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deltaJson => $composableBuilder(
    column: $table.deltaJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get fontSize => $composableBuilder(
    column: $table.fontSize,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get rotation => $composableBuilder(
    column: $table.rotation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get dx => $composableBuilder(
    column: $table.dx,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get dy => $composableBuilder(
    column: $table.dy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortIndex => $composableBuilder(
    column: $table.sortIndex,
    builder: (column) => ColumnFilters(column),
  );

  $$PageRowsTableFilterComposer get pageUid {
    final $$PageRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableFilterComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TextBlockRowsTableOrderingComposer
    extends Composer<_$NotesDatabase, $TextBlockRowsTable> {
  $$TextBlockRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get plainText => $composableBuilder(
    column: $table.plainText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deltaJson => $composableBuilder(
    column: $table.deltaJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get fontSize => $composableBuilder(
    column: $table.fontSize,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get rotation => $composableBuilder(
    column: $table.rotation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get dx => $composableBuilder(
    column: $table.dx,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get dy => $composableBuilder(
    column: $table.dy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortIndex => $composableBuilder(
    column: $table.sortIndex,
    builder: (column) => ColumnOrderings(column),
  );

  $$PageRowsTableOrderingComposer get pageUid {
    final $$PageRowsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableOrderingComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TextBlockRowsTableAnnotationComposer
    extends Composer<_$NotesDatabase, $TextBlockRowsTable> {
  $$TextBlockRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get plainText =>
      $composableBuilder(column: $table.plainText, builder: (column) => column);

  GeneratedColumn<String> get deltaJson =>
      $composableBuilder(column: $table.deltaJson, builder: (column) => column);

  GeneratedColumn<double> get fontSize =>
      $composableBuilder(column: $table.fontSize, builder: (column) => column);

  GeneratedColumn<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => column,
  );

  GeneratedColumn<double> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<double> get rotation =>
      $composableBuilder(column: $table.rotation, builder: (column) => column);

  GeneratedColumn<double> get dx =>
      $composableBuilder(column: $table.dx, builder: (column) => column);

  GeneratedColumn<double> get dy =>
      $composableBuilder(column: $table.dy, builder: (column) => column);

  GeneratedColumn<int> get sortIndex =>
      $composableBuilder(column: $table.sortIndex, builder: (column) => column);

  $$PageRowsTableAnnotationComposer get pageUid {
    final $$PageRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TextBlockRowsTableTableManager
    extends
        RootTableManager<
          _$NotesDatabase,
          $TextBlockRowsTable,
          TextBlockRow,
          $$TextBlockRowsTableFilterComposer,
          $$TextBlockRowsTableOrderingComposer,
          $$TextBlockRowsTableAnnotationComposer,
          $$TextBlockRowsTableCreateCompanionBuilder,
          $$TextBlockRowsTableUpdateCompanionBuilder,
          (TextBlockRow, $$TextBlockRowsTableReferences),
          TextBlockRow,
          PrefetchHooks Function({bool pageUid})
        > {
  $$TextBlockRowsTableTableManager(
    _$NotesDatabase db,
    $TextBlockRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TextBlockRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TextBlockRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TextBlockRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> uid = const Value.absent(),
                Value<String> pageUid = const Value.absent(),
                Value<String> plainText = const Value.absent(),
                Value<String?> deltaJson = const Value.absent(),
                Value<double> fontSize = const Value.absent(),
                Value<int> colorValue = const Value.absent(),
                Value<double> width = const Value.absent(),
                Value<double> rotation = const Value.absent(),
                Value<double> dx = const Value.absent(),
                Value<double> dy = const Value.absent(),
                Value<int> sortIndex = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TextBlockRowsCompanion(
                uid: uid,
                pageUid: pageUid,
                plainText: plainText,
                deltaJson: deltaJson,
                fontSize: fontSize,
                colorValue: colorValue,
                width: width,
                rotation: rotation,
                dx: dx,
                dy: dy,
                sortIndex: sortIndex,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String uid,
                required String pageUid,
                required String plainText,
                Value<String?> deltaJson = const Value.absent(),
                required double fontSize,
                required int colorValue,
                required double width,
                required double rotation,
                required double dx,
                required double dy,
                required int sortIndex,
                Value<int> rowid = const Value.absent(),
              }) => TextBlockRowsCompanion.insert(
                uid: uid,
                pageUid: pageUid,
                plainText: plainText,
                deltaJson: deltaJson,
                fontSize: fontSize,
                colorValue: colorValue,
                width: width,
                rotation: rotation,
                dx: dx,
                dy: dy,
                sortIndex: sortIndex,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$TextBlockRowsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({pageUid = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (pageUid) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.pageUid,
                                referencedTable: $$TextBlockRowsTableReferences
                                    ._pageUidTable(db),
                                referencedColumn: $$TextBlockRowsTableReferences
                                    ._pageUidTable(db)
                                    .uid,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$TextBlockRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$NotesDatabase,
      $TextBlockRowsTable,
      TextBlockRow,
      $$TextBlockRowsTableFilterComposer,
      $$TextBlockRowsTableOrderingComposer,
      $$TextBlockRowsTableAnnotationComposer,
      $$TextBlockRowsTableCreateCompanionBuilder,
      $$TextBlockRowsTableUpdateCompanionBuilder,
      (TextBlockRow, $$TextBlockRowsTableReferences),
      TextBlockRow,
      PrefetchHooks Function({bool pageUid})
    >;
typedef $$ImageBlockRowsTableCreateCompanionBuilder =
    ImageBlockRowsCompanion Function({
      required String uid,
      required String pageUid,
      required String path,
      required String ocrText,
      Value<Uint8List?> bytes,
      Value<String?> imageExt,
      Value<String?> imageMime,
      required double width,
      required double height,
      required double rotation,
      required double dx,
      required double dy,
      required double cropLeft,
      required double cropTop,
      required double cropRight,
      required double cropBottom,
      required int sortIndex,
      Value<int> rowid,
    });
typedef $$ImageBlockRowsTableUpdateCompanionBuilder =
    ImageBlockRowsCompanion Function({
      Value<String> uid,
      Value<String> pageUid,
      Value<String> path,
      Value<String> ocrText,
      Value<Uint8List?> bytes,
      Value<String?> imageExt,
      Value<String?> imageMime,
      Value<double> width,
      Value<double> height,
      Value<double> rotation,
      Value<double> dx,
      Value<double> dy,
      Value<double> cropLeft,
      Value<double> cropTop,
      Value<double> cropRight,
      Value<double> cropBottom,
      Value<int> sortIndex,
      Value<int> rowid,
    });

final class $$ImageBlockRowsTableReferences
    extends
        BaseReferences<_$NotesDatabase, $ImageBlockRowsTable, ImageBlockRow> {
  $$ImageBlockRowsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $PageRowsTable _pageUidTable(_$NotesDatabase db) =>
      db.pageRows.createAlias('image_block_rows__page_uid__page_rows__uid');

  $$PageRowsTableProcessedTableManager get pageUid {
    final $_column = $_itemColumn<String>('page_uid')!;

    final manager = $$PageRowsTableTableManager(
      $_db,
      $_db.pageRows,
    ).filter((f) => f.uid.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_pageUidTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ImageBlockRowsTableFilterComposer
    extends Composer<_$NotesDatabase, $ImageBlockRowsTable> {
  $$ImageBlockRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ocrText => $composableBuilder(
    column: $table.ocrText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get imageExt => $composableBuilder(
    column: $table.imageExt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get imageMime => $composableBuilder(
    column: $table.imageMime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get rotation => $composableBuilder(
    column: $table.rotation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get dx => $composableBuilder(
    column: $table.dx,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get dy => $composableBuilder(
    column: $table.dy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cropLeft => $composableBuilder(
    column: $table.cropLeft,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cropTop => $composableBuilder(
    column: $table.cropTop,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cropRight => $composableBuilder(
    column: $table.cropRight,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cropBottom => $composableBuilder(
    column: $table.cropBottom,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortIndex => $composableBuilder(
    column: $table.sortIndex,
    builder: (column) => ColumnFilters(column),
  );

  $$PageRowsTableFilterComposer get pageUid {
    final $$PageRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableFilterComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ImageBlockRowsTableOrderingComposer
    extends Composer<_$NotesDatabase, $ImageBlockRowsTable> {
  $$ImageBlockRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ocrText => $composableBuilder(
    column: $table.ocrText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get imageExt => $composableBuilder(
    column: $table.imageExt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get imageMime => $composableBuilder(
    column: $table.imageMime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get rotation => $composableBuilder(
    column: $table.rotation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get dx => $composableBuilder(
    column: $table.dx,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get dy => $composableBuilder(
    column: $table.dy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cropLeft => $composableBuilder(
    column: $table.cropLeft,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cropTop => $composableBuilder(
    column: $table.cropTop,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cropRight => $composableBuilder(
    column: $table.cropRight,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cropBottom => $composableBuilder(
    column: $table.cropBottom,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortIndex => $composableBuilder(
    column: $table.sortIndex,
    builder: (column) => ColumnOrderings(column),
  );

  $$PageRowsTableOrderingComposer get pageUid {
    final $$PageRowsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableOrderingComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ImageBlockRowsTableAnnotationComposer
    extends Composer<_$NotesDatabase, $ImageBlockRowsTable> {
  $$ImageBlockRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get ocrText =>
      $composableBuilder(column: $table.ocrText, builder: (column) => column);

  GeneratedColumn<Uint8List> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<String> get imageExt =>
      $composableBuilder(column: $table.imageExt, builder: (column) => column);

  GeneratedColumn<String> get imageMime =>
      $composableBuilder(column: $table.imageMime, builder: (column) => column);

  GeneratedColumn<double> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<double> get height =>
      $composableBuilder(column: $table.height, builder: (column) => column);

  GeneratedColumn<double> get rotation =>
      $composableBuilder(column: $table.rotation, builder: (column) => column);

  GeneratedColumn<double> get dx =>
      $composableBuilder(column: $table.dx, builder: (column) => column);

  GeneratedColumn<double> get dy =>
      $composableBuilder(column: $table.dy, builder: (column) => column);

  GeneratedColumn<double> get cropLeft =>
      $composableBuilder(column: $table.cropLeft, builder: (column) => column);

  GeneratedColumn<double> get cropTop =>
      $composableBuilder(column: $table.cropTop, builder: (column) => column);

  GeneratedColumn<double> get cropRight =>
      $composableBuilder(column: $table.cropRight, builder: (column) => column);

  GeneratedColumn<double> get cropBottom => $composableBuilder(
    column: $table.cropBottom,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortIndex =>
      $composableBuilder(column: $table.sortIndex, builder: (column) => column);

  $$PageRowsTableAnnotationComposer get pageUid {
    final $$PageRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ImageBlockRowsTableTableManager
    extends
        RootTableManager<
          _$NotesDatabase,
          $ImageBlockRowsTable,
          ImageBlockRow,
          $$ImageBlockRowsTableFilterComposer,
          $$ImageBlockRowsTableOrderingComposer,
          $$ImageBlockRowsTableAnnotationComposer,
          $$ImageBlockRowsTableCreateCompanionBuilder,
          $$ImageBlockRowsTableUpdateCompanionBuilder,
          (ImageBlockRow, $$ImageBlockRowsTableReferences),
          ImageBlockRow,
          PrefetchHooks Function({bool pageUid})
        > {
  $$ImageBlockRowsTableTableManager(
    _$NotesDatabase db,
    $ImageBlockRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ImageBlockRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ImageBlockRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ImageBlockRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> uid = const Value.absent(),
                Value<String> pageUid = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<String> ocrText = const Value.absent(),
                Value<Uint8List?> bytes = const Value.absent(),
                Value<String?> imageExt = const Value.absent(),
                Value<String?> imageMime = const Value.absent(),
                Value<double> width = const Value.absent(),
                Value<double> height = const Value.absent(),
                Value<double> rotation = const Value.absent(),
                Value<double> dx = const Value.absent(),
                Value<double> dy = const Value.absent(),
                Value<double> cropLeft = const Value.absent(),
                Value<double> cropTop = const Value.absent(),
                Value<double> cropRight = const Value.absent(),
                Value<double> cropBottom = const Value.absent(),
                Value<int> sortIndex = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ImageBlockRowsCompanion(
                uid: uid,
                pageUid: pageUid,
                path: path,
                ocrText: ocrText,
                bytes: bytes,
                imageExt: imageExt,
                imageMime: imageMime,
                width: width,
                height: height,
                rotation: rotation,
                dx: dx,
                dy: dy,
                cropLeft: cropLeft,
                cropTop: cropTop,
                cropRight: cropRight,
                cropBottom: cropBottom,
                sortIndex: sortIndex,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String uid,
                required String pageUid,
                required String path,
                required String ocrText,
                Value<Uint8List?> bytes = const Value.absent(),
                Value<String?> imageExt = const Value.absent(),
                Value<String?> imageMime = const Value.absent(),
                required double width,
                required double height,
                required double rotation,
                required double dx,
                required double dy,
                required double cropLeft,
                required double cropTop,
                required double cropRight,
                required double cropBottom,
                required int sortIndex,
                Value<int> rowid = const Value.absent(),
              }) => ImageBlockRowsCompanion.insert(
                uid: uid,
                pageUid: pageUid,
                path: path,
                ocrText: ocrText,
                bytes: bytes,
                imageExt: imageExt,
                imageMime: imageMime,
                width: width,
                height: height,
                rotation: rotation,
                dx: dx,
                dy: dy,
                cropLeft: cropLeft,
                cropTop: cropTop,
                cropRight: cropRight,
                cropBottom: cropBottom,
                sortIndex: sortIndex,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ImageBlockRowsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({pageUid = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (pageUid) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.pageUid,
                                referencedTable: $$ImageBlockRowsTableReferences
                                    ._pageUidTable(db),
                                referencedColumn:
                                    $$ImageBlockRowsTableReferences
                                        ._pageUidTable(db)
                                        .uid,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ImageBlockRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$NotesDatabase,
      $ImageBlockRowsTable,
      ImageBlockRow,
      $$ImageBlockRowsTableFilterComposer,
      $$ImageBlockRowsTableOrderingComposer,
      $$ImageBlockRowsTableAnnotationComposer,
      $$ImageBlockRowsTableCreateCompanionBuilder,
      $$ImageBlockRowsTableUpdateCompanionBuilder,
      (ImageBlockRow, $$ImageBlockRowsTableReferences),
      ImageBlockRow,
      PrefetchHooks Function({bool pageUid})
    >;
typedef $$InkStrokeRowsTableCreateCompanionBuilder =
    InkStrokeRowsCompanion Function({
      required String uid,
      required String pageUid,
      required int colorValue,
      required double width,
      required int toolIndex,
      required String pointsJson,
      required int sortIndex,
      Value<int> rowid,
    });
typedef $$InkStrokeRowsTableUpdateCompanionBuilder =
    InkStrokeRowsCompanion Function({
      Value<String> uid,
      Value<String> pageUid,
      Value<int> colorValue,
      Value<double> width,
      Value<int> toolIndex,
      Value<String> pointsJson,
      Value<int> sortIndex,
      Value<int> rowid,
    });

final class $$InkStrokeRowsTableReferences
    extends BaseReferences<_$NotesDatabase, $InkStrokeRowsTable, InkStrokeRow> {
  $$InkStrokeRowsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $PageRowsTable _pageUidTable(_$NotesDatabase db) =>
      db.pageRows.createAlias('ink_stroke_rows__page_uid__page_rows__uid');

  $$PageRowsTableProcessedTableManager get pageUid {
    final $_column = $_itemColumn<String>('page_uid')!;

    final manager = $$PageRowsTableTableManager(
      $_db,
      $_db.pageRows,
    ).filter((f) => f.uid.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_pageUidTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$InkStrokeRowsTableFilterComposer
    extends Composer<_$NotesDatabase, $InkStrokeRowsTable> {
  $$InkStrokeRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get toolIndex => $composableBuilder(
    column: $table.toolIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pointsJson => $composableBuilder(
    column: $table.pointsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortIndex => $composableBuilder(
    column: $table.sortIndex,
    builder: (column) => ColumnFilters(column),
  );

  $$PageRowsTableFilterComposer get pageUid {
    final $$PageRowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableFilterComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$InkStrokeRowsTableOrderingComposer
    extends Composer<_$NotesDatabase, $InkStrokeRowsTable> {
  $$InkStrokeRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get toolIndex => $composableBuilder(
    column: $table.toolIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pointsJson => $composableBuilder(
    column: $table.pointsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortIndex => $composableBuilder(
    column: $table.sortIndex,
    builder: (column) => ColumnOrderings(column),
  );

  $$PageRowsTableOrderingComposer get pageUid {
    final $$PageRowsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableOrderingComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$InkStrokeRowsTableAnnotationComposer
    extends Composer<_$NotesDatabase, $InkStrokeRowsTable> {
  $$InkStrokeRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => column,
  );

  GeneratedColumn<double> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<int> get toolIndex =>
      $composableBuilder(column: $table.toolIndex, builder: (column) => column);

  GeneratedColumn<String> get pointsJson => $composableBuilder(
    column: $table.pointsJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortIndex =>
      $composableBuilder(column: $table.sortIndex, builder: (column) => column);

  $$PageRowsTableAnnotationComposer get pageUid {
    final $$PageRowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.pageUid,
      referencedTable: $db.pageRows,
      getReferencedColumn: (t) => t.uid,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PageRowsTableAnnotationComposer(
            $db: $db,
            $table: $db.pageRows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$InkStrokeRowsTableTableManager
    extends
        RootTableManager<
          _$NotesDatabase,
          $InkStrokeRowsTable,
          InkStrokeRow,
          $$InkStrokeRowsTableFilterComposer,
          $$InkStrokeRowsTableOrderingComposer,
          $$InkStrokeRowsTableAnnotationComposer,
          $$InkStrokeRowsTableCreateCompanionBuilder,
          $$InkStrokeRowsTableUpdateCompanionBuilder,
          (InkStrokeRow, $$InkStrokeRowsTableReferences),
          InkStrokeRow,
          PrefetchHooks Function({bool pageUid})
        > {
  $$InkStrokeRowsTableTableManager(
    _$NotesDatabase db,
    $InkStrokeRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$InkStrokeRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$InkStrokeRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$InkStrokeRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> uid = const Value.absent(),
                Value<String> pageUid = const Value.absent(),
                Value<int> colorValue = const Value.absent(),
                Value<double> width = const Value.absent(),
                Value<int> toolIndex = const Value.absent(),
                Value<String> pointsJson = const Value.absent(),
                Value<int> sortIndex = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => InkStrokeRowsCompanion(
                uid: uid,
                pageUid: pageUid,
                colorValue: colorValue,
                width: width,
                toolIndex: toolIndex,
                pointsJson: pointsJson,
                sortIndex: sortIndex,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String uid,
                required String pageUid,
                required int colorValue,
                required double width,
                required int toolIndex,
                required String pointsJson,
                required int sortIndex,
                Value<int> rowid = const Value.absent(),
              }) => InkStrokeRowsCompanion.insert(
                uid: uid,
                pageUid: pageUid,
                colorValue: colorValue,
                width: width,
                toolIndex: toolIndex,
                pointsJson: pointsJson,
                sortIndex: sortIndex,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$InkStrokeRowsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({pageUid = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (pageUid) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.pageUid,
                                referencedTable: $$InkStrokeRowsTableReferences
                                    ._pageUidTable(db),
                                referencedColumn: $$InkStrokeRowsTableReferences
                                    ._pageUidTable(db)
                                    .uid,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$InkStrokeRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$NotesDatabase,
      $InkStrokeRowsTable,
      InkStrokeRow,
      $$InkStrokeRowsTableFilterComposer,
      $$InkStrokeRowsTableOrderingComposer,
      $$InkStrokeRowsTableAnnotationComposer,
      $$InkStrokeRowsTableCreateCompanionBuilder,
      $$InkStrokeRowsTableUpdateCompanionBuilder,
      (InkStrokeRow, $$InkStrokeRowsTableReferences),
      InkStrokeRow,
      PrefetchHooks Function({bool pageUid})
    >;

class $NotesDatabaseManager {
  final _$NotesDatabase _db;
  $NotesDatabaseManager(this._db);
  $$NotebookRowsTableTableManager get notebookRows =>
      $$NotebookRowsTableTableManager(_db, _db.notebookRows);
  $$PageRowsTableTableManager get pageRows =>
      $$PageRowsTableTableManager(_db, _db.pageRows);
  $$IndexTabRowsTableTableManager get indexTabRows =>
      $$IndexTabRowsTableTableManager(_db, _db.indexTabRows);
  $$TextBlockRowsTableTableManager get textBlockRows =>
      $$TextBlockRowsTableTableManager(_db, _db.textBlockRows);
  $$ImageBlockRowsTableTableManager get imageBlockRows =>
      $$ImageBlockRowsTableTableManager(_db, _db.imageBlockRows);
  $$InkStrokeRowsTableTableManager get inkStrokeRows =>
      $$InkStrokeRowsTableTableManager(_db, _db.inkStrokeRows);
}
