;;; vulpea-journal-ui.el --- UI widgets for vulpea-journal -*- lexical-binding: t; -*-
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
;; UI widgets for vulpea-journal that integrate with vulpea-ui sidebar.
;;
;; This module provides journal-specific widgets that appear in the
;; vulpea-ui sidebar when viewing journal notes. Widgets automatically
;; hide themselves when viewing non-journal notes.
;;
;; Built-in widgets:
;; - `vulpea-journal-widget-nav' - Navigation (prev/today/next)
;; - `vulpea-journal-widget-calendar' - Interactive month calendar
;; - `vulpea-journal-widget-created-today' - Notes created on date
;; - `vulpea-journal-widget-previous-years' - Same date in past years
;;
;; To use, add widgets to `vulpea-ui-sidebar-widgets':
;;
;;   (setq vulpea-ui-sidebar-widgets
;;         '(vulpea-journal-widget-nav
;;           vulpea-ui-widget-stats
;;           vulpea-journal-widget-calendar
;;           vulpea-ui-widget-outline
;;           vulpea-ui-widget-backlinks
;;           vulpea-journal-widget-created-today
;;           vulpea-journal-widget-previous-years))
;;
;;; Code:

(require 'dash)
(require 'vui)
(require 'vulpea)
(require 'vulpea-db)
(require 'vulpea-db-query)
(require 'vulpea-ui)
(require 'calendar)

;; Forward declarations
(declare-function vulpea-journal-find-note "vulpea-journal")
(declare-function vulpea-journal-note "vulpea-journal")
(declare-function vulpea-journal-note-p "vulpea-journal")
(declare-function vulpea-journal-note-date "vulpea-journal")
(declare-function vulpea-journal-dates-in-month "vulpea-journal")
(declare-function vulpea-journal-notes-for-date-across-years "vulpea-journal")


;;; Customization

(defgroup vulpea-journal-ui nil
  "UI widgets for vulpea-journal."
  :group 'vulpea-journal)

(defvar vulpea-journal-debug)

(defun vulpea-journal-ui--debug (format-string &rest args)
  "Log debug message using FORMAT-STRING and ARGS.
Only logs when `vulpea-journal-debug' is non-nil."
  (when (bound-and-true-p vulpea-journal-debug)
    (with-current-buffer (get-buffer-create "*vulpea-journal-debug*")
      (goto-char (point-max))
      (insert (apply #'format format-string args) "\n"))))

(defcustom vulpea-journal-ui-calendar-week-start 1
  "Day to start week on. 0 = Sunday, 1 = Monday."
  :type '(choice (const :tag "Sunday" 0)
          (const :tag "Monday" 1))
  :group 'vulpea-journal-ui)

(defcustom vulpea-journal-ui-created-today-exclude-journal t
  "If non-nil, exclude journal notes from Created Today widget."
  :type 'boolean
  :group 'vulpea-journal-ui)

(defcustom vulpea-journal-ui-previous-years-count 5
  "Number of years to look back."
  :type 'integer
  :group 'vulpea-journal-ui)

(defcustom vulpea-journal-ui-previous-years-preview-chars 256
  "Number of characters to show in preview."
  :type 'integer
  :group 'vulpea-journal-ui)

(defcustom vulpea-journal-ui-previous-years-hide-drawers t
  "If non-nil, hide org drawers in preview."
  :type 'boolean
  :group 'vulpea-journal-ui)

(defcustom vulpea-journal-ui-previous-years-expanded t
  "If non-nil, show previews expanded by default."
  :type 'boolean
  :group 'vulpea-journal-ui)


;;; Faces

(defface vulpea-journal-ui-widget-title
  '((t :inherit vulpea-ui-widget-header-face))
  "Face for journal widget titles."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-calendar-date
  '((t :inherit shadow))
  "Face for regular days in the calendar widget.
These are days without journal entries that are not today or selected."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-calendar-today
  '((t :weight bold :inherit error))
  "Face for today's date in the calendar widget.
Helps identify the current day at a glance. By default bold and
red (inherits from `error' face)."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-calendar-entry
  '((t :inherit diary))
  "Face for days with journal entries in the calendar widget.
These days are also marked with a dot (·) indicator."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-calendar-selected
  '((t :inherit hl-line))
  "Face for the currently selected day in the calendar widget.
This is the date of the journal entry you are currently viewing."
  :group 'vulpea-journal-ui)


;;; Helper Functions

(defun vulpea-journal-ui--visit-date (date)
  "Visit journal for DATE from sidebar context.
Opens the note in the main window, not the sidebar."
  (require 'vulpea-journal)
  (let ((note (vulpea-journal-note date))
        (main-win (vulpea-ui--get-main-window)))
    (when main-win
      (select-window main-win))
    (vulpea-visit note)))

(defun vulpea-journal-ui--strip-drawers (text)
  "Remove org drawers from TEXT."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]*:[A-Z_]+:[ \t]*\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?" nil t)
      (replace-match ""))
    (buffer-string)))

(defun vulpea-journal-ui--indent-text (text indent)
  "Indent each line of TEXT with INDENT spaces."
  (string-join
   (--map (concat (make-string indent ?\s) (string-trim-right it))
          (string-lines text t))
   "\n"))

(defun vulpea-journal-ui--get-note-preview (note max-chars)
  "Get preview of NOTE content, up to MAX-CHARS."
  (when-let ((path (vulpea-note-path note)))
    (when (file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path nil 0 (* max-chars 3))
        (goto-char (point-min))
        ;; Strip drawers if configured
        (when vulpea-journal-ui-previous-years-hide-drawers
          (let ((content (vulpea-journal-ui--strip-drawers (buffer-string))))
            (erase-buffer)
            (insert content)
            (goto-char (point-min))))
        ;; Skip front matter (#+keywords)
        (while (and (not (eobp))
                    (looking-at "^\\(#\\+\\|$\\)"))
          (forward-line 1))
        (let ((start (point))
              (end (min (+ (point) max-chars) (point-max))))
          (when (< start end)
            (string-trim (buffer-substring-no-properties start end))))))))


;;; Query Functions

(defun vulpea-journal-ui--query-created-today (date)
  "Return notes created on DATE."
  (let ((date-str (format-time-string "%Y-%m-%d" date)))
    (vulpea-journal-ui--debug "=== Created Today Query ===")
    (vulpea-journal-ui--debug "Looking for date: %s" date-str)
    (let ((results (vulpea-db-query
                    (lambda (note)
                      (and (= (vulpea-note-level note) 0)
                           (when-let ((created (cdr (assoc "CREATED" (vulpea-note-properties note)))))
                             (vulpea-journal-ui--debug "Note %s has CREATED=%s match=%s"
                                                       (vulpea-note-title note)
                                                       created
                                                       (string-prefix-p date-str created))
                             (string-prefix-p date-str created))
                           (or (not vulpea-journal-ui-created-today-exclude-journal)
                               (not (vulpea-journal-note-p note))))))))
      (vulpea-journal-ui--debug "Found %d notes" (length results))
      results)))


;;; Navigation Widget

(defcomponent vulpea-journal-widget-nav ()
  "Navigation widget for journal entries (prev/today/next)."
  :render
  (let ((note (use-vulpea-ui-note)))
    (when (vulpea-journal-note-p note)
      (let* ((date (vulpea-journal-note-date note))
             (go-prev (lambda ()
                        (vulpea-journal-ui--visit-date (time-subtract date (days-to-time 1)))))
             (go-today (lambda ()
                         (vulpea-journal-ui--visit-date (current-time))))
             (go-next (lambda ()
                        (vulpea-journal-ui--visit-date (time-add date (days-to-time 1))))))
        (vui-vstack
         ;; Header with date
         (vui-text (format-time-string "Journal: %Y-%m-%d %A" date)
           :face 'vulpea-journal-ui-widget-title)
         ;; Navigation buttons
         (vui-hstack
          :spacing 1
          (vui-button "< Prev" :on-click go-prev)
          (vui-button "Today" :on-click go-today)
          (vui-button "Next >" :on-click go-next)))))))


;;; Calendar Widget

(defun vulpea-journal-ui--calendar-build-rows (month year selected-day selected-month selected-year entry-days today-day today-month today-year on-select)
  "Build calendar rows for MONTH/YEAR.
SELECTED-DAY/SELECTED-MONTH/SELECTED-YEAR identify the selected date.
ENTRY-DAYS is list of days with journal entries.
TODAY-DAY/TODAY-MONTH/TODAY-YEAR identify actual today.
ON-SELECT is callback to handle date selection."
  (let* ((first-day-of-month (encode-time 0 0 0 1 month year))
         (first-dow (decoded-time-weekday (decode-time first-day-of-month)))
         (first-dow-adjusted (mod (- first-dow vulpea-journal-ui-calendar-week-start) 7))
         (days-in-month (calendar-last-day-of-month month year))
         (make-day-button
          (lambda (d)
            (let* ((date (encode-time 0 0 0 d month year))
                   (is-today (and (= d today-day)
                                  (= month today-month)
                                  (= year today-year)))
                   (is-selected (and (= d selected-day)
                                     (= month selected-month)
                                     (= year selected-year)))
                   (has-entry (--any-p (time-equal-p it date) entry-days))
                   (face (cond
                          (is-selected 'vulpea-journal-ui-calendar-selected)
                          (is-today 'vulpea-journal-ui-calendar-today)
                          (has-entry 'vulpea-journal-ui-calendar-entry)
                          (t 'vulpea-journal-ui-calendar-date)))
                   (day-text (format "%2d" d)))
              ;; Debug first 10 days
              (when (<= d 10)
                (vulpea-journal-ui--debug "Day %d: date=%s has-entry=%s"
                                          d
                                          (format-time-string "%Y-%m-%d %H:%M:%S" date)
                                          has-entry))
              (vui-button (format
                           (cond
                            (is-selected " %s ")
                            (is-today " %s ")
                            (has-entry " %s·")
                            (t " %s "))
                           day-text)
                :face face
                :on-click (lambda () (funcall on-select date))))))
         ;; All day buttons
         (day-buttons (-map make-day-button (-iota days-in-month 1)))
         ;; Add leading padding for first week
         (padded-days (-concat (-repeat first-dow-adjusted "") day-buttons))
         ;; Add trailing padding to complete last week
         (trailing-pad (mod (- 7 (mod (length padded-days) 7)) 7))
         (all-cells (-concat padded-days (-repeat trailing-pad ""))))
    ;; Split into weeks of 7
    (-partition 7 all-cells)))

(defcomponent vulpea-journal-widget-calendar ()
  "Calendar widget showing month view with journal entry indicators."
  :state ((view-month nil)
          (view-year nil))

  :render
  (let ((note (use-vulpea-ui-note)))
    (when (vulpea-journal-note-p note)
      (let* ((date (vulpea-journal-note-date note))
             (decoded (decode-time date))
             (selected-day (decoded-time-day decoded))
             (selected-month (decoded-time-month decoded))
             (selected-year (decoded-time-year decoded))
             ;; Use view-month/year if set, otherwise use selected date's month
             (display-month (or view-month selected-month))
             (display-year (or view-year selected-year))
             ;; Get days with entries (memoized)
             (entry-days (use-memo (display-month display-year)
                           (let ((days (vulpea-journal-dates-in-month display-month display-year)))
                             (vulpea-journal-ui--debug "=== Calendar Debug ===")
                             (vulpea-journal-ui--debug "Querying month=%d year=%d" display-month display-year)
                             (vulpea-journal-ui--debug "Found %d entry days" (length days))
                             (dolist (d days)
                               (vulpea-journal-ui--debug "  Entry day: %s (type: %s)"
                                                         (format-time-string "%Y-%m-%d" d)
                                                         (type-of d)))
                             days)))
             ;; Today (actual current date)
             (today (decode-time))
             (today-day (decoded-time-day today))
             (today-month (decoded-time-month today))
             (today-year (decoded-time-year today))
             ;; Day name headers
             (day-names (if (= vulpea-journal-ui-calendar-week-start 1)
                            '("Mo" "Tu" "We" "Th" "Fr" "Sa" "Su")
                          '("Su" "Mo" "Tu" "We" "Th" "Fr" "Sa")))
             ;; Column specs
             (columns (--map (list :header it :width 5) day-names))
             ;; Date selection handler
             (on-select (lambda (new-date)
                          (vulpea-journal-ui--visit-date new-date)))
             ;; Build rows
             (rows (vulpea-journal-ui--calendar-build-rows
                    display-month display-year
                    selected-day selected-month selected-year
                    entry-days
                    today-day today-month today-year on-select))
             (month-name (calendar-month-name display-month))
             ;; Navigation callbacks
             (go-prev-month (lambda ()
                              (vui-batch
                               (vui-set-state :view-month (if (= display-month 1) 12 (1- display-month)))
                               (vui-set-state :view-year (if (= display-month 1) (1- display-year) display-year)))))
             (go-next-month (lambda ()
                              (vui-batch
                               (vui-set-state :view-month (if (= display-month 12) 1 (1+ display-month)))
                               (vui-set-state :view-year (if (= display-month 12) (1+ display-year) display-year))))))
        ;; Reset view-month/year when selected date changes to different month
        (use-effect (selected-month selected-year)
          (vui-batch
           (vui-set-state :view-month nil)
           (vui-set-state :view-year nil)))

        (vui-component 'vulpea-ui-widget
          :title "Calendar"
          :children
          (lambda ()
            (vui-vstack
             ;; Month/year header with navigation
             (vui-hstack
              :spacing 1
              (vui-button "<" :on-click go-prev-month)
              (vui-box (vui-text (format "%s %d" month-name display-year) :face 'bold)
                :width 15
                :align :center)
              (vui-button ">" :on-click go-next-month))
             (vui-newline)
             ;; Calendar table
             (vui-table
              :columns columns
              :rows rows))))))))


;;; Created Today Widget

(defcomponent vulpea-journal-widget-created-today ()
  "Widget showing notes created on the journal entry's date."
  :state ((notes nil))

  :render
  (let ((note (use-vulpea-ui-note)))
    (when (vulpea-journal-note-p note)
      (let* ((date (vulpea-journal-note-date note))
             (count (length notes)))
        ;; Reload when date changes
        (use-effect (date)
          (vui-set-state :notes (vulpea-journal-ui--query-created-today date)))

        (vui-component 'vulpea-ui-widget
          :title "Created Today"
          :count count
          :children
          (lambda ()
            (if (null notes)
                (vui-text "No notes created today" :face 'shadow)
              (vui-list notes
                        (lambda (n)
                          (let* ((title (vulpea-note-title n))
                                 (tags (vulpea-note-tags n))
                                 (created (cdr (assoc "CREATED" (vulpea-note-properties n))))
                                 (time-str (if (and created (string-match "\\([0-9]+:[0-9]+\\)" created))
                                               (match-string 1 created)
                                             "     "))
                                 (visit-note (lambda ()
                                               (let ((main-win (vulpea-ui--get-main-window)))
                                                 (when main-win (select-window main-win))
                                                 (vulpea-visit n)))))
                            (vui-hstack
                             :spacing 1
                             (vui-text time-str :face 'shadow)
                             (vui-button title
                               :face 'link
                               :on-click visit-note)
                             (when tags
                               (vui-text (->> tags (--map (concat "#" it)) (string-join " "))
                                 :face 'shadow)))))
                        #'vulpea-note-id))))))))


;;; Previous Years Widget

(defcomponent vulpea-journal-widget-previous-year-entry (entry)
  "Single entry from a previous year."
  :state ((expanded vulpea-journal-ui-previous-years-expanded))

  :render
  (let* ((date (plist-get entry :date))
         (years-ago (plist-get entry :years-ago))
         (note (plist-get entry :note))
         (date-str (format-time-string "%Y-%m-%d" date))
         (preview (when expanded
                    (vulpea-journal-ui--get-note-preview
                     note
                     vulpea-journal-ui-previous-years-preview-chars)))
         (toggle-expanded (lambda ()
                            (vui-set-state :expanded (not expanded))))
         (visit-note (lambda ()
                            (let ((main-win (vulpea-ui--get-main-window)))
                              (when main-win (select-window main-win))
                              (vulpea-visit note)))))
    (vui-vstack
     (vui-hstack
      :spacing 1
      (vui-button (if expanded "▼" "▶")
        :on-click toggle-expanded)
      (vui-button date-str
        :face 'link
        :on-click visit-note)
      (vui-text (format "(%d year%s ago)"
                        years-ago
                        (if (= years-ago 1) "" "s"))
        :face 'shadow))
     (when (and expanded preview)
       (vui-text (vulpea-journal-ui--indent-text (concat preview "...") 4)
         :face 'font-lock-comment-face)))))

(defcomponent vulpea-journal-widget-previous-years ()
  "Widget showing same date from previous years."
  :state ((entries nil))

  :render
  (let ((note (use-vulpea-ui-note)))
    (when (vulpea-journal-note-p note)
      (let* ((date (vulpea-journal-note-date note))
             (count (length entries)))
        ;; Reload when date changes
        (use-effect (date)
          (vui-set-state :entries
                         (vulpea-journal-notes-for-date-across-years
                          date
                          vulpea-journal-ui-previous-years-count)))

        (vui-component 'vulpea-ui-widget
          :title "Previous Years"
          :count count
          :children
          (lambda ()
            (if (null entries)
                (vui-text "No entries from previous years" :face 'shadow)
              (vui-list entries
                        (lambda (entry)
                          (vui-component 'vulpea-journal-widget-previous-year-entry
                            :key (format-time-string "%Y%m%d" (plist-get entry :date))
                            :entry entry))
                        (lambda (entry)
                          (format-time-string "%Y%m%d" (plist-get entry :date)))))))))))


(provide 'vulpea-journal-ui)
;;; vulpea-journal-ui.el ends here
