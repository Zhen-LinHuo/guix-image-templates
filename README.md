# guix-image-templates

<div align="center">

[![License](https://badgen.net/github/license/Zhen-LinHuo/guix-image-templates)](LICENSE)
[![GitHub stars](https://badgen.net/github/stars/Zhen-LinHuo/guix-image-templates)](https://github.com/Zhen-LinHuo/guix-image-templates)
[![Last commit](https://badgen.net/github/last-commit/Zhen-LinHuo/guix-image-templates)](https://github.com/Zhen-LinHuo/guix-image-templates)
[![Star history](https://api.star-history.com/svg?repos=Zhen-LinHuo/guix-image-templates&type=Date)](https://star-history.com/#Zhen-LinHuo/guix-image-templates&Date)

</div>

Declarative [Guix System](https://guix.gnu.org) image templates for different specific types of machines. e.g. NAS and software routers.

Declarative [Guix System](https://guix.gnu.org) templates for appliances that are usually configured by hand: a NAS with a web panel, and a router-class box with a transparent proxy data plane.  Clone it, fill in the handful of values that are yours, build an image.

This repository is self-contained.  It has no dependency on any private repository, internal host name or cache, and it ships no credentials — if a file here needs a value that is specific to one deployment, that value is a placeholder.

## What you get

| Piece | Module | What it does |
|:--|:--|:--|
| Proxy core | `(templates packages proxy)` | `mihomo` and `dnsproxy` from pinned upstream releases, plus geodata |
| Overlay clients | `(templates packages sdwan)` | `netbird`, `easytier` (static releases); `zerotier` comes from nonguix |
| Egress data plane | `(templates services egress)` | dnsmasq → mihomo → dnsproxy DNS chain, mode switch and geodata timers |
| Overlay services | `(templates services sdwan)` | shepherd units for the three overlay clients, idle until provisioned |

Guix System has no systemd-resolved, so the DNS plane is spelled out with shepherd services instead of per-link resolvers; no systemd unit files are translated at runtime.

## Build your own image

Prerequisites: GNU Guix (with the `nonguix` channel for `zerotier` and the standard kernel), network access for the geodata fetch, and `qemu` only if you want to smoke-test the image.

```sh
git clone <this-repo> guix-image-templates
cd guix-image-templates

# GeoSite/GeoIP are needed at build time and are not committed
scripts/fetch-geodata.sh

cp systems/nas.scm.example systems/nas.scm
$EDITOR systems/nas.scm        # the four values below
```

Values that are yours to fill:

1. `host-name` and `timezone`/`locale`.
2. The admin account's password hash — generate it locally:

   ```sh
   openssl passwd -6 -salt "$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')" -stdin
   ```

   The salt must be hex only: a `$` inside it breaks the `$6$salt$hash` layout and the hash can never match.  The same string goes into the Webmin `password-crypt` field so the panel and the console share one credential.
3. Overlay zones (only if you run an overlay network):

   ```scheme
   (zones '(("corp.internal" . "10.99.0.1")))
   ```

   These are how the resolver answers names that only exist inside your overlay; leave `'()` if you have none.
4. Disk device names in `file-systems` and `swap-devices`.

Then build:

```sh
guix system image -t qcow2 -L modules systems/nas.scm
```

`-L modules` is what makes `(templates …)` importable without adding this repository as a channel.  To use it as a channel instead, add it to
`~/.config/guix/channels.scm` and `guix pull` (the `.guix-channel` file points at `modules/`).

Booting the result: pass `console=ttyS0` if the image is for a headless box, and expect the panel on port 10000 once `miniserv` is up.

## Provisioning at install time, not at build time

Nothing that identifies a tenant is baked into the image:

- `scripts/provision-mihomo.sh` merges a validated DNS/geodata fragment into the node config you bring, writes it `0600`, tests it with `mihomo -t` before replacing anything, and keeps a timestamped backup.  Subscription links are credentials; they never enter a layer.
- `scripts/sdwan-join.sh` writes overlay membership (`/etc/sdwan/*`, `0600`) and restarts the unit.  A fresh image reports `netbird status: NeedsLogin` and `zerotier-cli info` without a network — that is the expected, unprovisioned state, not a failure.
- `scripts/fetch-geodata.sh` and `scripts/guix-egress-check.sh` are operator tools: refresh geodata, and measure which mirrors are reachable through which path.  Every site-specific value they need is an environment variable.

## What is deliberately absent

- No internal host names, overlay addresses or substitute-cache URLs.
- No subscription link, setup key, network id or password hash.
- No hardware pinning for one machine: `systems/*.example` is a starting point,
  not a machine inventory.

`git grep -nE 'internal|10\.[0-9]+\.|192\.168\.'` should stay short and boring; if it grows, something site-specific has leaked in.

## Licence

GPL-3.0-or-later for everything in this repository.
