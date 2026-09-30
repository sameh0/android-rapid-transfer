// All of CUsbfs is static inline in include/cusbfs.h; this file only gives
// SwiftPM a compilation unit. The header is empty on non-Linux platforms.
#include "cusbfs.h"

// Keeps the translation unit non-empty where the header contributes nothing.
typedef int cusbfs_translation_unit_is_not_empty;
