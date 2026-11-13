#ifndef XCT_SYSTEM_H
#define XCT_SYSTEM_H
#include <stdint.h>
#include <CommonCrypto/CommonDigest.h>
int XCTSwapPaths(const char *source, const char *target);
int XCTMoveExclusive(const char *source, const char *target);
int XCTOpenReadOnly(const char *path);
int XCTCloneFile(int sourceFD, const char *destination);
int XCTModeIsDirectory(uint32_t mode);
int XCTOpenDirectoryAt(int parent, const char *name);
int XCTModeIsRegular(uint32_t mode);
int XCTModeIsSymlink(uint32_t mode);
#endif
