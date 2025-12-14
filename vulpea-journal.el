;;; vulpea-journal.el --- Daily note interface for vulpea -*- lexical-binding: t; -*-
;;
;; Copyright (c) 2024-2025 Boris Buliga <boris@d12frosted.io>
;;
;; Author: Boris Buliga <boris@d12frosted.io>
;; Maintainer: Boris Buliga <boris@d12frosted.io>
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1") (vulpea "2.0.0") (vulpea-ui "0.1.0") (dash "2.20.0"))
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
;; workflows. It integrates with vulpea-ui's sidebar to show
;; journal-specific widgets when viewing journal notes.
;;
;; Main features:
;; - Daily note identification and navigation
;; - Integration with vulpea-ui sidebar
;; - Calendar widget with entry indicators
;; - Previous years view
;; - Emacs calendar integration
;;
;; Quick start:
;;
;;   (require 'vulpea-journal)
;;   (vulpea-journal-setup)
;;   (global-set-key (kbd "C-c j") #'vulpea-journal)
;;
;;; Code:

(require 'vulpea)
(require 'vulpea-db)
(require 'vulpea-db-query)
(require 'vulpea-ui)
(require 'dash)
(require 'calendar)

(defvar vulpea-directory)


;;; Customization

(defgroup vulpea-journal nil
  "Daily note interface for vulpea."
  :group 'vulpea)

(defcustom vulpea-journal-default-template
  '(:file-name "journal/%Y-%m-%d.org"
    :title "%Y-%m-%d %A"
    :tags ("journal")
    :head "#+created: %<[%Y-%m-%d]>")
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
  journal/2024-11-25.org regardless of today's date.

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


;;; Journal Directory

(defun vulpea-journal--ensure-directory (file)
  "Ensure directory for FILE exists."
  (let ((dir (file-name-directory file)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))


;;; Debug

(defvar vulpea-journal-debug nil
  "Enable debug logging for vulpea-journal.")

(defun vulpea-journal--debug (format-string &rest args)
  "Log debug message using FORMAT-STRING and ARGS."
  (when vulpea-journal-debug
    (with-current-buffer (get-buffer-create "*vulpea-journal-debug*")
      (goto-char (point-max))
      (insert (apply #'format format-string args) "\n"))))


;;; Note Identification

(defun vulpea-journal-note-p (note)
  "Return non-nil if NOTE is a journal note."
  (and note
       (member (vulpea-journal--get-tag) (vulpea-note-tags note))))

(defun vulpea-journal-note-date (note)
  "Extract date from journal NOTE.
Returns time value or nil if not a journal note or date cannot be extracted.

Extracts date from the file path (e.g., journal/2025-12-08.org).
Falls back to CREATED property if file path doesn't contain a date."
  (when (vulpea-journal-note-p note)
    (let ((path (vulpea-note-path note)))
      (vulpea-journal--debug "note-date: title=%s path=%s"
                             (vulpea-note-title note)
                             path)
      ;; Extract date from file path first (most reliable)
      (or (vulpea-journal--date-from-file path)
          ;; Fall back to CREATED property
          (let* ((props (vulpea-note-properties note))
                 (created (cdr (assoc "CREATED" props))))
            (vulpea-journal--debug "note-date: fallback to props=%S created=%S"
                                   props created)
            (when (and created
                       (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" created))
              (let ((year (string-to-number (match-string 1 created)))
                    (month (string-to-number (match-string 2 created)))
                    (day (string-to-number (match-string 3 created))))
                (encode-time 0 0 0 day month year))))))))


;;; File Path Resolution

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

(defun vulpea-journal--date-from-file (file)
  "Extract date from journal FILE path.
Returns time value or nil if date cannot be extracted."
  (let ((filename (file-name-nondirectory file)))
    (when (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" filename)
      (let ((year (string-to-number (match-string 1 filename)))
            (month (string-to-number (match-string 2 filename)))
            (day (string-to-number (match-string 3 filename))))
        (encode-time 0 0 0 day month year)))))


;;; Note Lookup

(defun vulpea-journal-find-note (date)
  "Find existing journal note for DATE, or nil."
  (let ((file (vulpea-journal--file-for-date date)))
    (when (file-exists-p file)
      (car (vulpea-db-query-by-file-path file 0)))))

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

(defun vulpea-journal-all-dates ()
  "Return list of all dates with journal entries."
  (let* ((tag (vulpea-journal--get-tag))
         (notes (vulpea-db-query-by-tags-every (list tag)))
         (file-level-notes (--filter (= (vulpea-note-level it) 0) notes)))
    (vulpea-journal--debug "=== all-dates ===")
    (vulpea-journal--debug "Tag: %s" tag)
    (vulpea-journal--debug "Notes with tag: %d" (length notes))
    (vulpea-journal--debug "File-level notes: %d" (length file-level-notes))
    (->> file-level-notes
         (-map #'vulpea-journal-note-date)
         (-filter #'identity)
         (-sort #'time-less-p))))

(defun vulpea-journal-dates-in-range (start end)
  "Return list of dates with journal entries between [START, END)."
  (->> (vulpea-journal-all-dates)
       (--filter (and (or (time-equal-p start it) (time-less-p start it))
                      (time-less-p it end)))))

(defun vulpea-journal-dates-in-month (month year)
  "Return list of dates with journal entries in MONTH of YEAR."
  (let ((start (encode-time 0 0 0 1 month year))
        (end (encode-time 0 0 0 1 (if (= month 12) 1 (1+ month))
                          (if (= month 12) (1+ year) year))))
    (vulpea-journal-dates-in-range start end)))

(defun vulpea-journal-notes-for-date-across-years (date &optional years-back)
  "Return journal notes for same day as DATE in previous years.
YEARS-BACK specifies how many years to look back (default 5)."
  (let* ((decoded (decode-time date))
         (month (decoded-time-month decoded))
         (day (decoded-time-day decoded))
         (year (decoded-time-year decoded))
         (years-back (or years-back 5)))
    (->> (-iota years-back 1)
         (--map (let* ((past-year (- year it))
                       (check-date (encode-time 0 0 0 day month past-year)))
                  (when-let ((note (vulpea-journal-find-note check-date)))
                    (list :date check-date
                          :years-ago it
                          :note note))))
         (-non-nil))))


;;; Navigation

(defun vulpea-journal--adjacent-date (date direction)
  "Find adjacent journal entry date from DATE in DIRECTION.
DIRECTION is either `next' or `prev'.
Returns the date of the adjacent entry, or nil if none."
  (let ((all-dates (vulpea-journal-all-dates)))
    (pcase direction
      ('next
       (--first (time-less-p date it) all-dates))
      ('prev
       (--last (time-less-p it date) all-dates)))))


;;; Interactive Commands

;;;###autoload
(defun vulpea-journal (&optional date)
  "Open journal note for DATE (defaults to today).
Opens the note and shows vulpea-ui sidebar with journal widgets."
  (interactive)
  (let* ((date (or date (current-time)))
         (note (vulpea-journal-note date)))
    (vulpea-visit note)
    ;; Ensure sidebar is open
    (unless (vulpea-ui--sidebar-visible-p)
      (vulpea-ui-sidebar-open))))

;;;###autoload
(defun vulpea-journal-today ()
  "Open journal for today."
  (interactive)
  (vulpea-journal (current-time)))

;;;###autoload
(defun vulpea-journal-date (date)
  "Open journal for DATE.
When called interactively, prompt for date."
  (interactive (list (vulpea-journal--read-date "Journal date: ")))
  (vulpea-journal date))

(defun vulpea-journal--read-date (prompt)
  "Read a date from user with PROMPT."
  (let* ((org-read-date-prefer-future nil)
         (date-string (org-read-date nil nil nil prompt)))
    (org-time-string-to-time date-string)))

(defun vulpea-journal--buffer-note ()
  "Get the journal note for the current buffer.
Returns nil if current buffer is not visiting a journal note."
  (when-let ((file (buffer-file-name)))
    (car (vulpea-db-query-by-file-path file 0))))

;;;###autoload
(defun vulpea-journal-next ()
  "Navigate to the next journal entry."
  (interactive)
  (let ((note (vulpea-journal--buffer-note)))
    (if (not (vulpea-journal-note-p note))
        (user-error "Not viewing a journal note")
      (if-let* ((current-date (vulpea-journal-note-date note))
                (next-date (vulpea-journal--adjacent-date current-date 'next)))
          (vulpea-journal next-date)
        (message "No next journal entry")))))

;;;###autoload
(defun vulpea-journal-previous ()
  "Navigate to the previous journal entry."
  (interactive)
  (let ((note (vulpea-journal--buffer-note)))
    (if (not (vulpea-journal-note-p note))
        (user-error "Not viewing a journal note")
      (if-let* ((current-date (vulpea-journal-note-date note))
                (prev-date (vulpea-journal--adjacent-date current-date 'prev)))
          (vulpea-journal prev-date)
        (message "No previous journal entry")))))


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

(defun vulpea-journal-calendar-next ()
  "Move to next journal entry in calendar."
  (interactive)
  (let* ((date (calendar-cursor-to-date t))
         (time (when date
                 (encode-time 0 0 0 (nth 1 date) (nth 0 date) (nth 2 date))))
         (next-date (when time
                      (vulpea-journal--adjacent-date time 'next))))
    (if next-date
        (let ((decoded (decode-time next-date)))
          (calendar-goto-date (list (decoded-time-month decoded)
                                    (decoded-time-day decoded)
                                    (decoded-time-year decoded))))
      (message "No next journal entry"))))

(defun vulpea-journal-calendar-previous ()
  "Move to previous journal entry in calendar."
  (interactive)
  (let* ((date (calendar-cursor-to-date t))
         (time (when date
                 (encode-time 0 0 0 (nth 1 date) (nth 0 date) (nth 2 date))))
         (prev-date (when time
                      (vulpea-journal--adjacent-date time 'prev))))
    (if prev-date
        (let ((decoded (decode-time prev-date)))
          (calendar-goto-date (list (decoded-time-month decoded)
                                    (decoded-time-day decoded)
                                    (decoded-time-year decoded))))
      (message "No previous journal entry"))))


;;; Setup

;;;###autoload
(defun vulpea-journal-setup ()
  "Set up vulpea-journal integration.
This enables calendar marks and keybindings."
  ;; Calendar hooks
  (add-hook 'calendar-today-visible-hook #'vulpea-journal-calendar-mark-entries)
  (add-hook 'calendar-today-invisible-hook #'vulpea-journal-calendar-mark-entries)
  ;; Calendar keybindings
  (with-eval-after-load 'calendar
    (define-key calendar-mode-map (kbd "j") #'vulpea-journal-calendar-open)
    (define-key calendar-mode-map (kbd "]") #'vulpea-journal-calendar-next)
    (define-key calendar-mode-map (kbd "[") #'vulpea-journal-calendar-previous))
  ;; Load UI module for sidebar widgets
  (require 'vulpea-journal-ui))

(provide 'vulpea-journal)
;;; vulpea-journal.el ends here
