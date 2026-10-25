# `appliances/router/` — placeholder

This directory shows where the router-class appliance goes; it is empty on
purpose.  The layout expects, per appliance:

- `target.scm` — the operating system that ends up on the disk, built from
  `(templates appliances <name>)`;
- any appliance-specific install parameters.

The shared constructor lives in `modules/templates/appliances/<name>.scm`, so
every medium (`media/`) builds the same system.  A router variant adds its own
module there and its own `target.scm` here; nothing in `media/` or `installer/`
needs to change.
