;;; vulpea-journal-test.el --- Tests for vulpea-journal -*- lexical-binding: t; -*-
;;
;; Copyright (c) 2024-2026 Boris Buliga <boris@d12frosted.io>
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
;;; Commentary:
;;
;; Tests for vulpea-journal.
;;
;;; Code:

(require 'ert)
(require 'vulpea)
(require 'vulpea-db)
(require 'vulpea-journal)

;;; Test Infrastructure

(defmacro vulpea-test--with-temp-db (&rest body)
  "Execute BODY with temporary database."
  (declare (indent 0))
  `(let* ((temp-file (make-temp-file "vulpea-test-" nil ".db"))
          (temp-dir (make-temp-file "vulpea-test-notes-" t))
          (vulpea-db-location temp-file)
          (vulpea-default-notes-directory temp-dir)
          (vulpea-db-sync-directories (list temp-dir)))
     (unwind-protect
         (progn
           (vulpea-db-close)  ;; Close any existing connection
           (vulpea-db)  ;; Initialize fresh database
           ,@body)
       (vulpea-db-close)
       (when (file-exists-p temp-file)
         (delete-file temp-file))
       (when (file-directory-p temp-dir)
         (delete-directory temp-dir t)))))

;;; Journal File Path Tests

(ert-deftest vulpea-journal-file-path-relative ()
  "Test file path generation with relative directory."
  (let ((vulpea-default-notes-directory "/test/notes/")
        (vulpea-journal-default-template '(:file-name "journal/%Y%m%d.org"
                                           :title "%Y-%m-%d %A"
                                           :tags ("journal")))
        (date (encode-time 0 0 12 25 11 2024)))
    (should (string= (vulpea-journal--file-for-date date)
                     "/test/notes/journal/20241125.org"))))

(ert-deftest vulpea-journal-file-path-nested ()
  "Test file path with nested directory structure."
  (let ((vulpea-default-notes-directory "/notes/")
        (vulpea-journal-default-template '(:file-name "journal/%Y/%m/%Y%m%d.org"
                                           :title "%Y-%m-%d %A"
                                           :tags ("journal")))
        (date (encode-time 0 0 12 25 11 2024)))
    (should (string= (vulpea-journal--file-for-date date)
                     "/notes/journal/2024/11/20241125.org"))))

;;; Note Identification Tests

(ert-deftest vulpea-journal-note-p-true ()
  "Test journal note identification."
  (let ((vulpea-journal-default-template '(:file-name "journal/%Y%m%d.org"
                                           :title "%Y-%m-%d %A"
                                           :tags ("journal"))))
    (should (vulpea-journal-note-p
             (make-vulpea-note :id "test" :tags '("journal" "daily"))))))

(ert-deftest vulpea-journal-note-p-false ()
  "Test non-journal note identification."
  (let ((vulpea-journal-default-template '(:file-name "journal/%Y%m%d.org"
                                           :title "%Y-%m-%d %A"
                                           :tags ("journal"))))
    (should-not (vulpea-journal-note-p
                 (make-vulpea-note :id "test" :tags '("project" "work"))))))

(ert-deftest vulpea-journal-note-p-nil ()
  "Test nil note identification."
  (should-not (vulpea-journal-note-p nil)))

;;; Title Generation Tests

(ert-deftest vulpea-journal-title-for-date ()
  "Test title generation for date."
  (let ((vulpea-journal-default-template '(:file-name "journal/%Y%m%d.org"
                                           :title "%Y-%m-%d %A"
                                           :tags ("journal")))
        (date (encode-time 0 0 12 25 11 2024)))
    (should (string= (vulpea-journal--title-for-date date)
                     "2024-11-25 Monday"))))

;;; Date Extraction Tests

(ert-deftest vulpea-journal-date-from-note ()
  "Test date extraction from journal note."
  (let ((vulpea-journal-default-template '(:file-name "journal/%Y-%m-%d.org"
                                           :title "%Y-%m-%d %A"
                                           :tags ("journal")))
        (note (make-vulpea-note
               :id "test"
               :path "/notes/journal/2024-11-25.org"
               :tags '("journal"))))
    (let ((date (vulpea-journal-note-date note)))
      (should date)
      (let ((decoded (decode-time date)))
        (should (= (decoded-time-year decoded) 2024))
        (should (= (decoded-time-month decoded) 11))
        (should (= (decoded-time-day decoded) 25))))))

(ert-deftest vulpea-journal-date-from-note-not-journal ()
  "Test date extraction from non-journal note."
  (let ((vulpea-journal-default-template '(:file-name "journal/%Y-%m-%d.org"
                                           :title "%Y-%m-%d %A"
                                           :tags ("journal")))
        (note (make-vulpea-note
               :id "test"
               :path "/notes/project.org"
               :tags '("project"))))
    (should-not (vulpea-journal-note-date note))))

;;; Full Integration Test

(ert-deftest vulpea-journal-create-note ()
  "Test creating a journal note."
  (vulpea-test--with-temp-db
    (let* ((vulpea-journal-default-template '(:file-name "journal/%Y%m%d.org"
                                              :title "%Y-%m-%d %A"
                                              :tags ("journal")))
           (date (encode-time 0 0 12 25 11 2024)))
      ;; Create note (directory is created automatically)
      (let ((note (vulpea-journal-note date)))
        (should note)
        (should (vulpea-note-id note))
        (should (vulpea-journal-note-p note))
        ;; Should find same note again
        (let ((found (vulpea-journal-find-note date)))
          (should found)
          (should (string= (vulpea-note-id found) (vulpea-note-id note))))))))

(ert-deftest vulpea-journal-find-note-after-db-rebuild ()
  "Test finding journal note after database rebuild.
Reproduces issue #5: after clearing the database and running a full
scan, `vulpea-journal-find-note' should still find journal entries.

This verifies that the journal uses the same directory as the sync
system (`vulpea-default-notes-directory') so paths remain consistent
across database rebuilds."
  (vulpea-test--with-temp-db
    (let* ((vulpea-journal-default-template '(:file-name "journal/%Y%m%d.org"
                                              :title "%Y-%m-%d %A"
                                              :tags ("journal")))
           (date (encode-time 0 0 12 25 11 2024)))
      ;; Create journal entry
      (let ((note (vulpea-journal-note date)))
        (should note)
        (should (vulpea-note-id note))
        ;; Clear database and rebuild via full scan
        (vulpea-db-clear)
        (vulpea-db-sync-full-scan)
        ;; Should still find the note after rebuild
        (let ((found (vulpea-journal-find-note date)))
          (should found)
          (should (string= (vulpea-note-id found)
                           (vulpea-note-id note))))))))

(ert-deftest vulpea-journal-find-note-nil-default-directory ()
  "Test finding journal note when vulpea-default-notes-directory is nil.
Simulates the common case where users only set
`vulpea-db-sync-directories' and expect
`vulpea-default-notes-directory' to dynamically resolve.

This reproduces the remaining issue #5: defcustom timing means
`vulpea-default-notes-directory' can be nil or stale when the user
only configures `vulpea-db-sync-directories'."
  (let* ((temp-file (make-temp-file "vulpea-test-" nil ".db"))
         (temp-dir (make-temp-file "vulpea-test-notes-" t))
         (vulpea-db-location temp-file)
         (vulpea-default-notes-directory nil)
         (vulpea-db-sync-directories (list temp-dir)))
    (unwind-protect
        (progn
          (vulpea-db-close)
          (vulpea-db)
          (let* ((vulpea-journal-default-template
                  '(:file-name "journal/%Y%m%d.org"
                    :title "%Y-%m-%d %A"
                    :tags ("journal")))
                 (date (encode-time 0 0 12 25 11 2024))
                 (note (vulpea-journal-note date)))
            (should note)
            (should (vulpea-note-id note))
            ;; Clear database and rebuild via full scan
            (vulpea-db-clear)
            (vulpea-db-sync-full-scan)
            ;; Should still find the note after rebuild
            (let ((found (vulpea-journal-find-note date)))
              (should found)
              (should (string= (vulpea-note-id found)
                               (vulpea-note-id note))))))
      (vulpea-db-close)
      (when (file-exists-p temp-file)
        (delete-file temp-file))
      (when (file-directory-p temp-dir)
        (delete-directory temp-dir t)))))

(ert-deftest vulpea-journal-find-note-directory-mismatch ()
  "Test finding journal note when directory paths differ in representation.
Simulates the case where `vulpea-default-notes-directory' and
`vulpea-db-sync-directories' use different string representations
of the same directory (e.g., symlink vs truename on macOS)."
  (let* ((temp-file (make-temp-file "vulpea-test-" nil ".db"))
         (temp-dir (make-temp-file "vulpea-test-notes-" t))
         (truename-dir (file-truename temp-dir))
         (vulpea-db-location temp-file)
         ;; Use original (possibly symlinked) path for notes directory
         (vulpea-default-notes-directory temp-dir)
         ;; Use truename for sync directories (simulates mismatch)
         (vulpea-db-sync-directories (list truename-dir)))
    (unwind-protect
        (progn
          (vulpea-db-close)
          (vulpea-db)
          (let* ((vulpea-journal-default-template
                  '(:file-name "journal/%Y%m%d.org"
                    :title "%Y-%m-%d %A"
                    :tags ("journal")))
                 (date (encode-time 0 0 12 25 11 2024))
                 (note (vulpea-journal-note date)))
            (should note)
            (should (vulpea-note-id note))
            ;; Clear database and rebuild via full scan
            ;; Sync will use truename-dir, storing truename paths
            (vulpea-db-clear)
            (vulpea-db-sync-full-scan)
            ;; Journal lookup uses temp-dir (non-truename)
            ;; Should still find the note despite path difference
            (let ((found (vulpea-journal-find-note date)))
              (should found)
              (should (string= (vulpea-note-id found)
                               (vulpea-note-id note))))))
      (vulpea-db-close)
      (when (file-exists-p temp-file)
        (delete-file temp-file))
      (when (file-directory-p temp-dir)
        (delete-directory temp-dir t)))))

(ert-deftest vulpea-journal-find-note-tilde-in-directory ()
  "Test finding journal note when sync directories use ~ notation.
Reproduces the core issue #5 scenario: when
`vulpea-db-sync-directories' contains \"~/notes\" instead of
\"/home/user/notes\", the database must still find journal entries
after a full scan rebuild."
  (let* ((temp-file (make-temp-file "vulpea-test-" nil ".db"))
         ;; Create temp dir under home so abbreviate-file-name
         ;; produces ~/...  path (can't use make-temp-file because
         ;; system temp dirs are not under home).
         (home-dir (expand-file-name "~"))
         (dir-name (format "vulpea-test-%s" (format-time-string "%s%N")))
         (expanded-dir (file-name-as-directory
                        (concat (file-name-as-directory home-dir)
                                dir-name)))
         (abbreviated-dir (abbreviate-file-name expanded-dir))
         (vulpea-db-location temp-file)
         ;; Use abbreviated (tilde) path — this is what users
         ;; typically configure in their init files
         (vulpea-default-notes-directory abbreviated-dir)
         (vulpea-db-sync-directories (list abbreviated-dir)))
    ;; Only run when abbreviation actually differs (i.e., we're
    ;; under a real home directory)
    (when (not (string= expanded-dir abbreviated-dir))
      (unwind-protect
          (progn
            (make-directory expanded-dir t)
            (vulpea-db-close)
            (vulpea-db)
            (let* ((vulpea-journal-default-template
                    '(:file-name "journal/%Y%m%d.org"
                      :title "%Y-%m-%d %A"
                      :tags ("journal")))
                   (date (encode-time 0 0 12 25 11 2024))
                   (note (vulpea-journal-note date)))
              (should note)
              (should (vulpea-note-id note))
              ;; Clear database and rebuild via full scan
              (vulpea-db-clear)
              (vulpea-db-sync-full-scan)
              ;; Should find the note after rebuild despite ~/... vs
              ;; /home/user/... path difference
              (let ((found (vulpea-journal-find-note date)))
                (should found)
                (should (string= (vulpea-note-id found)
                                 (vulpea-note-id note))))))
        (vulpea-db-close)
        (when (file-exists-p temp-file)
          (delete-file temp-file))
        (when (file-directory-p expanded-dir)
          (delete-directory expanded-dir t))))))

(ert-deftest vulpea-journal-no-overwrite-existing-file ()
  "Test that existing files not in database are not overwritten."
  (vulpea-test--with-temp-db
    (let* ((vulpea-journal-default-template '(:file-name "journal/%Y%m%d.org"
                                              :title "%Y-%m-%d %A"
                                              :tags ("journal")))
           (date (encode-time 0 0 12 25 11 2024))
           (file (vulpea-journal--file-for-date date))
           (original-content "* My important notes\nDon't lose this!"))
      ;; Create directory and file manually (simulating pre-existing file)
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert original-content))
      ;; Attempting to get journal note should error, not overwrite
      (should-error (vulpea-journal-note date))
      ;; Verify original content is preserved
      (should (string= (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string))
                       original-content)))))

