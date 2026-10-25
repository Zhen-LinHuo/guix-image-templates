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
             (gnu services ssh)
             (srfi srfi-1)          ; remove
             (guix gexp)
             (gnu packages bash)
             (templates appliances nas))   ; pulls the appliance closure in too

(define here (dirname (current-filename)))

;; geodata for the proxy packages: evaluating the appliance reads it, and
;; evaluation happens on the medium, not on the build machine.
(define geodata-entry
  (let ((dir (getenv "GUIX_TEMPLATES_GEODATA")))
    (and dir (list "install/geodata" (local-file dir "geodata" #:recursive? #t)))))

(define target-config
  (local-file (string-append here "/../appliances/nas/target.scm")
              "target.scm"))

;; The channel modules the target config imports.  Baked in so the medium does
;; not need `guix pull` (and therefore does not need the network) to evaluate it.
(define channel-modules
  (local-file (string-append here "/../modules") "modules" #:recursive? #t))

;; Extra module trees to bake into the medium, colon-separated.  The appliance
;; imports modules from channels the installer's own guile does not carry, and
;; `guix system init' has to evaluate the target config offline.  Set at build
;; time: GUIX_TEMPLATES_EXTRA_MODULES=/path/to/channel:/other/channel
(define extra-module-dirs
  (let ((value (getenv "GUIX_TEMPLATES_EXTRA_MODULES")))
    (if value
        (remove string-null? (string-split value #\:))
        '())))

(define extra-module-entries
  (map (lambda (dir)
         ;; Exactly a two-element list, like the entries in installation-os.
         (list (string-append "install/extra/" (basename dir))
               (local-file dir (string-append "extra-" (basename dir))
                           #:recursive? #t)))
       extra-module-dirs))

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
            ;; A string, not a list: the record comment says "list of strings",
            ;; but the service expands (list "--autologin" auto-login), so a list
            ;; produces a nested argument and agetty never starts.
            (auto-login "root"))))

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
   (cons "console=ttyS0"
         (operating-system-user-kernel-arguments installation-os)))
  (services
   (append
           (modify-services
               ;; No substitute signing key on the medium.  Activation runs
               ;; `guix archive --generate-key' before udev, and that call blocks
               ;; on getrandom() until the CRNG is initialised — in a VM it never
               ;; is, so the installer hung at "gathering entropy" and never
               ;; reached the console.  An installer publishes no substitutes.
               ;;
               ;; No sshd either: the medium is driven over the serial console,
               ;; and a daemon that answers with an auto-login root is only ever
               ;; reachable by the wrong people.
               (remove (lambda (service)
                         (eq? (service-kind service) openssh-service-type))
                       (operating-system-user-services installation-os))
             (guix-service-type config =>
                                (guix-configuration
                                 (inherit config)
                                 (generate-substitute-key? #f))))
           (list
            (simple-service 'installer-payload etc-service-type
                            (append
                             (append
                              (list `("install/target.scm" ,target-config)
                                   `("install/modules" ,channel-modules)
                                   `("install/install.sh" ,install-script)
                                   `("install/auto-install.sh" ,auto-install-script))
                              (if geodata-entry (list geodata-entry) '())
                              extra-module-entries)))
            serial-getty-service
            auto-install-service))))
