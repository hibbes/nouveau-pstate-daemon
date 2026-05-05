# Event-Driven Redesign v0.2.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 2s-polling load-based daemon with an event-driven architecture (swayidle + small root helper + boot-time pinning service) so that `/sys/kernel/debug/dri/0/pstate` is written only on actual user-activity transitions instead of on every load-curve crossing. The new design eliminates the kernel WARN-loop trigger after Chrome graphics faults without requiring out-of-tree kernel patches.

**Architecture:**
- **Boot-time pinning** via OpenRC oneshot service: writes a configurable safe pstate (default `0e`) at boot and on stop. No daemon loop.
- **User-session bridge** via swayidle (`ext-idle-notify-v1`) launched from labwc autostart. swayidle calls a tiny privileged helper (`nv-pstate`) on idle/resume/lock/unlock/sleep events. Helper writes pstate via `/sys/kernel/debug/dri/0/pstate`, gated by a sudoers fragment.
- **Idle-inhibitor compatibility**: video players (mpv, Firefox) that set `zwp_idle_inhibitor_v1` keep the session in the active pstate even without keystrokes. labwc honors the protocol.

**Tech Stack:** bash (POSIX-compatible where reasonable), OpenRC, swayidle (>= 1.8), sudo, shellcheck (static analysis), make (install/uninstall).

**Repo:** `~/nouveau-pstate-daemon` (public, GitHub `hibbes/nouveau-pstate-daemon`). Currently at v0.1.0.

**Branch:** `event-driven-v0.2.0` (new feature branch off `main`).

---

## File Structure

| Path | Status | Purpose |
|---|---|---|
| `bin/nv-pstate` | NEW | Root helper: validates input, optional dmesg pre-check, writes pstate file |
| `bin/nouveau-pstate-swayidle` | NEW | User-session swayidle launcher (delegates to `sudo nv-pstate`) |
| `openrc/init.d/nouveau-pstate-daemon` | REWRITE | Oneshot pinning service (no longer a polling daemon) |
| `openrc/conf.d/nouveau-pstate-daemon` | REWRITE | Just `BOOT_PSTATE=0e` |
| `config/sudoers.d/nouveau-pstate` | NEW | `%nouveau-pstate ALL=(root) NOPASSWD: /usr/local/bin/nv-pstate` |
| `config/labwc-autostart-snippet.sh` | NEW | Example drop-in for `~/.config/labwc/autostart` |
| `Makefile` | NEW | `install`, `uninstall`, `check` (shellcheck), `test` (smoke) targets |
| `CHANGELOG.md` | NEW | v0.2.0 entry + retroactive v0.1.0 |
| `README.md` | REWRITE | Architecture, install steps, swayidle integration, breaking changes from v0.1.0 |
| `bin/nouveau-pstate-daemon` | REMOVE | The polling daemon is obsolete; functionality split between init.d and swayidle bridge |
| `tests/test_nv-pstate.sh` | NEW | Smoke test against a tempfile-mocked PSTATE_FILE |

---

## Task 0: Branch + Plan File Setup

**Files:**
- Verify: `~/nouveau-pstate-daemon/docs/superpowers/plans/2026-05-03-event-driven-redesign-v0.2.0.md` (this file)

- [ ] **Step 1: Create feature branch off main**

```bash
cd ~/nouveau-pstate-daemon
git checkout main
git pull --ff-only origin main
git checkout -b event-driven-v0.2.0
```

Expected: clean branch, working tree clean.

- [ ] **Step 2: Commit plan file**

```bash
git add docs/superpowers/plans/2026-05-03-event-driven-redesign-v0.2.0.md
git commit -m "docs: add v0.2.0 implementation plan"
```

---

## Task 1: `bin/nv-pstate` — privileged write helper

**Files:**
- Create: `bin/nv-pstate`
- Test: `tests/test_nv-pstate.sh`

**Responsibility.** Validate the input pstate (allowlist `0e`, `03`, plus `auto`/`force_auto` for completeness). Optionally check dmesg for recent fault evidence and skip the write if found (best-effort, non-fatal). Write to `${PSTATE_FILE:-/sys/kernel/debug/dri/0/pstate}`. Log to `${LOG_FILE:-/var/log/nouveau-pstate.log}`. Maintain `/run/nouveau-pstate.state` for status integration. Exit 0 on success, non-zero on fail.

- [ ] **Step 1: Write the smoke test first**

Create `tests/test_nv-pstate.sh`:

```bash
#!/bin/bash
# Smoke test for bin/nv-pstate. Mocks PSTATE_FILE and LOG_FILE via env.
# Exit 0 on all-pass, 1 on any failure.

set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
NV="$ROOT/bin/nv-pstate"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PSTATE="$WORK/pstate"
LOG="$WORK/nouveau-pstate.log"
STATE="$WORK/state"
: > "$PSTATE"

fail=0

run() {
    PSTATE_FILE="$PSTATE" LOG_FILE="$LOG" STATE_FILE="$STATE" \
        DMESG_CHECK_DISABLE=1 "$NV" "$@"
}

# 1. valid pstate writes file
run 0e || { echo "FAIL: 0e write returned non-zero"; fail=1; }
[[ "$(cat "$PSTATE")" == "0e" ]] || { echo "FAIL: 0e not in PSTATE_FILE"; fail=1; }

# 2. another valid pstate
run 03 || { echo "FAIL: 03 write returned non-zero"; fail=1; }
[[ "$(cat "$PSTATE")" == "03" ]] || { echo "FAIL: 03 not in PSTATE_FILE"; fail=1; }

# 3. invalid pstate is rejected (nonzero exit, file unchanged)
run deadbeef && { echo "FAIL: invalid pstate accepted"; fail=1; }
[[ "$(cat "$PSTATE")" == "03" ]] || { echo "FAIL: PSTATE_FILE mutated by invalid input"; fail=1; }

# 4. STATE_FILE reflects last value
[[ "$(cat "$STATE")" == "03" ]] || { echo "FAIL: STATE_FILE not updated"; fail=1; }

# 5. log file received entries
[[ -s "$LOG" ]] || { echo "FAIL: LOG_FILE empty"; fail=1; }

# 6. duplicate write is debounced (no extra log line)
lines_before=$(wc -l < "$LOG")
run 03 || { echo "FAIL: idempotent 03 write returned non-zero"; fail=1; }
lines_after=$(wc -l < "$LOG")
[[ "$lines_after" -eq "$lines_before" ]] || { echo "FAIL: duplicate write not debounced (before=$lines_before after=$lines_after)"; fail=1; }

if [[ $fail -eq 0 ]]; then
    echo "PASS: all nv-pstate smoke tests"
    exit 0
else
    exit 1
fi
```

