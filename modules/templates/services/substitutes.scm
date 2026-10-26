;;; modules/templates/services/substitutes.scm — where binaries come from.
;;;
;;; The appliance runs the non-libre kernel from nonguix.  If the nonguix
;;; substitute server is not listed AND its signing key is not authorised,
;;; `guix system init' finds no binary for the kernel and compiles Linux from
;;; source on the target machine — a 3 GB install dies with the OOM killer long
;;; before it finishes, and a real machine just sits there for hours.
;;;
;;; So the list and the key travel together, in one place, and every medium and
;;; every installed system uses this one definition.
;;;
;;; Site policy (an internal cache in front of these) belongs in the site layer
;;; that wraps the appliance, not here.
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (templates services substitutes)
  #:use-module (guix gexp)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:export (%appliance-substitute-urls
            nonguix-signing-key
            authorised-substitute-keys))

(define %appliance-substitute-urls
  ;; nonguix first: it is the only one that carries the kernel this appliance
  ;; boots.  The Guix servers follow for everything else.
  '("https://substitutes.nonguix.org"
    "https://mirror.sjtu.edu.cn/guix/"
    "https://ci.guix.gnu.org"
    "https://bordeaux.guix.gnu.org"))

; Relative to this file, which is how local-file resolves it — and it has to
;; live inside modules/, because that is the tree a medium copies into the store.
(define nonguix-signing-key
  (local-file "../assets/nonguix-signing-key.pub"))

(define (authorised-substitute-keys)
  "The Guix project's keys plus nonguix's, which is what the URLs above need."
  (cons nonguix-signing-key %default-authorized-guix-keys))
