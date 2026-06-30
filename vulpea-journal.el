;;; vulpea-journal.el --- Daily note interface for vulpea -*- lexical-binding: t; -*-
;;
;; Copyright (c) 2024-2026 Boris Buliga <boris@d12frosted.io>
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; Author: Boris Buliga <boris@d12frosted.io>
;; Maintainer: Boris Buliga <boris@d12frosted.io>
;; Version: 1.0.1
;; Package-Requires: ((emacs "29.1") (vulpea "2.0.0") (vulpea-ui "1.0.0") (dash "2.20.0"))
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

(declare-function vulpea-journal-ui-setup "vulpea-journal-ui")

(defvar vulpea-default-notes-directory)
(defvar vulpea-db-sync-directories)


;;; Customization

(defgroup vulpea-journal nil
  "Daily note interface for vulpea."
  :group 'vulpea)

(defcustom vulpea-journal-tag "journal"
  "Tag that identifies journal notes.

This is used by `vulpea-journal-note-p' to check if a note is a
journal note. Template builders (`vulpea-journal-template-daily',
`vulpea-journal-template-monthly') use this as the default tag.

If you use a raw plist for `vulpea-journal-default-template',
make sure the first element of `:tags' matches this value."
  :type 'string
  :group 'vulpea-journal)

(defcustom vulpea-journal-default-template
  '(:file-name "journal/%Y-%m-%d.org"
    :title "%Y-%m-%d %A"
    :tags ("journal")
    :head "#+created: %<[%Y-%m-%d]>")
  "Default template for journal notes.

Can be a plist or a function taking DATE and returning a plist.

Required keys:
- `:file-name' - strftime format for file path (relative to
  `vulpea-default-notes-directory')
- `:title' - strftime format for note title
- `:tags' - List of tags (first should match `vulpea-journal-tag')

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


;;; Template Builders

(defun vulpea-journal--normalize-specs (specs)
  "Normalize SPECS into a list of template specs.
SPECS may be nil, a single spec (a strftime string or a function
of one argument DATE), or a list of such specs.  A single spec is
wrapped in a one-element list.  Shared by :entry-groups and :aliases."
  (cond
   ((null specs) nil)
   ((or (stringp specs) (functionp specs)) (list specs))
   ((listp specs) specs)
   (t (error "Invalid template spec list: %S" specs))))

(cl-defun vulpea-journal-template-daily (&key
                                         (file-name "journal/%Y-%m-%d.org")
                                         (title "%Y-%m-%d %A")
                                         (tags (list vulpea-journal-tag))
                                         aliases head body properties meta context)
  "Create a daily journal template (one file per day).

Returns a plist suitable for `vulpea-journal-default-template'.

All parameters are optional with sensible defaults:
- FILE-NAME: strftime format for file path (default: journal/%Y-%m-%d.org)
- TITLE: strftime format for note title (default: %Y-%m-%d %A)
- TAGS: list of tags (default: (\"journal\"))
- ALIASES: optional note aliases, computed per entry.  Each element is
  a strftime string expanded for the entry's date (e.g. \"%Y-%m-%d\")
  or a function of one argument (DATE) returning the alias; a single
  spec may be given without a list.  Written to the property named by
  `vulpea-buffer-alias-property' so the entry can be linked by a short
  stamp instead of its title.
- HEAD, BODY, PROPERTIES, META, CONTEXT: passed to `vulpea-create'"
  (append
   (list :file-name file-name :title title :tags tags)
   (when aliases (list :aliases (vulpea-journal--normalize-specs aliases)))
   (when head (list :head head))
   (when body (list :body body))
   (when properties (list :properties properties))
   (when meta (list :meta meta))
   (when context (list :context context))))

(cl-defun vulpea-journal-template-monthly (&key
                                           (file-name "journal/%Y-%m.org")
                                           (title "%Y-%m")
                                           (tags (list vulpea-journal-tag))
                                           (entry-level 1)
                                           (entry-title "%d %A")
                                           entry-groups
                                           aliases head body properties meta context)
  "Create a monthly journal template (one file per month).

Daily entries are created as headings inside the monthly file.

Returns a plist suitable for `vulpea-journal-default-template'.

All parameters are optional with sensible defaults:
- FILE-NAME: strftime format for monthly file (default: journal/%Y-%m.org)
- TITLE: strftime format for file-level title (default: %Y-%m)
- TAGS: list of tags (default: (\"journal\"))
- ENTRY-LEVEL: heading level for daily entries (default: 1).  Ignored
  when ENTRY-GROUPS is set, in which case it is derived (see below).
- ENTRY-TITLE: strftime format for entry heading (default: %d %A)
- ENTRY-GROUPS: optional grouping headings that nest the daily entry
  deeper inside the file.  Each element produces one heading level
  between the file and the entry and is either a strftime format
  string (e.g. \"week %V\") or a function of one argument (DATE)
  returning the heading title.  A single spec may be given without
  wrapping it in a list.  When set, ENTRY-LEVEL is derived as
  1 + number of groups so lookup and creation agree.  For example,
  :entry-groups \\='(\"week %V\") nests each day under a \"week NN\"
  heading and entries live at level 2.
- ALIASES: optional note aliases, computed per entry.  Each element is
  a strftime string expanded for the entry's date (e.g. \"%Y-%m-%d\")
  or a function of one argument (DATE) returning the alias; a single
  spec may be given without a list.  Written to the property named by
  `vulpea-buffer-alias-property' so the entry can be linked by a short
  stamp instead of its title.
- BODY, PROPERTIES, CONTEXT: applied to each daily entry.
- HEAD: applied to the monthly file (the container), not the entries.
- META: file-level only; monthly heading entries do not carry meta,
  as `vulpea-create' supports meta on file-level notes only."
  (let* ((groups (vulpea-journal--normalize-specs entry-groups))
         (entry-level (if groups (1+ (length groups)) entry-level)))
    (append
     (list :file-name file-name :title title :tags tags
           :entry-level entry-level :entry-title entry-title)
     (when groups (list :entry-groups groups))
     (when aliases (list :aliases (vulpea-journal--normalize-specs aliases)))
     (when head (list :head head))
     (when body (list :body body))
     (when properties (list :properties properties))
     (when meta (list :meta meta))
     (when context (list :context context)))))


;;; Template Resolution

(defun vulpea-journal--get-template (date)
  "Get resolved template plist for DATE."
  (if (functionp vulpea-journal-default-template)
      (funcall vulpea-journal-default-template date)
    vulpea-journal-default-template))

(defun vulpea-journal--heading-entry-p (&optional date)
  "Return non-nil if current template is configured for heading-level entries.
Optional DATE is used for template resolution (defaults to current time)."
  (let ((tpl (vulpea-journal--get-template (or date (current-time)))))
    (plist-get tpl :entry-level)))

(defun vulpea-journal--entry-level (date)
  "Return :entry-level from template for DATE, or nil for file-per-day."
  (plist-get (vulpea-journal--get-template date) :entry-level))

(defun vulpea-journal--entry-title-for-date (date)
  "Return heading title for DATE using :entry-title format."
  (let ((fmt (plist-get (vulpea-journal--get-template date) :entry-title)))
    (format-time-string fmt date)))


;;; Journal Directory

(defun vulpea-journal--ensure-directory (file)
  "Ensure directory for FILE exists."
  (let ((dir (file-name-directory file)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))


;;; Debug

(defvar vulpea-journal-debug nil
  "Enable debug logging for `vulpea-journal'.")

(defun vulpea-journal--debug (format-string &rest args)
  "Log debug message using FORMAT-STRING and ARGS."
  (when vulpea-journal-debug
    (with-current-buffer (get-buffer-create "*vulpea-journal-debug*")
      (goto-char (point-max))
      (insert (apply #'format format-string args) "\n"))))


;;; Active Date Tracking

(defvar-local vulpea-journal--active-date nil
  "The journal date currently being viewed in this buffer.
Set by `vulpea-journal' and `vulpea-journal-ui--visit-date'
to track which specific day is active, especially important for
monthly templates where multiple days share the same file.")

(defun vulpea-journal--set-active-date (date &optional buffer)
  "Set the active journal DATE in BUFFER (defaults to current buffer).
When the sidebar is visible, refreshes it to reflect the new date."
  (with-current-buffer (or buffer (current-buffer))
    (setq vulpea-journal--active-date date)))

(defun vulpea-journal-active-date (&optional buffer)
  "Get the active journal date from BUFFER (defaults to current buffer)."
  (buffer-local-value 'vulpea-journal--active-date
                      (or buffer (current-buffer))))


;;; Note Identification

(defun vulpea-journal-note-p (note)
  "Return non-nil if NOTE is a journal note."
  (and note
       (member vulpea-journal-tag (vulpea-note-tags note))))

(defun vulpea-journal-note-date (note)
  "Extract date from journal NOTE.
Returns time value or nil if not a journal note or date cannot be extracted.

For file-level notes (daily): extracts date from the file path.
For heading-level notes (monthly): extracts date from CREATED property.
Falls back to CREATED property in all cases."
  (when (vulpea-journal-note-p note)
    (let ((path (vulpea-note-path note)))
      (vulpea-journal--debug "note-date: title=%s path=%s level=%s"
                             (vulpea-note-title note)
                             path
                             (vulpea-note-level note))
      (if (> (or (vulpea-note-level note) 0) 0)
          ;; Heading-level note: use CREATED property
          (vulpea-journal--date-from-created note)
        ;; File-level note: extract from file path, fallback to CREATED
        (or (vulpea-journal--date-from-file path)
            (vulpea-journal--date-from-created note))))))

(defun vulpea-journal--date-from-created (note)
  "Extract date from CREATED property of NOTE."
  (let* ((props (vulpea-note-properties note))
         (created (cdr (assoc "CREATED" props))))
    (vulpea-journal--debug "date-from-created: props=%S created=%S"
                           props created)
    (when (and created
               (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" created))
      (let ((year (string-to-number (match-string 1 created)))
            (month (string-to-number (match-string 2 created)))
            (day (string-to-number (match-string 3 created))))
        (encode-time 0 0 0 day month year)))))


;;; File Path Resolution

(defun vulpea-journal--file-for-date (date)
  "Return file path for journal note on DATE."
  (let* ((tpl (vulpea-journal--get-template date))
         (file-fmt (plist-get tpl :file-name)))
    (expand-file-name
     (format-time-string file-fmt date)
     (or vulpea-default-notes-directory
         (car vulpea-db-sync-directories)))))

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
  (let* ((entry-level (vulpea-journal--entry-level date))
         (file (vulpea-journal--file-for-date date)))
    (if entry-level
        ;; Heading-level entry: find by file path + level + CREATED date
        (vulpea-journal--find-heading-note file entry-level date)
      ;; File-level entry: find by file path at level 0
      (when (file-exists-p file)
        (or (car (vulpea-db-query-by-file-path file 0))
            ;; Fallback: try with resolved truename for symlink cases
            ;; (e.g., macOS /var -> /private/var)
            (let ((truename (file-truename file)))
              (unless (string= truename file)
                (car (vulpea-db-query-by-file-path truename 0))))
            ;; Fallback: try with abbreviated path for databases that
            ;; store paths with ~ instead of expanded home directory
            (let ((abbreviated (abbreviate-file-name file)))
              (unless (string= abbreviated file)
                (car (vulpea-db-query-by-file-path abbreviated 0)))))))))

(defun vulpea-journal--find-heading-note (file level date)
  "Find heading-level journal note in FILE at LEVEL matching DATE."
  (when (file-exists-p file)
    (let* ((target-date-str (format-time-string "%Y-%m-%d" date))
           (notes (vulpea-journal--query-file-notes file level)))
      (--first
       (let ((created (cdr (assoc "CREATED" (vulpea-note-properties it)))))
         (and created (string-match-p (regexp-quote target-date-str) created)))
       notes))))

(defun vulpea-journal--query-file-notes (file level)
  "Query notes in FILE at LEVEL, trying path variations."
  (or (vulpea-db-query-by-file-path file level)
      (let ((truename (file-truename file)))
        (unless (string= truename file)
          (vulpea-db-query-by-file-path truename level)))
      (let ((abbreviated (abbreviate-file-name file)))
        (unless (string= abbreviated file)
          (vulpea-db-query-by-file-path abbreviated level)))))

(defun vulpea-journal-note (date)
  "Get journal note for DATE, creating if needed."
  (or (vulpea-journal-find-note date)
      (vulpea-journal--create-note date)))

(defun vulpea-journal--create-note (date)
  "Create a new journal note for DATE.
For daily templates, creates a file-level note.
For monthly templates, creates a heading inside the monthly container."
  (let* ((tpl (vulpea-journal--get-template date))
         (entry-level (plist-get tpl :entry-level)))
    (if entry-level
        (vulpea-journal--create-heading-note date tpl)
      (vulpea-journal--create-file-note date tpl))))

(defun vulpea-journal--create-file-note (date tpl)
  "Create a file-level journal note for DATE using template TPL."
  (let* ((file (vulpea-journal--file-for-date date))
         (title (vulpea-journal--title-for-date date))
         (id (org-id-new)))
    (when (file-exists-p file)
      (error "File %s already exists but is not in vulpea database.
This can happen if the file was created manually or lacks required properties.
To fix: either delete the file, or add it to vulpea by ensuring it has
an ID property and running `vulpea-db-sync-full-scan'" file))
    (vulpea-journal--ensure-directory file)
    (vulpea-create
     title
     file
     :id id
     :tags (plist-get tpl :tags)
     :head (plist-get tpl :head)
     :body (plist-get tpl :body)
     :properties (vulpea-journal--entry-properties tpl date nil)
     :meta (plist-get tpl :meta)
     :context (plist-get tpl :context))
    (vulpea-db-get-by-id id)))

(defun vulpea-journal--resolve-spec (spec date)
  "Resolve template SPEC for DATE to a string.
SPEC is either a strftime format string (expanded for DATE) or a
function of one argument (DATE) returning a string.  Shared by
:entry-groups and :aliases."
  (cond
   ((functionp spec) (funcall spec date))
   ((stringp spec) (format-time-string spec date))
   (t (error "Invalid template spec: %S" spec))))

(defun vulpea-journal--resolve-aliases (tpl date)
  "Return the list of resolved alias strings for DATE from TPL.
Each TPL :aliases spec is resolved via `vulpea-journal--resolve-spec'.
Returns nil when TPL has no :aliases."
  (mapcar (lambda (spec) (vulpea-journal--resolve-spec spec date))
          (vulpea-journal--normalize-specs (plist-get tpl :aliases))))

(defun vulpea-journal--alias-property (aliases)
  "Return a one-element alist setting the alias property for ALIASES.
The property name is `vulpea-buffer-alias-property'.  An alias that
contains whitespace or a double quote is wrapped in double quotes,
matching how vulpea stores and parses aliases.  Returns nil when
ALIASES is empty."
  (when aliases
    (list (cons vulpea-buffer-alias-property
                (mapconcat
                 (lambda (alias)
                   (if (string-match-p "[ \t\"]" alias)
                       (format "%S" alias)
                     alias))
                 aliases " ")))))

(defun vulpea-journal--entry-properties (tpl date base)
  "Build the property alist for a journal entry on DATE.
BASE is an alist of journal-managed properties (e.g. CREATED).
Appends TPL :properties and the resolved :aliases property."
  (append base
          (plist-get tpl :properties)
          (vulpea-journal--alias-property
           (vulpea-journal--resolve-aliases tpl date))))

(defun vulpea-journal--find-child-heading (file level title outline-path)
  "Find heading note in FILE at LEVEL titled TITLE under OUTLINE-PATH.
OUTLINE-PATH is the expected ancestor heading titles, outermost
first.  Returns the matching `vulpea-note' or nil."
  (--first
   (and (string= (vulpea-note-title it) title)
        (equal (vulpea-note-outline-path it) outline-path))
   (vulpea-journal--query-file-notes file level)))

(defun vulpea-journal--ensure-group-path (container date groups)
  "Ensure the chain of GROUPS headings under CONTAINER for DATE.
CONTAINER is the file-level container `vulpea-note'.  GROUPS is a
list of group specs (see `vulpea-journal--resolve-spec').
Missing group headings are created on demand and existing ones are
reused.  Returns the deepest container note that should parent the
entry, which is CONTAINER itself when GROUPS is empty."
  (let ((parent container)
        (file (vulpea-note-path container))
        (ancestry nil))
    (dolist (spec (vulpea-journal--normalize-specs groups) parent)
      (let* ((title (vulpea-journal--resolve-spec spec date))
             (level (1+ (vulpea-note-level parent)))
             (existing (vulpea-journal--find-child-heading
                        file level title (reverse ancestry))))
        ;; Group headings carry no :tags and no CREATED property of
        ;; their own; they inherit the file's filetags structurally,
        ;; so date lookup never confuses them with daily entries.
        (setq parent (or existing
                         (vulpea-create title nil
                                        :parent parent
                                        :after 'last)))
        (push title ancestry)))))

(defun vulpea-journal--create-heading-note (date tpl)
  "Create a heading-level journal note for DATE using template TPL.
When TPL has a non-nil :entry-groups, the entry is nested under the
chain of date-derived grouping headings (created on demand)."
  (let* ((file (vulpea-journal--file-for-date date))
         (entry-title (vulpea-journal--entry-title-for-date date))
         (date-str (format-time-string "[%Y-%m-%d]" date))
         ;; Find or create the container (file-level note), then walk
         ;; the optional chain of grouping headings for this date.
         (container (vulpea-journal--ensure-container file date tpl))
         (parent (vulpea-journal--ensure-group-path
                  container date (plist-get tpl :entry-groups))))
    ;; Create heading entry under the deepest container.
    ;; Note: no :tags here - headings inherit filetags from container
    (vulpea-create
     entry-title
     nil
     :parent parent
     :body (plist-get tpl :body)
     :properties (vulpea-journal--entry-properties
                  tpl date `(("CREATED" . ,date-str)))
     :context (plist-get tpl :context)
     :after 'last)))

(defun vulpea-journal--ensure-container (file date tpl)
  "Ensure monthly container file exists at FILE for DATE.
TPL is the journal template. Returns the container vulpea-note."
  (or
   ;; Try to find existing container
   (car (vulpea-journal--query-file-notes file 0))
   ;; Create new container
   (let ((title (vulpea-journal--title-for-date date))
         (id (org-id-new)))
     (vulpea-journal--ensure-directory file)
     (vulpea-create
      title
      file
      :id id
      :tags (plist-get tpl :tags)
      :head (plist-get tpl :head))
     (vulpea-db-get-by-id id))))


;;; Date Queries

(defun vulpea-journal-all-dates ()
  "Return list of all dates with journal entries.
Includes both file-level entries (daily) and heading-level entries (monthly)."
  (let* ((notes (vulpea-db-query-by-tags-every (list vulpea-journal-tag))))
    (vulpea-journal--debug "=== all-dates ===")
    (vulpea-journal--debug "Tag: %s" vulpea-journal-tag)
    (vulpea-journal--debug "Notes with tag: %d" (length notes))
    (->> notes
         ;; Include file-level notes with YYYY-MM-DD in filename (daily)
         ;; and heading-level notes with CREATED property (monthly)
         ;; Exclude file-level container notes (no date in filename)
         (--filter (or (and (= (vulpea-note-level it) 0)
                            (vulpea-journal--date-from-file
                             (vulpea-note-path it)))
                       (> (vulpea-note-level it) 0)))
         (-map #'vulpea-journal-note-date)
         (-filter #'identity)
         (-uniq)
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
    (vulpea-journal--set-active-date date)
    ;; Ensure sidebar is open
    (unless (vulpea-ui--sidebar-visible-p)
      (vulpea-ui-sidebar-open))
    ;; For same-file navigation (monthly), force sidebar refresh
    (when (vulpea-ui--sidebar-visible-p)
      (vulpea-ui-sidebar-refresh))))

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
  (minibuffer-with-setup-hook
      (lambda ()
        (local-set-key
         (kbd "M-<left>") #'vulpea-journal-date-previous)
        (local-set-key
         (kbd "M-<right>") #'vulpea-journal-date-next))

    ;; Code below is exactly the same as the original vulpea-journal--read-date function
    (let* ((org-read-date-prefer-future nil)
           (date-string (org-read-date nil nil nil prompt)))
      (org-time-string-to-time date-string))))

(defun vulpea-journal--buffer-note ()
  "Get the journal note for the current buffer.
For heading-level entries, uses `vulpea-journal--active-date' to find
the specific heading note. Returns nil if not visiting a journal note."
  (when-let ((file (buffer-file-name)))
    (let ((active-date vulpea-journal--active-date))
      (if (and active-date (vulpea-journal--heading-entry-p active-date))
          ;; Heading-level entry: find by active date
          (let ((entry-level (vulpea-journal--entry-level active-date)))
            (vulpea-journal--find-heading-note file entry-level active-date))
        ;; File-level entry
        (car (vulpea-db-query-by-file-path file 0))))))

;;;###autoload
(defun vulpea-journal-next ()
  "Navigate to the next journal entry."
  (interactive)
  (let ((current-date (or vulpea-journal--active-date
                          (vulpea-journal-note-date
                           (vulpea-journal--buffer-note)))))
    (if (null current-date)
        (user-error "Not viewing a journal note")
      (if-let* ((next-date (vulpea-journal--adjacent-date current-date 'next)))
          (vulpea-journal next-date)
        (message "No next journal entry")))))

;;;###autoload
(defun vulpea-journal-previous ()
  "Navigate to the previous journal entry."
  (interactive)
  (let ((current-date (or vulpea-journal--active-date
                          (vulpea-journal-note-date
                           (vulpea-journal--buffer-note)))))
    (if (null current-date)
        (user-error "Not viewing a journal note")
      (if-let* ((prev-date (vulpea-journal--adjacent-date current-date 'prev)))
          (vulpea-journal prev-date)
        (message "No previous journal entry")))))


;;; Calendar Integration

(defface vulpea-journal-calendar-entry-face
  '((t :inherit bold :foreground "forest green"))
  "Face for calendar days that have journal entries."
  :group 'vulpea-journal)

(defun vulpea-journal-calendar-mark-entries ()
  "Mark days in calendar that have journal entries.
Marks entries for all visible months (previous, current, next)."
  (when (and (boundp 'displayed-month) (boundp 'displayed-year))
    ;; Calendar shows 3 months: prev, current, next
    ;; Query all 3 to mark entries in adjacent months
    (let* ((prev-month (1- displayed-month))
           (prev-year displayed-year)
           (next-month (1+ displayed-month))
           (next-year displayed-year))
      ;; Adjust for year boundaries
      (when (< prev-month 1)
        (setq prev-month 12
              prev-year (1- displayed-year)))
      (when (> next-month 12)
        (setq next-month 1
              next-year (1+ displayed-year)))
      ;; Collect entries from all 3 months
      (let ((entries (append
                      (vulpea-journal-dates-in-month prev-month prev-year)
                      (vulpea-journal-dates-in-month displayed-month displayed-year)
                      (vulpea-journal-dates-in-month next-month next-year))))
        (dolist (date entries)
          (let* ((decoded (decode-time date))
                 (day (decoded-time-day decoded))
                 (month (decoded-time-month decoded))
                 (year (decoded-time-year decoded)))
            (when (calendar-date-is-visible-p (list month day year))
              (calendar-mark-visible-date
               (list month day year)
               'vulpea-journal-calendar-entry-face))))))))

(defun vulpea-journal--funcall-in-calendar (fn)
  "Call FN in the calendar window during `org-read-date'.
Falls back to `org-eval-in-calendar' on Org < 9.8."
  (if (fboundp 'org-funcall-in-calendar)
      (org-funcall-in-calendar fn)
    (with-no-warnings (org-eval-in-calendar (list 'funcall fn)))))

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

(defun vulpea-journal-date-previous ()
  "Move to the previous date that has a journal entry.
Intended for use while reading a date with `vulpea-journal-date'."
  (interactive)
  (vulpea-journal--funcall-in-calendar #'vulpea-journal-calendar-previous))

(defun vulpea-journal-date-next ()
  "Move to the next date that has a journal entry.
Intended for use while reading a date with `vulpea-journal-date'."
  (interactive)
  (vulpea-journal--funcall-in-calendar #'vulpea-journal-calendar-next))

;;; Calendar Minor Mode

(defvar vulpea-journal-calendar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "j") #'vulpea-journal-calendar-open)
    (define-key map (kbd "]") #'vulpea-journal-calendar-next)
    (define-key map (kbd "[") #'vulpea-journal-calendar-previous)
    map)
  "Keymap for `vulpea-journal-calendar-mode'.")

(define-minor-mode vulpea-journal-calendar-mode
  "Minor mode for journal integration in calendar buffers.
Provides keybindings for navigating journal entries from the calendar.

\\{vulpea-journal-calendar-mode-map}"
  :lighter nil
  :keymap vulpea-journal-calendar-mode-map)


;;; Setup

;;;###autoload
(defun vulpea-journal-setup ()
  "Set up `vulpea-journal' integration.

This function configures:

1. Calendar integration - enables `vulpea-journal-calendar-mode' in
   calendar buffers, providing keybindings for opening and navigating
   journal entries.  Also marks days with journal entries.

2. Sidebar keybindings - adds journal navigation keys to
   `vulpea-ui-sidebar-mode-map'.

3. Sidebar widgets - registers journal-specific widgets (navigation,
   calendar, created today, previous years) with `vulpea-ui'."
  ;; Calendar hooks for marking entries
  (add-hook 'calendar-today-visible-hook #'vulpea-journal-calendar-mark-entries)
  (add-hook 'calendar-today-invisible-hook #'vulpea-journal-calendar-mark-entries)
  ;; Enable calendar minor mode
  (add-hook 'calendar-mode-hook #'vulpea-journal-calendar-mode)
  ;; Load and setup UI module for sidebar widgets
  (require 'vulpea-journal-ui)
  (vulpea-journal-ui-setup))

(provide 'vulpea-journal)
;;; vulpea-journal.el ends here
