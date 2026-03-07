#ifndef JXL_EXPORT_H
#define JXL_EXPORT_H

#ifdef JXL_STATIC_DEFINE
#	define JXL_EXPORT
#	define JXL_NO_EXPORT
#else
#	ifndef JXL_EXPORT
#		define JXL_EXPORT __attribute__((visibility("default")))
#	endif
#	ifndef JXL_NO_EXPORT
#		define JXL_NO_EXPORT __attribute__((visibility("hidden")))
#	endif
#endif

#ifndef JXL_DEPRECATED
#	define JXL_DEPRECATED __attribute__((__deprecated__))
#endif

#ifndef JXL_DEPRECATED_EXPORT
#	define JXL_DEPRECATED_EXPORT JXL_EXPORT JXL_DEPRECATED
#endif

#ifndef JXL_DEPRECATED_NO_EXPORT
#	define JXL_DEPRECATED_NO_EXPORT JXL_NO_EXPORT JXL_DEPRECATED
#endif

#endif
