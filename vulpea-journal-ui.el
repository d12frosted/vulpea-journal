;;; vulpea-journal-ui.el --- VUI-based UI for vulpea-journal -*- lexical-binding: t; -*-
;;
;; Copyright (c) 2024-2025 Boris Buliga <boris@d12frosted.io>
;;
;; Author: Boris Buliga <boris@d12frosted.io>
;; Maintainer: Boris Buliga <boris@d12frosted.io>
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see
;; <http://www.gnu.org/licenses/>.
;;
;; This file is not part of GNU Emacs.
;;
;; URL: https://github.com/d12frosted/vulpea-journal
;;
;;; Commentary:
;;
;; VUI-based declarative UI for vulpea-journal.
;;
;; This module provides a modern, component-based UI using vui.el.
;; Components are reactive and automatically re-render when state changes.
;;
;; Built-in widgets:
;; - `calendar' - Interactive month calendar
;; - `created-today' - Notes created on current date
;; - `links-to-today' - Notes linking to today's journal
;; - `previous-years' - Same date in previous years
;;
;; Creating custom widgets:
;;
;;   (vulpea-journal-ui-register-widget
;;    'my-widget
;;    :component 'my-widget-component
;;    :order 25)
;;
;;   (defcomponent my-widget-component ()
;;     :render
;;     (let ((date (use-vui-journal-date)))
;;       (vui-vstack
;;        (vui-text "My Widget" :face 'vulpea-journal-ui-widget-title)
;;        ...)))
;;
;; Then add to `vulpea-journal-ui-widgets':
;;
;;   (add-to-list 'vulpea-journal-ui-widgets 'my-widget)
;;
;;; Code:

(require 'vui)
(require 'vulpea)
(require 'vulpea-db)
(require 'vulpea-db-query)
(require 'calendar)

;; Forward declarations
(declare-function vulpea-journal-find-note "vulpea-journal")
(declare-function vulpea-journal-note "vulpea-journal")
(declare-function vulpea-journal-note-p "vulpea-journal")
(declare-function vulpea-journal-dates-in-month "vulpea-journal")
(declare-function vulpea-journal--date-from-note "vulpea-journal")

(defvar vulpea-journal-widgets-buffer-name)

;;; Contexts
;; Share data across the component tree without prop drilling

(defcontext vui-journal-date)
(defcontext vui-journal-set-date)
(defcontext vui-journal-note-buffer)

;;; Faces

(defgroup vulpea-journal-ui nil
  "VUI-based UI for vulpea-journal."
  :group 'vulpea-journal)

(defface vulpea-journal-ui-header
  '((t :inherit org-level-1))
  "Face for journal header."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-widget-title
  '((t :inherit org-level-2))
  "Face for widget titles."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-calendar-today
  '((t :inherit highlight :weight bold))
  "Face for today in calendar."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-calendar-entry
  '((t :inherit bold))
  "Face for days with journal entries."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-calendar-selected
  '((t :inherit region))
  "Face for selected day in calendar."
  :group 'vulpea-journal-ui)

;;; Widget Registry

(defvar vulpea-journal-ui--widget-registry (make-hash-table :test 'eq)
  "Registry of available widgets.
Keys are widget names (symbols), values are plists with:
  :component - Symbol naming the vui component
  :order - Number for display order (lower = earlier)")

(defcustom vulpea-journal-ui-widgets
  '(calendar created-today links-to-today previous-years)
  "List of widgets to display in journal view.
Each element is a symbol naming a registered widget.
Order in this list is secondary to widget :order property."
  :type '(repeat symbol)
  :group 'vulpea-journal-ui)

(defun vulpea-journal-ui-register-widget (name &rest props)
  "Register a widget NAME with PROPS.

PROPS is a plist with:
  :component - Symbol naming the vui component to render
  :order - Number for display order (default 50, lower = earlier)

Example:
  (vulpea-journal-ui-register-widget
   \\='my-tasks
   :component \\='my-tasks-widget
   :order 15)"
  (puthash name props vulpea-journal-ui--widget-registry))

(defun vulpea-journal-ui-get-widget (name)
  "Get widget definition for NAME from registry."
  (gethash name vulpea-journal-ui--widget-registry))

(defun vulpea-journal-ui--get-enabled-widgets ()
  "Return list of enabled widget definitions, sorted by order."
  (let ((widgets nil))
    (dolist (name vulpea-journal-ui-widgets)
      (when-let ((def (vulpea-journal-ui-get-widget name)))
        (push (cons name def) widgets)))
    (sort widgets
          (lambda (a b)
            (< (or (plist-get (cdr a) :order) 50)
               (or (plist-get (cdr b) :order) 50))))))

;;; Navigation Bar Component

(defcomponent vui-journal-nav-bar ()
  :render
  (let ((set-date (use-vui-journal-set-date)))
    (vui-hstack
     :spacing 1
     (vui-button "< Prev"
       :on-click (lambda ()
                   (let ((date (use-vui-journal-date)))
                     (funcall set-date
                              (time-subtract date (days-to-time 1))))))
     (vui-button "Today"
       :on-click (lambda ()
                   (funcall set-date (current-time))))
     (vui-button "Next >"
       :on-click (lambda ()
                   (let ((date (use-vui-journal-date)))
                     (funcall set-date
                              (time-add date (days-to-time 1)))))))))

;;; Calendar Widget Component

(defcustom vulpea-journal-ui-calendar-week-start 1
  "Day to start week on. 0 = Sunday, 1 = Monday."
  :type '(choice (const :tag "Sunday" 0)
          (const :tag "Monday" 1))
  :group 'vulpea-journal-ui)

(defun vulpea-journal-ui--calendar-build-rows (month year current-day entry-days today-day today-month today-year set-date)
  "Build calendar rows for MONTH/YEAR.
CURRENT-DAY is the selected day.
ENTRY-DAYS is list of days with journal entries.
TODAY-DAY/TODAY-MONTH/TODAY-YEAR identify today.
SET-DATE is callback to change date."
  (let* ((first-day-of-month (encode-time 0 0 0 1 month year))
         (first-dow (decoded-time-weekday (decode-time first-day-of-month)))
         (first-dow-adjusted (mod (- first-dow vulpea-journal-ui-calendar-week-start) 7))
         (days-in-month (calendar-last-day-of-month month year))
         (day 1)
         (rows nil))
    ;; Build weeks
    (while (<= day days-in-month)
      (let ((week nil))
        ;; Padding for first week
        (when (and (= day 1) (> first-dow-adjusted 0))
          (dotimes (_ first-dow-adjusted)
            (push "" week)))
        ;; Days in this week
        (while (and (<= day days-in-month) (< (length week) 7))
          (let* ((d day)
                 (is-today (and (= d today-day)
                                (= month today-month)
                                (= year today-year)))
                 (is-selected (= d current-day))
                 (has-entry (member d entry-days))
                 (face (cond
                        (is-today 'vulpea-journal-ui-calendar-today)
                        (has-entry 'vulpea-journal-ui-calendar-entry)
                        (t nil)))
                 (day-text (format "%2d" d)))
            (push (vui-button (if is-selected
                                  (format "[%s]" day-text)
                                (format " %s " day-text))
                    :face face
                    :on-click (lambda ()
                                (funcall set-date
                                         (encode-time 0 0 0 d month year))))
                  week))
          (setq day (1+ day)))
        ;; Pad end of last week
        (while (< (length week) 7)
          (push "" week))
        (push (nreverse week) rows)))
    (nreverse rows)))

(defcomponent vui-journal-calendar ()
  :render
  (let* ((date (use-vui-journal-date))
         (set-date (use-vui-journal-set-date))
         (decoded (decode-time date))
         (month (decoded-time-month decoded))
         (year (decoded-time-year decoded))
         (current-day (decoded-time-day decoded))
         ;; Get days with entries
         (entry-days (use-memo (month year)
                       (mapcar (lambda (d)
                                 (decoded-time-day (decode-time d)))
                               (vulpea-journal-dates-in-month month year))))
         ;; Today info
         (today (decode-time))
         (today-day (decoded-time-day today))
         (today-month (decoded-time-month today))
         (today-year (decoded-time-year today))
         ;; Day name headers
         (day-names (if (= vulpea-journal-ui-calendar-week-start 1)
                        '("Mo" "Tu" "We" "Th" "Fr" "Sa" "Su")
                      '("Su" "Mo" "Tu" "We" "Th" "Fr" "Sa")))
         ;; Column specs
         (columns (mapcar (lambda (name)
                            (list :header name :width 4 :align :center))
                          day-names))
         ;; Build rows
         (rows (vulpea-journal-ui--calendar-build-rows
                month year current-day entry-days
                today-day today-month today-year set-date))
         (month-name (calendar-month-name month)))
    (vui-vstack
     ;; Widget title
     (vui-text "Calendar" :face 'vulpea-journal-ui-widget-title)
     ;; Month/year header with navigation
     (vui-hstack
      :spacing 1
      (vui-button "<"
        :on-click (lambda ()
                    (funcall set-date
                             (encode-time 0 0 0 1
                                          (if (= month 1) 12 (1- month))
                                          (if (= month 1) (1- year) year)))))
      (vui-box (vui-text (format "%s %d" month-name year) :face 'bold)
        :width 15
        :align :center)
      (vui-button ">"
        :on-click (lambda ()
                    (funcall set-date
                             (encode-time 0 0 0 1
                                          (if (= month 12) 1 (1+ month))
                                          (if (= month 12) (1+ year) year))))))
     (vui-newline)
     ;; Calendar table
     (vui-table
      :columns columns
      :rows rows))))

;;; Created Today Widget

(defcustom vulpea-journal-ui-created-today-exclude-journal t
  "If non-nil, exclude journal notes from Created Today widget."
  :type 'boolean
  :group 'vulpea-journal-ui)

(defun vulpea-journal-ui--query-created-today (date)
  "Return notes created on DATE."
  (let ((date-str (format-time-string "%Y-%m-%d" date)))
    (vulpea-db-query
     (lambda (note)
       (and (= (vulpea-note-level note) 0)
            (when-let ((created (cdr (assoc "CREATED" (vulpea-note-properties note)))))
              (string-prefix-p date-str created))
            (or (not vulpea-journal-ui-created-today-exclude-journal)
                (not (vulpea-journal-note-p note))))))))

(defcomponent vui-journal-note-item (note)
  :render
  (let* ((title (vulpea-note-title note))
         (tags (vulpea-note-tags note))
         (created (cdr (assoc "CREATED" (vulpea-note-properties note))))
         (time-str (if (and created (string-match "\\([0-9]+:[0-9]+\\)" created))
                       (match-string 1 created)
                     "     ")))
    (vui-hstack
     :spacing 1
     (vui-text time-str :face 'shadow)
     (vui-button title
       :face 'link
       :on-click (lambda () (vulpea-visit note t)))
     (when tags
       (vui-text (string-join (mapcar (lambda (tag) (concat "#" tag)) tags) " ")
         :face 'shadow)))))

(defcomponent vui-journal-created-today ()
  :state ((notes nil)
          (loading t)
          (collapsed nil))

  :render
  (let* ((date (use-vui-journal-date))
         (count (length notes)))

    ;; Reload when date changes
    (use-effect (date)
      (vui-batch
       (vui-set-state :loading t)
       (vui-set-state :notes (vulpea-journal-ui--query-created-today date))
       (vui-set-state :loading nil)))

    (vui-vstack
     ;; Header
     (vui-hstack
      :spacing 1
      (vui-button (if collapsed "▸" "▾")
        :on-click (lambda () (vui-set-state :collapsed (not collapsed))))
      (vui-text "Created Today" :face 'vulpea-journal-ui-widget-title)
      (when (> count 0)
        (vui-text (format "(%d)" count) :face 'shadow)))
     ;; Content
     (unless collapsed
       (if loading
           (vui-text "Loading..." :face 'shadow)
         (if (null notes)
             (vui-text "  No notes created today" :face 'shadow)
           (vui-vstack
            :indent 2
            (vui-list notes
                      (lambda (note)
                        (vui-component 'vui-journal-note-item
                          :key (vulpea-note-id note)
                          :note note))
                      #'vulpea-note-id))))))))

;;; Links to Today Widget

(defun vulpea-journal-ui--query-links-to-today (date)
  "Return notes linking to today's journal note for DATE."
  (when-let* ((today-note (vulpea-journal-find-note date))
              (today-id (vulpea-note-id today-note)))
    (vulpea-db-query-by-links-some (list today-id))))

(defcomponent vui-journal-links-to-today ()
  :state ((notes nil)
          (loading t)
          (collapsed nil))

  :render
  (let* ((date (use-vui-journal-date))
         (count (length notes)))

    ;; Reload when date changes
    (use-effect (date)
      (vui-batch
       (vui-set-state :loading t)
       (vui-set-state :notes (vulpea-journal-ui--query-links-to-today date))
       (vui-set-state :loading nil)))

    (vui-vstack
     ;; Header
     (vui-hstack
      :spacing 1
      (vui-button (if collapsed "▸" "▾")
        :on-click (lambda () (vui-set-state :collapsed (not collapsed))))
      (vui-text "Links to Today" :face 'vulpea-journal-ui-widget-title)
      (when (> count 0)
        (vui-text (format "(%d)" count) :face 'shadow)))
     ;; Content
     (unless collapsed
       (if loading
           (vui-text "Loading..." :face 'shadow)
         (if (null notes)
             (vui-text "  No notes link to today" :face 'shadow)
           (vui-vstack
            :indent 2
            (vui-list notes
                      (lambda (note)
                        (let ((title (vulpea-note-title note))
                              (tags (vulpea-note-tags note)))
                          (vui-hstack
                           :spacing 1
                           (vui-button title
                             :face 'link
                             :on-click (lambda () (vulpea-visit note t)))
                           (when tags
                             (vui-text (string-join
                                        (mapcar (lambda (tag) (concat "#" tag)) tags)
                                        " ")
                               :face 'shadow)))))
                      #'vulpea-note-id))))))))

;;; Previous Years Widget

(defcustom vulpea-journal-ui-previous-years-count 5
  "Number of years to look back."
  :type 'integer
  :group 'vulpea-journal-ui)

(defcustom vulpea-journal-ui-previous-years-preview-chars 150
  "Number of characters to show in preview."
  :type 'integer
  :group 'vulpea-journal-ui)

(defun vulpea-journal-ui--query-previous-years (date)
  "Return journal notes from same date in previous years for DATE."
  (let* ((decoded (decode-time date))
         (month (decoded-time-month decoded))
         (day (decoded-time-day decoded))
         (year (decoded-time-year decoded))
         (results nil))
    (dotimes (i vulpea-journal-ui-previous-years-count)
      (let* ((past-year (- year (1+ i)))
             (check-date (encode-time 0 0 0 day month past-year)))
        (when-let ((note (vulpea-journal-find-note check-date)))
          (push (list :date check-date
                      :years-ago (1+ i)
                      :note note)
                results))))
    (nreverse results)))

(defun vulpea-journal-ui--get-note-preview (note max-chars)
  "Get preview of NOTE content, up to MAX-CHARS."
  (when-let ((path (vulpea-note-path note)))
    (when (file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path nil 0 (* max-chars 3))
        (goto-char (point-min))
        ;; Skip front matter
        (while (and (not (eobp))
                    (looking-at "^\\(#\\+\\|:\\|$\\)"))
          (forward-line 1))
        (let ((start (point))
              (end (min (+ (point) max-chars) (point-max))))
          (when (< start end)
            (string-trim (buffer-substring-no-properties start end))))))))

(defcomponent vui-journal-previous-year-entry (entry)
  :state ((expanded nil))

  :render
  (let* ((date (plist-get entry :date))
         (years-ago (plist-get entry :years-ago))
         (note (plist-get entry :note))
         (date-str (format-time-string "%Y-%m-%d" date))
         (preview (when expanded
                    (vulpea-journal-ui--get-note-preview
                     note
                     vulpea-journal-ui-previous-years-preview-chars))))
    (vui-vstack
     (vui-hstack
      :spacing 1
      (vui-button (if expanded "▾" "▸")
        :on-click (lambda () (vui-set-state :expanded (not expanded))))
      (vui-button date-str
        :face 'link
        :on-click (lambda () (vulpea-visit note t)))
      (vui-text (format "(%d year%s ago)"
                        years-ago
                        (if (= years-ago 1) "" "s"))
        :face 'shadow))
     (when (and expanded preview)
       (vui-vstack
        :indent 4
        (vui-text (concat preview "...") :face 'font-lock-comment-face))))))

(defcomponent vui-journal-previous-years ()
  :state ((entries nil)
          (loading t)
          (collapsed nil))

  :render
  (let* ((date (use-vui-journal-date))
         (count (length entries)))

    ;; Reload when date changes
    (use-effect (date)
      (vui-batch
       (vui-set-state :loading t)
       (vui-set-state :entries (vulpea-journal-ui--query-previous-years date))
       (vui-set-state :loading nil)))

    (vui-vstack
     ;; Header
     (vui-hstack
      :spacing 1
      (vui-button (if collapsed "▸" "▾")
        :on-click (lambda () (vui-set-state :collapsed (not collapsed))))
      (vui-text "This Day in Previous Years" :face 'vulpea-journal-ui-widget-title)
      (when (> count 0)
        (vui-text (format "(%d)" count) :face 'shadow)))
     ;; Content
     (unless collapsed
       (if loading
           (vui-text "Loading..." :face 'shadow)
         (if (null entries)
             (vui-text "  No entries from previous years" :face 'shadow)
           (vui-vstack
            :indent 2
            (vui-list entries
                      (lambda (entry)
                        (vui-component 'vui-journal-previous-year-entry
                          :key (format-time-string "%Y%m%d" (plist-get entry :date))
                          :entry entry))
                      (lambda (entry)
                        (format-time-string "%Y%m%d" (plist-get entry :date)))))))))))

;;; Main Journal View Component

(defcomponent vui-journal-widgets-view ()
  :render
  (let ((date (use-vui-journal-date))
        (widgets (vulpea-journal-ui--get-enabled-widgets)))
    (vui-vstack
     ;; Header
     (vui-text (format-time-string "Journal: %Y-%m-%d %A" date)
       :face 'vulpea-journal-ui-header)
     ;; Navigation
     (vui-component 'vui-journal-nav-bar)
     (vui-newline)
     ;; Widgets from registry
     (if (null widgets)
         (vui-text "No widgets configured. See `vulpea-journal-ui-widgets'."
           :face 'shadow)
       (apply #'vui-fragment
              (mapcan (lambda (widget-entry)
                        (let* ((name (car widget-entry))
                               (def (cdr widget-entry))
                               (component (plist-get def :component)))
                          (list (vui-component component :key name)
                                (vui-newline))))
                      widgets))))))