Make executable:

```bash
chmod +x tests/test_nv-pstate.sh
```

- [ ] **Step 2: Run the test to confirm it fails (no nv-pstate yet)**

```bash
./tests/test_nv-pstate.sh
```

Expected: FAIL — `bin/nv-pstate` does not exist.

- [ ] **Step 3: Implement `bin/nv-pstate`**

Create `bin/nv-pstate`:

```bash
#!/bin/bash
# nv-pstate: privileged write helper for /sys/kernel/debug/dri/0/pstate.
# Called from boot-pinning service or user-session swayidle bridge via sudo.
#
# Usage: nv-pstate <pstate>
#   pstate ::= 0e | 03 | auto | force_auto
#
# Env overrides (testing):
#   PSTATE_FILE          target file (default /sys/kernel/debug/dri/0/pstate)
#   LOG_FILE             append-log (default /var/log/nouveau-pstate.log)
#   STATE_FILE           last-state cache (default /run/nouveau-pstate.state)
#   DMESG_CHECK_DISABLE  if set non-empty, skip the dmesg pre-check

set -u

: "${PSTATE_FILE:=/sys/kernel/debug/dri/0/pstate}"
: "${LOG_FILE:=/var/log/nouveau-pstate.log}"
: "${STATE_FILE:=/run/nouveau-pstate.state}"
: "${DMESG_CHECK_DISABLE:=}"
: "${DMESG_LOOKBACK:=120}"

ALLOWED='^(0e|03|auto|force_auto)$'

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || \
        printf '%s\n' "$*" >&2
}

usage() {
    printf 'usage: %s <0e|03|auto|force_auto>\n' "$0" >&2
    exit 64
}

[[ $# -eq 1 ]] || usage
target=$1
[[ $target =~ $ALLOWED ]] || { log "reject: invalid pstate '$target'"; exit 64; }

# Idempotence: if last-state matches, no-op silently.
if [[ -r "$STATE_FILE" ]]; then
    last=$(cat "$STATE_FILE" 2>/dev/null || true)
    if [[ "$last" == "$target" ]]; then
        exit 0
    fi
fi

# Best-effort dmesg pre-check. Requires CAP_SYSLOG or root.
# If we see recent channel-fault / wedge evidence, skip the write to avoid
# kicking the kernel work item again on a dead engine.
if [[ -z "$DMESG_CHECK_DISABLE" ]] && command -v journalctl >/dev/null 2>&1; then
    fault=$(journalctl -k --since "${DMESG_LOOKBACK} seconds ago" --no-pager 2>/dev/null | \
        grep -E 'TRAP_CCACHE|PT_NOT_PRESENT|PAGE_NOT_PRESENT|errored - disabling channel|gt215_clk_pre' | \
        tail -1)
    if [[ -n "$fault" ]]; then
        log "skip $target: recent fault in dmesg ($fault)"
        exit 0
    fi
fi

if [[ ! -e "$PSTATE_FILE" ]]; then
    log "fatal: $PSTATE_FILE does not exist"
    exit 71
fi
if [[ ! -w "$PSTATE_FILE" ]]; then
    log "fatal: $PSTATE_FILE not writable"
    exit 77
fi

if printf '%s\n' "$target" > "$PSTATE_FILE" 2>/dev/null; then
    log "pstate -> $target"
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    printf '%s\n' "$target" > "$STATE_FILE" 2>/dev/null || true
    exit 0
fi

log "error: write '$target' to $PSTATE_FILE failed (errno=$?)"
exit 74
```

Make executable:

```bash
chmod +x bin/nv-pstate
```

- [ ] **Step 4: Run shellcheck**

```bash
shellcheck bin/nv-pstate
```

Expected: zero warnings, zero errors. Fix any issue before continuing.

- [ ] **Step 5: Run smoke test, expect pass**

```bash
./tests/test_nv-pstate.sh
```

Expected: `PASS: all nv-pstate smoke tests`.

- [ ] **Step 6: Commit**

```bash
git add bin/nv-pstate tests/test_nv-pstate.sh
git commit -m "feat(nv-pstate): privileged write helper with dmesg pre-check"
```

---

## Task 2: `bin/nouveau-pstate-swayidle` — user-session bridge

**Files:**
- Create: `bin/nouveau-pstate-swayidle`

**Responsibility.** Wrap a `swayidle` invocation with the six standard event handlers (`timeout`, `resume`, `before-sleep`, `after-resume`, `lock`, `unlock`). Each handler invokes `sudo /usr/local/bin/nv-pstate <pstate>`. Designed to be launched from `~/.config/labwc/autostart`. Reads idle-timeout from `${NOUVEAU_PSTATE_IDLE_TIMEOUT:-60}`.

- [ ] **Step 1: Write the bridge script**

Create `bin/nouveau-pstate-swayidle`:

