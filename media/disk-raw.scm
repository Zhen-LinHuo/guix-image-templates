;;; media/disk-raw.scm — offline medium: a disk image you write directly.
;;;
;;; For sites with no network at install time: `xzcat` it onto the target disk
;;; from a rescue system, or restore it with dd.  It carries no installer and
;;; asks no questions, which is the point — and also the reason the installer
;;; medium stays the default deliverable: this one bakes one disk layout.
;;;
;;;   guix system image -t raw -L modules media/disk-raw.scm
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (templates appliances nas)
             (gnu bootloader grub))

(nas-operating-system
 ;; SATA/NVMe naming as the image type creates it; the raw type writes a
 ;; partition table with a single root partition.
 #:root-device "/dev/sda1"
 #:root-type "ext4"
 #:bootloader grub-bootloader
 #:boot-targets '("/dev/sda")
 #:kernel-arguments '("quiet" "console=ttyS0"))
