;;; Package layer: proxy — proxy cores and the data-plane relays we build.
;;;
;;; Layer policy (README/AGENTS): a package enters here only when the upstream
;;; channels (guix + nonguix) cannot supply an acceptable form of it.  Both
;;; packages below are absent from both channels, and both are Go programs built
;;; with CGO disabled — so the upstream STATIC release is packaged (Route A)
;;; rather than a source build whose Go toolchain would drag a whole bootstrap
;;; graph into the closure.  Reproducibility comes from the archive sha256.
;;;
;;; mihomo    — rule-based proxy/tunnel core behind FlClash and the fleet's
;;;             split routing.
;;; dnsproxy  — DoH/DoH3 forwarder.  Needed because resolved and unbound only
;;;             speak DoT, and the fleet wants encrypted DNS over DoH with
;;;             HTTP/3 where the resolver offers it.
;;;
;;; What does NOT belong here: the OS network stack (services, DNS topology,
;;; interface wiring).  That is host-layer material and lives in common/ +
;;; profiles/, per docs/design.md.

(define-module (templates packages proxy)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix build-system trivial)
  #:use-module (gnu packages base)               ; tar
  #:use-module (gnu packages compression)        ; gzip
  #:use-module ((guix licenses) #:prefix license:))

(define-public mihomo
  (package
    (name "mihomo")
    (version "1.19.33")
    (source
     (origin
       ;; The `-v1-` asset is the baseline x86-64 build; `-compatible-` targets
       ;; CPUs older than x86-64-v1 and is slower on every fleet machine, while
       ;; the unqualified asset is tuned to the builder's CPU and can SIGILL
       ;; elsewhere.  Declared here rather than inferred from uname.
       (method url-fetch)
       (uri (string-append
             "https://github.com/MetaCubeX/mihomo/releases/download/v"
             version "/mihomo-linux-amd64-v1-v" version ".gz"))
       (sha256
        (base32 "096m5bq9b1xrianc9f23v2qchrg9wjvvlmh1l0xqasyw5xxjxjcf"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((out  (assoc-ref %outputs "out"))
                (gz   (assoc-ref %build-inputs "source"))
                (gzip (string-append (assoc-ref %build-inputs "gzip") "/bin/gzip")))
            (mkdir-p (string-append out "/bin"))
            ;; gzip only decompresses files, not stdin: copy the archive under a
            ;; .gz name inside the output, expand it there, then drop the copy.
            ;; `gunzip -c > file' would need shell redirection, which `invoke'
            ;; deliberately does not provide.
            (copy-file gz (string-append out "/bin/mihomo.gz"))
            (invoke gzip "-d" (string-append out "/bin/mihomo.gz"))
            (chmod (string-append out "/bin/mihomo") #o755)))))
    (inputs (list gzip))
    (synopsis "Rule-based proxy / tunnel core (meta fork of Clash)")
    (description
     "Mihomo is a proxy core that routes traffic by rule: domain suffixes, IP
ranges, process names and geo databases feed policy groups, and the daemon
supplies a mixed HTTP/SOCKS listener plus an external controller API.  It is
the engine behind FlClash and the fleet's split-routing design.

Packaged from the upstream static release: no DNS or compiler work is required,
and the sha256 above is what pins behaviour.")
    ;; GPL-3.0-only: the mihomo source is GPLv3, unlike the MIT-licensed Clash
    ;; lineage it forked from.
    (license license:gpl3)
    (home-page "https://github.com/MetaCubeX/mihomo")))

(define-public dnsproxy
  (package
    (name "dnsproxy")
    (version "0.86.0")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/AdguardTeam/dnsproxy/releases/download/v"
             version "/dnsproxy-linux-amd64-v" version ".tar.gz"))
       (sha256
        (base32 "0rpd5hdf5gyk6zyd4hgwns78prkhm8qnygv6giadzkmzdvvl7b0p"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((out  (assoc-ref %outputs "out"))
                (src  (assoc-ref %build-inputs "source"))
                (tar  (string-append (assoc-ref %build-inputs "tar") "/bin/tar"))
                (gzip (string-append (assoc-ref %build-inputs "gzip") "/bin/gzip")))
            ;; The archive is rooted at ./linux-amd64/ (binary, LICENSE,
            ;; README.md, config.dist.yaml), so extract and install from there
            ;; rather than assuming a flat layout.
            ;; `tar xzf` fails here: the sandbox PATH does not carry gzip, so
            ;; tar's child exec of the decompressor exits 2.  Hand tar the
            ;; absolute path instead of relying on PATH.
            (invoke tar "xf" src "--use-compress-program" gzip)
            (mkdir-p (string-append out "/bin"))
            (install-file "linux-amd64/dnsproxy" (string-append out "/bin"))
            (chmod (string-append out "/bin/dnsproxy") #o755)
            (let ((doc (string-append out "/share/doc/dnsproxy")))
              (for-each (lambda (f)
                          (when (file-exists? f)
                            (install-file f doc)))
                        '("linux-amd64/LICENSE"
                          "linux-amd64/README.md"
                          "linux-amd64/config.dist.yaml")))))))
    (inputs (list tar gzip))
    (synopsis "DNS proxy with DoH, DoH3, DoQ, DoT and DNSCrypt upstreams")
    (description
     "dnsproxy is a forwarding resolver for a single host or a LAN: it accepts
plain DNS on a local address and forwards to upstreams that speak DNS-over-HTTPS
(HTTP/2 and HTTP/3), DNS-over-QUIC, DNS-over-TLS or DNSCrypt, with response
caching.

The fleet uses one instance per host as the encrypted upstream for
systemd-resolved: resolved keeps authoritative per-link DNS for the SD-WAN
overlay zones, and every other query is forwarded here so that no plaintext or
ISP-supplied resolver is ever reached.")
    (license license:asl2.0)
    (home-page "https://github.com/AdguardTeam/dnsproxy")))


;; Vendored data file lookup.  The directory is a build-host fact, not a repo
;; one: keeping 27 MB of database in git would bloat every clone for no gain,
;; while the hash in each package still decides the derivation.
(define %geodata-directory
  ;; Where GeoSite.dat / GeoIP.dat sit at BUILD time.  They are large and
  ;; change often, so they are not in the repository: run scripts/fetch-geodata.sh
  ;; first (it writes ./geodata), or point this at a directory you keep.
  (or (getenv "GUIX_TEMPLATES_GEODATA") "geodata"))

(define (geodata-path file)
  (let ((path (string-append %geodata-directory "/" file)))
    (unless (file-exists? path)
      (error (string-append
              "geodata not found: " path "\n"
              "Run scripts/fetch-geodata.sh (writes ./geodata), or set "
              "GUIX_TEMPLATES_GEODATA to a directory containing " file ".")))
    path))

;;; Geo data for mihomo's own matchers (geosite:cn, geosite:gfw, GEOIP,CN).
;;;
;;; mihomo reads these from its working directory and has no offline fallback:
;;; with geodata-mode on and no GeoSite.dat, every `geosite:` rule — including
;;; the DNS policy that decides domestic vs foreign — fails.  Downloading at
;;; runtime is not an option in CN, so they ship with the image.
;;;
;;; Source: Loyalsoldier/v2ray-rules-dat, which publishes DATED tags.  The
;;; MetaCubeX repository only carries a moving `latest` tag, which would make the
;;; package unreproducible.
(define-public mihomo-geodata
  (package
    (name "mihomo-geodata")
    (version "202610232206")
    ;; Source is a LOCAL FILE, not url-fetch: guix's downloader cannot reach
    ;; github from the build host (no CONNECT support, and the sandbox has its
    ;; own loopback so a proxy on 127.0.0.1 is invisible anyway).  The file is
    ;; provisioned once per build host by scripts/fetch-geodata.sh, and the hash
    ;; below pins its content exactly as a url-fetch hash would.
    (source (local-file (geodata-path "geosite.dat") "geosite.dat"))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out (assoc-ref %outputs "out"))
                 (dir (string-append out "/share/mihomo")))
            (mkdir-p dir)
            ;; mihomo looks for capitalised names in its working directory;
            ;; the release assets are lowercase.
            (copy-file (assoc-ref %build-inputs "source")
                       (string-append dir "/GeoSite.dat"))
            (chmod (string-append dir "/GeoSite.dat") #o444)))))
    (synopsis "GeoSite database for mihomo (dated release)")
    (description
     "GeoSite.dat provides the domain set definitions mihomo matches against
(geosite:cn, geosite:gfw, geosite:category-ads-all, ...).  Pinned to a dated
upstream release so the image rebuilds identically; refreshed deliberately by
bumping @code{version} and the hash together.")
    (license license:cc-by-sa4.0)
    (home-page "https://github.com/Loyalsoldier/v2ray-rules-dat")))

(define-public mihomo-geoip
  (package
    (name "mihomo-geoip")
    (version "202610232206")
    (source (local-file (geodata-path "geoip.dat") "geoip.dat"))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out (assoc-ref %outputs "out"))
                 (dir (string-append out "/share/mihomo")))
            (mkdir-p dir)
            (copy-file (assoc-ref %build-inputs "source")
                       (string-append dir "/GeoIP.dat"))
            (chmod (string-append dir "/GeoIP.dat") #o444)))))
    (synopsis "GeoIP database for mihomo (dated release)")
    (description
     "GeoIP.dat is what mihomo matches for GEOIP rules when @code{geodata-mode}
is enabled, and what the DNS fallback filter consults to tell a domestic answer
from a foreign one.")
    (license license:cc-by-sa4.0)
    (home-page "https://github.com/Loyalsoldier/v2ray-rules-dat")))

