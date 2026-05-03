/*
 * compat/mman-win32.h — POSIX compatibility shim for Windows (MinGW)
 *
 * Provides mmap/munmap, memmem, and getline — all POSIX/GNU extensions
 * that MinGW-w64 does not ship — implemented with Win32 APIs and standard C.
 * Included only when _WIN32 is defined.
 *
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Eliminater74
 */

#ifndef COMPAT_MMAN_WIN32_H
#define COMPAT_MMAN_WIN32_H

#ifdef _WIN32

#include <windows.h>
#include <io.h>        /* _get_osfhandle, _access */
#include <stdio.h>     /* FILE, fgetc */
#include <stdlib.h>    /* malloc, realloc */
#include <string.h>    /* memcmp */
#include <stddef.h>    /* size_t, ptrdiff_t */

/* ssize_t is not defined on Windows */
#ifndef _SSIZE_T_DEFINED
#define _SSIZE_T_DEFINED
typedef long long ssize_t;
#endif

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
    size_t i;

    if (needlelen == 0)
        return (void *)haystack;
    if (haystacklen < needlelen)
        return NULL;

    for (i = 0; i <= haystacklen - needlelen; i++)
        if (memcmp(h + i, n, needlelen) == 0)
            return (void *)(h + i);

    return NULL;
}

/*
 * getline — read a line from a stream, growing the buffer as needed.
 * POSIX.1-2008 extension; not in MinGW-w64's msvcrt.dll.
 */
static inline ssize_t getline(char **lineptr, size_t *n, FILE *stream)
{
    size_t pos = 0;
    int c;

    if (!lineptr || !n || !stream)
        return -1;

    if (!*lineptr || *n == 0) {
        *n = 128;
        *lineptr = (char *)malloc(*n);
        if (!*lineptr)
            return -1;
    }

    while ((c = fgetc(stream)) != EOF) {
        /* grow buffer if needed (leave room for '\0') */
        if (pos + 1 >= *n) {
            size_t new_size = *n * 2;
            char *tmp = (char *)realloc(*lineptr, new_size);
            if (!tmp)
                return -1;
            *lineptr = tmp;
            *n = new_size;
        }
        (*lineptr)[pos++] = (char)c;
        if (c == '\n')
            break;
    }

    if (pos == 0 && c == EOF)
        return -1;

    (*lineptr)[pos] = '\0';
    return (ssize_t)pos;
}

/* F_OK for access() */
#ifndef F_OK
#define F_OK 0
#endif

#endif /* _WIN32 */
#endif /* COMPAT_MMAN_WIN32_H */