;;; Root Component with Context Providers

(defcomponent vui-journal-root (initial-date)
  :state ((date nil))

  :on-mount
  (unless date
    (vui-set-state :date (or initial-date (current-time))))

  :render
  (vui-journal-date-provider
      (or date (current-time))
    (vui-journal-set-date-provider
        (lambda (new-date)
          (vui-set-state :date new-date))
      (vui-component 'vui-journal-widgets-view))))

;;; Public API

;;;###autoload
(defun vulpea-journal-ui-open (&optional date)
  "Open journal widgets view for DATE using vui.
DATE defaults to today."
  (interactive)
  (let ((buffer-name (or vulpea-journal-widgets-buffer-name "*vulpea-journal*")))
    (vui-mount (vui-component 'vui-journal-root
                 :initial-date (or date (current-time)))
               buffer-name)
    (pop-to-buffer buffer-name)))

;;; Register Built-in Widgets

(vulpea-journal-ui-register-widget
 'calendar
 :component 'vui-journal-calendar
 :order 10)

(vulpea-journal-ui-register-widget
 'created-today
 :component 'vui-journal-created-today
 :order 20)

(vulpea-journal-ui-register-widget
 'links-to-today
 :component 'vui-journal-links-to-today
 :order 30)

(vulpea-journal-ui-register-widget
 'previous-years
 :component 'vui-journal-previous-years
 :order 40)

(provide 'vulpea-journal-ui)
;;; vulpea-journal-ui.el ends here
