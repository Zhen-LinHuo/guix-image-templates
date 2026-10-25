;;; appliances/nas/target.scm — the system that ends up ON THE DISK.
;;;
;;; This is what an unattended install evaluates, and it is also a valid
;;; config.scm to run by hand (`guix system init appliances/nas/target.scm /mnt`).
;;; Device names are filesystem labels because an installed disk must survive
;;; controller renames (/dev/sda -> /dev/sdb when a USB stick is plugged in).
;;;
;;; Partitioning, labels and the ESP are created by installer/install.sh; if you
;;; install by hand, create the same labels or edit the two device paths here.
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (templates appliances nas)
             (gnu bootloader grub)
             (gnu system file-systems))

(nas-operating-system
 #:root-device "/dev/disk/by-label/nas-root"
 #:root-type "ext4"
 #:bootloader grub-efi-bootloader
 #:boot-targets '("/boot/efi")
 #:extra-file-systems
 (list (file-system
         (mount-point "/boot/efi")
         (device "/dev/disk/by-label/nas-esp")
         (type "vfat")))
 #:kernel-arguments '("quiet" "console=ttyS0"))
