/*
 * getcwd_fix_nodeps.c - zero-dependency LD_PRELOAD getcwd shim
 * Works with both musl AND glibc programs (no libc linkage).
 */
#define _GNU_SOURCE

/* memmove - implement inline to avoid libc dep */
static void *my_memmove(void *dst, const void *src, unsigned long n) {
    char *d = (char *)dst;
    const char *s = (const char *)src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n; s += n;
        while (n--) *--d = *--s;
    }
    return dst;
}

static unsigned long my_strlen(const char *s) {
    const char *p = s;
    while (*p) p++;
    return p - s;
}

static int my_strncmp(const char *a, const char *b, unsigned long n) {
    while (n-- && *a && (*a == *b)) { a++; b++; }
    return n == (unsigned long)-1 ? 0 : (unsigned char)*a - (unsigned char)*b;
}

#define CHROOT_PREFIX "/mnt/debian"
#define PREFIX_LEN    11

/* Override getcwd for BOTH musl and glibc programs */
char *getcwd(char *buf, unsigned long size) {
    long ret;
    __asm__ volatile (
        "mov $183, %%eax\n\t"
        "mov %1, %%ebx\n\t"
        "mov %2, %%ecx\n\t"
        "int $0x80\n\t"
        "mov %%eax, %0"
        : "=r"(ret)
        : "r"(buf), "r"(size)
        : "eax", "ebx", "ecx", "memory"
    );
    if (ret < 0) return (char *)0;

    if (buf && my_strncmp(buf, CHROOT_PREFIX, PREFIX_LEN) == 0) {
        unsigned long full_len = my_strlen(buf);
        unsigned long remaining = full_len - PREFIX_LEN;
        if (remaining == 0) {
            buf[0] = '/'; buf[1] = '\0';
        } else if (buf[PREFIX_LEN] == '/') {
            my_memmove(buf, buf + PREFIX_LEN, remaining + 1);
        }
    }
    return buf;
}

/* Also override __getcwd used internally by some glibc versions */
char *__getcwd(char *buf, unsigned long size) __attribute__((alias("getcwd")));
