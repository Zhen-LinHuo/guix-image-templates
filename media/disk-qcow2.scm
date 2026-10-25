;;; media/disk-qcow2.scm — development medium: a throwaway VM image of the NAS.
;;;
;;; This is NOT the deliverable.  It exists so the appliance can be booted and
;;; tested without hardware; the shipped medium is media/installer-iso.scm (or
;;; media/disk-raw.scm for offline flashing).  Both build the SAME appliance
;;; from (templates appliances nas) — only the device naming differs, which is
;;; the whole point of parameterising it.
;;;
;;;   guix system image -t qcow2 -L modules media/disk-qcow2.scm
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (templates appliances nas)
             (gnu bootloader grub))

(nas-operating-system
 ;; The qcow2 image type creates its own partition table with an ext4 root, so
 ;; the root device must be the one that layout produces, not a label.
 #:root-device "/dev/vda1"
 #:root-type "ext4"
 #:bootloader grub-bootloader
 #:boot-targets '("/dev/vda")
 #:kernel-arguments '("quiet" "console=ttyS0"))
