;;; vulpea-journal-test.el --- Tests for vulpea-journal -*- lexical-binding: t; -*-
;;
;; Copyright (c) 2024-2025 Boris Buliga <boris@d12frosted.io>
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

;; Declare variables for dynamic binding in lexical-binding mode
(defvar vulpea-directory)
(defvar vulpea-db-location)
(defvar vulpea-db-sync-directories)
(defvar vulpea-journal-default-template)

;;; Test Infrastructure

(defmacro vulpea-test--with-temp-db (&rest body)
  "Execute BODY with temporary database."
  (declare (indent 0))
  `(let* ((temp-file (make-temp-file "vulpea-test-" nil ".db"))
          (temp-dir (make-temp-file "vulpea-test-notes-" t))
          (vulpea-db-location temp-file)
          (vulpea-directory temp-dir)
          (vulpea-db-sync-directories (list temp-dir)))
     (unwind-protect
         (progn
           (vulpea-db)  ;; Initialize database
           ,@body)
       (when (file-exists-p temp-file)
         (delete-file temp-file))
       (when (file-directory-p temp-dir)
         (delete-directory temp-dir t)))))

;;; Journal File Path Tests

(ert-deftest vulpea-journal-file-path-relative ()
  "Test file path generation with relative directory."
  (let ((vulpea-directory "/test/notes/")
        (vulpea-journal-default-template '(:file-name "journal/%Y%m%d.org"
                                           :title "%Y-%m-%d %A"
                                           :tags ("journal")))
        (date (encode-time 0 0 12 25 11 2024)))
    (should (string= (vulpea-journal--file-for-date date)
                     "/test/notes/journal/20241125.org"))))

(ert-deftest vulpea-journal-file-path-nested ()
  "Test file path with nested directory structure."
  (let ((vulpea-directory "/notes/")
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

(provide 'vulpea-journal-test)
;;; vulpea-journal-test.el ends here
