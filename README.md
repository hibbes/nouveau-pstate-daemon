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
`ext-idle-notify-v1` (sway, hyprland, river, niri, kwin_wayland 6+).
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
