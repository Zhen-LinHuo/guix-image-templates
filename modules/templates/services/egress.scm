;;; Egress data plane services for Guix System (host layer).
;;;
;;; Design (why these daemons and not systemd-resolved):
;;;
;;;   apps → dnsmasq :53 → ┬─ <overlay zone 1> → that overlay's resolver
;;;                        ├─ <overlay zone 2> → ...
;;;                        └─ everything else   → mihomo :1053
;;;                        └─ everything else → mihomo :1053  (primary)
;;;                                             └ falls back to dnsproxy :5300
;;;
;;; This mirrors the systemd hosts exactly: there, resolved answers the overlay
;;; zones from per-link routing domains and forwards the rest to mihomo; here
;;; dnsmasq answers the same zones from `server=/zone/ip` and forwards the rest
;;; to mihomo.  ONE component decides zone-based resolution (mihomo,
;;; which owns the geo data and can send queries through the proxy), so the two
;;; families cannot give different answers for the same name.
;;;
;;; dnsproxy is no longer in the resolution chain — it is the fuse: mihomo may
;;; be absent (an unprovisioned profile, boot order, an operator stopping the
;;; client),
;;; and `strict-order' makes dnsmasq try mihomo first and dnsproxy only when
;;; mihomo stops answering.
;;;
;;; Guix System is shepherd-based: there is no systemd-resolved, so the
;;; "resolved keeps per-link DNS" trick used on systemd hosts has no equivalent
;;; here.  dnsmasq supplies per-zone routing with `server=/zone/ip` lines, and
;;; dnsproxy supplies what neither resolved nor unbound can: DoH over HTTP/3.
;;;
;;; mihomo runs alongside and deliberately has NO dns block: proxied names are
;;; resolved by the exit node (no local pollution surface), DIRECT names by
;;; dnsmasq.  Enabling mihomo's own DNS would reintroduce the failure this
;;; design removes — an internal name resolved through a public DoH, then handed
;;; to a proxy that cannot route the overlay address (502).

(define-module (templates services egress)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages admin)          ; shepherd (herd)
  #:use-module (gnu packages curl)
  #:use-module (gnu packages dns)
  #:use-module (gnu packages linux)          ; iproute
  #:use-module (guix gexp)
  #:use-module ((templates packages proxy)
                ;; Prefix: a record field named `geoip' would otherwise generate an
                ;; accessor `mihomo-geoip' that collides with the package of the
                ;; same name imported here.
                #:prefix pkg:)
  #:use-module (srfi srfi-13)
  #:use-module (guix records)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:export (mihomo-service-type
            mihomo-configuration
            dnsproxy-service-type
            dnsproxy-configuration
            split-dns-service-type
            split-dns-configuration
            egress-mode-switch-service-type
            egress-mode-switch-configuration
            geo-update-service-type
            geo-update-configuration))

;; ---------------------------------------------------------------------------
;; mihomo
;; ---------------------------------------------------------------------------

(define-record-type* <mihomo-configuration>
  mihomo-configuration make-mihomo-configuration
  mihomo-configuration?
  (mihomo            mihomo-mihomo            (default pkg:mihomo))
  (geosite           mihomo-geosite           (default pkg:mihomo-geodata))
  (geoip             mihomo-geoip             (default pkg:mihomo-geoip))
  (config-directory  mihomo-config-directory  (default "/var/lib/mihomo"))
  (log-file          mihomo-log-file          (default "/var/log/mihomo.log")))

(define (mihomo-shepherd-service config)
  (let ((mihomo  (mihomo-mihomo config))
        (geosite (mihomo-geosite config))
        (geoip   (mihomo-geoip config))
        (dir     (mihomo-config-directory config))
        (log     (mihomo-log-file config)))
    (list
     (shepherd-service
      (documentation "Rule-based proxy core (mihomo).")
      (provision '(mihomo))
      ;; '(user-processes) rather than '(networking): the latter symbol only
      ;; exists when a networking service is configured, and none of these
      ;; daemons needs a link up — dnsproxy and dnsmasq bind loopback.
      (requirement '(user-processes))
      (start
       #~(lambda ()
           ;; Geo data must sit in the working directory under capitalised
           ;; names: mihomo silently loses every `geosite:` matcher (including
           ;; the DNS policy) when they are absent, and the image has no network
           ;; access to fetch them at boot.
           ;;
           ;; SEED, do not symlink: the geo databases are also refreshed at
           ;; runtime (geo-update-service-type) and a store symlink would be
           ;; read-only, silently discarding every refresh.  A file that is
           ;; already there is therefore left untouched — the shipped version is
           ;; a floor, not a pin.
           (mkdir-p #$dir)
           (for-each (lambda (pair)
                       (let ((target (car pair)) (seed (cdr pair)))
                         ;; A 0-byte file is exactly what an unclean shutdown
                         ;; leaves behind: the journal replays onto a truncated
                         ;; inode, so `file-exists?' still says yes while mihomo
                         ;; then fails on every GEOIP/GEOIP rule at load time.
                         ;; Treat empty the same as absent and reseed from the
                         ;; store — this runs before the core is started, so the
                         ;; repair happens before validation can fail.
                         (unless (and (file-exists? target)
                                      (> (vector-ref (stat target) 7) 0))
                           (copy-file seed target)
                           ;; The store copy is 0444; geo-update replaces these
                           ;; at runtime, so leave them writable.
                           (chmod target #o644))))
                     (list (cons #$(string-append dir "/GeoSite.dat")
                                 #$(file-append geosite "/share/mihomo/GeoSite.dat"))
                           (cons #$(string-append dir "/GeoIP.dat")
                                 #$(file-append geoip "/share/mihomo/GeoIP.dat"))))
           ;; The subscription-backed config is provisioned after install: it
           ;; carries node credentials and must never be baked into an image.
           ;; Without it there is nothing to route, so report and stay idle
           ;; instead of respawn-looping.
           (if (file-exists? #$(string-append dir "/config.yaml"))
               ((make-forkexec-constructor
                 (list #$(file-append mihomo "/bin/mihomo")
                       "-d" #$dir "-f" #$(string-append dir "/config.yaml"))
                 #:log-file #$log))
               (begin
                 (format (current-error-port)
                         "mihomo: no config at ~a/config.yaml; staying idle~%"
                         #$dir)
                 ;; Shepherd treats a #f result as "failed to start", which
                 ;; would leave every freshly installed machine with a failing
                 ;; unit before it has ever been provisioned.  Return an
                 ;; explicit sentinel: the service reports itself started with
                 ;; the value `not-provisioned', which is the truth — started,
                 ;; with no worker process yet.
                 'not-provisioned))))
      ;; The stop procedure sees whatever `start' returned, so it has to cope
      ;; with the sentinel as well as with a real pid.
      (stop #~(lambda (running)
                (when (integer? running)
                  (catch 'system-error
                    (lambda () (kill running 15))
                    (lambda args #t)))
                #t))))))

(define mihomo-service-type
  (service-type
   (name 'mihomo)
   (extensions (list (service-extension shepherd-root-service-type
                                        mihomo-shepherd-service)))
   (default-value (mihomo-configuration))
   (description "Run mihomo with a host-provisioned subscription config.")))

;; ---------------------------------------------------------------------------
;; dnsproxy — the encrypted upstream (DoH / DoH3)
;; ---------------------------------------------------------------------------

(define-record-type* <dnsproxy-configuration>
  dnsproxy-configuration make-dnsproxy-configuration
  dnsproxy-configuration?
  (dnsproxy      dnsproxy-dnsproxy      (default pkg:dnsproxy))
  (listen        dnsproxy-listen        (default "127.0.0.1"))
  ;; 5353 belongs to avahi/mDNS — never take it.
  (port          dnsproxy-port          (default 5300))
  ;; Bootstrap DNS for the DoH upstream hostnames.  Without this dnsproxy
  ;; resolves "doh.pub" through the system resolver — which is dnsmasq, which
  ;; forwards here — a loop that ends in i/o timeout and took DNS down
  ;; completely on the first boot.  Explicit, operator-chosen resolvers only:
  ;; never DHCP- or ISP-supplied.
  (bootstrap     dnsproxy-bootstrap     (default '("223.5.5.5" "119.29.29.29")))
  ;; Our resolvers, never DHCP's or the ISP's.  h3:// first where the resolver
  ;; offers HTTP/3, with the same host over https:// behind it so a
  ;; QUIC-hostile network degrades instead of failing.
  (upstreams     dnsproxy-upstreams
                 (default '("h3://dns.alidns.com/dns-query"
                            "https://dns.alidns.com/dns-query"
                            "h3://doh.pub/dns-query"
                            "https://doh.pub/dns-query")))
  (cache         dnsproxy-cache         (default #t))
  (log-file      dnsproxy-log-file      (default "/var/log/dnsproxy.log")))

(define (dnsproxy-shepherd-service config)
  (let ((dnsproxy (dnsproxy-dnsproxy config))
        (listen   (dnsproxy-listen config))
        (port     (dnsproxy-port config))
        (ups      (dnsproxy-upstreams config))
        (boot     (dnsproxy-bootstrap config))
        (cache?   (dnsproxy-cache config))
        (log      (dnsproxy-log-file config)))
    (list
     (shepherd-service
      (documentation "DoH/DoH3 forwarding resolver.")
      (provision '(dnsproxy))
      ;; '(user-processes) rather than '(networking): the latter symbol only
      ;; exists when a networking service is configured, and none of these
      ;; daemons needs a link up — dnsproxy and dnsmasq bind loopback.
      (requirement '(user-processes))
      (start
       ;; Build the argv here, at configuration-evaluation time.  Doing it
       ;; inside the gexp would run append-map inside the shepherd's user
       ;; module, which only imports (shepherd service): no srfi-1, hence
       ;; "Unbound variable: append-map" at boot.
       (let ((argv (append (list (file-append dnsproxy "/bin/dnsproxy")
                                 "-l" listen "-p" (number->string port))
                           (append-map (lambda (u) (list "-u" u)) ups)
                           (append-map (lambda (b) (list "--bootstrap" b)) boot)
                           (if cache? (list "--cache") '()))))
         #~(make-forkexec-constructor '#$argv #:log-file #$log)))
      (stop #~(make-kill-destructor))))))

(define dnsproxy-service-type
  (service-type
   (name 'dnsproxy)
   (extensions (list (service-extension shepherd-root-service-type
                                        dnsproxy-shepherd-service)))
   (default-value (dnsproxy-configuration))
   (description "Forward plain DNS on loopback to DoH upstreams (fuse for
when mihomo is unavailable).")))

;; ---------------------------------------------------------------------------
;; split-dns — dnsmasq with per-zone routing to the SD-WAN resolvers
;; ---------------------------------------------------------------------------

(define-record-type* <split-dns-configuration>
  split-dns-configuration make-split-dns-configuration
  split-dns-configuration?
  (dnsmasq          split-dns-dnsmasq          (default dnsmasq))
  ;; zone → resolver, e.g. '(("corp.internal" . "10.99.0.1")).
  ;; Intentionally EMPTY by default: overlay domain names and gateway addresses
  ;; are site facts, not design decisions, and baking one site's topology into a
  ;; shared module both breaks every other site and leaks that site's addressing.
  ;; The host entry passes its own list; a zone with no resolver is simply not
  ;; routed, so an empty list still yields a valid config.
  (zones            split-dns-zones            (default '()))
  ;; Order matters: mihomo is the authoritative resolver for everything that is
  ;; not an overlay zone; dnsproxy only answers when mihomo is down.
  (upstreams        split-dns-upstreams
                    (default '("127.0.0.1#1053" "127.0.0.1#5300")))
  (port             split-dns-port             (default 53))
  (log-file         split-dns-log-file         (default "/var/log/dnsmasq.log")))

(define (split-dns-configuration-file config)
  (let ((zones (split-dns-zones config))
        (ups   (split-dns-upstreams config))
        (port  (split-dns-port config)))
    (mixed-text-file
     "dnsmasq.conf"
     "# Generated by (templates services egress).\n"
     "no-resolv\n"                     ; ignore what the DHCP client wrote
     "no-poll\n"
     "domain-needed\n"
     "bogus-priv\n"
     "listen-address=127.0.0.1\n"
     "bind-interfaces\n"
     "port=" (number->string port) "\n"
     "cache-size=1000\n"
     ;; strict-order: try the first server (mihomo) and only then the fuse;
     ;; without it dnsmasq load-balances on responsiveness and would leak half
     ;; the queries past the zone split.
     "strict-order\n"
     (string-join (map (lambda (u) (string-append "server=" u "\n")) ups) "")
     (string-join
      (map (match-lambda
             ((zone . resolver)
              (string-append "server=/" zone "/" resolver "\n")))
           zones)
      ""))))

(define (split-dns-shepherd-service config)
  (let ((dnsmasq (split-dns-dnsmasq config))
        (conf    (split-dns-configuration-file config))
        (log     (split-dns-log-file config)))
    (list
     (shepherd-service
      (documentation "Split-horizon DNS: overlay zones direct, rest via DoH.")
      (provision '(split-dns dns))
      (requirement '(dnsproxy))
      (start
       #~(make-forkexec-constructor
          ;; Short options on purpose: dnsmasq takes the long form's argument
          ;; only as --conf-file=FILE, otherwise it reports
          ;; "junk found in command line" and exits 1.
          (list #$(file-append dnsmasq "/sbin/dnsmasq") "-k" "-C" #$conf)
          #:log-file #$log))
      (stop #~(make-kill-destructor))))))

(define split-dns-service-type
  (service-type
   (name 'split-dns)
   (extensions (list (service-extension shepherd-root-service-type
                                        split-dns-shepherd-service)))
   (default-value (split-dns-configuration))
   (description "dnsmasq routing overlay zones to their own resolvers and
everything else to the local DoH forwarder.")))

;; ---------------------------------------------------------------------------
;; egress mode switch — is the default gateway a router we own?
;; ---------------------------------------------------------------------------

(define-record-type* <egress-mode-switch-configuration>
  egress-mode-switch-configuration make-egress-mode-switch-configuration
  egress-mode-switch-configuration?
  ;; MACs of transparent-proxy routers we own.  When the default gateway is one
  ;; of them, the router already provides egress, so mihomo stays in direct
  ;; mode.  Any other gateway (campus, hotel, a friend's LAN) means this host
  ;; must supply its own egress → rule mode.  Site identity comes from the MAC,
  ;; never from SSID or subnet guessing.
  (trusted-gateway-macs egress-mode-switch-trusted-gateway-macs
                        (default '()))
  (controller      egress-mode-switch-controller  (default "http://127.0.0.1:9090"))
  (secret-file     egress-mode-switch-secret-file (default "/var/lib/mihomo/secret"))
  (rule-mode       egress-mode-switch-rule-mode   (default "rule"))
  (direct-mode     egress-mode-switch-direct-mode (default "direct"))
  ;; Vixie cron syntax, as accepted by shepherd-timer.  Every two minutes keeps
  ;; the reaction to a network change short without costing anything measurable.
  (schedule        egress-mode-switch-schedule (default "*/2 * * * *")))

(define (egress-mode-switch-script config)
  ;; A POSIX shell script, not a Scheme program: the job reads the neighbour
  ;; table and PATCHes one JSON field, and shell keeps "what does it actually
  ;; run" answerable.  mixed-text-file concatenates strings and file-append
  ;; gexps, so the pieces are passed separately instead of string-append'ed.
  (let ((macs (egress-mode-switch-trusted-gateway-macs config))
        (ctl  (egress-mode-switch-controller config))
        (sec  (egress-mode-switch-secret-file config))
        (rule (egress-mode-switch-rule-mode config))
        (dir  (egress-mode-switch-direct-mode config)))
    (mixed-text-file
     "egress-mode-switch.sh"
     "#!/bin/sh\n"
     "set -u\n"
     "# Absolute paths: the shepherd's timer environment has no profile on PATH.\n"
     "IP=\"" (file-append iproute "/sbin/ip") "\"\n"
     "CURL=\"" (file-append curl "/bin/curl") "\"\n"
     (string-append
      "CTL=\"" ctl "\"\n"
      "SEC=\"" sec "\"\n"
      "RULE=\"" rule "\"\n"
      "DIRECT=\"" dir "\"\n"
      "TRUSTED=\"" (string-join macs " ") "\"\n")
     "gw=$($IP route show default | awk '{print $3; exit}')\n"
     "[ -n \"${gw:-}\" ] || exit 0\n"
     "mac=$($IP neigh show \"$gw\" | awk '{print $5; exit}')\n"
     "# Default is to provide our own egress; only a gateway we own flips it off.\n"
     "target=\"$RULE\"\n"
     "for m in $TRUSTED; do [ \"$mac\" = \"$m\" ] && target=\"$DIRECT\"; done\n"
     "[ -r \"$SEC\" ] || { echo \"egress-mode-switch: no secret at $SEC\" >&2; exit 0; }\n"
     "secret=$(cat \"$SEC\")\n"
     "code=$($CURL -s -o /dev/null -w '%{http_code}' -X PATCH \\\n"
     "        -H \"Authorization: Bearer $secret\" \\\n"
     "        -H 'Content-Type: application/json' \\\n"
     "        -d \"{\\\"mode\\\":\\\"$target\\\"}\" \"$CTL/configs\")\n"
     "[ \"$code\" = \"204\" ] || "
     "echo \"egress-mode-switch: PATCH $code (mac $mac, mode $target)\" >&2\n")))

(define (egress-mode-switch-timer config)
  ;; Shepherd timer, not an mcron job.  The Guix manual calls mcron
  ;; "historical and somewhat less flexible" and points at shepherd timers as
  ;; the way to run periodic system tasks; the timer takes Vixie cron syntax
  ;; directly, so no schedule-procedure gymnastics are needed.
  (shepherd-timer
   '(egress-mode-switch)
   (egress-mode-switch-schedule config)
   #~(#$(file-append bash "/bin/bash") #$(egress-mode-switch-script config))
   #:requirement '(user-processes)
   #:documentation "Flip mihomo between rule and direct according to the gateway."))

(define egress-mode-switch-service-type
  (service-type
   (name 'egress-mode-switch)
   (extensions (list (service-extension shepherd-root-service-type
                                        (lambda (config)
                                          (list (egress-mode-switch-timer config))))))
   (default-value (egress-mode-switch-configuration))
   (description "Flip mihomo between rule and direct mode according to the
identity of the default gateway.")))

;; ---------------------------------------------------------------------------
;; geo-update — the databases are a floor, not a pin
;; ---------------------------------------------------------------------------

(define-record-type* <geo-update-configuration>
  geo-update-configuration make-geo-update-configuration
  geo-update-configuration?
  ;; (file-name . url) pairs, refreshed once a day.
  ;;
  ;; Default source = MetaCubeX meta-rules-dat, which is what the upstream client already
  ;; runs: the upstream client ships exactly these geox-url values (geo-update-interval 24,
  ;; auto-update off) and the OpenWRT router's mihomo uses the same built-in
  ;; defaults.  Using one source everywhere keeps `geosite:cn` meaning the same
  ;; thing on every host.
  ;;
  ;; NOTE the deliberate split with the image baseline: the shipped .dat follows
  ;; a DATED, hashed release (templates/packages/proxy.scm) because a rebuild must be
  ;; reproducible, while this runtime source tracks `latest` because a long-lived
  ;; host must not stay frozen.  First successful run moves the host onto
  ;; `latest`; from then on the shipped copy is only a floor for a fresh install.
  (sources        geo-update-sources
                  (default '(("GeoSite.dat" .
                              "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat")
                             ("GeoIP.dat" .
                              "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"))))
  (config-directory geo-update-config-directory (default "/var/lib/mihomo"))
  ;; Upstream lives on github, which is unreachable directly from CN.  Point
  ;; this at the host's own proxy listener (mihomo's mixed port) so the update
  ;; job works without touching system-wide proxy settings.
  (proxy          geo-update-proxy
                  (default "http://127.0.0.1:7890"))
  (service-name   geo-update-service-name     (default "mihomo")))

(define (geo-update-script config)
  (let ((sources (geo-update-sources config))
        (dir     (geo-update-config-directory config))
        (svc     (geo-update-service-name config))
        (proxy   (geo-update-proxy config)))
    (mixed-text-file
     "geo-update.sh"
     "#!/bin/sh\n"
     "set -u\n"
     "CURL=\"" (file-append curl "/bin/curl") "\"\n"
     "HERD=\"" (file-append shepherd "/bin/herd") "\"\n"
     "DIR=\"" dir "\"\n"
     "SVC=\"" svc "\"\n"
     "PROXY=\"" proxy "\"\n"
     "PROXY_ARG=\"\"\n"
     "[ -n \"$PROXY\" ] && PROXY_ARG=\"-x $PROXY\"\n"
     "changed=0\n"
     (string-join
      (map (lambda (pair)
             (string-append
              "url=\"" (cdr pair) "\"\n"
              "tmp=\"$DIR/.new-" (car pair) "\"\n"
              "if $CURL -fsSL --max-time 300 $PROXY_ARG -o \"$tmp\" \"$url\"; then\n"
              "  # Guard against a proxy error page or a truncated download being\n"
              "  # installed as a database: a real .dat is megabytes.\n"
              "  if [ \"$(wc -c < \"$tmp\")\" -gt 1000000 ]; then\n"
              "    mv \"$tmp\" \"$DIR/" (car pair) "\" && chmod 0444 \"$DIR/" (car pair) "\" && changed=1\n"
              "  else\n"
              "    echo \"geo-update: " (car pair) " too small, keeping previous\" >&2\n"
              "    rm -f \"$tmp\"\n"
              "  fi\n"
              "else\n"
              "  echo \"geo-update: fetch failed for " (car pair) "\" >&2\n"
              "  rm -f \"$tmp\"\n"
              "fi\n"))
           sources)
      "")
     "[ \"$changed\" = 1 ] && $HERD restart \"$SVC\" || true\n")))

(define (geo-update-timers config)
  (if (null? (geo-update-sources config))
      '()          ; explicitly emptied by the host: never run a download job
      (list (shepherd-timer
             '(geo-update)
             "0 3 * * *"                ; daily 03:00, Vixie cron syntax
             #~(#$(file-append bash "/bin/bash") #$(geo-update-script config))
             #:requirement '(user-processes)
             #:documentation "Refresh GeoSite/GeoIP and restart mihomo if changed."))))

(define geo-update-service-type
  (service-type
   (name 'geo-update)
   (extensions (list (service-extension shepherd-root-service-type
                                        geo-update-timers)))
   (default-value (geo-update-configuration))
   (description "Refresh GeoSite/GeoIP databases from configured mirrors and
restart the proxy when they change.  The image ships a dated baseline; this
service is how a long-lived host stops being frozen at that baseline.")))
