# Private implementation included by std/posix/posix; not a standalone module.

# Android is EXCLUDED on purpose, and this file is the whole of that
# platform's difference. Bionic is a Linux libc in the sense that
# `defined(linux)` is set, but it does NOT export `getdents64`: it is not among
# its public symbols, so binding it here produced an object that fails to LINK
# (`undefined symbol: getdents64`) rather than one that fails at run time.
# Bionic does export the real `opendir`/`readdir`/`closedir`, and its
# `struct dirent` is the same 64-bit-inode record the code below parses by hand,
# so the branch at the bottom uses those instead.
#
# The exclusion has to live HERE rather than in `posix.nim`'s dispatch: Android
# does satisfy `defined(linux)`, so it selects this include.
when defined(android):
  type
    Dirent* {.pure.} = object ## Bionic `struct dirent`, 64-bit inode
      d_ino: uint64           # offset 0
      d_off: int64            # 8
      d_reclen: uint16        # 16
      d_type*: uint8          # 18
      d_name*: array[256, char] # 19

    DIR* {.pure.} = object ## opaque libc directory stream; only ever
                           ## handled by pointer, never dereferenced here
      opaque: pointer

  # Bionic's `readdir` returns a pointer into libc's own buffer, valid until the
  # next call, and skips the deleted-entry slots the glibc version has to filter
  # itself. `std/dirs` reads `d_name` immediately, so handing the pointer back is
  # correct here.
  proc opendir*(name: cstring): nil ptr DIR {.importc: "opendir", sideEffect.}
  proc readdir*(dirp: nil ptr DIR): nil ptr Dirent {.importc: "readdir", sideEffect.}
  proc closedir*(dirp: nil ptr DIR): cint {.importc: "closedir", sideEffect.}
else:
  # `opendir`/`readdir`/`closedir` are libc functions (`DIR` is an opaque libc
  # buffer), not syscalls, so on Linux they are reimplemented on top of
  # open(2) + getdents64(2) + close(2) for every configuration. `Dirent`
  # keeps the same two fields (`d_type`, `d_name`) the consumers read, but
  # with a native layout — its bytes are copied out of the raw
  # `struct linux_dirent64` records.
  const
    dentBufSize = 4096

  type
    Dirent* {.pure.} = object
      d_type*: uint8
      d_name*: array[256, char]

    DIR* {.pure.} = object
      fd: cint
      bpos: int32        ## read cursor into `buf`
      nread: int32       ## valid bytes currently in `buf`
      ent: Dirent        ## scratch entry returned by `readdir`
      buf: array[dentBufSize, byte]

  # Linux `getdents64`; exported by glibc (2.30+) and musl, and lowered to
  # the raw syscall by arkham.
  proc getdents64(fd: cint; dirp: pointer; count: int): clong {.importc: "getdents64", sideEffect.}

  proc opendir*(name: cstring): nil ptr DIR {.sideEffect.} =
    let fd = open(name, O_RDONLY or O_DIRECTORY or O_CLOEXEC)
    if fd < 0:
      setErrno cint(-fd)
      return nil
    result = cast[ptr DIR](alloc0(sizeof(DIR)))
    result.fd = fd
    result.bpos = 0
    result.nread = 0

  proc closedir*(dirp: nil ptr DIR): cint {.sideEffect.} =
    if dirp == nil:
      setErrno EBADF
      return cint(-1)
    let fd = dirp.fd
    dealloc(dirp)
    result = close(fd)

  proc readdir*(dirp: nil ptr DIR): nil ptr Dirent {.sideEffect.} =
    if dirp == nil:
      setErrno EBADF
      return nil
    while true:
      if dirp.bpos >= dirp.nread:
        let n = pcall(getdents64(dirp.fd, addr dirp.buf[0], dentBufSize))
        if n < 0:
          setErrno cint(int(-n))
          return nil
        if n == 0:
          setErrno cint(0)  # genuine end of directory
          return nil
        dirp.nread = int32(n)
        dirp.bpos = 0
      # One `struct linux_dirent64` starts at buf[bpos]:
      #   d_ino  @0 (u64), d_off @8 (s64), d_reclen @16 (u16),
      #   d_type @18 (u8), d_name @19 (NUL-terminated, variable length).
      let base = cast[uint](addr dirp.buf[0]) + uint(dirp.bpos)
      let reclen = cast[ptr uint16](base + 16'u)[]
      dirp.ent.d_type = cast[ptr uint8](base + 18'u)[]
      let namePtr = cast[ptr UncheckedArray[char]](base + 19'u)
      dirp.bpos += int32(reclen)
      var i = 0
      while i < 255 and namePtr[i] != '\0':
        dirp.ent.d_name[i] = namePtr[i]
        inc i
      dirp.ent.d_name[i] = '\0'
      return addr dirp.ent
