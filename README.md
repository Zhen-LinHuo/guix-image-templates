# guix-image-templates

<div align="center">

[![License](https://badgen.net/github/license/Zhen-LinHuo/guix-image-templates)](LICENSE)
[![GitHub stars](https://badgen.net/github/stars/Zhen-LinHuo/guix-image-templates)](https://github.com/Zhen-LinHuo/guix-image-templates)
[![Last commit](https://badgen.net/github/last-commit/Zhen-LinHuo/guix-image-templates)](https://github.com/Zhen-LinHuo/guix-image-templates)
[![Star history](https://api.star-history.com/svg?repos=Zhen-LinHuo/guix-image-templates&type=Date)](https://star-history.com/#Zhen-LinHuo/guix-image-templates&Date)

</div>

Declarative [Guix System](https://guix.gnu.org) image templates for different
specific types of machines, e.g. NAS and software routers.

Templates for appliances that are usually configured by hand: a NAS with a web
panel, and a software router with an overlay network and a policy-routed egress
plane.  Clone it, fill in the handful of values that are yours, build an image.

This repository is self-contained.  It has no dependency on any private
repository, internal host name or cache, and it ships no credentials — if a file
here needs a value that is specific to one deployment, that value is a
placeholder.

## Intended use

This is infrastructure configuration: it wires publicly available daemons
(`mihomo`, `dnsproxy`, `netbird`, `easytier`, `zerotier`) into a declarative
system.  It ships no service, no upstream nodes and no credentials — a built
image does nothing until an operator provisions a profile on it.

Whoever deploys it is responsible for how it is used and for complying with the
laws, contracts and network policies that apply to them.  The authors provide no
connectivity service and accept no liability for misuse or for any loss arising
from the use of this software, which is offered as-is without warranty, as set
out in the licence below.

## Repository layout

Two axes, because "which appliance" and "which medium" are separate decisions:

- `modules/templates/` — the channel: packages, services, and the appliance
  constructors.
- `modules/templates/appliances/nas.scm` — the NAS appliance itself,
  parameterised by medium (root device, bootloader, boot targets).
- `appliances/nas/target.scm` — the system that ends up on the disk: filesystem
  labels, ESP, GRUB EFI.
- `appliances/router/` — where the router appliance goes; empty on purpose.
- `media/installer-iso.scm` — **the deliverable**: an installation ISO that
  installs unattended when the kernel command line names a disk.
- `media/disk-qcow2.scm` — development medium: a throwaway VM of the same
  appliance, for testing before hardware exists.
- `media/disk-raw.scm` — offline medium: a disk image written directly, for
  sites with no network at install time.
- `installer/` — what the ISO runs: partition, format, `guix system init`,
  bootloader.

Every medium builds the same appliance from the same constructor, so the system
you tested in a VM is the system the installer writes to hardware.

## What you get

| Piece | Module | What it does |
|:--|:--|:--|
| Routing core | `(templates packages proxy)` | `mihomo` and `dnsproxy` from pinned upstream releases, plus geodata |
| Overlay clients | `(templates packages sdwan)` | `netbird`, `easytier` (static releases); `zerotier` comes from nonguix |
| Egress plane | `(templates services egress)` | dnsmasq → mihomo → dnsproxy resolver chain, mode switch and geodata timers |
| Overlay services | `(templates services sdwan)` | shepherd units for the three overlay clients, idle until provisioned |
| Appliance | `(templates appliances nas)` | the whole NAS system, bound to one medium's devices |

Guix System has no systemd-resolved, so the DNS plane is spelled out with
shepherd services instead of per-link resolvers; no systemd unit files are
translated at runtime.

## Build a medium

Prerequisites: GNU Guix (with the `nonguix` channel for `zerotier` and the
standard kernel) and network access for the geodata fetch.

```sh
git clone <this-repo> guix-image-templates
cd guix-image-templates

# GeoSite/GeoIP are build inputs and are not committed
scripts/fetch-geodata.sh

# the deliverable: an installation ISO
guix system image -t iso9660 -L modules media/installer-iso.scm

# development: the same appliance as a VM
guix system image -t qcow2 -L modules media/disk-qcow2.scm

# offline sites: a disk image to write directly
guix system image -t raw -L modules media/disk-raw.scm
```

`-L modules` is what makes `(templates …)` importable without adding this
repository as a channel; to use it as a channel instead, add it to
`~/.config/guix/channels.scm` and `guix pull`.

### Installing

Boot the ISO and either let it install itself:

```
install.disk=/dev/sda          # kernel command line; add install.erase=1 to wipe
```

or run it by hand from the installer console:

```sh
bash /etc/install/install.sh /dev/sda
```

The installer refuses a disk that already holds partitions unless `--erase` (or
`install.erase=1`) says so, and it refuses the medium it booted from: a USB
stick is usually enumerated before the internal disk, so it is the one that gets
`/dev/sda`, and "install to sda" would erase the installer itself.  The check
asks the device rather than the kernel name — transport (`usb`/`sr`), the
removable flag, and the disk carrying the live root.  `--allow-removable` (or
`install.allow_removable=1`) overrides it when the target really is a USB disk.  It creates a 512 MiB ESP
(`nas-esp`) and an ext4 root (`nas-root`), then runs `guix system init` from the
config and modules baked into the medium.

Values that are yours to fill, in the two files that own them:

1. `host-name`, `timezone`, `locale` — `modules/templates/appliances/nas.scm`.
2. The admin password hash (both the account and the Webmin `password-crypt`):

   ```sh
   openssl passwd -6 -salt "$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')" -stdin
   ```

   Hex-only salt: a `$` inside it breaks the `$6$salt$hash` layout and the hash
   can never match.
3. Overlay zones and the trusted-gateway MAC whitelist — pass them from your own
   site entry (`appliances/<name>/site.scm`, git-ignored), which wraps the
   constructor; never from the shared module.
4. Disk layout — `appliances/nas/target.scm` (labels) and `installer/install.sh`
   (partition sizes), if your hardware needs something other than 512 MiB ESP
   plus one root partition.

## Provisioning at install time, not at build time

Nothing that identifies a tenant is baked into the image:

- `scripts/provision-mihomo.sh` merges a validated DNS/geodata fragment into the node config you bring, writes it `0600`, tests it with `mihomo -t` before replacing anything, and keeps a timestamped backup.  Subscription links are credentials; they never enter a layer.
- `scripts/sdwan-join.sh` writes overlay membership (`/etc/sdwan/*`, `0600`) and restarts the unit.  A fresh image reports `netbird status: NeedsLogin` and `zerotier-cli info` without a network — that is the expected, unprovisioned state, not a failure.
- `scripts/fetch-geodata.sh` and `scripts/guix-egress-check.sh` are operator tools: refresh geodata, and measure which mirrors are reachable through which path.  Every site-specific value they need is an environment variable.

## What is deliberately absent

- No internal host names, overlay addresses or substitute-cache URLs.
- No subscription link, setup key, network id or password hash.
- No gateway MAC addresses: the egress mode switch takes a whitelist of gateways
  you own, and that whitelist is empty here — it is a site fact, not a template
  default.
- No hardware pinning for one machine: `appliances/*/target.scm` is a starting
  point, not a machine inventory.

`git grep -nE 'internal|10\.[0-9]+\.|192\.168\.|([0-9a-f]{2}:){5}'` should stay
short and boring; if it grows, something site-specific has leaked in.

## Licence

GPL-3.0-or-later for everything in this repository.
