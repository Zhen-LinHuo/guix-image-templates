;;; modules/templates/appliances/nas.scm — the NAS appliance, parameterised by medium.
;;;
;;; One system definition, several media.  What varies between a VM image, a
;;; disk image written to hardware, and a system installed by the installer is
;;; only the DEVICE NAMING (and, for the installer, the bootloader target): the
;;; package set, the services, the resolver chain and the account model must be
;;; identical, or the VM you tested is not the machine you shipped.
;;;
;;; Usage from a media entry point:
;;;
;;;   (use-modules (templates appliances nas))
;;;   (nas-operating-system #:root-device "/dev/disk/by-label/nas-root"
;;;                         #:bootloader grub-efi-bootloader
;;;                         #:boot-targets '("/boot/efi"))
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (templates appliances nas)
  #:use-module (gnu)
  #:use-module (gnu services)
  #:use-module (gnu services networking)
  #:use-module (gnu services ssh)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader grub)
  #:use-module (gnu system file-systems)
  #:use-module (nongnu packages linux)
  #:use-module (guix gexp)
  #:use-module (templates services egress)
  #:use-module (templates services sdwan)
  #:use-module (templates packages sdwan)
  #:use-module (webmin-guix services webmin)
  #:export (nas-operating-system
            %nas-packages
            %nas-base-file-systems))

(define %nas-packages
  ;; Hardware and panel support that the appliance needs on every medium.
  ;; "zerotier" comes from the nonguix channel; netbird and easytier are
  ;; packaged by this channel.
  (append (map specification->package
               '("mdadm" "smartmontools" "curl" "psmisc" "net-tools"
                 "zerotier"))
          (list netbird easytier)
          %base-packages))

;; File systems every medium shares, minus the root entry (the part that
;; differs: /dev/vda1 on a VM, a label on an installed disk).
(define %nas-base-file-systems %base-file-systems)

(define* (nas-operating-system #:key
                               (host-name "nas")
                               (root-device "/dev/disk/by-label/nas-root")
                               (root-type "ext4")
                               (bootloader grub-efi-bootloader)
                               (boot-targets '("/boot/efi"))
                               (extra-file-systems '())
                               (extra-services '())
                               (kernel-arguments '("quiet")))
  "Return the NAS operating system bound to the devices of one medium.

ROOT-DEVICE is how the booted system finds its root; on an installed disk that
is a filesystem label (stable across controller renames), on a VM image it is
the partition device the image type actually creates.  BOOTLOADER/BOOT-TARGETS
are the medium's boot story: GRUB in BIOS mode on /dev/vda for a throwaway VM,
GRUB-EFI on the ESP for hardware."
  (operating-system
    (host-name host-name)
    (timezone "Asia/Shanghai")
    (locale "en_US.utf8")

    ;; linux-libre loses drivers that matter on assorted small-form-factor and
    ;; industrial boards (wired NICs, storage controllers); the standard kernel
    ;; from nonguix is the default here.
    (kernel linux)
    (kernel-arguments kernel-arguments)

    (initrd-modules (cons* "raid456" "raid1" (base-initrd-modules linux)))

    (bootloader (bootloader-configuration
                  (bootloader bootloader)
                  (targets boot-targets)))

    (file-systems (append (list (file-system
                                  (mount-point "/")
                                  (device root-device)
                                  (type root-type)))
                          extra-file-systems
                          %nas-base-file-systems))

    (users (cons (user-account
                   (name "admin")
                   (group "users")
                   (supplementary-groups '("wheel"))
                   ;; Hash only (crypt-6), replaced during provisioning.  A
                   ;; plaintext default would land in a world-readable store
                   ;; path; provisioning must change it before exposure.
                   (password "$6$CHANGEMEsalthex$REPLACE-with-openssl-passwd-6-output"))
                 %base-user-accounts))

    (packages %nas-packages)

    (services
     (append
      extra-services
      (list
       (service openssh-service-type
                (openssh-configuration
                 (permit-root-login 'prohibit-password)   ; keys only
                 (password-authentication? #t)))

       ;; dhcpcd would otherwise overwrite /etc/resolv.conf with the
       ;; DHCP-supplied resolvers — exactly what this design keeps out.
       (service dhcpcd-service-type
                (dhcpcd-configuration
                 (command-arguments '("-C" "resolv.conf"))))

       (simple-service 'nas-resolv-conf etc-service-type
                       (list `("resolv.conf"
                               ,(plain-file "resolv.conf"
                                            "nameserver 127.0.0.1\noptions edns0 trust-ad\n"))))

       ;; SD-WAN transports, strongest first.  Every unit idles until
       ;; scripts/sdwan-join.sh writes /etc/sdwan/*; nothing here carries a
       ;; membership credential, so the image stays tenant-neutral.
       (service zerotier-service-type)
       (service netbird-service-type)
       (service easytier-service-type)

       (service mihomo-service-type
                (mihomo-configuration
                 (config-directory "/var/lib/mihomo")))
       (service dnsproxy-service-type)          ; fuse behind mihomo

       ;; Overlay zones and gateway MACs are site facts: they belong in the
       ;; site layer that wraps this function, never as module defaults.
       (service split-dns-service-type
                (split-dns-configuration
                 (zones '())))
       (service egress-mode-switch-service-type
                (egress-mode-switch-configuration
                 (trusted-gateway-macs '())))
       (service geo-update-service-type)        ; 24 h, size-guarded

       (service webmin-service-type
                (webmin-configuration
                 ;; Hash is set at provisioning; TLS is expected to be
                 ;; terminated by a reverse proxy in front of Webmin.
                 (password-crypt "$6$CHANGEMEsalthex$REPLACE-with-openssl-passwd-6-output"))))
      %base-services))))
