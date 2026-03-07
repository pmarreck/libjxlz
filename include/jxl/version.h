/* Copyright (c) the JPEG XL Project Authors. All rights reserved.
 *
 * Use of this source code is governed by a BSD-style
 * license that can be found in the LICENSE file.
 */

#ifndef JXL_VERSION_H_
#define JXL_VERSION_H_

#if defined(JPEGXL_MAJOR_VERSION) || defined(JPEGXL_MINOR_VERSION) || \
	defined(JPEGXL_PATCH_VERSION)
#error JPEGXL_VERSION is already defined
#endif

#define JPEGXL_MAJOR_VERSION 0
#define JPEGXL_MINOR_VERSION 1
#define JPEGXL_PATCH_VERSION 0

#define JPEGXL_COMPUTE_NUMERIC_VERSION(major, minor, patch) \
	(((major) << 24) | ((minor) << 16) | ((patch) << 8) | 0)

#define JPEGXL_NUMERIC_VERSION \
	JPEGXL_COMPUTE_NUMERIC_VERSION(JPEGXL_MAJOR_VERSION, JPEGXL_MINOR_VERSION, JPEGXL_PATCH_VERSION)

#endif
