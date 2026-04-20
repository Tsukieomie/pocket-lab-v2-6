/*
 * getcwd_fix.c — LD_PRELOAD shim for iSH chroot getcwd() path correction
 * Pocket Security Lab v2.8
 *
 * Problem:
 *   iSH 4.20.69 chroot is not a true namespace-isolated chroot.
 *   The getcwd() syscall returns the HOST path (e.g. /mnt/debian/tmp/myrepo)
 *   instead of the chroot-relative path (/tmp/myrepo).
 *   Alpine git reads this path for safe.directory and worktree validation,
 *   then tries to stat() it from inside the chroot — where it resolves to
 *   /mnt/debian/mnt/debian/tmp/myrepo (nonexistent) → fatal error.
 *
 * Fix:
 *   Override getcwd() to strip the /mnt/debian prefix before returning.
 *   Compiled with Alpine gcc (musl) so it works inside the musl chroot context.
 *
 * Build (on Alpine/iSH host):
 *   gcc -shared -fPIC -nostartfiles -o libgetcwd_fix.so getcwd_fix.c
 *   cp libgetcwd_fix.so /mnt/debian/usr/local/musl/lib/
 *
 * Usage (in wrapper scripts):
 *   export LD_PRELOAD=/usr/local/musl/lib/libgetcwd_fix.so
 */

#define _GNU_SOURCE
#include <stddef.h>
#include <string.h>

#define CHROOT_PREFIX "/mnt/debian"
#define PREFIX_LEN    11

char *getcwd(char *buf, size_t size) {
    long ret = 0;

    /* Direct syscall 183 (getcwd, x86 32-bit) to avoid infinite recursion */
    __asm__ volatile (
        "mov $183, %%eax\n"
        "mov %1, %%ebx\n"
        "mov %2, %%ecx\n"
        "int $0x80\n"
        "mov %%eax, %0\n"
        : "=r"(ret)
        : "r"(buf), "r"(size)
        : "eax", "ebx", "ecx"
    );

    if (ret < 0) return (char *)0;

    /* Strip /mnt/debian prefix if present */
    if (buf && strncmp(buf, CHROOT_PREFIX, PREFIX_LEN) == 0) {
        size_t full_len = strlen(buf);
        size_t remaining = full_len - PREFIX_LEN;

        if (remaining == 0) {
            buf[0] = '/';
            buf[1] = '\0';
        } else if (buf[PREFIX_LEN] == '/') {
            memmove(buf, buf + PREFIX_LEN, remaining + 1);
        }
    }

    return buf;
}