```bash
#!/bin/bash
# nouveau-pstate-swayidle: user-session swayidle wrapper.
# Launches swayidle with handlers that toggle the GPU pstate via the privileged
# helper /usr/local/bin/nv-pstate (sudo, NOPASSWD via sudoers fragment).
#
# Designed to be started from ~/.config/labwc/autostart on Wayland sessions.
#
# Env overrides:
#   NOUVEAU_PSTATE_IDLE_TIMEOUT  seconds to idle before downclock (default 60)
#   NOUVEAU_PSTATE_IDLE          idle pstate (default 0e)
#   NOUVEAU_PSTATE_ACTIVE        active pstate (default 03)
#   NV_PSTATE_BIN                helper path (default /usr/local/bin/nv-pstate)

set -u

: "${NOUVEAU_PSTATE_IDLE_TIMEOUT:=60}"
: "${NOUVEAU_PSTATE_IDLE:=0e}"
: "${NOUVEAU_PSTATE_ACTIVE:=03}"
: "${NV_PSTATE_BIN:=/usr/local/bin/nv-pstate}"

if ! command -v swayidle >/dev/null 2>&1; then
    printf 'nouveau-pstate-swayidle: swayidle not found in PATH\n' >&2
    exit 127
fi
if [[ ! -x "$NV_PSTATE_BIN" ]]; then
    printf 'nouveau-pstate-swayidle: %s not executable\n' "$NV_PSTATE_BIN" >&2
    exit 127
fi

idle_cmd="sudo -n $NV_PSTATE_BIN $NOUVEAU_PSTATE_IDLE"
active_cmd="sudo -n $NV_PSTATE_BIN $NOUVEAU_PSTATE_ACTIVE"

exec swayidle -w \
    timeout "$NOUVEAU_PSTATE_IDLE_TIMEOUT" "$idle_cmd" \
        resume "$active_cmd" \
    before-sleep "$idle_cmd" \
    after-resume "$active_cmd" \
    lock         "$idle_cmd" \
    unlock       "$active_cmd"
```

Make executable:

```bash
chmod +x bin/nouveau-pstate-swayidle
```

- [ ] **Step 2: Run shellcheck**

```bash
shellcheck bin/nouveau-pstate-swayidle
```

Expected: zero warnings.

- [ ] **Step 3: Smoke-check it parses and rejects missing helper cleanly**

```bash
NV_PSTATE_BIN=/nonexistent ./bin/nouveau-pstate-swayidle
echo "exit=$?"
```

Expected: `nouveau-pstate-swayidle: /nonexistent not executable`, exit 127.

- [ ] **Step 4: Commit**

```bash
git add bin/nouveau-pstate-swayidle
git commit -m "feat(swayidle): user-session bridge wrapping swayidle event handlers"
```

---

## Task 3: Refactor `openrc/init.d/nouveau-pstate-daemon` to oneshot pinning service

**Files:**
- Modify: `openrc/init.d/nouveau-pstate-daemon`
- Modify: `openrc/conf.d/nouveau-pstate-daemon`

