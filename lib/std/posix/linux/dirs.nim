# Private implementation included by std/posix/posix; not a standalone module.

when defined(android):
  # Android defines both `linux` and `android`, so `posix.nim` includes this
  # file. Bionic is a Linux libc, but it does NOT export `getdents64`: the
  # symbol is not public, so binding it produced an object that fails to LINK
  # (`undefined symbol: getdents64`) rather than one that fails at run time.
  # It does export the real `opendir`/`readdir`/`closedir`, and its
  # `struct dirent` is the same 64-bit-inode record the glibc path parses by
  # hand (`dirent.h`: `dirent` is `dirent64` on every Android ABI), so Android
  # implements the `DirStream` interface with those calls instead.
  type
    Dirent* {.pure.} = object ## Bionic `struct dirent` (64-bit inode)
      d_ino: uint64             # offset 0
      d_off: int64              # 8
      d_reclen: uint16          # 16
      d_type*: uint8            # 18
      d_name*: array[256, char] # 19

    DirStream* = object
      ## An open directory. Not open (closed, or `openDirStream` failed) when
      ## `stream` is nil.
      stream: nil pointer

  proc libcOpendir(name: cstring): nil pointer {.importc: "opendir", sideEffect.}
  proc libcReaddir(dirp: pointer): nil ptr Dirent {.importc: "readdir", sideEffect.}
  proc libcClosedir(dirp: pointer): cint {.importc: "closedir", sideEffect.}

  proc openDirStream*(d: var DirStream; path: cstring): clong {.sideEffect.} =
    ## Opens the directory `path`. Returns 0, or -errno.
    d.stream = libcOpendir(path)
    result = if d.stream == nil: -clong(errno()) else: 0

  proc nextDirEntry*(d: var DirStream; name: var cstring; dType: var uint8): clong {.sideEffect.} =
    ## Reads the next entry: 1 with `name` and `dType` set, 0 at the end, or
    ## -errno. `name` points into Bionic's buffer and is valid until the next
    ## call.
    let stream = d.stream
    if stream == nil:
      result = -clong(EBADF)
    else:
      # `readdir` returns nil both at the end and on an error and tells them
      # apart only through errno, so errno has to start out clear.
      setErrno 0
      let e = libcReaddir(stream)
      if e == nil:
        result = -clong(errno())
      else:
        name = cast[cstring](addr e.d_name[0])
        dType = e.d_type
        result = 1

  proc closeDirStream*(d: var DirStream): clong {.sideEffect.} =
    ## Closes `d`. Returns 0, or -errno. Closing a stream that is not open
    ## does nothing.
    let stream = d.stream
    if stream == nil:
      result = 0
    else:
      result = pcall(libcClosedir(stream))
      d.stream = nil
else:
  # Linux `getdents64`; exported by glibc (2.30+) and musl, and lowered to
  # the raw syscall by arkham. Each record is a `struct linux_dirent64`:
  #   d_ino @0 (u64), d_off @8 (s64), d_reclen @16 (u16),
  #   d_type @18 (u8), d_name @19 (NUL-terminated, variable length).
  proc getdents64(fd: cint; dirp: pointer; count: int): clong {.importc: "getdents64", sideEffect.}

  proc readDirRecords(fd: cint; buf: pointer; size: int; cookie: ptr Off): clong {.sideEffect.} =
    pcall(getdents64(fd, buf, size))

  const
    direntReclenAt* = 16
    direntTypeAt* = 18
    direntNameAt* = 19
    direntSkipsZeroIno* = false

  include "../dirbuf"
