;;; media/disk-raw.scm — offline medium: a disk image you write directly.
;;;
;;; This is a testing aid, not a deliverable.  Write it onto a disk with dd when
;;; you want the appliance bootable without running the installer — on a VM, or
;;; on a machine you are about to wipe anyway.  It bakes one disk layout and
;;; cannot adapt to anyone else's, which is exactly why the installer medium is
;;; what ships.
;;;
;;;   guix system image -t efi-raw -L modules media/disk-raw.scm
;;;
;;; The layout matches what installer/install.sh creates — GPT, ESP on partition
;;; one, ext4 root on partition two — so a machine can move between the two media
;;; without changing its bootloader or its partition scheme.  The image is
;;; written at a fixed size; growing the root partition to the whole disk is a
;;; first-boot job (`growpart' + `resize2fs'), not something the image can do.
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (templates appliances nas)
             (gnu bootloader grub)
             (gnu system file-systems))

(nas-operating-system
 ;; efi-raw names the partitions sda1 (ESP) and sda2 (root) on the first disk
 ;; the image is written to.
 #:root-device "/dev/sda2"
 #:root-type "ext4"
 #:bootloader grub-efi-bootloader
 #:boot-targets '("/boot/efi")
 #:extra-file-systems
 (list (file-system
         (mount-point "/boot/efi")
         (device "/dev/sda1")
         (type "vfat")))
 #:kernel-arguments '("quiet" "console=ttyS0"))
