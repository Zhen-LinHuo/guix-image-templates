;;; Shared helper: locate a file that ships with this repository.
;;;
;;; Assets are vendored binaries and keys.  They must be reachable from a build
;;; that has no network, which means the package definitions have to find them
;;; relative to the module tree rather than to the caller's working directory.
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (templates packages assets)
  #:use-module (guix gexp)
  #:export (asset-directory
            vendored-file))

(define (module-directory relative)
  "Directory holding RELATIVE, looked up on %load-path.

current-filename is not usable here: under `guix system' it is #f inside a macro
transformer, and inside compiled code it points into the compilation cache, where
no sibling assets exist.  %load-path is the one thing the caller sets for us, so
the module is located by walking it."
  (let loop ((dirs %load-path))
    (cond ((null? dirs) (error "cannot locate module file" relative))
          ((file-exists? (string-append (car dirs) "/" relative))
           (dirname (string-append (car dirs) "/" relative)))
          (else (loop (cdr dirs))))))

(define (asset-directory)
  "Absolute path of modules/templates/assets."
  (canonicalize-path
   (string-append (module-directory "templates/packages/assets.scm") "/../assets")))

(define (vendored-file relative)
  "The asset at RELATIVE, as a gexp input."
  (local-file (string-append (asset-directory) "/" relative)
              (basename relative)))