**Responsibility.** Replace the polling-daemon service definition with a oneshot service that calls `/usr/local/bin/nv-pstate ${BOOT_PSTATE}` at start and again at stop (defensive: any value of `BOOT_PSTATE` is allowed by `nv-pstate`'s allowlist; default `0e`).

- [ ] **Step 1: Rewrite `openrc/init.d/nouveau-pstate-daemon`**

Overwrite with:

```bash
#!/sbin/openrc-run
# nouveau-pstate-daemon: boot-time pstate pin (v0.2.0+).
# v0.1.0 was a polling daemon; from v0.2.0 the service only sets a safe
# pstate at boot and reasserts it on stop. The activity-driven part lives
# in the user session via bin/nouveau-pstate-swayidle.

description="Boot-time nouveau pstate pin (NVAC/Tesla)"

depend() {
    need localmount
    after sysfs
}

: "${BOOT_PSTATE:=0e}"
: "${NV_PSTATE_BIN:=/usr/local/bin/nv-pstate}"

start() {
    ebegin "Pinning nouveau pstate to $BOOT_PSTATE"
    "$NV_PSTATE_BIN" "$BOOT_PSTATE"
    eend $?
}

stop() {
    ebegin "Restoring nouveau pstate to $BOOT_PSTATE on stop"
    "$NV_PSTATE_BIN" "$BOOT_PSTATE"
    eend $?
}
```

- [ ] **Step 2: Rewrite `openrc/conf.d/nouveau-pstate-daemon`**

Overwrite with:

```bash
# nouveau-pstate-daemon configuration (v0.2.0+).
#
# BOOT_PSTATE: pstate to set at boot and on service stop.
#   0e = idle/350 MHz (energy-efficient, default)
#   03 = active/800 MHz (always-fast, no power saving)
BOOT_PSTATE=0e

# Path to the privileged write helper. Override only if you installed elsewhere.
NV_PSTATE_BIN=/usr/local/bin/nv-pstate
```

- [ ] **Step 3: Run shellcheck on init.d (with OpenRC shim awareness)**

```bash
shellcheck -s bash -e SC2034 openrc/init.d/nouveau-pstate-daemon
shellcheck openrc/conf.d/nouveau-pstate-daemon
```

Expected: zero warnings (SC2034 disabled because `description` looks unused but is consumed by openrc-run).

- [ ] **Step 4: Commit**

```bash
git add openrc/init.d/nouveau-pstate-daemon openrc/conf.d/nouveau-pstate-daemon
git commit -m "refactor(openrc): convert polling daemon to oneshot boot-pin service"
```

---

## Task 4: Sudoers fragment + labwc autostart example

**Files:**
- Create: `config/sudoers.d/nouveau-pstate`
- Create: `config/labwc-autostart-snippet.sh`

- [ ] **Step 1: Create `config/sudoers.d/nouveau-pstate`**

```bash
mkdir -p config/sudoers.d
```

Write `config/sudoers.d/nouveau-pstate`:

```
# Allow members of the 'nouveau-pstate' group to run the privileged write
# helper without a password, restricted to the helper's exact path.
#
# Install with: install -m 0440 config/sudoers.d/nouveau-pstate /etc/sudoers.d/
# After installing, add your user to the group:  usermod -aG nouveau-pstate <user>
%nouveau-pstate ALL=(root) NOPASSWD: /usr/local/bin/nv-pstate
```

- [ ] **Step 2: Create `config/labwc-autostart-snippet.sh`**

```bash
mkdir -p config
```

Write `config/labwc-autostart-snippet.sh`:

```bash
# Drop this line into your ~/.config/labwc/autostart to launch the
# nouveau-pstate swayidle bridge alongside the rest of your session.
#
# The bridge requires:
#   - /usr/local/bin/nv-pstate installed
#   - /etc/sudoers.d/nouveau-pstate installed
#   - your user in group 'nouveau-pstate'
#   - swayidle on $PATH

/usr/local/bin/nouveau-pstate-swayidle &
```

- [ ] **Step 3: Commit**

```bash
git add config/sudoers.d/nouveau-pstate config/labwc-autostart-snippet.sh
git commit -m "feat(config): sudoers fragment + labwc autostart example"
```

---

## Task 5: `Makefile` for install / uninstall / check / test

**Files:**
- Create: `Makefile`

**Responsibility.** Standard targets to install all artifacts to system paths (DESTDIR-aware), run shellcheck (`make check`), run the smoke test (`make test`), and reverse-install (`make uninstall`).

- [ ] **Step 1: Write the Makefile**

```makefile
# nouveau-pstate-daemon Makefile (v0.2.0+).
#
# Targets:
#   make install     install all artifacts (root or sudo)
#   make uninstall   reverse-install
#   make check       shellcheck all shell scripts
#   make test        smoke-test bin/nv-pstate against a tempfile
#
# Override DESTDIR / PREFIX for staged installs or non-/usr/local layouts.

PREFIX ?= /usr/local
DESTDIR ?=
BINDIR = $(DESTDIR)$(PREFIX)/bin
SUDOERSDIR = $(DESTDIR)/etc/sudoers.d
INITDIR = $(DESTDIR)/etc/init.d
CONFDIR = $(DESTDIR)/etc/conf.d

SHELLS = bin/nv-pstate bin/nouveau-pstate-swayidle openrc/init.d/nouveau-pstate-daemon

.PHONY: install uninstall check test

install:
	install -d $(BINDIR) $(SUDOERSDIR) $(INITDIR) $(CONFDIR)
	install -m 0755 bin/nv-pstate $(BINDIR)/nv-pstate
	install -m 0755 bin/nouveau-pstate-swayidle $(BINDIR)/nouveau-pstate-swayidle
	install -m 0440 config/sudoers.d/nouveau-pstate $(SUDOERSDIR)/nouveau-pstate
	install -m 0755 openrc/init.d/nouveau-pstate-daemon $(INITDIR)/nouveau-pstate-daemon
	install -m 0644 openrc/conf.d/nouveau-pstate-daemon $(CONFDIR)/nouveau-pstate-daemon
	@echo
	@echo "Install done. Next steps:"
	@echo "  groupadd -f nouveau-pstate && usermod -aG nouveau-pstate <your-user>"
	@echo "  rc-update add nouveau-pstate-daemon default"
	@echo "  rc-service nouveau-pstate-daemon start"
	@echo "  Add /usr/local/bin/nouveau-pstate-swayidle to ~/.config/labwc/autostart"

uninstall:
	rm -f $(BINDIR)/nv-pstate
	rm -f $(BINDIR)/nouveau-pstate-swayidle
	rm -f $(SUDOERSDIR)/nouveau-pstate
	rm -f $(INITDIR)/nouveau-pstate-daemon
	rm -f $(CONFDIR)/nouveau-pstate-daemon

check:
	shellcheck bin/nv-pstate bin/nouveau-pstate-swayidle
	shellcheck -s bash -e SC2034 openrc/init.d/nouveau-pstate-daemon
	shellcheck openrc/conf.d/nouveau-pstate-daemon
	shellcheck tests/test_nv-pstate.sh

test:
	./tests/test_nv-pstate.sh
```

- [ ] **Step 2: Run `make check`**

```bash
make check
```

Expected: zero warnings.

- [ ] **Step 3: Run `make test`**

```bash
make test
```

Expected: `PASS: all nv-pstate smoke tests`.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "feat(make): install/uninstall/check/test targets"
```

---

## Task 6: Remove the legacy polling daemon

**Files:**
- Delete: `bin/nouveau-pstate-daemon`

**Rationale.** The polling-daemon binary is fully replaced by the boot-pin service (init.d) plus the user-session swayidle bridge. Keeping it would advertise an obsolete usage and confuse users browsing the repo.

- [ ] **Step 1: Remove the file**

```bash
git rm bin/nouveau-pstate-daemon
```

- [ ] **Step 2: Commit**

```bash
git commit -m "refactor: drop legacy polling daemon (replaced by init.d + swayidle bridge)"
```

---

## Task 7: `CHANGELOG.md`

**Files:**
- Create: `CHANGELOG.md`

- [ ] **Step 1: Write the changelog**

```markdown
# Changelog

All notable changes to this project will be documented in this file.

## v0.2.0 — 2026-05-NN

### Architecture change

The 2 s polling daemon has been replaced by an event-driven design:

- A boot-time OpenRC oneshot pins a configurable safe pstate (default `0e`).
- A user-session `swayidle` bridge toggles between idle and active pstates on
  `ext-idle-notify-v1` events (idle timeout, resume, sleep, lock, unlock).
- A small privileged helper (`nv-pstate`) does the actual write under sudo.

### Why

The old polling daemon was the dominant trigger for a kernel WARN-loop
on Tesla / NVAC after a graphics-channel fault (e.g. Chrome triggering
TRAP_CCACHE / PT_NOT_PRESENT). Each load-curve crossing scheduled a
clock-reprogram on a wedged engine. Event-driven writes (a few per day
instead of dozens to hundreds) shrink that trigger surface to near zero
without requiring out-of-tree kernel patches.

### Added

- `bin/nv-pstate` — privileged write helper with optional dmesg pre-check
- `bin/nouveau-pstate-swayidle` — user-session swayidle bridge
- `config/sudoers.d/nouveau-pstate` — group-scoped sudoers fragment
- `config/labwc-autostart-snippet.sh` — drop-in autostart example
- `Makefile` — `install`, `uninstall`, `check`, `test` targets
- `tests/test_nv-pstate.sh` — smoke test

### Changed

- `openrc/init.d/nouveau-pstate-daemon` — now a oneshot boot-pin service,
  no longer a polling daemon. Service name preserved for upgrade compat.
- `openrc/conf.d/nouveau-pstate-daemon` — single `BOOT_PSTATE` setting.

### Removed

- `bin/nouveau-pstate-daemon` — the polling daemon binary. If you depend on
  load-based switching with no compositor, pin v0.1.0.

### Migration from v0.1.0

1. Pull v0.2.0, run `make install`.
2. `groupadd -f nouveau-pstate && usermod -aG nouveau-pstate <user>` (re-login).
3. `rc-service nouveau-pstate-daemon restart` (now a oneshot pin).
4. Add `/usr/local/bin/nouveau-pstate-swayidle &` to your labwc autostart.
5. `pkill -USR1 labwc` or restart your session to pick it up.

## v0.1.0 — 2026-05-03

Initial public release. Load-based polling daemon (2 s sample, hysteresis
16 s DOWN / 4 s UP) toggling between pstate `0e` (350 MHz) and `03`
(800 MHz). Reference hardware: Apple Mac mini Late 2009 (NVAC/MCP79).
```

(replace `2026-05-NN` with the actual release date during Task 11)

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: add CHANGELOG with v0.1.0 retroactive + v0.2.0 entry"
```

---

## Task 8: Rewrite `README.md`

**Files:**
- Modify: `README.md`

**Responsibility.** Document the new architecture, install flow, integration with swayidle, and migration from v0.1.0.

- [ ] **Step 1: Read the current README to preserve attribution / license / hardware context**

```bash
cat README.md
```

Note any sections (license, credits, hardware reference) to keep verbatim.

- [ ] **Step 2: Overwrite README.md**

```markdown
# nouveau-pstate-daemon

Event-driven nouveau GPU pstate switcher for NVAC / NV50-Tesla integrated
graphics. Reference hardware: Apple Mac mini Late 2009 (NVIDIA 9400M, MCP79).

## What it does

Keeps the GPU at a low pstate (`0e`, ~350 MHz) when the user session is idle
and bumps it to a higher pstate (`03`, ~800 MHz) when the user is active.
Both states share the same VBIOS voltage rail on NVAC, so transitions are
voltage-neutral and safe.

## How it works

```
                       boot
                        |
                        v
              +-------------------+
              |  OpenRC oneshot   |  set BOOT_PSTATE (0e by default)
              |  nouveau-pstate-  |
              |  daemon           |
              +-------------------+

       user logs into Wayland session (labwc, sway, hyprland, ...)
                        |
                        v
       compositor autostart launches:
              +-------------------+
              | swayidle bridge   |  ext-idle-notify-v1 events
              +---------+---------+
                        |
              sudo /usr/local/bin/nv-pstate {0e|03}
                        |
                        v
              /sys/kernel/debug/dri/0/pstate
```

The bridge writes pstate only on transitions: idle timeout, resume,
before-sleep, after-resume, lock, unlock. Typical write count is single
digits per day instead of dozens to hundreds.

For workloads with no input but heavy GPU use (full-screen video), the
bridge respects compositor `zwp_idle_inhibitor_v1` requests, which mpv,
Firefox, and most video-capable apps set automatically.

## Installation

```sh
git clone https://github.com/hibbes/nouveau-pstate-daemon
cd nouveau-pstate-daemon
sudo make install
sudo groupadd -f nouveau-pstate
sudo usermod -aG nouveau-pstate $USER
# log out + log back in for the group change to take effect
sudo rc-update add nouveau-pstate-daemon default
sudo rc-service nouveau-pstate-daemon start
echo '/usr/local/bin/nouveau-pstate-swayidle &' >> ~/.config/labwc/autostart
```

Restart your Wayland session to pick up the autostart entry.

## Verifying it works

```sh
cat /run/nouveau-pstate.state          # current pstate as last set
tail -f /var/log/nouveau-pstate.log    # transitions
```

## Tunables

`/etc/conf.d/nouveau-pstate-daemon`:

| variable | default | meaning |
|---|---|---|
| `BOOT_PSTATE` | `0e` | pstate to pin at boot and on service stop |

Bridge env (export from autostart):

| variable | default | meaning |
|---|---|---|
| `NOUVEAU_PSTATE_IDLE_TIMEOUT` | `60` | idle seconds before downclock |
| `NOUVEAU_PSTATE_IDLE` | `0e` | pstate when idle |
| `NOUVEAU_PSTATE_ACTIVE` | `03` | pstate when active |

## Compositor support

Tested on labwc. Should work on any compositor implementing
`ext-idle-notify-v1` (sway, hyprland, river, niri, kwin\_wayland 6+).
GNOME and KDE Wayland sessions ship their own power management;
this project does not target them.

X11 sessions are out of scope for the activity-driven part. Install the
service for boot pinning only and skip the autostart line.

## Migration from v0.1.0

v0.1.0 was a polling daemon. v0.2.0 replaces it with the design above.
See [CHANGELOG.md](CHANGELOG.md) for the migration steps.

## Why event-driven instead of polling?

The polling daemon was the dominant trigger for a kernel WARN-loop on
Tesla / NVAC after a graphics-channel fault. Each load-curve crossing
scheduled a clock-reprogram on a wedged engine; the kernel kept retrying
because userspace kept poking. Event-driven writes happen only on real
user-activity transitions, which removes the trigger almost entirely
without requiring out-of-tree kernel patches.

## Hardware reference

- Apple Mac mini Late 2009 (Core 2 Duo, MCP79 chipset)
- NVIDIA GeForce 9400M IGP (NVAC, NV50/Tesla family)
- Distros validated on: Gentoo (kernel 7.0.x, OpenRC, labwc)

Other Tesla GPUs (G80–G92, GT2xx) should work but have not been validated.

## License

See [LICENSE](LICENSE).
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README for v0.2.0 event-driven architecture"
```

---

## Task 8.5: Wedge-Recovery Subscriber (DRM `WEDGED=rebind` uAPI)

**Files:**
- Create: `bin/nouveau-pstate-wedge-handler`
- Create: `config/udev/99-nouveau-pstate-wedge.rules`
- Create: `tests/test_wedge_handler.sh`
- Modify: `Makefile`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Responsibility.** Subscribe to the DRM `WEDGED=rebind` udev event that the in-tree
nouveau FIFO recovery path emits (Linux 6.15+ DRM uAPI, validated live on 2026-05-05
on Mac mini NVAC with patched 7.0.3 kernel). On match, log the event verbatim and set
a sticky-file `/run/nouveau-pstate.wedged` so status bars and the user can see that
the GPU asked for rebind. **No automatic rebind in v0.2.0** — auto-rebind on a live
Wayland session is too disruptive; that is a v0.3.0+ decision.

The subscriber proves the daemon-side of the WEDGED=rebind contract and makes the
upstream story for the kernel patch round-trip (kernel emits, userspace consumes).

- [ ] **Step 1: Write the smoke test first**

Create `tests/test_wedge_handler.sh`:

```bash
#!/bin/bash
# Smoke test for bin/nouveau-pstate-wedge-handler. Mocks the udev env via
# environment variables and overrides the log + sticky paths for isolation.

set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
H="$ROOT/bin/nouveau-pstate-wedge-handler"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

LOG="$WORK/wedge.log"
STICKY="$WORK/wedged"

fail=0

run() {
    WEDGE_LOG_FILE="$LOG" WEDGE_STICKY_FILE="$STICKY" \
        ACTION="$1" SUBSYSTEM="$2" WEDGED="$3" DEVNAME="$4" "$H"
}

# 1. Matching event: ACTION=change SUBSYSTEM=drm WEDGED=rebind -> log + sticky
run change drm rebind /dev/dri/card0 || { echo "FAIL: matching event returned non-zero"; fail=1; }
[[ -s "$LOG" ]] || { echo "FAIL: log empty after match"; fail=1; }
[[ -f "$STICKY" ]] || { echo "FAIL: sticky file not created"; fail=1; }
grep -q "WEDGED=rebind" "$LOG" || { echo "FAIL: log missing WEDGED=rebind"; fail=1; }
grep -q "/dev/dri/card0" "$LOG" || { echo "FAIL: log missing DEVNAME"; fail=1; }
grep -q "/dev/dri/card0" "$STICKY" || { echo "FAIL: sticky missing DEVNAME"; fail=1; }

# 2. Non-matching ACTION: should no-op (exit 0, no new log entry)
lines_before=$(wc -l < "$LOG")
run remove drm rebind /dev/dri/card0 || { echo "FAIL: non-matching exit non-zero"; fail=1; }
lines_after=$(wc -l < "$LOG")
[[ "$lines_after" -eq "$lines_before" ]] || { echo "FAIL: non-matching ACTION still logged"; fail=1; }

# 3. Non-matching WEDGED value: should no-op
lines_before=$(wc -l < "$LOG")
run change drm bus-reset /dev/dri/card0 || { echo "FAIL: bus-reset exit non-zero"; fail=1; }
lines_after=$(wc -l < "$LOG")
[[ "$lines_after" -eq "$lines_before" ]] || { echo "FAIL: non-rebind WEDGED still logged"; fail=1; }

# 4. Missing required env: must exit non-zero (defensive)
WEDGE_LOG_FILE="$LOG" WEDGE_STICKY_FILE="$STICKY" "$H" && { echo "FAIL: missing env accepted"; fail=1; }

if [[ $fail -eq 0 ]]; then
    echo "PASS: all wedge-handler smoke tests"
    exit 0
else
    exit 1
fi
```

Make executable:

```bash
chmod +x tests/test_wedge_handler.sh
```

- [ ] **Step 2: Run the test, expect FAIL (handler does not exist yet)**

```bash
./tests/test_wedge_handler.sh
```

Expected: FAIL.

- [ ] **Step 3: Implement `bin/nouveau-pstate-wedge-handler`**

Create `bin/nouveau-pstate-wedge-handler`:

```bash
#!/bin/bash
# nouveau-pstate-wedge-handler: udev RUN+= subscriber for the DRM
# WEDGED=rebind uAPI (Linux 6.15+). Logs the event and sets a sticky
# file so the user/session can react. Does NOT trigger an automatic
# unbind/bind in v0.2.0; that decision belongs to a future release.
#
# Reads udev environment via standard variables: ACTION, SUBSYSTEM,
# WEDGED, DEVNAME (others are appended to the log if present).
#
# Env overrides (testing):
#   WEDGE_LOG_FILE       append-log (default /var/log/nouveau-pstate-wedge.log)
#   WEDGE_STICKY_FILE    sticky last-event marker (default /run/nouveau-pstate.wedged)

set -u

: "${WEDGE_LOG_FILE:=/var/log/nouveau-pstate-wedge.log}"
: "${WEDGE_STICKY_FILE:=/run/nouveau-pstate.wedged}"
: "${ACTION:=}"
: "${SUBSYSTEM:=}"
: "${WEDGED:=}"
: "${DEVNAME:=}"

if [[ -z "$ACTION" || -z "$SUBSYSTEM" ]]; then
    printf 'nouveau-pstate-wedge-handler: missing ACTION/SUBSYSTEM env\n' >&2
    exit 64
fi

if [[ "$ACTION" != "change" || "$SUBSYSTEM" != "drm" || "$WEDGED" != "rebind" ]]; then
    exit 0
fi

ts=$(date '+%Y-%m-%d %H:%M:%S')
mkdir -p "$(dirname "$WEDGE_LOG_FILE")" 2>/dev/null || true
mkdir -p "$(dirname "$WEDGE_STICKY_FILE")" 2>/dev/null || true

{
    printf '%s WEDGED=rebind DEVNAME=%s SUBSYSTEM=drm ACTION=change\n' \
        "$ts" "${DEVNAME:-?}"
} >> "$WEDGE_LOG_FILE" 2>/dev/null || true

{
    printf 'ts=%s\n' "$ts"
    printf 'WEDGED=%s\n' "$WEDGED"
    printf 'DEVNAME=%s\n' "$DEVNAME"
    printf 'SUBSYSTEM=%s\n' "$SUBSYSTEM"
    printf 'ACTION=%s\n' "$ACTION"
    [[ -n "${DEVPATH:-}" ]] && printf 'DEVPATH=%s\n' "$DEVPATH"
    [[ -n "${SEQNUM:-}"  ]] && printf 'SEQNUM=%s\n'  "$SEQNUM"
    [[ -n "${MAJOR:-}"   ]] && printf 'MAJOR=%s\n'   "$MAJOR"
    [[ -n "${MINOR:-}"   ]] && printf 'MINOR=%s\n'   "$MINOR"
} > "$WEDGE_STICKY_FILE" 2>/dev/null || true

exit 0
```

Make executable:

```bash
chmod +x bin/nouveau-pstate-wedge-handler
```

- [ ] **Step 4: Run shellcheck and the smoke test**

```bash
shellcheck bin/nouveau-pstate-wedge-handler tests/test_wedge_handler.sh
./tests/test_wedge_handler.sh
```

Expected: zero shellcheck warnings, `PASS: all wedge-handler smoke tests`.

- [ ] **Step 5: Commit handler + test**

```bash
git add bin/nouveau-pstate-wedge-handler tests/test_wedge_handler.sh
git commit -m "feat(wedge-handler): subscribe to DRM WEDGED=rebind uAPI (log-only)"
```

- [ ] **Step 6: Create the udev rule**

```bash
mkdir -p config/udev
```

Write `config/udev/99-nouveau-pstate-wedge.rules`:

```
# Subscribe to the DRM WEDGED=rebind uAPI (Linux 6.15+, in-tree as of
# nouveau FIFO Tesla recovery patch). The handler runs synchronously in
# the udev event-processing path, so it must finish quickly. The current
# implementation is log-only; auto-rebind is intentionally not done here.
ACTION=="change", SUBSYSTEM=="drm", ENV{WEDGED}=="rebind", RUN+="/usr/local/bin/nouveau-pstate-wedge-handler"
```

- [ ] **Step 7: Commit udev rule**

```bash
git add config/udev/99-nouveau-pstate-wedge.rules
git commit -m "feat(udev): rule routing WEDGED=rebind events to wedge handler"
```

- [ ] **Step 8: Update Makefile**

Modify `Makefile`:

- Add `UDEVDIR = $(DESTDIR)/etc/udev/rules.d`
- Add to `SHELLS`: `bin/nouveau-pstate-wedge-handler`
- In `install`: copy handler to `$(BINDIR)`, copy rule to `$(UDEVDIR)`
- In `uninstall`: remove handler + rule
- In `check`: add `bin/nouveau-pstate-wedge-handler` and `tests/test_wedge_handler.sh`
- In `test`: also run `./tests/test_wedge_handler.sh`
- Print a hint after install: `Run 'udevadm control --reload-rules' to pick up the wedge rule`

Verify:

```bash
make check
make test
```

- [ ] **Step 9: Commit Makefile changes**

```bash
git add Makefile
git commit -m "feat(make): install wedge handler + udev rule, extend check/test"
```

- [ ] **Step 10: Update README.md**

Add a new section after "Compositor support":

```markdown
## Wedge recovery (DRM `WEDGED=rebind` uAPI)

Linux 6.15 introduced a generic DRM uAPI for drivers to signal that the
GPU is wedged and userspace should rebind the driver
(`drm_dev_wedged_event` / `WEDGED=rebind` udev property). The in-tree
nouveau FIFO recovery path on Tesla / NVAC emits this event after a
configurable burst of channel faults (default 10 within 60 s).

This daemon subscribes to those events via a udev rule. When triggered,
the handler:

- writes a one-line entry to `/var/log/nouveau-pstate-wedge.log`
- writes a key=value sticky snapshot to `/run/nouveau-pstate.wedged`

It does **not** trigger an automatic unbind/bind in v0.2.0 — that is too
disruptive on a live Wayland session. Status bars and the user can read
the sticky file to see whether the GPU has asked for rebind since boot.

To clear the sticky after a manual recovery: `rm /run/nouveau-pstate.wedged`.
```

Add to the architecture diagram a second arrow from `/dev/dri/card0` back up to a
"udev WEDGED=rebind" node feeding the handler.

- [ ] **Step 11: Update CHANGELOG.md v0.2.0 entry**

Add to the "Added" section of v0.2.0:

```markdown
- `bin/nouveau-pstate-wedge-handler` — udev subscriber for the DRM
  `WEDGED=rebind` uAPI; logs to `/var/log/nouveau-pstate-wedge.log` and
  sets sticky `/run/nouveau-pstate.wedged`. Log-only in v0.2.0.
- `config/udev/99-nouveau-pstate-wedge.rules` — udev rule routing the
  matching events to the handler.
```

- [ ] **Step 12: Commit doc updates**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document WEDGED=rebind subscriber in README + CHANGELOG"
```

---

## Task 9: Local install + smoke verification

**Files:** none

**Responsibility.** Install the new artifacts on the developer's own machine, verify the boot-pin service works, verify the swayidle bridge launches, observe the pstate transitions on real input.

- [ ] **Step 1: `make install`**

```bash
sudo make install
```

Expected: each `install` line prints, no errors. Final block prints next-steps hints.

- [ ] **Step 2: Add user to group, restart shell**

```bash
sudo groupadd -f nouveau-pstate
sudo usermod -aG nouveau-pstate "$USER"
```

Open a new terminal (the group change applies to new sessions). Verify:

```bash
id | tr ',' '\n' | grep nouveau-pstate
```

Expected: a line containing `nouveau-pstate`.

- [ ] **Step 3: Sanity-check sudoers**

```bash
sudo visudo -c -f /etc/sudoers.d/nouveau-pstate
```

Expected: `parsed OK`.

- [ ] **Step 4: Test the helper through sudo (no password prompt)**

```bash
sudo -n /usr/local/bin/nv-pstate 0e
cat /run/nouveau-pstate.state
```

Expected: state file contains `0e`. No password prompt.

- [ ] **Step 5: Stop the legacy v0.1.0 service if it's still running, switch over**

```bash
sudo rc-service nouveau-pstate-daemon restart
sudo rc-update add nouveau-pstate-daemon default
sudo rc-status default | grep nouveau
```

Expected: service starts as oneshot and finishes; status shows it as started.

- [ ] **Step 6: Add the bridge to labwc autostart**

```bash
echo '/usr/local/bin/nouveau-pstate-swayidle &' >> ~/.config/labwc/autostart
```

Restart the Wayland session (log out + log in, or `pkill labwc` if you know what you're doing).

- [ ] **Step 7: Observe transitions**

```bash
tail -f /var/log/nouveau-pstate.log
```

Stop typing for 60 s — expect a `pstate -> 0e` line. Touch keyboard/mouse — expect `pstate -> 03`. Lock screen, unlock — expect 0e then 03.

If any step fails, debug before proceeding. The daemon must be observably correct end-to-end before tagging.

- [ ] **Step 8: Run for at least one full day before tagging**

No git step here. Just leave it installed and verify nothing regresses for 24 h.

---

## Task 10: Tag v0.2.0 + GitHub release

**Files:** none (git only)

- [ ] **Step 1: Update the date in CHANGELOG.md**

Replace `## v0.2.0 — 2026-05-NN` with the actual release date.

```bash
sed -i "s/## v0.2.0 — 2026-05-NN/## v0.2.0 — $(date +%Y-%m-%d)/" CHANGELOG.md
git add CHANGELOG.md
git commit -m "docs(changelog): set v0.2.0 release date"
```

- [ ] **Step 2: Push the feature branch and open a PR (or fast-forward main if solo dev)**

For solo dev (no PR review):

```bash
git checkout main
git merge --ff-only event-driven-v0.2.0
git push origin main
```

If a PR review is desired, create the PR first via `gh pr create`, get review, then merge.

- [ ] **Step 3: Tag v0.2.0**

```bash
git tag -a v0.2.0 -m "v0.2.0 — event-driven redesign (swayidle bridge + boot-pin service)"
git push origin v0.2.0
```

- [ ] **Step 4: Write release notes to `/tmp/v0.2.0-notes.md`**

```markdown
Event-driven redesign. The 2 s polling daemon is replaced by:

- a boot-time OpenRC oneshot that pins a safe pstate
- a user-session `swayidle` bridge that switches pstate on
  `ext-idle-notify-v1` events (idle, resume, sleep, lock, unlock)
- a small privileged helper (`nv-pstate`) gated by a group-scoped sudoers fragment

This shrinks the pstate-write trigger surface from "every load-curve
crossing" (dozens to hundreds per day) to "a few user-activity
transitions per day" — which eliminates the kernel WARN-loop trigger
on Tesla / NVAC after a Chrome graphics-channel fault, without
requiring out-of-tree kernel patches.

## Breaking changes

- `bin/nouveau-pstate-daemon` (the polling binary) has been removed.
- `openrc/init.d/nouveau-pstate-daemon` is now a oneshot pinning service.
- A new `nouveau-pstate` group + sudoers fragment replaces the previous
  root-only operation model.

See [CHANGELOG.md](CHANGELOG.md) for the migration steps.
```

- [ ] **Step 5: Show release plan to user, await OK before publishing**

Per memory rule "Externe Posts: Volltext+Aktion vor Send", do **not** publish the release without explicit user OK. Print the planned `gh` command:

```bash
gh release create v0.2.0 -R hibbes/nouveau-pstate-daemon \
    --title "v0.2.0 - event-driven redesign" \
    --notes-file /tmp/v0.2.0-notes.md
```

Wait for user confirmation before running it.

- [ ] **Step 6: After OK, create the GitHub release**

Run the command above. Capture the URL. Confirm with the user.

- [ ] **Step 7: Update memory + KG**

Update `~/.claude/projects/-home-neo/memory/project_nouveau_pstate_daemon_mac_mini.md`
with a v0.2.0 release section. Add observation to the
`Nouveau P-State Daemon` KG entity. Mention that 0005 is no longer load-bearing
on the reference machine.

---

## Self-Review Checklist

After all tasks are complete, run through this:

- [ ] **Spec coverage.** Each item in the architecture summary maps to a task:
  Boot-pin service → Task 3. Helper → Task 1. Bridge → Task 2.
  Sudoers/autostart → Task 4. Install/test scaffolding → Task 5.
  Legacy removal → Task 6. Docs → Tasks 7+8. Verification → Task 9. Release → Task 10.
- [ ] **Placeholder scan.** No `TBD`, no `add error handling`, no `similar to Task N`.
- [ ] **Type consistency.** Helper binary name (`nv-pstate`) matches across init.d,
  swayidle bridge, sudoers fragment, Makefile, README, CHANGELOG.
- [ ] **Group name consistency.** `nouveau-pstate` group matches in sudoers fragment,
  Makefile install message, README, CHANGELOG.
- [ ] **Path consistency.** `/usr/local/bin/nv-pstate` and `/usr/local/bin/nouveau-pstate-swayidle`
  match across all artifacts.
- [ ] **State file path consistency.** `/run/nouveau-pstate.state` matches between
  helper, README, and v0.1.0 carry-over (status-bar integration).
