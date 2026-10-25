;;; media/installer-iso.scm — the shipped medium: an installation ISO.
;;;
;;; It inherits Guix's own installation OS (so `guix`, the partitioning tools and
;;; a working live root are all present and supported upstream) and adds three
;;; things: the target system definition, this channel's modules, and a one-shot
;;; service that installs without a human when the kernel command line names a
;;; disk.
;;;
;;;   guix system image -t iso9660 -L modules media/installer-iso.scm
;;;
;;; Unattended:  add  install.disk=/dev/sda  (and install.erase=1 to wipe it)
;;; Interactive: boot without those arguments and run
;;;                 bash /etc/install/install.sh /dev/sda
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later

(use-modules (gnu)
             (gnu system install)
             (gnu services)
             (gnu services base)
             (gnu services shepherd)
             (guix gexp)
             (gnu packages bash)
             (templates appliances nas))   ; pulls the appliance closure in too

(define here (dirname (current-filename)))

(define target-config
  (local-file (string-append here "/../appliances/nas/target.scm")
              "target.scm"))

;; The channel modules the target config imports.  Baked in so the medium does
;; not need `guix pull` (and therefore does not need the network) to evaluate it.
(define channel-modules
  (local-file (string-append here "/../modules") "modules" #:recursive? #t))

(define install-script
  (local-file (string-append here "/../installer/install.sh") "install.sh"))

(define auto-install-script
  (local-file (string-append here "/../installer/auto-install.sh") "auto-install.sh"))

;; A serial console with an automatic root login.  Headless appliances are
;; installed over IPMI/serial, and the verification of this medium needs a
;; scriptable console — an installer that only answers on tty1 is untestable
;; without a display.
(define serial-getty-service
  (service agetty-service-type
           (agetty-configuration
            (tty "ttyS0")
            (baud-rate "115200")
            (term "vt100")
            ;; Guix's agetty takes a list of logins to try, not a boolean.
            (auto-login '("root")))))

(define auto-install-service
  (simple-service
   'auto-install shepherd-root-service-type
   (list (shepherd-service
          (provision '(auto-install))
          (requirement '(user-processes))
          (one-shot? #t)
          ;; The decision (install or stay interactive) lives in the script, not
          ;; here: a gexp cannot call host-side procedures, and duplicating the
          ;; /proc/cmdline parsing in Scheme buys nothing.
          (start #~(make-forkexec-constructor
                    (list #$(file-append bash "/bin/bash") "/etc/install/auto-install.sh")
                    #:log-file "/var/log/auto-install.log"))
          (stop #~(const #t))
          (documentation "Install the target system when install.disk= is given.")))))

(operating-system
  (inherit installation-os)
  (host-name "installer")
  (kernel-arguments
   ;; random.trust_cpu=on: the live system generates ssh host keys during boot,
   ;; and without a trusted entropy source that blocks for minutes inside a VM
   ;; (or on a board with no RTC-backed seed).  Harmless where RDRAND is absent.
   (cons* "console=ttyS0" "random.trust_cpu=on"
          (operating-system-user-kernel-arguments installation-os)))
  (services
   (append (operating-system-user-services installation-os)
           (list
            (simple-service 'installer-payload etc-service-type
                            (list `("install/target.scm" ,target-config)
                                  `("install/modules" ,channel-modules)
                                  `("install/install.sh" ,install-script)
                                  `("install/auto-install.sh" ,auto-install-script)))
            serial-getty-service
            auto-install-service))))
