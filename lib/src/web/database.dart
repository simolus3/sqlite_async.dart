import 'dart:async';
import 'dart:js_interop';

import 'package:sqlite3/common.dart';
import 'package:sqlite3_web/sqlite3_web.dart';
import 'package:sqlite_async/mutex.dart';
import 'package:sqlite_async/src/common/sqlite_database.dart';
import 'package:sqlite_async/src/sqlite_connection.dart';
import 'package:sqlite_async/src/sqlite_queries.dart';
import 'package:sqlite_async/src/update_notification.dart';
import 'protocol.dart';

class WebDatabase
    with SqliteQueries, SqliteDatabaseMixin
    implements SqliteDatabase {
  final Database _database;
  final Mutex? _mutex;

  @override
  bool closed = false;

  WebDatabase(this._database, this._mutex);

  @override
  Future<void> close() async {
    await _database.dispose();
    closed = true;
  }

  @override
  Future<bool> getAutoCommit() async {
    final response = await _database.customRequest(
        CustomDatabaseMessage(CustomDatabaseMessageKind.getAutoCommit));
    return (response as JSBoolean?)?.toDart ?? false;
  }

  @override
  Future<void> initialize() {
    return Future.value();
  }

  @override
  Future<void> get isInitialized => initialize();

  @override
  Never isolateConnectionFactory() {
    throw UnimplementedError();
  }

  @override
  int get maxReaders => throw UnimplementedError();

  @override
  Never get openFactory => throw UnimplementedError();

  @override
  Future<T> readLock<T>(Future<T> Function(SqliteReadContext tx) callback,
      {Duration? lockTimeout, String? debugContext}) async {
    if (_mutex case var mutex?) {
      return await mutex.lock(() async {
        final context = _SharedContext(this);
        try {
          return await callback(context);
        } finally {
          context.markClosed();
        }
      });
    } else {
      // No custom mutex, coordinate locks through shared worker.
      await _database.customRequest(
          CustomDatabaseMessage(CustomDatabaseMessageKind.requestSharedLock));

      try {
        return await callback(_SharedContext(this));
      } finally {
        await _database.customRequest(
            CustomDatabaseMessage(CustomDatabaseMessageKind.releaseLock));
      }
    }
  }

  @override
  Stream<UpdateNotification> get updates =>
      _database.updates.map((event) => UpdateNotification({event.tableName}));

  @override
  // todo: Why do we have to expose both a stream and a controller?
  StreamController<UpdateNotification> get updatesController =>
      throw UnimplementedError();

  @override
  Future<T> writeLock<T>(Future<T> Function(SqliteWriteContext tx) callback,
      {Duration? lockTimeout, String? debugContext}) async {
    if (_mutex case var mutex?) {
      return await mutex.lock(() async {
        final context = _ExlusiveContext(this);
        try {
          return await callback(context);
        } finally {
          context.markClosed();
        }
      });
    } else {
      // No custom mutex, coordinate locks through shared worker.
      await _database.customRequest(CustomDatabaseMessage(
          CustomDatabaseMessageKind.requestExclusiveLock));
      final context = _ExlusiveContext(this);

      try {
        return await callback(context);
      } finally {
        context.markClosed();
        await _database.customRequest(
            CustomDatabaseMessage(CustomDatabaseMessageKind.releaseLock));
      }
    }
  }
}

class _SharedContext implements SqliteReadContext {
  final WebDatabase _database;
  bool _contextClosed = false;

  _SharedContext(this._database);

  @override
  bool get closed => _contextClosed || _database.closed;

  @override
  Future<T> computeWithDatabase<T>(
      Future<T> Function(CommonDatabase db) compute) {
    // Can't be implemented: The database may live on another worker.
    throw UnimplementedError();
  }

  @override
  Future<Row> get(String sql, [List<Object?> parameters = const []]) async {
    final results = await getAll(sql, parameters);
    return results.single;
  }

  @override
  Future<ResultSet> getAll(String sql,
      [List<Object?> parameters = const []]) async {
    return await _database._database.select(sql, parameters);
  }

  @override
  Future<bool> getAutoCommit() async {
    return _database.getAutoCommit();
  }

  @override
  Future<Row?> getOptional(String sql,
      [List<Object?> parameters = const []]) async {
    final results = await getAll(sql, parameters);
    return results.singleOrNull;
  }

  void markClosed() {
    _contextClosed = true;
  }
}

class _ExlusiveContext extends _SharedContext implements SqliteWriteContext {
  _ExlusiveContext(super.database);

  @override
  Future<ResultSet> execute(String sql,
      [List<Object?> parameters = const []]) async {
    return await _database._database.select(sql, parameters);
  }

  @override
  Future<void> executeBatch(
      String sql, List<List<Object?>> parameterSets) async {
    for (final set in parameterSets) {
      // use execute instead of select to avoid transferring rows from the
      // worker to this context.
      await _database._database.execute(sql, set);
    }
  }
}
