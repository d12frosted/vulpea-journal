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
;; - `created-today' - Notes created on selected date
;; - `links-to-today' - Notes linking to selected date's journal
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
;;     (let ((selected-date (use-vui-journal-selected-date)))
;;       (vui-vstack
;;        (vui-text "My Widget" :face 'vulpea-journal-ui-widget-title)
;;        ...)))
;;
;; Then add to `vulpea-journal-ui-widgets':
;;
;;   (add-to-list 'vulpea-journal-ui-widgets 'my-widget)
;;
;;; Code:

(require 'dash)
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

(defcontext vui-journal-selected-date)
(defcontext vui-journal-set-selected-date)
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

(defface vulpea-journal-ui-calendar-date
  '((t :inherit shadow))
  "Face for regular days in calendar."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-calendar-today
  '((t :weight bold :inherit error))
  "Face for today in calendar."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-calendar-entry
  '((t :inherit diary))
  "Face for days with journal entries."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-calendar-selected
  '((t :inherit hl-line))
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
  (->> vulpea-journal-ui-widgets
       (-map (lambda (name)
               (when-let ((def (vulpea-journal-ui-get-widget name)))
                 (cons name def))))
       (-non-nil)
       (--sort (< (or (plist-get (cdr it) :order) 50)
                  (or (plist-get (cdr other) :order) 50)))))

;;; Reusable Collapsible Widget Component

;; Reusable collapsible widget with header, count, and item list.
;;
;; TITLE is the widget title string.
;; ITEMS is the list of items to display.
;; EMPTY-MESSAGE is shown when ITEMS is nil.
;; RENDER-ITEM is a function (lambda (item) vnode) to render each item.
;; ITEM-KEY is a function (lambda (item) key) for list reconciliation.
(defcomponent vui-collapsible-widget (title items empty-message render-item item-key)
  :state ((collapsed nil))

  :render
  (let ((count (length items))
        (toggle-collapsed (lambda () (vui-set-state :collapsed (not collapsed)))))
    (vui-vstack
     ;; Header
     (vui-hstack
      :spacing 1
      (vui-button (if collapsed "▸" "▾")
        :on-click toggle-collapsed)
      (vui-text title :face 'vulpea-journal-ui-widget-title)
      (when (> count 0)
        (vui-text (format "(%d)" count) :face 'shadow)))
     ;; Content
     (unless collapsed
       (if (null items)
           (vui-text empty-message :face 'shadow)
         (vui-vstack
          :indent 2
          (vui-list items render-item item-key)))))))

;;; Navigation Bar Component

(defcomponent vui-journal-nav-bar ()
  :render
  (let* ((selected-date (use-vui-journal-selected-date))
         (set-selected-date (use-vui-journal-set-selected-date))
         ;; Stable callbacks that capture current values
         (go-prev (lambda ()
                    (funcall set-selected-date
                             (time-subtract selected-date (days-to-time 1)))))
         (go-today (lambda ()
                     (funcall set-selected-date (current-time))))
         (go-next (lambda ()
                    (funcall set-selected-date
                             (time-add selected-date (days-to-time 1))))))
    (vui-hstack
     :spacing 1
     (vui-button "< Prev" :on-click go-prev)
     (vui-button "Today" :on-click go-today)
     (vui-button "Next >" :on-click go-next))))

;;; Calendar Widget Component

(defcustom vulpea-journal-ui-calendar-week-start 1
  "Day to start week on. 0 = Sunday, 1 = Monday."
  :type '(choice (const :tag "Sunday" 0)
          (const :tag "Monday" 1))
  :group 'vulpea-journal-ui)

(defun vulpea-journal-ui--calendar-build-rows (month year selected-day selected-month selected-year entry-days today-day today-month today-year set-selected-date)
  "Build calendar rows for MONTH/YEAR.
SELECTED-DAY/SELECTED-MONTH/SELECTED-YEAR identify the selected date.
ENTRY-DAYS is list of days with journal entries.
TODAY-DAY/TODAY-MONTH/TODAY-YEAR identify actual today.
SET-SELECTED-DATE is callback to change selected date."
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
                   (has-entry (-contains-p entry-days date))
                   (face (cond
                          (is-selected 'vulpea-journal-ui-calendar-selected)
                          (is-today 'vulpea-journal-ui-calendar-today)
                          (has-entry 'vulpea-journal-ui-calendar-entry)
                          (t 'vulpea-journal-ui-calendar-date)))
                   (day-text (format "%2d" d)))
              (vui-button (format
                           (cond
                            (is-selected " %s ")
                            (is-today " %s ")
                            (has-entry " %s·")
                            (t " %s "))
                           day-text)
                :face face
                :on-click (lambda () (funcall set-selected-date date))))))
         ;; All day buttons
         (day-buttons (-map make-day-button (-iota days-in-month 1)))
         ;; Add leading padding for first week
         (padded-days (-concat (-repeat first-dow-adjusted "") day-buttons))
         ;; Add trailing padding to complete last week
         (trailing-pad (mod (- 7 (mod (length padded-days) 7)) 7))
         (all-cells (-concat padded-days (-repeat trailing-pad ""))))
    ;; Split into weeks of 7
    (-partition 7 all-cells)))

(defcomponent vui-journal-calendar ()
  :render
  (let* ((selected-date (use-vui-journal-selected-date))
         (set-selected-date (use-vui-journal-set-selected-date))
         ;; Selected date components
         (selected (decode-time selected-date))
         (selected-day (decoded-time-day selected))
         (selected-month (decoded-time-month selected))
         (selected-year (decoded-time-year selected))
         ;; Get days with entries (memoised)
         (entry-days (use-memo (selected-month selected-year)
                       (vulpea-journal-dates-in-month selected-month selected-year)))
         ;; Today (actual current date)
         (today (decode-time))
         (today-day (decoded-time-day today))
         (today-month (decoded-time-month today))
         (today-year (decoded-time-year today))
         ;; Day name headers
         (day-names (if (= vulpea-journal-ui-calendar-week-start 1)
                        '("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun")
                      '("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat")))
         ;; Column specs
         (columns (--map (list :header it :width 6) day-names))
         ;; Build rows
         (rows (vulpea-journal-ui--calendar-build-rows
                selected-month selected-year
                selected-day selected-month selected-year
                entry-days
                today-day today-month today-year set-selected-date))
         (month-name (calendar-month-name selected-month))
         ;; Navigation callbacks
         (go-prev-month (lambda ()
                          (funcall set-selected-date
                                   (encode-time 0 0 0 1
                                                (if (= selected-month 1) 12 (1- selected-month))
                                                (if (= selected-month 1) (1- selected-year) selected-year)))))
         (go-next-month (lambda ()
                          (funcall set-selected-date
                                   (encode-time 0 0 0 1
                                                (if (= selected-month 12) 1 (1+ selected-month))
                                                (if (= selected-month 12) (1+ selected-year) selected-year))))))
    (vui-vstack
     ;; Widget title
     (vui-text "Calendar" :face 'vulpea-journal-ui-widget-title)
     ;; Month/year header with navigation
     (vui-hstack
      :spacing 1
      (vui-button "<" :on-click go-prev-month)
      (vui-box (vui-text (format "%s %d" month-name selected-year) :face 'bold)
        :width 15
        :align :center)
      (vui-button ">" :on-click go-next-month))
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
                     "     "))
         (visit-note (lambda () (vulpea-visit note t))))
    (vui-hstack
     :spacing 1
     (vui-text time-str :face 'shadow)
     (vui-button title
       :face 'link
       :on-click visit-note)
     (when tags
       (vui-text (->> tags (--map (concat "#" it)) (string-join " "))
         :face 'shadow)))))

(defcomponent vui-journal-created-today ()
  :state ((notes nil))

  :render
  (let ((selected-date (use-vui-journal-selected-date)))
    ;; Reload when selected date changes
    (use-effect (selected-date)
      (vui-set-state :notes (vulpea-journal-ui--query-created-today selected-date)))

    (vui-component 'vui-collapsible-widget
      :title "Created Today"
      :items notes
      :empty-message "  No notes created today"
      :render-item (lambda (note)
                     (vui-component 'vui-journal-note-item
                       :key (vulpea-note-id note)
                       :note note))
      :item-key #'vulpea-note-id)))

;;; Links to Today Widget

(defun vulpea-journal-ui--query-links-to-today (date)
  "Return notes linking to today's journal note for DATE."
  (when-let* ((today-note (vulpea-journal-find-note date))
              (today-id (vulpea-note-id today-note)))
    (vulpea-db-query-by-links-some (list today-id))))

(defcomponent vui-journal-link-item (note)
  :render
  (let* ((title (vulpea-note-title note))
         (tags (vulpea-note-tags note))
         (visit-note (use-callback (note)
                       (lambda () (vulpea-visit note t)))))
    (vui-hstack
     :spacing 1
     (vui-button title
       :face 'link
       :on-click visit-note)
     (when tags
       (vui-text (->> tags (--map (concat "#" it)) (string-join " "))
         :face 'shadow)))))

(defcomponent vui-journal-links-to-today ()
  :state ((notes nil))

  :render
  (let ((selected-date (use-vui-journal-selected-date)))
    ;; Reload when selected date changes
    (use-effect (selected-date)
      (vui-set-state :notes (vulpea-journal-ui--query-links-to-today selected-date)))

    (vui-component 'vui-collapsible-widget
      :title "Links to Today"
      :items notes
      :empty-message "  No notes link to today"
      :render-item (lambda (note)
                     (vui-component 'vui-journal-link-item
                       :key (vulpea-note-id note)
                       :note note))
      :item-key #'vulpea-note-id)))

;;; Previous Years Widget

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

(defun vulpea-journal-ui--strip-drawers (text)
  "Remove org drawers from TEXT."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]*:[A-Z_]+:[ \t]*\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?" nil t)
      (replace-match ""))
    (buffer-string)))

(defun vulpea-journal-ui--query-previous-years (date)
  "Return journal notes from same date in previous years for DATE."
  (let* ((decoded (decode-time date))
         (month (decoded-time-month decoded))
         (day (decoded-time-day decoded))
         (year (decoded-time-year decoded)))
    (->> (-iota vulpea-journal-ui-previous-years-count 1)
         (--map (let* ((past-year (- year it))
                       (check-date (encode-time 0 0 0 day month past-year)))
                  (when-let ((note (vulpea-journal-find-note check-date)))
                    (list :date check-date
                          :years-ago it
                          :note note))))
         (-non-nil))))

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

(defcomponent vui-journal-previous-year-entry (entry)
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
         (visit-note (lambda () (vulpea-visit note t))))
    (vui-vstack
     (vui-hstack
      :spacing 1
      (vui-button (if expanded "▾" "▸")
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

(defcomponent vui-journal-previous-years ()
  :state ((entries nil))

  :render
  (let ((selected-date (use-vui-journal-selected-date)))
    ;; Reload when selected date changes
    (use-effect (selected-date)
      (vui-set-state :entries (vulpea-journal-ui--query-previous-years selected-date)))

    (vui-component 'vui-collapsible-widget
      :title "This Day in Previous Years"
      :items entries
      :empty-message "  No entries from previous years"
      :render-item (lambda (entry)
                     (vui-component 'vui-journal-previous-year-entry
                       :key (format-time-string "%Y%m%d" (plist-get entry :date))
                       :entry entry))
      :item-key (lambda (entry)
                  (format-time-string "%Y%m%d" (plist-get entry :date))))))

;;; Main Journal View Component

(defcomponent vui-journal-widgets-view ()
  :render
  (let ((selected-date (use-vui-journal-selected-date))
        (widgets (vulpea-journal-ui--get-enabled-widgets)))
    (vui-vstack
     ;; Header
     (vui-text (format-time-string "Journal: %Y-%m-%d %A" selected-date)
       :face 'vulpea-journal-ui-header)
     ;; Navigation
     (vui-component 'vui-journal-nav-bar)
     (vui-newline)
     ;; Widgets from registry
     (if (null widgets)
         (vui-text "No widgets configured. See `vulpea-journal-ui-widgets'."
           :face 'shadow)
       (apply
        #'vui-vstack
        :spacing 1
        (-map (-lambda ((name . def))
                (vui-component (plist-get def :component) :key name))
              widgets))))))

;;; Root Component with Context Providers

(defcomponent vui-journal-root (initial-date)
  :state ((selected-date (or initial-date (current-time))))

  :render
  (progn
    ;; Open journal note when selected date changes
    (use-effect (selected-date)
      (when-let ((note (vulpea-journal-note selected-date)))
        (let ((widgets-window (selected-window)))
          (save-selected-window
            (other-window 1)
            (vulpea-visit note)
            (select-window widgets-window)))))

    (vui-journal-selected-date-provider selected-date
      (vui-journal-set-selected-date-provider
          (lambda (new-selected-date)
            (vui-set-state :selected-date new-selected-date))
        (vui-component 'vui-journal-widgets-view)))))

;;; Public API

;;;###autoload
(defun vulpea-journal-ui-open (&optional date)
  "Open journal widgets view for DATE using vui.
DATE defaults to today.

Note: Prefer using `vulpea-journal' which sets up the full
two-window layout with the journal note and widgets sidebar."
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