;;; Template Builder Tests

(ert-deftest vulpea-journal-template-daily-defaults ()
  "Test daily template builder produces correct defaults."
  (let ((tpl (vulpea-journal-template-daily)))
    (should (plist-get tpl :file-name))
    (should (plist-get tpl :title))
    (should (plist-get tpl :tags))
    (should (member "journal" (plist-get tpl :tags)))
    ;; Daily templates should not have :entry-level
    (should-not (plist-get tpl :entry-level))))

(ert-deftest vulpea-journal-template-monthly-defaults ()
  "Test monthly template builder produces correct defaults."
  (let ((tpl (vulpea-journal-template-monthly)))
    (should (plist-get tpl :file-name))
    (should (plist-get tpl :title))
    (should (plist-get tpl :tags))
    (should (member "journal" (plist-get tpl :tags)))
    ;; Monthly templates must have :entry-level and :entry-title
    (should (plist-get tpl :entry-level))
    (should (= (plist-get tpl :entry-level) 1))
    (should (plist-get tpl :entry-title))))

(ert-deftest vulpea-journal-template-daily-overrides ()
  "Test daily template builder accepts overrides."
  (let ((tpl (vulpea-journal-template-daily
              :tags '("journal" "daily")
              :head "#+custom: header")))
    (should (equal (plist-get tpl :tags) '("journal" "daily")))
    (should (equal (plist-get tpl :head) "#+custom: header"))))

(ert-deftest vulpea-journal-template-monthly-overrides ()
  "Test monthly template builder accepts overrides."
  (let ((tpl (vulpea-journal-template-monthly
              :entry-title "%d %A"
              :tags '("journal" "monthly"))))
    (should (equal (plist-get tpl :entry-title) "%d %A"))
    (should (equal (plist-get tpl :tags) '("journal" "monthly")))))

;;; Template Helper Tests

(ert-deftest vulpea-journal-heading-entry-p-daily ()
  "Test heading-entry-p returns nil for daily templates."
  (let ((vulpea-journal-default-template (vulpea-journal-template-daily)))
    (should-not (vulpea-journal--heading-entry-p))))

(ert-deftest vulpea-journal-heading-entry-p-monthly ()
  "Test heading-entry-p returns non-nil for monthly templates."
  (let ((vulpea-journal-default-template (vulpea-journal-template-monthly)))
    (should (vulpea-journal--heading-entry-p))))

(ert-deftest vulpea-journal-entry-title-for-date ()
  "Test entry title generation for monthly template."
  (let ((vulpea-journal-default-template (vulpea-journal-template-monthly))
        (date (encode-time 0 0 12 25 11 2024)))
    (should (stringp (vulpea-journal--entry-title-for-date date)))
    ;; Should contain the day number
    (should (string-match-p "25" (vulpea-journal--entry-title-for-date date)))))

;;; Monthly File Path Tests

(ert-deftest vulpea-journal-monthly-file-path ()
  "Test file path for monthly template."
  (let ((vulpea-default-notes-directory "/test/notes/")
        (vulpea-journal-default-template (vulpea-journal-template-monthly))
        (date (encode-time 0 0 12 25 11 2024)))
    ;; Monthly file should not include day in filename
    (let ((file (vulpea-journal--file-for-date date)))
      (should (string-match-p "2024" file))
      (should (string-match-p "11" file))
      ;; Should NOT match "25" as a standalone component in filename
      ;; (the month file covers the whole month)
      (should-not (string-match-p "2024-11-25" (file-name-nondirectory file))))))

;;; Monthly Integration Tests

(ert-deftest vulpea-journal-monthly-create-note ()
  "Test creating a monthly journal note creates container and heading."
  (vulpea-test--with-temp-db
    (let* ((vulpea-journal-default-template (vulpea-journal-template-monthly))
           (date (encode-time 0 0 12 25 11 2024)))
      (let ((note (vulpea-journal-note date)))
        (should note)
        (should (vulpea-note-id note))
        ;; Heading entry should be at entry-level (1)
        (should (= (vulpea-note-level note) 1))
        ;; Should have journal tag
        (should (vulpea-journal-note-p note))))))

(ert-deftest vulpea-journal-monthly-find-note ()
  "Test finding a monthly journal note by date."
  (vulpea-test--with-temp-db
    (let* ((vulpea-journal-default-template (vulpea-journal-template-monthly))
           (date (encode-time 0 0 12 25 11 2024)))
      ;; Create the note
      (let ((note (vulpea-journal-note date)))
        (should note)
        ;; Find the same note
        (let ((found (vulpea-journal-find-note date)))
          (should found)
          (should (string= (vulpea-note-id found)
                           (vulpea-note-id note))))))))

(ert-deftest vulpea-journal-monthly-multiple-entries ()
  "Test multiple daily entries in same monthly file."
  (vulpea-test--with-temp-db
    (let* ((vulpea-journal-default-template (vulpea-journal-template-monthly))
           (date1 (encode-time 0 0 12 20 11 2024))
           (date2 (encode-time 0 0 12 25 11 2024))
           (date3 (encode-time 0 0 12 30 11 2024)))
      ;; Create entries for three different days
      (let ((note1 (vulpea-journal-note date1))
            (note2 (vulpea-journal-note date2))
            (note3 (vulpea-journal-note date3)))
        ;; All should exist
        (should note1)
        (should note2)
        (should note3)
        ;; All different IDs
        (should-not (string= (vulpea-note-id note1) (vulpea-note-id note2)))
        (should-not (string= (vulpea-note-id note2) (vulpea-note-id note3)))
        ;; All in the same file
        (should (string= (vulpea-note-path note1) (vulpea-note-path note2)))
        (should (string= (vulpea-note-path note2) (vulpea-note-path note3)))
        ;; All at level 1
        (should (= (vulpea-note-level note1) 1))
        (should (= (vulpea-note-level note2) 1))
        (should (= (vulpea-note-level note3) 1))
        ;; Each can be found independently
        (should (string= (vulpea-note-id (vulpea-journal-find-note date1))
                         (vulpea-note-id note1)))
        (should (string= (vulpea-note-id (vulpea-journal-find-note date2))
                         (vulpea-note-id note2)))
        (should (string= (vulpea-note-id (vulpea-journal-find-note date3))
                         (vulpea-note-id note3)))))))

(ert-deftest vulpea-journal-monthly-all-dates ()
  "Test all-dates includes entries from monthly templates."
  (vulpea-test--with-temp-db
    (let* ((vulpea-journal-default-template (vulpea-journal-template-monthly))
           (date1 (encode-time 0 0 12 20 11 2024))
           (date2 (encode-time 0 0 12 25 11 2024)))
      ;; Create two entries
      (vulpea-journal-note date1)
      (vulpea-journal-note date2)
      ;; all-dates should return both dates
      (let ((dates (vulpea-journal-all-dates)))
        (should (= (length dates) 2))
        ;; Dates should be sorted
        (should (time-less-p (nth 0 dates) (nth 1 dates)))))))

(ert-deftest vulpea-journal-monthly-note-date-extraction ()
  "Test date extraction from monthly heading note."
  (vulpea-test--with-temp-db
    (let* ((vulpea-journal-default-template (vulpea-journal-template-monthly))
           (date (encode-time 0 0 12 25 11 2024)))
      (let* ((note (vulpea-journal-note date))
             (extracted (vulpea-journal-note-date note)))
        (should extracted)
        (let ((decoded (decode-time extracted)))
          (should (= (decoded-time-year decoded) 2024))
          (should (= (decoded-time-month decoded) 11))
          (should (= (decoded-time-day decoded) 25)))))))

(ert-deftest vulpea-journal-monthly-after-db-rebuild ()
  "Test monthly entries survive database rebuild."
  (vulpea-test--with-temp-db
    (let* ((vulpea-journal-default-template (vulpea-journal-template-monthly))
           (date (encode-time 0 0 12 25 11 2024)))
      (let ((note (vulpea-journal-note date)))
        (should note)
        ;; Clear database and rebuild
        (vulpea-db-clear)
        (vulpea-db-sync-full-scan)
        ;; Should still find the note
        (let ((found (vulpea-journal-find-note date)))
          (should found)
          (should (string= (vulpea-note-id found)
                           (vulpea-note-id note))))))))

(ert-deftest vulpea-journal-monthly-different-months ()
  "Test entries in different months create different files."
  (vulpea-test--with-temp-db
    (let* ((vulpea-journal-default-template (vulpea-journal-template-monthly))
           (nov-date (encode-time 0 0 12 25 11 2024))
           (dec-date (encode-time 0 0 12 15 12 2024)))
      (let ((nov-note (vulpea-journal-note nov-date))
            (dec-note (vulpea-journal-note dec-date)))
        (should nov-note)
        (should dec-note)
        ;; Should be in different files
        (should-not (string= (vulpea-note-path nov-note)
                             (vulpea-note-path dec-note)))))))

;;; Daily Backward Compatibility

(ert-deftest vulpea-journal-daily-still-works-with-builder ()
  "Test daily template builder creates notes same as before."
  (vulpea-test--with-temp-db
    (let* ((vulpea-journal-default-template (vulpea-journal-template-daily))
           (date (encode-time 0 0 12 25 11 2024)))
      (let ((note (vulpea-journal-note date)))
        (should note)
        (should (vulpea-note-id note))
        ;; Daily entries are file-level (level 0)
        (should (= (vulpea-note-level note) 0))
        (should (vulpea-journal-note-p note))
        ;; Should find same note
        (let ((found (vulpea-journal-find-note date)))
          (should found)
          (should (string= (vulpea-note-id found)
                           (vulpea-note-id note))))))))

(provide 'vulpea-journal-test)
;;; vulpea-journal-test.el ends here
