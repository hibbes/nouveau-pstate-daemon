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
- `bin/nouveau-pstate-wedge-handler` — udev subscriber for the DRM
  `WEDGED=rebind` uAPI (Linux 6.15+). Logs to
  `/var/log/nouveau-pstate-wedge.log` and writes a sticky snapshot to
  `/run/nouveau-pstate.wedged`. Log-only in v0.2.0; auto-rebind is
  deferred to a future release because it would tear down the live
  Wayland session.
- `config/sudoers.d/nouveau-pstate` — group-scoped sudoers fragment
- `config/labwc-autostart-snippet.sh` — drop-in autostart example
- `config/udev/99-nouveau-pstate-wedge.rules` — udev rule routing the
  matching `WEDGED=rebind` events to the wedge handler
- `Makefile` — `install`, `uninstall`, `check`, `test` targets
- `tests/test_nv-pstate.sh` — smoke test
- `tests/test_wedge_handler.sh` — smoke test for the wedge handler

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
16 s DOWN / 4 s UP) toggling between pstate `03` (150/300 MHz, idle) and
`0e` (350/800 MHz, active). Reference hardware: Apple Mac mini Late 2009
(NVAC/MCP79).
