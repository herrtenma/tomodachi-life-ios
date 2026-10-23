#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <syslog.h>
#endif

#include "nxrt.h"

// One write per line: separate vfprintf + fputc calls interleaved lines across threads.
void nx_log(const char *fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf - 1, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof buf - 2) n = sizeof buf - 2;
    buf[n++] = '\n';
    fwrite(buf, 1, n, stderr);
#if TARGET_OS_IPHONE
    // Also the device log: readable live over USB (idevicesyslog -p nxrt), the file is Documents/nxrt.log.
    buf[n - 1] = 0;
    syslog(LOG_NOTICE, "%s", buf);
#endif
}

_Noreturn void nx_fatal(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("FATAL: ", stderr);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
#if TARGET_OS_IPHONE
    va_start(ap, fmt);
    char buf[1024];
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    syslog(LOG_ERR, "FATAL: %s", buf);
#endif
    exit(1);
}
