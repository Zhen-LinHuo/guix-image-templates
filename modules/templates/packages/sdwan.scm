;;; Package layer: SD-WAN clients — the three overlay transports the fleet
;;; treats as P0/P1/P2 (NetBird → EasyTier → ZeroTier).
;;;
;;; Layer policy: only what the upstream channels cannot supply lands here.
;;;   zerotier  — packaged by nonguix, imported as-is by the host layer.
;;;   netbird   — Go, CGO-free: use the upstream static release (same Route A
;;;               as mihomo; a source build would drag the Go toolchain in).
;;;   easytier  — Rust: a source build needs cargo + crates.io, neither of
;;;               which is reachable from the build sandbox here.  Ship the
;;;               upstream static release and pin it by sha256.
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
  #:use-module ((guix licenses) #:prefix license:))

(define-public netbird
  (package
    (name "netbird")
    (version "0.81.4")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/netbirdio/netbird/releases/download/v"
             version "/netbird_" version "_linux_amd64.tar.gz"))
       (sha256
        (base32 "0rbiwshwfc8kwp0hhwsj3afaidp4iwbcj2ym2cjxqkaqjvixgcz9"))))
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
  (package
    (name "easytier")
    (version "2.6.4")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/EasyTier/EasyTier/releases/download/v"
             version "/easytier-linux-x86_64-v" version ".zip"))
       (sha256
        (base32 "1mnz15y3bd3v8knmz89gs3jpgpbc8bhifzg4dyk8yrdsxpm5kdk1"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out   (assoc-ref %outputs "out"))
                 (src   (assoc-ref %build-inputs "source"))
                 (unzip (string-append (assoc-ref %build-inputs "unzip") "/bin/unzip"))
                 (work  (string-append out "/extract")))
            (mkdir-p work)
            (mkdir-p (string-append out "/bin"))
            (invoke unzip "-q" src "-d" work)
            (for-each
             (lambda (b)
               (let ((f (string-append work "/easytier-linux-x86_64/" b)))
                 (when (file-exists? f)
                   (install-file f (string-append out "/bin"))
                   (chmod (string-append out "/bin/" b) #o555))))
             '("easytier-core" "easytier-cli"))
            (delete-file-recursively work)))))
    (native-inputs (list unzip))
    (home-page "https://easytier.cn")
    (synopsis "Decentralised mesh VPN client (static release)")
    (description
     "EasyTier builds a peer-to-peer mesh over TCP/UDP/QUIC/WebSocket with
WireGuard-based encryption.  This package ships easytier-core and easytier-cli
from the upstream static release.")
    (license license:asl2.0)))
