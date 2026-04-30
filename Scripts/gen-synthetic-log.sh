#!/usr/bin/env bash
# gen-synthetic-log.sh — regenerate test-data/perf/synthetic-100k.log
#
# Produces a 100K-line dated-syslog fixture for perf benchmarking. Stable
# (no random clock state — uses a sequential timestamp) so timing
# comparisons across runs and machines are meaningful.
#
# Format mirrors install.log shape: "YYYY-MM-DD HH:MM:SS-05 host process[pid]: message"
# Mixed levels (info/warn/error) in realistic ratios (~95% info, 4% warn, 1% error).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=test-data/perf/synthetic-100k.log

awk 'BEGIN {
    # Start timestamp: 2026-01-01 00:00:00-05
    base_year = 2026; base_mon = 1; base_day = 1
    base_hour = 0; base_min = 0; base_sec = 0

    procs[1] = "softwareupdated"
    procs[2] = "Installer Progress"
    procs[3] = "loginwindow"
    procs[4] = "kernel"
    procs[5] = "syslogd"
    procs[6] = "diskmanagementd"
    procs[7] = "WindowServer"
    procs[8] = "launchd"

    msgs_info[1] = "operation completed successfully"
    msgs_info[2] = "starting periodic maintenance"
    msgs_info[3] = "registered with the system"
    msgs_info[4] = "received heartbeat from peer"
    msgs_info[5] = "cache invalidated; rebuilding"
    msgs_info[6] = "session ended cleanly"
    msgs_info[7] = "configuration loaded from disk"

    msgs_warn[1] = "WARN: retrying after transient failure"
    msgs_warn[2] = "WARNING: deprecated API usage"
    msgs_warn[3] = "Warning: throttling enabled"

    msgs_err[1] = "ERROR: failed to acquire lock"
    msgs_err[2] = "ERROR: connection refused (errno 61)"
    msgs_err[3] = "CRITICAL: out of memory"

    srand(42)  # deterministic
    for (i = 1; i <= 100000; i++) {
        # advance ~30s per row (so 100K rows span ~35 days)
        ts_sec = i * 30
        h = base_hour + int(ts_sec / 3600) % 24
        m = base_min + int(ts_sec / 60) % 60
        s = base_sec + ts_sec % 60
        d = base_day + int(ts_sec / 86400)
        # roll month at day 30 to keep things tidy (no leap year math)
        mo = base_mon + int(d / 30)
        d_in_mo = d % 30
        if (d_in_mo == 0) d_in_mo = 30
        if (mo > 12) mo = ((mo - 1) % 12) + 1
        yr = base_year + int((base_mon - 1 + int(d / 30)) / 12)

        proc = procs[1 + int(rand() * 8)]
        pid = 100 + int(rand() * 9000)

        roll = rand()
        if (roll < 0.95) {
            msg = msgs_info[1 + int(rand() * 7)]
        } else if (roll < 0.99) {
            msg = msgs_warn[1 + int(rand() * 3)]
        } else {
            msg = msgs_err[1 + int(rand() * 3)]
        }

        printf "%04d-%02d-%02d %02d:%02d:%02d-05 host %s[%d]: %s\n", \
            yr, mo, d_in_mo, h, m, s, proc, pid, msg
    }
}' > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines, $(du -h "$OUT" | cut -f1))"
