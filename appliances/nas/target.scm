;;; appliances/nas/target.scm — the system that ends up ON THE DISK.
;;;
;;; A thin wrapper: the definition lives in (templates appliances nas), so the
;;; medium that installs it and the person who runs `guix system init' by hand
;;; evaluate the same object.  Device names are filesystem labels because an
;;; installed disk must survive controller renames (/dev/sda -> /dev/sdb when a
;;; USB stick is plugged in); the installer creates those labels.
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (templates appliances nas))

(nas-target-os)
