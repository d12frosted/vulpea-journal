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

(defcontext journal-date)
(defcontext journal-set-date)
(defcontext journal-note-buffer)

;;; Faces

(defgroup vulpea-journal-ui nil
  "VUI-based UI for vulpea-journal."
  :group 'vulpea-journal)

(defface vulpea-journal-ui-header
  '((t :inherit bold :height 1.2))
  "Face for journal header."
  :group 'vulpea-journal-ui)

(defface vulpea-journal-ui-widget-title
  '((t :inherit bold))
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

;;; Navigation Bar Component

(defcomponent journal-nav-bar ()
  :render
  (let ((set-date (use-journal-set-date)))
    (vui-hstack
     :spacing 2
     (vui-button "< Yesterday"
       :on-click (lambda ()
                   (let ((date (use-journal-date)))
                     (funcall set-date
                              (time-subtract date (days-to-time 1))))))
     (vui-button "Today"
       :on-click (lambda ()
                   (funcall set-date (current-time))))
     (vui-button "Tomorrow >"
       :on-click (lambda ()
                   (let ((date (use-journal-date)))
                     (funcall set-date
                              (time-add date (days-to-time 1)))))))))

;;; Calendar Widget Component

(defcustom vulpea-journal-ui-calendar-week-start 1
  "Day to start week on. 0 = Sunday, 1 = Monday."
  :type '(choice (const :tag "Sunday" 0)
                 (const :tag "Monday" 1))
  :group 'vulpea-journal-ui)

(defcomponent journal-calendar ()
  :render
  (let* ((date (use-journal-date))
         (set-date (use-journal-set-date))
         (decoded (decode-time date))
         (month (decoded-time-month decoded))
         (year (decoded-time-year decoded))
         (current-day (decoded-time-day decoded))
         ;; Get days with entries
         (entry-days (mapcar (lambda (d)
                               (decoded-time-day (decode-time d)))
                             (vulpea-journal-dates-in-month month year)))
         ;; Today info
         (today (decode-time))
         (today-day (decoded-time-day today))
         (today-month (decoded-time-month today))
         (today-year (decoded-time-year today))
         ;; Calendar calculation
         (first-day-of-month (encode-time 0 0 0 1 month year))
         (first-dow (decoded-time-weekday (decode-time first-day-of-month)))
         (first-dow-adjusted (mod (- first-dow vulpea-journal-ui-calendar-week-start) 7))
         (days-in-month (calendar-last-day-of-month month year))
         (month-name (calendar-month-name month)))
    (vui-vstack
     ;; Widget title with collapse toggle (could add later)
     (vui-text "Calendar" :face 'vulpea-journal-ui-widget-title)
     (vui-newline)
     ;; Month/year header
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
     ;; Day headers
     (let ((day-names (if (= vulpea-journal-ui-calendar-week-start 1)
                          '("Mo" "Tu" "We" "Th" "Fr" "Sa" "Su")
                        '("Su" "Mo" "Tu" "We" "Th" "Fr" "Sa"))))
       (apply #'vui-hstack :spacing 1
              (mapcar (lambda (d)
                        (vui-box (vui-text d :face 'shadow)
                                 :width 3 :align :center))
                      day-names)))
     ;; Calendar grid
     (vui-fragment
      (let ((day 1)
            (rows nil))
        ;; Build weeks
        (while (<= day days-in-month)
          (let ((week-cells nil))
            ;; Initial padding for first week
            (when (and (= day 1) (> first-dow-adjusted 0))
              (dotimes (_ first-dow-adjusted)
                (push (vui-box (vui-text " ") :width 3 :align :center) week-cells)))
            ;; Days in this week
            (while (and (<= day days-in-month)
                        (or (null week-cells)
                            (< (+ (length week-cells)
                                  (if (= day 1) 0 0))
                               7)))
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
                      week-cells))
              (setq day (1+ day)))
            ;; Pad end of last week
            (while (< (length week-cells) 7)
              (push (vui-box (vui-text " ") :width 3 :align :center) week-cells))
            (push (apply #'vui-hstack :spacing 1 (nreverse week-cells)) rows)))
        (apply #'vui-vstack (nreverse rows)))))))

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

(defcomponent journal-note-item (note)
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

(defcomponent journal-created-today ()
  :state ((notes nil)
          (loading t)
          (collapsed nil))

  :on-mount
  (let ((date (use-journal-date)))
    (vui-batch
     (vui-set-state :notes (vulpea-journal-ui--query-created-today date))
     (vui-set-state :loading nil)))

  :on-update
  ;; Reload when date changes
  (let ((date (use-journal-date))
        (prev-date (plist-get prev-props :date)))
    (unless (equal date prev-date)
      (vui-batch
       (vui-set-state :loading t)
       (vui-set-state :notes (vulpea-journal-ui--query-created-today date))
       (vui-set-state :loading nil))))

  :render
  (let ((count (length notes)))
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
                        (vui-component 'journal-note-item
                          :key (vulpea-note-id note)
                          :note note))
                      #'vulpea-note-id))))))))

;;; Links to Today Widget

(defun vulpea-journal-ui--query-links-to-today (date)
  "Return notes linking to today's journal note for DATE."
  (when-let* ((today-note (vulpea-journal-find-note date))
              (today-id (vulpea-note-id today-note)))
    (vulpea-db-query-by-links-some (list today-id))))

(defcomponent journal-links-to-today ()
  :state ((notes nil)
          (loading t)
          (collapsed nil))

  :on-mount
  (let ((date (use-journal-date)))
    (vui-batch
     (vui-set-state :notes (vulpea-journal-ui--query-links-to-today date))
     (vui-set-state :loading nil)))

  :on-update
  (let ((date (use-journal-date))
        (prev-date (plist-get prev-props :date)))
    (unless (equal date prev-date)
      (vui-batch
       (vui-set-state :loading t)
       (vui-set-state :notes (vulpea-journal-ui--query-links-to-today date))
       (vui-set-state :loading nil))))

  :render
  (let ((count (length notes)))
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

(defcomponent journal-previous-year-entry (entry)
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

(defcomponent journal-previous-years ()
  :state ((entries nil)
          (loading t)
          (collapsed nil))

  :on-mount
  (let ((date (use-journal-date)))
    (vui-batch
     (vui-set-state :entries (vulpea-journal-ui--query-previous-years date))
     (vui-set-state :loading nil)))

  :on-update
  (let ((date (use-journal-date))
        (prev-date (plist-get prev-props :date)))
    (unless (equal date prev-date)
      (vui-batch
       (vui-set-state :loading t)
       (vui-set-state :entries (vulpea-journal-ui--query-previous-years date))
       (vui-set-state :loading nil))))

  :render
  (let ((count (length entries)))
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
                        (vui-component 'journal-previous-year-entry
                          :key (format-time-string "%Y%m%d" (plist-get entry :date))
                          :entry entry))
                      (lambda (entry)
                        (format-time-string "%Y%m%d" (plist-get entry :date)))))))))))

;;; Main Journal View Component

(defcomponent journal-widgets-view ()
  :render
  (let ((date (use-journal-date)))
    (vui-vstack
     :spacing 1
     ;; Header
     (vui-text (format-time-string "Journal: %Y-%m-%d %A" date)
               :face 'vulpea-journal-ui-header)
     (vui-newline)
     ;; Navigation
     (vui-component 'journal-nav-bar)
     (vui-newline)
     (vui-text (make-string 40 ?─))
     (vui-newline)
     ;; Widgets
     (vui-component 'journal-calendar)
     (vui-newline)
     (vui-component 'journal-created-today)
     (vui-newline)
     (vui-component 'journal-links-to-today)
     (vui-newline)
     (vui-component 'journal-previous-years))))

;;; Root Component with Context Providers

(defcomponent journal-root (initial-date)
  :state ((date nil))

  :on-mount
  (unless date
    (vui-set-state :date (or initial-date (current-time))))

  :render
  (journal-date-provider
      (or date (current-time))
    (journal-set-date-provider
        (lambda (new-date)
          (vui-set-state :date new-date))
      (vui-component 'journal-widgets-view))))

;;; Public API

;;;###autoload
(defun vulpea-journal-ui-open (&optional date)
  "Open journal widgets view for DATE using vui.
DATE defaults to today."
  (interactive)
  (let ((buffer-name (or vulpea-journal-widgets-buffer-name "*vulpea-journal*")))
    (vui-mount (vui-component 'journal-root
                 :initial-date (or date (current-time)))
               buffer-name)
    (pop-to-buffer buffer-name)))

(provide 'vulpea-journal-ui)
;;; vulpea-journal-ui.el ends here
