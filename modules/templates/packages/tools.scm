;;; templates --- small tools the base system leaves out
;;; Copyright © 2026 Zhen-Lin Huo <zhen-lin.huo@gmx.com>
;;;
;;; This file is part of guix-image-templates.
;;;
;;; guix-image-templates is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU General Public License as published
;;; by the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; guix-image-templates is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
;;; Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License along
;;; with guix-image-templates.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;;
;;; Tools that a running Guix System lacks not because the package is absent
;;; but because it lives in a place the system profile does not expose.  Each
;;; one here installs a single command rather than a whole package's worth of
;;; them, so the system profile stays close to %base-packages.
;;;
;;; Code:

(define-module (templates packages tools)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix build-system trivial)
  #:use-module (guix licenses)
  #:use-module (gnu packages base)                ; glibc
  #:export (glibc-getent))

(define-public glibc-getent
  (package
    (name "glibc-getent")
    (version (package-version glibc))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:builder
           ;; No (guix build utils) here: a trivial builder runs with a bare
           ;; load path, and importing it fails with "no code for module".
           ;; `mkdir' and `symlink' are core Guile, which is all this needs.
           #~(begin
               (unless (file-exists? #$output) (mkdir #$output))
               (let ((bin (string-append #$output "/bin")))
                 (unless (file-exists? bin) (mkdir bin))
                 ;; A symlink, not a copy: getent reads the host's own
                 ;; /etc/nsswitch.conf and /etc/resolv.conf at run time, so it
                 ;; must be the very same binary the C library ships.
                 (symlink #$(file-append glibc "/bin/getent")
                          (string-append bin "/getent"))))))
    (synopsis "Query the name service switch, without glibc on PATH")
    (description
     "Installs just @command{getent} from the GNU C Library.  Guix System keeps
glibc off @code{PATH} because it is an implicit input rather than an installed
package, which leaves @command{getent} unavailable even though the library is
present.  Adding the whole package would also expose @command{ld.so},
@command{iconv} and the locale tools; this provides only the query tool, so
@command{getent hosts}, @command{getent passwd} and friends work while the
system profile stays otherwise unchanged.")
    (home-page "https://www.gnu.org/software/libc/")
    (license lgpl2.1+)))
