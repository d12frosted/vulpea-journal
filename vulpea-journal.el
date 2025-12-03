;;; vulpea-journal.el --- Daily note interface for vulpea -*- lexical-binding: t; -*-
;;
;; Copyright (c) 2024-2025 Boris Buliga <boris@d12frosted.io>
;;
;; Author: Boris Buliga <boris@d12frosted.io>
;; Maintainer: Boris Buliga <boris@d12frosted.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (vulpea "2.0.0") (vui "0.1.0"))
;; Keywords: org-mode, roam, convenience
;; URL: https://github.com/d12frosted/vulpea-journal
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
;; Created: 25 Nov 2025
;;
;; License: GPLv3
;;
;;; Commentary:
;;
;; vulpea-journal provides a day-centric interface for daily note
;; workflows. It creates a focused workspace with today's journal
;; note and contextual widgets powered by vui.el.
;;
;; Main features:
;; - Daily note identification and navigation
;; - Two-window layout: org buffer + widgets buffer
;; - Reactive widget system using vui.el
;; - Calendar integration
;;
;; Quick start:
;;
;;   (require 'vulpea-journal)
;;   (global-set-key (kbd "C-c j") #'vulpea-journal)
;;
;;; Code:

(require 'vulpea)
(require 'vulpea-db)
(require 'vulpea-db-query)
(require 'vui)
(require 'calendar)

(defvar vulpea-directory)

;;; Customization

(defgroup vulpea-journal nil
  "Daily note interface for vulpea."
  :group 'vulpea)

(defcustom vulpea-journal-default-template
  '(:file-name "journal/%Y-%m-%d.org"
    :title "%Y-%m-%d %A"
    :tags ("journal"))
  "Default template for journal notes.

Can be a plist or a function taking DATE and returning a plist.

Required keys:
- `:file-name' - strftime format for file path (relative to
  `vulpea-directory')
- `:title' - strftime format for note title
- `:tags' - List of tags (first tag identifies journal notes)

Optional keys (same as `vulpea-create-default-template'):
- `:head' - Header content after #+title
- `:body' - Note body content
- `:properties' - Alist for property drawer
- `:meta' - Alist for metadata
- `:context' - Plist for template variables

Note on template syntax:

  `:file-name' and `:title' use strftime format (e.g., %Y-%m-%d)
  because they must be expanded for the TARGET DATE, not current
  time. When you open journal for Nov 25, the file should be
  20241125.org regardless of today's date.

  Other keys (`:head', `:body', etc.) use vulpea's %<format> syntax
  and are expanded by `vulpea-create' at note creation time.

Example:

  (setq vulpea-journal-default-template
        \\='(:file-name \"journal/%Y-%m-%d.org\"
          :title \"%Y-%m-%d %A\"
          :tags (\"journal\" \"daily\")
          :head \"#+created: %<[%Y-%m-%d]>\"
          :body \"* Morning\\n\\n* Evening\\n\"))

Or as a function for dynamic configuration:

  (setq vulpea-journal-default-template
        (lambda (date)
          (list :file-name (format-time-string \"journal/%Y-%m-%d.org\" date)
                :title (format-time-string \"%Y-%m-%d %A\" date)
                :tags \\='(\"journal\"))))"
  :type '(choice (plist :key-type symbol :value-type sexp)
          function)
  :group 'vulpea-journal)

(defcustom vulpea-journal-window-ratio 0.5
  "Ratio of window width for the daily note buffer.
The widgets buffer takes the remaining space."
  :type 'float
  :group 'vulpea-journal)

(defcustom vulpea-journal-widgets-buffer-name "*vulpea-journal*"
  "Name for the journal widgets buffer."
  :type 'string
  :group 'vulpea-journal)

;;; Template Resolution

(defun vulpea-journal--get-template (date)
  "Get resolved template plist for DATE."
  (if (functionp vulpea-journal-default-template)
      (funcall vulpea-journal-default-template date)
    vulpea-journal-default-template))

(defun vulpea-journal--get-tag ()
  "Get the primary journal tag from template.
Uses current time for template resolution."
  (or (car (plist-get (vulpea-journal--get-template (current-time)) :tags))
      "journal"))

;;; Variables

(defvar-local vulpea-journal--current-date nil
  "Current date displayed in journal view.")

(defvar-local vulpea-journal--note-buffer nil
  "Associated note buffer for widgets buffer.")

(defvar-local vulpea-journal--widgets-buffer nil
  "Associated widgets buffer for note buffer.")

;;; Journal Directory

(defun vulpea-journal--ensure-directory (file)
  "Ensure directory for FILE exists."
  (let ((dir (file-name-directory file)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

;;; Note Identification

(defun vulpea-journal-note-p (note)
  "Return non-nil if NOTE is a journal note."
  (and note
       (member (vulpea-journal--get-tag) (vulpea-note-tags note))))

(defun vulpea-journal--file-for-date (date)
  "Return file path for journal note on DATE."
  (let* ((tpl (vulpea-journal--get-template date))
         (file-fmt (plist-get tpl :file-name)))
    (expand-file-name
     (format-time-string file-fmt date)
     vulpea-directory)))

(defun vulpea-journal--title-for-date (date)
  "Return title for journal note on DATE."
  (let* ((tpl (vulpea-journal--get-template date))
         (title-fmt (plist-get tpl :title)))
    (format-time-string title-fmt date)))

(defun vulpea-journal--date-from-note (note)
  "Extract date from journal NOTE.
Returns time value or nil if not a journal note."
  (when (vulpea-journal-note-p note)
    (let* ((path (vulpea-note-path note))
           (filename (file-name-nondirectory path)))
      ;; Try to parse date from filename
      (when (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" filename)
        (let ((year (string-to-number (match-string 1 filename)))
              (month (string-to-number (match-string 2 filename)))
              (day (string-to-number (match-string 3 filename))))
          (encode-time 0 0 0 day month year))))))

;;; Note Lookup

(defun vulpea-journal-find-note (date)
  "Find existing journal note for DATE, or nil."
  (let ((file (vulpea-journal--file-for-date date)))
    (when (file-exists-p file)
      (car (vulpea-db-query
            (lambda (note)
              (and (string= (vulpea-note-path note) file)
                   (= (vulpea-note-level note) 0))))))))

(defun vulpea-journal-today-note ()
  "Get today's journal note, creating if needed."
  (vulpea-journal-note (current-time)))

(defun vulpea-journal-note (date)
  "Get journal note for DATE, creating if needed."
  (or (vulpea-journal-find-note date)
      (vulpea-journal--create-note date)))

(defun vulpea-journal--create-note (date)
  "Create a new journal note for DATE."
  (let* ((tpl (vulpea-journal--get-template date))
         (file (vulpea-journal--file-for-date date))
         (title (vulpea-journal--title-for-date date))
         (id (org-id-new)))
    (vulpea-journal--ensure-directory file)
    (vulpea-create
     title
     file
     :id id
     :tags (plist-get tpl :tags)
     :head (plist-get tpl :head)
     :body (plist-get tpl :body)
     :properties (plist-get tpl :properties)
     :meta (plist-get tpl :meta)
     :context (plist-get tpl :context))
    ;; Return the created note
    (vulpea-db-get-by-id id)))

;;; Date Queries

(defun vulpea-journal-dates-in-range (start end)
  "Return list of dates with journal entries between [START, END)."
  (->> (list (vulpea-journal--get-tag))
       (vulpea-db-query-by-tags-every)
       (--filter (when-let ((date (vulpea-journal--date-from-note it)))
                   (and (or (time-equal-p start date) (time-less-p start date))
                        (time-less-p date end)
                        date)))
       (-map #'vulpea-journal--date-from-note)
       (-filter #'identity)))

(defun vulpea-journal-dates-in-month (month year)
  "Return list of dates with journal entries in MONTH of YEAR."
  (let ((start (encode-time 0 0 0 1 month year))
        (end (encode-time 0 0 0 1 (if (= month 12) 1 (1+ month))
                          (if (= month 12) (1+ year) year))))
    (vulpea-journal-dates-in-range start end)))

(defun vulpea-journal-all-dates ()
  "Return list of all dates with journal entries."
  (->> (list (vulpea-journal--get-tag))
       (vulpea-db-query-by-tags-every)
       (-map #'vulpea-journal--date-from-note)
       (-filter #'identity)))

;;; Two-Window Layout

(defun vulpea-journal--get-note-buffer (note)
  "Get or create buffer for NOTE."
  (find-file-noselect (vulpea-note-path note)))

(defun vulpea-journal--setup-windows (note-buffer widgets-buffer)
  "Set up two-window layout with NOTE-BUFFER and WIDGETS-BUFFER."
  (delete-other-windows)
  (switch-to-buffer note-buffer)
  (let* ((total-width (window-total-width))
         (note-width (floor (* total-width vulpea-journal-window-ratio)))
         (widgets-window (split-window-right note-width)))
    (set-window-buffer widgets-window widgets-buffer)
    ;; Return to note buffer
    (select-window (get-buffer-window note-buffer))))

;;; Interactive Commands

;;;###autoload
(defun vulpea-journal (&optional date)
  "Open journal view for DATE (defaults to today).
Creates a two-window layout with the journal note on the left
and interactive widgets on the right."
  (interactive)
  (require 'vulpea-journal-ui)
  (let* ((date (or date (current-time)))
         (note (vulpea-journal-note date))
         (note-buffer (vulpea-journal--get-note-buffer note)))
    ;; Mount vui widgets
    (vui-mount (vui-component 'vui-journal-root :initial-date date)
               vulpea-journal-widgets-buffer-name)
    (let ((widgets-buffer (get-buffer vulpea-journal-widgets-buffer-name)))
      ;; Link buffers
      (with-current-buffer note-buffer
        (setq-local vulpea-journal--widgets-buffer widgets-buffer)
        (setq-local vulpea-journal--current-date date))
      (with-current-buffer widgets-buffer
        (setq-local vulpea-journal--note-buffer note-buffer)
        (setq-local vulpea-journal--current-date date))
      ;; Set up windows
      (vulpea-journal--setup-windows note-buffer widgets-buffer))))

;;;###autoload
(defun vulpea-journal-today ()
  "Open journal view for today."
  (interactive)
  (vulpea-journal (current-time)))

;;;###autoload
(defun vulpea-journal-date (date)
  "Open journal view for DATE.
When called interactively, prompt for date."
  (interactive (list (vulpea-journal--read-date "Journal date: ")))
  (vulpea-journal date))

(defun vulpea-journal--read-date (prompt)
  "Read a date from user with PROMPT."
  (let* ((org-read-date-prefer-future nil)
         (date-string (org-read-date nil nil nil prompt)))
    (org-time-string-to-time date-string)))

;;; Navigation Commands

(defun vulpea-journal-quit ()
  "Quit journal view and restore window configuration."
  (interactive)
  (when-let ((widgets-buffer (get-buffer vulpea-journal-widgets-buffer-name)))
    (when-let ((window (get-buffer-window widgets-buffer)))
      (delete-window window))
    (kill-buffer widgets-buffer)))

(defun vulpea-journal-edit-note ()
  "Switch to the note buffer for editing."
  (interactive)
  (when vulpea-journal--note-buffer
    (select-window (get-buffer-window vulpea-journal--note-buffer))))

;;; Calendar Integration

(defface vulpea-journal-calendar-entry-face
  '((t :inherit bold :foreground "forest green"))
  "Face for calendar days that have journal entries."
  :group 'vulpea-journal)

(defun vulpea-journal-calendar-mark-entries ()
  "Mark days in calendar that have journal entries."
  (when (and (boundp 'displayed-month) (boundp 'displayed-year))
    (let ((entries (vulpea-journal-dates-in-month displayed-month displayed-year)))
      (dolist (date entries)
        (let* ((decoded (decode-time date))
               (day (decoded-time-day decoded))
               (month (decoded-time-month decoded))
               (year (decoded-time-year decoded)))
          (when (calendar-date-is-visible-p (list month day year))
            (calendar-mark-visible-date
             (list month day year)
             'vulpea-journal-calendar-entry-face)))))))

(defun vulpea-journal-calendar-open ()
  "Open journal for date at point in calendar."
  (interactive)
  (let ((date (calendar-cursor-to-date t)))
    (when date
      (vulpea-journal (encode-time 0 0 0
                                   (nth 1 date)   ; day
                                   (nth 0 date)   ; month
                                   (nth 2 date))))))

;;;###autoload
(defun vulpea-journal-calendar-setup ()
  "Set up calendar integration for vulpea-journal.
Call this in your init file to enable calendar marks and keybindings."
  (add-hook 'calendar-today-visible-hook #'vulpea-journal-calendar-mark-entries)
  (add-hook 'calendar-today-invisible-hook #'vulpea-journal-calendar-mark-entries)
  ;; Add keybindings to calendar mode
  (with-eval-after-load 'calendar
    (define-key calendar-mode-map (kbd "j") #'vulpea-journal-calendar-open)))

(provide 'vulpea-journal)
;;; vulpea-journal.el ends here
