# nouveau-pstate-daemon

A small userspace daemon that toggles the nouveau driver's `pstate` between
idle and load levels based on GPU activity, on Tesla-class NVIDIA hardware.

Tested on **NVAC (MCP79/MCP7A) integrated GeForce 9400M** in an Apple Mac mini
(Late 2009). The general approach should work on other Tesla GPUs with
appropriate re-calibration; see "Calibration" below.

## Why this exists

nouveau's in-kernel pstate machinery on Tesla is purely manual: you can write
`/sys/kernel/debug/dri/0/pstate` to set a level, but the driver never raises
or lowers it on its own. Cards therefore sit at their boot pstate
indefinitely. On NVAC that boot pstate is `0e` (350 MHz core / 800 MHz
shader), which is hotter and louder than necessary for desktop idle.

This daemon fills that gap. It watches the nouveau MSI interrupt rate via
`/proc/interrupts` and switches between two pstates with hysteresis:

- Below `DOWN_THRESHOLD` for `DOWN_HOLD` consecutive samples → `PSTATE_IDLE`.
- At or above `UP_THRESHOLD` for `UP_HOLD` consecutive samples → `PSTATE_LOAD`.

## Why it is reasonably safe on NVAC

Inspection of the on-board VBIOS perf table on the Mac mini Late 2009 shows
two relevant facts:

| Pstate | Core | Shader | Voltage |
|--------|------|--------|---------|
| `03` | 150 MHz | 300 MHz | 0.90 V |
| `0e` | 350 MHz | 800 MHz | 0.90 V |
| `0f` | 450 MHz | 1100 MHz | 1.01 V |

1. Pstates `03` and `0e` share the same voltage (0.90 V), so toggling
   between them is a pure frequency change with no voltage transition.
2. Memory clock on NVAC is hardcoded to 0 in `nvkm/subdev/clk/mcp77.c`, so
   no memory reclocking is performed. The historical Tesla failure mode
   "memory retraining causes scanout corruption / X lockup" cannot trigger.

These two properties together make `03 ↔ 0e` the lowest-risk pstate
transition available on this silicon. The daemon does **not** touch `0f`
without manual override, because `0f` requires the voltage controller
to be exercised and that path is less verified on Apple-branded VBIOS.

## Inspiration / prior art

- [sasha0552/nvidia-pstated](https://github.com/sasha0552/nvidia-pstated)
  implements the same idea — load-based pstate switching as a daemon — for
  the proprietary NVIDIA driver. This project does the same job for nouveau
  on Tesla-class hardware.
- [ventureoo/nouveau-reclocking](https://github.com/ventureoo/nouveau-reclocking)
  is a static helper for setting a fixed pstate; complementary, not
  overlapping.

## Status

- Verified: NVAC / MCP79 / GeForce 9400M IGP on Mac mini Late 2009, kernel
  `6.18.22-gentoo-dist`, OpenRC.
- Unverified on other Tesla SKUs; thresholds will need re-calibration and
  the safety claim about voltage-neutral 03↔0e depends on the per-card
  VBIOS perf table.

## Install (OpenRC, Gentoo)

```sh
sudo install -m 0755 bin/nouveau-pstate-daemon /usr/local/bin/
sudo install -m 0755 openrc/init.d/nouveau-pstate-daemon /etc/init.d/
sudo install -m 0644 openrc/conf.d/nouveau-pstate-daemon /etc/conf.d/
```

Test in foreground first; only `rc-update add` once you have observed
sensible behavior in your own logs.

## Calibration

The default thresholds (`UP_THRESHOLD=100`, `DOWN_THRESHOLD=80`) were
derived from a 60s idle / 60s `glxgears` run on the reference hardware.
Other Tesla cards or other workloads will produce a different distribution.
Re-run the calibration before trusting the defaults:

```sh
# baseline (whatever counts as "idle" for your usage)
prev=$(awk '/nvkm/{print $2}' /proc/interrupts)
for i in {1..60}; do
    sleep 1
    now=$(awk '/nvkm/{print $2}' /proc/interrupts)
    echo $((now - prev)); prev=$now
done | sort -n | uniq -c
```

Then repeat under your typical "load" scenario. Pick `UP_THRESHOLD` well
above the idle distribution's max and `DOWN_THRESHOLD` slightly above the
idle distribution's mean.

## Tunables

All overridable via `/etc/conf.d/nouveau-pstate-daemon` or environment:

| Variable | Default | Meaning |
|---|---|---|
| `SAMPLE_INTERVAL` | `2` | Seconds between IRQ-rate samples. |
| `UP_THRESHOLD` | `100` | IRQ/s at which to up-clock. |
| `UP_HOLD` | `2` | Consecutive samples above `UP_THRESHOLD` before switching. |
| `DOWN_THRESHOLD` | `80` | IRQ/s below which to down-clock. |
| `DOWN_HOLD` | `8` | Consecutive samples at or below `DOWN_THRESHOLD` before switching. |
| `PSTATE_LOAD` | `0e` | Pstate to use under load. |
| `PSTATE_IDLE` | `03` | Pstate to use at idle. |
| `PSTATE_FILE` | `/sys/kernel/debug/dri/0/pstate` | Where to write. |
| `IRQ_NAME` | `nvkm` | Token to grep in `/proc/interrupts`. |
| `LOG_FILE` | `/var/log/nouveau-pstate.log` | Pstate-transition log. |

## Caveats and known limits

- Pstate writes use `debugfs`, which is privileged. The daemon must run as
  root.
- IRQ-rate is a proxy for GPU activity, not a direct busy counter.
  Pathological workloads that move large amounts of data per interrupt
  (long compute kernels) may underclock when they should not. Adjust
  `DOWN_HOLD` upward if you see this.
- Suspend/resume is fragile on NVAC independently of this daemon (see
  [drm/nouveau#148](https://gitlab.freedesktop.org/drm/nouveau/-/issues/148)).
  The daemon does not interact with the suspend path, but you may need to
  restart the service after resume if pstate writes start failing.
- The daemon does not change voltage. The voltage controller path on the
  Apple NVAC VBIOS has not been independently verified by this project; see
  the perf-table excerpt above for why this is fine for `03 ↔ 0e` but is
  the reason `0f` is intentionally avoided.

## License

GPL-2.0-only. The kernel interfaces this daemon writes to are part of
GPL-licensed `drivers/gpu/drm/nouveau`, so GPL-2 alignment is the
idiomatic choice.
