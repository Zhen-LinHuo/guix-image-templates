;;; Service layer: SD-WAN clients — NetBird (P0), EasyTier (P1), ZeroTier (P2).
;;;
;;; Why a service layer at all: none of the three vendors ships a Guix service,
;;; and they disagree about init systems, so each one is a thin shepherd unit
;;; running the vendor binary in the FOREGROUND (shepherd owns the pid).
;;;
;;; Membership is credentials, not configuration: setup keys, network ids and
;;; shared secrets are written by scripts/sdwan-join.sh at provisioning time
;;; into /etc/sdwan/ (root-only).  Nothing here embeds an overlay identity, so
;;; the same image can join a different tenant without a rebuild.
;;;
;;; Unprovisioned behaviour: each start script checks for its own config first
;;; and exits 0 when absent — the unit is "up but idle" instead of crash-looping
;;; or failing the boot.  Provisioning writes the config, then restarts the unit.
;;;
;;; ZeroTier needs /dev/net/tun only; the optional zerotier kernel module (an
;;; L2 fast path) is not required and is absent on Guix, which is fine.  It is
;;; started in the FOREGROUND (no -d) so shepherd owns the pid.

(define-module (templates services sdwan)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (guix packages)
  #:use-module (gnu packages base)                ; coreutils (idle placeholder)
  #:use-module (templates packages sdwan)
  #:export (zerotier-service-type
            zerotier-configuration
            netbird-service-type
            netbird-configuration
            easytier-service-type
            easytier-configuration))

;;; ---------------------------------------------------------------------------
;;; ZeroTier
;;; ---------------------------------------------------------------------------

(define zerotier-package
  ;; nonguix carries ZeroTier; nothing in Guix proper does.
  (@ (nongnu packages vpn) zerotier))

(define-record-type* <zerotier-configuration>
  zerotier-configuration make-zerotier-configuration
  zerotier-configuration?
  (package    zerotier-configuration-package (default zerotier-package))
  (data-dir   zerotier-configuration-data-dir (default "/var/lib/zerotier-one"))
  (network    zerotier-configuration-network (default #f)))   ; network id, optional

(define (zerotier-shepherd-service config)
  (let ((pkg     (zerotier-configuration-package config))
        (datadir (zerotier-configuration-data-dir config)))
    (list
     (shepherd-service
      (documentation "ZeroTier One overlay daemon.")
      (provision '(zerotier))
      (requirement '(networking))
      (start #~(begin
                 ;; shepherd's user module is minimal: read-line lives here.
                 (use-modules (ice-9 rdelim))
                 (lambda ()
                   (mkdir-p #$datadir)
                   (let ((pid (make-forkexec-constructor
                               (list #$(file-append pkg "/sbin/zerotier-one")
                                     #$datadir)
                               #:log-file "/var/log/zerotier-one.log")))
                     ;; The network id comes from the provisioning file, so one
                     ;; image can join any tenant.  Join is retried: a cold start
                     ;; needs a few seconds before its control socket answers.
                     (let* ((nwfile "/etc/sdwan/zerotier.network")
                            (nw (and (file-exists? nwfile)
                                     (call-with-input-file nwfile read-line))))
                       (when (and nw (not (string-null? nw)))
                         (let loop ((n 0))
                           (when (< n 30)
                             (unless (zero?
                                      (system* #$(file-append pkg "/sbin/zerotier-cli")
                                               "-D/var/lib/zerotier-one"
                                               "join" nw))
                               (sleep 1)
                               (loop (+ n 1)))))))
                     pid))))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define zerotier-service-type
  (service-type
   (name 'zerotier)
   (description "ZeroTier overlay network client (P2 transport).")
   (extensions (list (service-extension shepherd-root-service-type
                                        zerotier-shepherd-service)))
   (default-value (zerotier-configuration))))

;;; ---------------------------------------------------------------------------
;;; NetBird
;;; ---------------------------------------------------------------------------

(define-record-type* <netbird-configuration>
  netbird-configuration make-netbird-configuration
  netbird-configuration?
  (package   netbird-configuration-package (default netbird))
  (state     netbird-configuration-state (default "/var/lib/netbird/default.json"))
  (log-file  netbird-configuration-log-file (default "/var/log/netbird/client.log")))

(define (netbird-shepherd-service config)
  (let ((pkg   (netbird-configuration-package config))
        (state (netbird-configuration-state config))
        (log   (netbird-configuration-log-file config)))
    (list
     (shepherd-service
      (documentation "NetBird daemon (P0 transport).")
      (provision '(netbird))
      (requirement '(networking))
      (start #~(lambda ()
                 ;; Paths mirror the vendor's systemd unit: state under
                 ;; /var/lib/netbird, client log at /var/log/netbird/client.log,
                 ;; control socket at /var/run/netbird.sock — so anything that
                 ;; knows NetBird (docs, scripts, `netbird debug`) finds them
                 ;; where it expects, even though the supervisor here is
                 ;; shepherd rather than systemd.
                 (mkdir-p (dirname #$state))
                 (mkdir-p (dirname #$log))
                 (make-forkexec-constructor
                  (list #$(file-append pkg "/bin/netbird") "service" "run"
                        "-c" #$state
                        "--daemon-addr" "unix:///var/run/netbird.sock"
                        "--log-file" #$log)
                  #:log-file "/var/log/netbird-service.log")))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define netbird-service-type
  (service-type
   (name 'netbird)
   (description "NetBird overlay client daemon (P0 transport).")
   (extensions (list (service-extension shepherd-root-service-type
                                        netbird-shepherd-service)))
   (default-value (netbird-configuration))))

;;; ---------------------------------------------------------------------------
;;; EasyTier
;;; ---------------------------------------------------------------------------

(define-record-type* <easytier-configuration>
  easytier-configuration make-easytier-configuration
  easytier-configuration?
  (package     easytier-configuration-package (default easytier))
  (config-file easytier-configuration-config-file (default "/etc/sdwan/easytier.toml")))

(define (easytier-shepherd-service config)
  (let ((pkg (easytier-configuration-package config))
        (cfg (easytier-configuration-config-file config)))
    (list
     (shepherd-service
      (documentation "EasyTier mesh node (P1 transport).")
      (provision '(easytier))
      (requirement '(networking))
      (start #~(lambda ()
                 ;; No config yet = not provisioned: stay idle instead of
                 ;; respawn-looping (measured: easytier-core exits 1 without -c).
                 ;; No config = not provisioned.  Run an idle placeholder so the
                 ;; unit reports "running" instead of "failed", and log why:
                 ;; returning #f makes shepherd flag it failing and respawn-loop.
                 (mkdir-p (dirname #$cfg))
                 (if (file-exists? #$cfg)
                     (make-forkexec-constructor
                      (list #$(file-append pkg "/bin/easytier-core")
                            "-c" #$cfg)
                      #:log-file "/var/log/easytier.log")
                     (begin
                       (format #t "easytier: ~a absent — idle until scripts/sdwan-join.sh provisions it~%" #$cfg)
                       (make-forkexec-constructor
                        (list #$(file-append coreutils "/bin/sleep") "infinity"))))))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define easytier-service-type
  (service-type
   (name 'easytier)
   (description "EasyTier P2P mesh client (P1 transport).")
   (extensions (list (service-extension shepherd-root-service-type
                                        easytier-shepherd-service)))
   (default-value (easytier-configuration))))
