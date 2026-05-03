/*
 * Android Blob Utility
 *
 * Copyright (c) 2026 Eliminater74
 * Copyright (c) 2014 JackpotClavin (original author)
 *
 * SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

#ifndef _ANDROID_BLOB_UTILITY_H_
#define _ANDROID_BLOB_UTILITY_H_

#define _GNU_SOURCE
#include <stdlib.h>

#define MAX_LIB_NAME 128
#define ALL_LIBS_SIZE 131072 /* 128KB — modern Android has far more libraries */

/* #define DEBUG */

/* Change value below to match your /system dump's SDK version. */
/* See: https://developer.android.com/guide/topics/manifest/uses-sdk-element.html#ApiLevels */
#define SYSTEM_DUMP_SDK_VERSION 19 /* Android KitKat */

#define SYSTEM_DUMP_ROOT "/home/android/system_dump"

#define SYSTEM_VENDOR "manufacturer"
#define SYSTEM_DEVICE "device"

/*
 * Search directories for proprietary blobs, checked in order.
 * Covers pre-Treble /system/vendor/, post-Treble /vendor/ (SDK 26+),
 * and APEX module paths (SDK 29+).
 */
const char *blob_directories[] = {
    /* Vendor partition (post-Treble, Android 8.0+) */
    "/vendor/lib64/egl/",
    "/vendor/lib/egl/",
    "/vendor/lib64/hw/",
    "/vendor/lib/hw/",
    "/vendor/lib64/",
    "/vendor/lib/",
    "/vendor/bin/",
    /* APEX modules (Android 10+, SDK 29+) */
    "/apex/com.android.art/lib64/",
    "/apex/com.android.art/lib/",
    "/apex/com.android.i18n/lib64/",
    "/apex/com.android.i18n/lib/",
    "/apex/com.android.media/lib64/",
    "/apex/com.android.media/lib/",
    "/apex/com.android.media.swcodec/lib64/",
    "/apex/com.android.media.swcodec/lib/",
    "/apex/com.android.neuralnetworks/lib64/",
    "/apex/com.android.neuralnetworks/lib/",
    "/apex/com.android.os.statsd/lib64/",
    "/apex/com.android.os.statsd/lib/",
    "/apex/com.android.runtime/lib64/",
    "/apex/com.android.runtime/lib/",
    "/apex/com.android.tethering/lib64/",
    "/apex/com.android.tethering/lib/",
    /* System partition */
    "/lib64/egl/",
    "/lib/egl/",
    "/lib64/hw/",
    "/lib/hw/",
    "/lib64/",
    "/lib/",
    "/usr/lib/",
    "/usr/lib/alsa-lib/",
    "/bin/",
    NULL
};

const char *lib_beginning = "lib";
const char *egl_beginning = "egl";

const char *lib_ending = ".so";

#endif /* _ANDROID_BLOB_UTILITY_H_ */
