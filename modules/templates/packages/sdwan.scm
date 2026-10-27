;;; Package layer: SD-WAN clients — the three overlay transports this template wire
;;; treats as P0/P1/P2 (NetBird → EasyTier → ZeroTier).
;;;
;;; Layer policy: only what the upstream channels cannot supply lands here.
;;;   zerotier  — packaged by nonguix, imported as-is by the host layer.
;;;   netbird   — Go, CGO-free: use the upstream static release (same Route A
;;;               as mihomo; a source build would drag the Go toolchain in).
;;;   easytier  — Rust: a source build needs cargo + crates.io, neither of
;;;               which is reachable from the build sandbox here.  Ship a static
;;;               build of OUR fork, vendored into assets/ so the medium builds
;;;               without a route to github.com.
;;;
;;; None of these packages carries configuration.  Overlay membership is
;;; *credentials* (setup keys, network ids, shared secrets) and lives in the
;;; provisioning step, never in the store.

(define-module (templates packages sdwan)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix build-system trivial)
  #:use-module (gnu packages base)                ; tar
  #:use-module (gnu packages compression)         ; gzip, unzip
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (templates packages assets))

(define-public netbird
  (package
    (name "netbird")
    (version "0.81.4")
    (source
     (vendored-file (string-append
                     "netbird/netbird_" version "_linux_amd64.tar.gz")))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out  (assoc-ref %outputs "out"))
                 (src  (assoc-ref %build-inputs "source"))
                 (tar  (string-append (assoc-ref %build-inputs "tar") "/bin/tar"))
                 (gz   (string-append (assoc-ref %build-inputs "gzip") "/bin/gzip"))
                 (work (string-append out "/extract")))
            (mkdir-p work)
            (mkdir-p (string-append out "/bin"))
            (copy-file src (string-append out "/nb.tar.gz"))
            ;; tar shells out to gzip via PATH, which the build sandbox does not
            ;; provide: decompress explicitly, then untar the plain archive.
            (invoke gz "-d" (string-append out "/nb.tar.gz"))
            (invoke tar "xf" (string-append out "/nb.tar") "-C" work)
            (install-file (string-append work "/netbird")
                          (string-append out "/bin"))
            (chmod (string-append out "/bin/netbird") #o555)
            (delete-file-recursively work)
            (delete-file (string-append out "/nb.tar"))))))
    (native-inputs (list tar gzip))
    (home-page "https://netbird.io")
    (synopsis "WireGuard-based overlay network client (static release)")
    (description
     "NetBird is a peer-to-peer overlay built on WireGuard with SSO-backed
identity.  This package ships the upstream static client binary; the daemon
and its state live in the host layer.")
    (license license:agpl3)))

(define-public easytier
  ;; Our fork, not upstream: the MagicDNS and domain handling the appliance
  ;; needs lives there (assets/easytier/PROVENANCE records the tag and patches).
  ;; Vendored as a tarball because the medium must build this where github.com
  ;; is unreachable — a fixed-output download would fail at the rack, not at
  ;; build time.
  (package
    (name "easytier")
    (version "2.7.0-astra.8")
    (source (vendored-file "easytier/easytier-2.7.0-astra.8-linux-x86_64.tar.gz"))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          ;; `tar' looks for gzip on PATH, not among its inputs.
          (setenv "PATH"
                  (string-append (assoc-ref %build-inputs "gzip") "/bin:"
                                 (assoc-ref %build-inputs "tar") "/bin:"
                                 (getenv "PATH")))
          (let* ((out  (assoc-ref %outputs "out"))
                 (src  (assoc-ref %build-inputs "source"))
                 (work (string-append out "/extract")))
            (mkdir-p work)
            (mkdir-p (string-append out "/bin"))
            (invoke "tar" "xzf" src "-C" work)
            (for-each
             (lambda (b)
               (let ((f (string-append work "/" b)))
                 (when (file-exists? f)
                   (install-file f (string-append out "/bin"))
                   (chmod (string-append out "/bin/" b) #o555))))
             '("easytier-core" "easytier-cli"))
            (install-file (string-append work "/PROVENANCE")
                          (string-append out "/share/doc/easytier"))
            (install-file (string-append work "/LICENSE")
                          (string-append out "/share/doc/easytier"))
            (delete-file-recursively work)))))
    (native-inputs (list tar gzip))
    (home-page "https://github.com/EasyTier/EasyTier")
    (synopsis "Decentralised mesh VPN client (static build from our fork)")
    (description
     "EasyTier builds a peer-to-peer mesh over TCP/UDP/QUIC/WebSocket with
WireGuard-based encryption.  This package ships easytier-core and easytier-cli
built from the fork tag that carries the MagicDNS and domain-handling fixes the
appliance relies on; the tarball is vendored so the build needs no network.")
    (license license:lgpl3)))
