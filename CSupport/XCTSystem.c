#include "XCTSystem.h"
#include <fcntl.h>
#include <stdio.h>
int XCTSwapPaths(const char *s, const char *t) { return renamex_np(s, t, RENAME_SWAP); }
int XCTMoveExclusive(const char *s, const char *t) { return renamex_np(s, t, RENAME_EXCL); }
#include <sys/stat.h>
int XCTOpenReadOnly(const char *path) { return open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC); }
int XCTModeIsRegular(uint32_t mode) { return S_ISREG(mode); }
int XCTModeIsSymlink(uint32_t mode) { return S_ISLNK(mode); }

#include <sys/clonefile.h>
int XCTCloneFile(int sourceFD, const char *destination) { return fclonefileat(sourceFD, AT_FDCWD, destination, 0); }

int XCTModeIsDirectory(uint32_t mode) { return S_ISDIR(mode); }

// Keep POSIX openat in C; older iOS runtimes lack the Swift 6.2 Darwin overlay.
int XCTOpenDirectoryAt(int parent, const char *name) {
    return openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}
