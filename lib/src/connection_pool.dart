import 'dart:async';

import 'mutex.dart';
import 'port_channel.dart';
import 'sqlite_connection.dart';
import 'sqlite_connection_impl.dart';
import 'sqlite_open_factory.dart';
import 'sqlite_queries.dart';
import 'update_notification.dart';

/// A connection pool with a single write connection and multiple read connections.
class SqliteConnectionPool with SqliteQueries implements SqliteConnection {
  SqliteConnection? _writeConnection;

  final List<SqliteConnectionImpl> _readConnections = [];

  final SqliteOpenFactory _factory;
  final SerializedPortClient _upstreamPort;

  @override
  final Stream<UpdateNotification>? updates;

  final int maxReaders;

  final String? debugName;

  final Mutex mutex;

  /// Open a new connection pool.
  ///
  /// The provided factory is used to open connections on demand. Connections
  /// are only opened when requested for the first time.
  ///
  /// [maxReaders] specifies the maximum number of read connections.
  /// A maximum of one write connection will be opened.
  ///
  /// Read connections are opened in read-only mode, and will reject any statements
  /// that modify the database.
  SqliteConnectionPool(this._factory,
      {this.updates,
      this.maxReaders = 5,
      SqliteConnection? writeConnection,
      this.debugName,
      required this.mutex,
      required SerializedPortClient upstreamPort})
      : _writeConnection = writeConnection,
        _upstreamPort = upstreamPort;

  @override
  Future<T> readLock<T>(Future<T> Function(SqliteReadContext tx) callback,
      {Duration? lockTimeout}) async {
    await _expandPool();

    bool haveLock = false;
    var completer = Completer<T>();

    var futures = _readConnections.sublist(0).map((connection) async {
      try {
        return await connection.readLock((ctx) async {
          if (haveLock) {
            // Already have a different lock - release this one.
            return false;
          }
          haveLock = true;

          var future = callback(ctx);
          completer.complete(future);

          // We have to wait for the future to complete before we can release the
          // lock.
          try {
            await future;
          } catch (_) {
            // Ignore
          }

          return true;
        }, lockTimeout: lockTimeout);
      } on TimeoutException {
        return false;
      }
    });

    final stream = Stream<bool>.fromFutures(futures);
    var gotAny = await stream.any((element) => element);

    if (!gotAny) {
      // All TimeoutExceptions
      throw TimeoutException('Failed to get a read connection', lockTimeout);
    }

    try {
      return await completer.future;
    } catch (e) {
      // throw e;
      rethrow;
    }
  }

  @override
  Future<T> writeLock<T>(Future<T> Function(SqliteWriteContext tx) callback,
      {Duration? lockTimeout}) {
    _writeConnection ??= SqliteConnectionImpl(
        upstreamPort: _upstreamPort,
        primary: false,
        updates: updates,
        debugName: debugName != null ? '$debugName-writer' : null,
        mutex: mutex,
        readOnly: false,
        openFactory: _factory);
    return _writeConnection!.writeLock(callback, lockTimeout: lockTimeout);
  }

  Future<void> _expandPool() async {
    if (_readConnections.length >= maxReaders) {
      return;
    }
    bool hasCapacity = _readConnections.any((connection) => !connection.locked);
    if (!hasCapacity) {
      var name = debugName == null
          ? null
          : '$debugName-${_readConnections.length + 1}';
      var connection = SqliteConnectionImpl(
          upstreamPort: _upstreamPort,
          primary: false,
          updates: updates,
          debugName: name,
          mutex: mutex,
          readOnly: true,
          openFactory: _factory);
      _readConnections.add(connection);

      // Edge case:
      // If we don't await here, there is a chance that a different connection
      // is used for the transaction, and that it finishes and deletes the database
      // while this one is still opening. This is specifically triggered in tests.
      // To avoid that, we wait for the connection to be ready.
      await connection.ready;
    }
  }
}
