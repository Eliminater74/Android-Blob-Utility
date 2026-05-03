/*
 * compat/mman-win32.h — minimal POSIX mmap/munmap/memmem for Windows (MinGW)
 *
 * Provides the small subset of POSIX memory-mapping and string-search APIs
 * that android-blob-utility uses, implemented on top of the Win32 API.
 * Only included when compiling for Windows (_WIN32).
 *
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Eliminater74
 */

#ifndef COMPAT_MMAN_WIN32_H
#define COMPAT_MMAN_WIN32_H

#ifdef _WIN32

#include <windows.h>
#include <io.h>        /* _get_osfhandle, _access */
#include <string.h>    /* memcmp */
#include <stddef.h>    /* size_t */

/* ---- mmap constants (only the ones we actually use) ---- */
#ifndef PROT_READ
#define PROT_READ   0x1
#endif
#ifndef MAP_PRIVATE
#define MAP_PRIVATE 0x2
#endif
#ifndef MAP_FAILED
#define MAP_FAILED  ((void *)-1)
#endif

/*
 * mmap — read-only file mapping via Win32 CreateFileMapping/MapViewOfFile.
 * addr, prot, flags, and offset are accepted but ignored; we always map
 * the whole file read-only from the start, which is all this program needs.
 */
static inline void *mmap(void *addr, size_t length, int prot, int flags,
                          int fd, long offset)
{
    (void)addr; (void)prot; (void)flags; (void)offset;

    HANDLE hFile = (HANDLE)_get_osfhandle(fd);
    if (hFile == INVALID_HANDLE_VALUE)
        return MAP_FAILED;

    HANDLE hMapping = CreateFileMapping(hFile, NULL, PAGE_READONLY, 0, 0, NULL);
    if (!hMapping)
        return MAP_FAILED;

    void *ptr = MapViewOfFile(hMapping, FILE_MAP_READ, 0, 0, length);
    CloseHandle(hMapping);  /* safe; the view keeps the mapping alive */

    return ptr ? ptr : MAP_FAILED;
}

/* munmap — release a view obtained from mmap above */
static inline int munmap(void *addr, size_t length)
{
    (void)length;
    return UnmapViewOfFile(addr) ? 0 : -1;
}

/*
 * memmem — locate a byte sequence within a memory region.
 * GNU extension; not provided by MinGW-w64.
 */
static inline void *memmem(const void *haystack, size_t haystacklen,
                             const void *needle,   size_t needlelen)
{
    const char *h = (const char *)haystack;
    const char *n = (const char *)needle;

    if (needlelen == 0)
        return (void *)haystack;
    if (haystacklen < needlelen)
        return NULL;

    for (size_t i = 0; i <= haystacklen - needlelen; i++)
        if (memcmp(h + i, n, needlelen) == 0)
            return (void *)(h + i);

    return NULL;
}

/* access() is _access() under MSVC but MinGW maps it — include the header */
#include <io.h>
#ifndef F_OK
#define F_OK 0
#endif

#endif /* _WIN32 */
#endif /* COMPAT_MMAN_WIN32_H */
