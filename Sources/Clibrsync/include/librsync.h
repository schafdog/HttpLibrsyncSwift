#ifndef CLIBRSYNC_WRAPPER_H
#define CLIBRSYNC_WRAPPER_H

// Umbrella header that includes the system librsync header
// This allows us to use the system-installed librsync while
// keeping the module structure flexible across platforms

#if __has_include(<librsync/librsync.h>)
#include <librsync/librsync.h>
#else
#include <librsync.h>
#endif

#endif /* CLIBRSYNC_WRAPPER_H */
