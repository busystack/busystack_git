import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'models.dart';

/// Linux statx has a stable, architecture-independent ABI. Using raw paths
/// avoids Dart's String conversion at the filesystem identity boundary.
final class LinuxPaths {
  static final _lib = DynamicLibrary.process();
  static final _statx = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>, Int32, Uint32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>, int, int, Pointer<Uint8>)
      >('statx');
  static final _readlink = _lib
      .lookupFunction<
        IntPtr Function(Pointer<Uint8>, Pointer<Uint8>, IntPtr),
        int Function(Pointer<Uint8>, Pointer<Uint8>, int)
      >('readlink');
  static final _open = _lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, Uint32),
        int Function(Pointer<Utf8>, int, int)
      >('open');
  static final _openat = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>, Int32, Uint32),
        int Function(int, Pointer<Uint8>, int, int)
      >('openat');
  static final _truncate = _lib
      .lookupFunction<Int32 Function(Int32, Int64), int Function(int, int)>(
        'ftruncate',
      );
  static final _close = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _flock = _lib
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  static final _write = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('write');
  static final _fsync = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
  static final _errno = _lib
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__errno_location',
      );
  static final _chmod = _lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');
  static final _fchmod = _lib
      .lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
        'fchmod',
      );
  static final _renameat = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>, Int32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint8>)
      >('renameat');
  static final _unlinkat = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>, Int32),
        int Function(int, Pointer<Uint8>, int)
      >('unlinkat');
  static final _symlinkat = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Int32, Pointer<Uint8>),
        int Function(Pointer<Uint8>, int, Pointer<Uint8>)
      >('symlinkat');
  static final _access = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, Int32),
        int Function(int, Pointer<Utf8>, int, int)
      >('faccessat');
  static bool canWrite(String path) {
    final raw = path.toNativeUtf8();
    try {
      return _access(-100, raw, 2, 0x200) == 0;
    } finally {
      calloc.free(raw);
    }
  }

  static void chmod(String path, int mode) {
    final raw = path.toNativeUtf8();
    try {
      if (_chmod(raw, mode) != 0)
        throw const GitException(GitErrorCode.unsafePath);
    } finally {
      calloc.free(raw);
    }
  }

  static ({int mode, int size, bool exists, String identity, String stamp})
  stat(List<int> path) {
    final raw = calloc<Uint8>(path.length + 1), buffer = calloc<Uint8>(256);
    try {
      raw.asTypedList(path.length).setAll(0, path);
      if (_statx(-100, raw, 0x100, 0x7ff, buffer) != 0) {
        if (_errno().value == 2)
          return (
            mode: 0,
            size: 0,
            exists: false,
            identity: 'absent',
            stamp: 'absent',
          );
        throw const GitException(GitErrorCode.unsafePath);
      }
      final data = ByteData.sublistView(buffer.asTypedList(256));
      return _metadata(data);
    } finally {
      calloc.free(raw);
      calloc.free(buffer);
    }
  }

  static ({int mode, int size, bool exists, String identity, String stamp})
  descriptorStat(int fd) {
    final raw = calloc<Uint8>(1), buffer = calloc<Uint8>(256);
    try {
      if (_statx(fd, raw, 0x1000, 0x7ff, buffer) != 0)
        throw const GitException(GitErrorCode.unsafePath);
      return _metadata(ByteData.sublistView(buffer.asTypedList(256)));
    } finally {
      calloc.free(raw);
      calloc.free(buffer);
    }
  }

  static ({int mode, int size, bool exists, String identity, String stamp})
  _metadata(ByteData data) => (
    mode: data.getUint16(28, Endian.host),
    size: data.getUint64(40, Endian.host),
    exists: true,
    identity:
        '${data.getUint32(136, Endian.host)}:${data.getUint32(140, Endian.host)}:${data.getUint64(32, Endian.host)}',
    stamp:
        '${data.getInt64(96, Endian.host)}:${data.getUint32(104, Endian.host)}:${data.getInt64(112, Endian.host)}:${data.getUint32(120, Endian.host)}:${data.getUint64(40, Endian.host)}',
  );
  static Uint8List linkTarget(List<int> path) {
    final raw = calloc<Uint8>(path.length + 1), buffer = calloc<Uint8>(65536);
    try {
      raw.asTypedList(path.length).setAll(0, path);
      final size = _readlink(raw, buffer, 65536);
      if (size < 0 || size == 65536)
        throw const GitException(GitErrorCode.unsafePath);
      return Uint8List.fromList(buffer.asTypedList(size));
    } finally {
      calloc.free(raw);
      calloc.free(buffer);
    }
  }

  static int open(String path, {bool exclusive = false}) {
    final raw = path.toNativeUtf8();
    try {
      final fd = _open(
        raw,
        2 | 0x40 | 0x20000 | 0x80000 | (exclusive ? 0x80 : 0),
        0x180,
      );
      if (fd < 0) throw const GitException(GitErrorCode.locked);
      return fd;
    } finally {
      calloc.free(raw);
    }
  }

  static bool tryLock(int fd) => _flock(fd, 2 | 4) == 0;
  static bool trySharedLock(int fd) => _flock(fd, 1 | 4) == 0;
  static void close(int fd) {
    _close(fd);
  }

  static void setDescriptorMode(int fd, int mode) {
    if (_fchmod(fd, mode & 0x1ff) != 0)
      throw const GitException(GitErrorCode.unsafePath);
  }

  /// Index replacement and cleanup stay relative to the verified metadata
  /// directory. A changed lock entry is never adopted or deleted.
  static void finishIndexLock(
    List<int> path,
    int ownedFd, {
    required bool install,
  }) {
    final slash = path.lastIndexOf(47);
    if (slash < 1) throw const GitException(GitErrorCode.unsafePath);
    final parent = secureOpen(path.sublist(0, slash), directory: true);
    final basename = path.sublist(slash + 1),
        lockedName = [...basename, ...'.lock'.codeUnits];
    final source = calloc<Uint8>(lockedName.length + 1),
        target = calloc<Uint8>(basename.length + 1);
    try {
      source.asTypedList(lockedName.length).setAll(0, lockedName);
      target.asTypedList(basename.length).setAll(0, basename);
      final current = _openat(parent, source, 0x20000 | 0x80000 | 0x800, 0);
      if (current < 0) {
        if (!install && _errno().value == 2) return;
        throw const GitException(GitErrorCode.unsafePath);
      }
      try {
        if (descriptorStat(current).identity !=
            descriptorStat(ownedFd).identity) {
          throw const GitException(
            GitErrorCode.staleReview,
            diagnostic:
                'The index lock entry changed. Its replacement was left untouched.',
          );
        }
      } finally {
        close(current);
      }
      final result = install
          ? _renameat(parent, source, parent, target)
          : _unlinkat(parent, source, 0);
      if (result != 0) throw const GitException(GitErrorCode.unsafePath);
      if (_fsync(parent) != 0)
        throw const GitException(GitErrorCode.commandFailed);
    } finally {
      close(parent);
      calloc.free(source);
      calloc.free(target);
    }
  }

  /// Resolve each component with O_NOFOLLOW, including ancestors. This is used
  /// for engine-owned file writes, rather than following a checked path later.
  static int secureOpen(
    List<int> absolutePath, {
    bool create = false,
    bool exclusive = false,
    bool directory = false,
    bool readOnly = false,
  }) {
    if (absolutePath.isEmpty ||
        absolutePath.first != 47 ||
        absolutePath.contains(0))
      throw const GitException(GitErrorCode.unsafePath);
    final root = '/'.toNativeUtf8();
    var fd = -1;
    try {
      fd = _open(root, 0x10000 | 0x20000 | 0x80000, 0);
    } finally {
      calloc.free(root);
    }
    if (fd < 0) throw const GitException(GitErrorCode.unsafePath);
    try {
      var start = 1;
      for (var i = 1; i <= absolutePath.length; i++) {
        if (i < absolutePath.length && absolutePath[i] != 47) continue;
        final part = absolutePath.sublist(start, i);
        if (part.isEmpty ||
            part.length == 1 && part[0] == 46 ||
            part.length == 2 && part[0] == 46 && part[1] == 46)
          throw const GitException(GitErrorCode.unsafePath);
        final name = calloc<Uint8>(part.length + 1);
        int next;
        try {
          name.asTypedList(part.length).setAll(0, part);
          next = _openat(
            fd,
            name,
            0x20000 |
                0x80000 |
                (i == absolutePath.length
                    ? (directory
                              ? 0x10000
                              : readOnly
                              ? 0x800
                              : 2) |
                          (create ? 0x40 : 0) |
                          (exclusive ? 0x80 : 0)
                    : 0x10000),
            0x180,
          );
        } finally {
          calloc.free(name);
        }
        if (next < 0)
          throw GitException(
            _errno().value == 17
                ? GitErrorCode.locked
                : GitErrorCode.unsafePath,
          );
        _close(fd);
        fd = next;
        start = i + 1;
      }
      final result = fd;
      fd = -1;
      return result;
    } finally {
      if (fd >= 0) _close(fd);
    }
  }

  /// Atomic replacement relative to an opened, non-symlink parent directory.
  /// Existing links are replaced as directory entries and never followed.
  static void replaceWorking(List<int> path, Uint8List? bytes, String mode) {
    final slash = path.lastIndexOf(47);
    if (slash < 1) throw const GitException(GitErrorCode.unsafePath);
    final parent = secureOpen(path.sublist(0, slash), directory: true);
    final name = calloc<Uint8>(path.length - slash);
    final temporary =
        '.busystack-result-${DateTime.now().microsecondsSinceEpoch}-$parent'
            .codeUnits;
    final temp = calloc<Uint8>(temporary.length + 1);
    var created = false;
    try {
      name
          .asTypedList(path.length - slash - 1)
          .setAll(0, path.sublist(slash + 1));
      temp.asTypedList(temporary.length).setAll(0, temporary);
      if (bytes == null) {
        if (_unlinkat(parent, name, 0) != 0 && _errno().value != 2)
          throw const GitException(GitErrorCode.unsafePath);
        _fsync(parent);
        return;
      }
      if (mode == '120000') {
        if (bytes.contains(0))
          throw const GitException(GitErrorCode.invalidRequest);
        final target = calloc<Uint8>(bytes.length + 1);
        try {
          target.asTypedList(bytes.length).setAll(0, bytes);
          if (_symlinkat(target, parent, temp) != 0)
            throw const GitException(GitErrorCode.unsafePath);
        } finally {
          calloc.free(target);
        }
        created = true;
      } else {
        final fd = _openat(
          parent,
          temp,
          2 | 0x40 | 0x80 | 0x20000 | 0x80000,
          0x180,
        );
        if (fd < 0) throw const GitException(GitErrorCode.unsafePath);
        created = true;
        try {
          writeAndFlush(fd, bytes);
          if (_fchmod(fd, mode == '100755' ? 0x1ed : 0x1a4) != 0)
            throw const GitException(GitErrorCode.commandFailed);
        } finally {
          close(fd);
        }
      }
      if (_renameat(parent, temp, parent, name) != 0)
        throw const GitException(GitErrorCode.unsafePath);
      created = false;
      _fsync(parent);
    } finally {
      if (created) _unlinkat(parent, temp, 0);
      close(parent);
      calloc.free(name);
      calloc.free(temp);
    }
  }

  static void replaceExisting(List<int> path, Uint8List bytes) {
    final fd = secureOpen(path);
    try {
      if (_truncate(fd, 0) != 0)
        throw const GitException(GitErrorCode.commandFailed);
      writeAndFlush(fd, bytes);
    } finally {
      close(fd);
    }
  }

  static void writeAndFlush(int fd, Uint8List bytes) {
    final raw = calloc<Uint8>(bytes.length);
    try {
      raw.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final written = _write(fd, raw + offset, bytes.length - offset);
        if (written <= 0) throw const GitException(GitErrorCode.commandFailed);
        offset += written;
      }
      if (_fsync(fd) != 0) throw const GitException(GitErrorCode.commandFailed);
    } finally {
      calloc.free(raw);
    }
  }
}
