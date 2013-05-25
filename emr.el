;;; emr.el --- Emacs refactoring system.

;; Copyright (C) 2013 Chris Barrett

;; Author: Chris Barrett <chris.d.barrett@me.com>
;; Version: 0.3.0
;; Keywords: tools convenience refactoring
;; Package-Requires: ((s "1.3.1") (dash "1.2.0") (cl-lib "0.2") (popup "0.5.0") (emacs "24.1") (list-utils "0.3.0"))
;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Add this package to your load path and add an autoload for `emr-show-refactor-menu`.
;; Bind the `emr-show-refactor-menu` command to something convenient.
;;
;; (autoload 'emr-show-refactor-menu "emr")
;; (define-key prog-mode-map (kbd "M-RET") 'emr-show-refactor-menu)
;; (eval-after-load "emr" '(emr-initialize))
;;
;; See README.md for more information.

;;; Code:

(require 'dash)
(require 's)
(require 'cl-lib)
(require 'popup)

(defgroup emacs-refactor nil
  "Provides refactoring tools for Emacs."
  :group 'tools
  :prefix "emr-")

(defcustom emr-report-actions t
  "Non-nil means display an indication when a refactoring results in an insertion."
  :type 'checkbox
  :group 'emacs-refactor)

;;; ----------------------------------------------------------------------------
;;; Utility functions
;;;
;;; Functions that could be useful to extensions.

(defun emr-move-above-defun ()
  "Move to the start of the current defun.
If the defun is preceded by comments, move above them."
  (interactive)
  (beginning-of-defun)
  (while (save-excursion
           (forward-line -1)
           (emr-looking-at-comment?))
    (forward-line -1)))

(defun emr-looking-at-string? ()
  "Return non-nil if point is inside a string."
  (and (in-string-p) t))

(defun emr-looking-at-comment? ()
  "Non-nil if point is on a comment."
  (-contains? '(font-lock-comment-face font-lock-comment-delimiter-face)
              (face-at-point)))

(defun emr-blank? (str)
  "Non-nil if STR is null, empty or whitespace-only."
  (s-blank? (s-trim str)))

(defun emr-insert-above-defun (str)
  "Insert and indent STR above the current top level form.
Return the position of the end of STR."
  (save-excursion
    (let ((mark-ring nil))
      ;; Move to position above top-level form.
      (beginning-of-line)
      (emr-move-above-defun)
      (open-line 2)
      ;; Perform insertion.
      (insert str)
      ;; Ensure there is leading blank line.
      (save-excursion
        (emr-move-above-defun)
        (unless (save-excursion
                  (forward-line -1)
                  (emr-blank? (thing-at-point 'line)))
          (open-line 1)))
      (point))))

;;; ----------------------------------------------------------------------------
;;; Reporting
;;;
;;; These commands may be used to describe the changes made to buffers. See
;;; example in emr-elisp.

(defun* emr:ellipsize (str &optional (maxlen (window-width (minibuffer-window))))
  (if (> (length str) maxlen)
      (concat (substring-no-properties str 0 (1- maxlen)) "…")
    str))

(defun emr:indexed-lines (str)
  "Split string STR into a list of conses.
The index is the car and the line is the cdr."
  (--map-indexed (cons it-index it) (s-lines str)))

(defun emr:diff-lines (str1 str2)
  "Get the lines that differ between strings STR1 and STR2."
  (--remove (equal (car it) (cdr it))
            (-zip (emr:indexed-lines str1) (emr:indexed-lines str2))))

(defun* emr:report-action (description line text)
  "Report the action that occured at the point of difference."
  (when emr-report-actions

    (->> (if (s-blank? text)
             "nil"
           (replace-regexp-in-string "[ \n\r\t]+" " " text))

      (format "%s line %s: %s" description line)
      (emr:ellipsize)
      (message))))

(defun emr:line-visible? (line)
  "Return true if LINE is within the visible bounds of the current window."
  (let* ((min (line-number-at-pos (window-start)))
         (max (line-number-at-pos (window-end))))
    (and (>= line min) (<= line max))))

(defmacro emr-reporting-buffer-changes (description &rest body)
  "Perform a refactoring action and notify the user of changes that were made.
* DESCRIPTION describes the overall action, and is shown to the user.
* BODY forms perform the refactor action."
  (declare (indent 1))
  `(let ((before-changes (buffer-string)))
     ,@body
     ;; Report changes.
     (-when-let (diff (and emr-report-actions
                           (car (emr:diff-lines before-changes (buffer-string)))))
       (cl-destructuring-bind (_ . (line . text)) diff
         (unless (emr:line-visible? line)
           (emr:report-action ,description line text))))))

;;; ----------------------------------------------------------------------------
;;; Popup menu
;;; Items to be displayed in the refactoring popup menu are added using the
;;; `emr-declare-action' macro.

(defvar emr:refactor-commands (make-hash-table :test 'equal)
  "A hashtable of refactoring commands used to build menu items.")

;;;###autoload
(defun emr-initialize ()
  "Activate language support for EMR."
  (eval-after-load "lisp-mode" '(require 'emr-elisp))
  (eval-after-load "cc-mode" '(require 'emr-c)))

;;;###autoload
(defmacro* emr-declare-action (function &key modes title (predicate t) description)
  "Define a refactoring command.

* FUNCTION is the refactoring command to perform.

* MODE is the major mode in which this

* TITLE is the name of the command that will be displayed in the popup menu.

* PREDICATE is a condition that must be satisfied to display this item.
If PREDICATE is not supplied, the item will always be visible for this mode.

* DESCRIPTION is shown to the left of the title in the popup menu."
  (declare (indent 1))
  (cl-assert modes)
  (cl-assert title)
  (let ((modes (if (symbolp modes) (list modes) modes)))
    `(let ((fname ',(intern (format "%s--%s" function title)))
           (fn (lambda ()
                 (when (and (apply 'derived-mode-p ',modes)
                            (ignore-errors
                              (eval ,predicate)))
                   (popup-make-item ,title :value ',function :summary ,description)))))
       ;; Create a function and insert it into the commands table.
       (puthash fname fn emr:refactor-commands)
       ',function)))

(defun emr:hash-values (ht)
  (cl-loop for v being the hash-values in ht collect v))

;;;###autoload
(defun emr-show-refactor-menu ()
  "Show the extraction menu at point."
  (interactive)
  (-if-let (actions (->> emr:refactor-commands
                      (emr:hash-values)
                      (-map 'funcall)
                      (-remove 'null)))
    (atomic-change-group
      (-when-let (action (popup-menu* actions :isearch t))
        (call-interactively action)))
    (error "No refactorings available")))

(provide 'emr)

;; Local Variables:
;; lexical-binding: t
;; End:

;;; emr.el ends here
