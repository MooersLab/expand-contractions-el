;;; expand-contractions-test.el --- Tests for expand-contractions -*- lexical-binding: t; coding: utf-8; -*-

;; Copyright (C) 2026 Blaine Mooers

;; Author: Blaine Mooers <blaine-mooers@ou.edu>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests.  Run them with "make test" from the package directory.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'expand-contractions)

(defconst expand-contractions-test--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Root directory of the package.")

(defmacro expand-contractions-test--with-defaults (&rest body)
  "Run BODY with default settings and the bundled CSV file."
  (declare (indent 0) (debug t))
  `(let ((expand-contractions-csv-file
          (expand-file-name "contractions.csv" expand-contractions-test--root))
         (expand-contractions-user-alist nil)
         (expand-contractions-exclude nil)
         (expand-contractions-normalize-quotes t)
         (expand-contractions-disambiguate t)
         (expand-contractions-protect-markup t)
         (expand-contractions-make-backup t)
         (expand-contractions-verbose nil))
     ,@body))

(defun expand-contractions-test--x (string &optional kind)
  "Expand STRING of KIND with default settings."
  (expand-contractions-test--with-defaults
    (expand-contractions-string string kind)))

(defmacro expand-contractions-test--with-temp-dir (var &rest body)
  "Bind VAR to a fresh temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (file-name-as-directory (make-temp-file "exp-contr-" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun expand-contractions-test--write (file text)
  "Write TEXT to FILE as UTF-8."
  (let ((coding-system-for-write 'utf-8))
    (write-region text nil file nil 'silent)))

(defun expand-contractions-test--read (file)
  "Return the contents of FILE."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (buffer-string)))

;;;; CSV data

(ert-deftest expand-contractions-test-csv-clean ()
  "The bundled CSV has no duplicates and no stray whitespace."
  (expand-contractions-test--with-defaults
    (let* ((alist (expand-contractions-read-csv expand-contractions-csv-file))
           (keys (mapcar (lambda (p) (downcase (car p))) alist)))
      (should (> (length alist) 200))
      (should (= (length keys) (length (delete-dups (copy-sequence keys)))))
      (with-temp-buffer
        (insert-file-contents expand-contractions-csv-file)
        (goto-char (point-min))
        (should-not (re-search-forward "[ \t]," nil t))
        (should-not (re-search-forward ",[ \t]" nil t))
        (should-not (re-search-forward "[ \t]$" nil t))))))

(ert-deftest expand-contractions-test-csv-corrections ()
  "Corrections from the review are present in the CSV."
  (expand-contractions-test--with-defaults
    (expand-contractions-reload)
    (should (equal (expand-contractions-lookup "won't") "will not"))
    (should (equal (expand-contractions-lookup "doesn't") "does not"))
    (should (equal (expand-contractions-lookup "y'know") "you know"))
    (should (equal (expand-contractions-lookup "oughtn't") "ought not"))
    (should (equal (expand-contractions-lookup "when'll") "when will"))
    (should (equal (expand-contractions-lookup "I'd've") "I would have"))
    (should-not (expand-contractions-lookup "gon't"))
    (should-not (expand-contractions-lookup "nall"))
    (should-not (expand-contractions-lookup "wonnot"))
    (should-not (expand-contractions-lookup "y'knonwn"))))

(ert-deftest expand-contractions-test-csv-reader ()
  "The reader skips headers and comments and handles quoting."
  (expand-contractions-test--with-temp-dir dir
    (let ((f (expand-file-name "c.csv" dir)))
      (expand-contractions-test--write
       f "contraction,expansion\n# comment\n\n  ain’t , is not \n\"y'all\",\"you all\"\n")
      (should (equal (expand-contractions-read-csv f)
                     '(("ain't" . "is not") ("y'all" . "you all")))))))

;;;; Basic expansion

(ert-deftest expand-contractions-test-basic ()
  (should (equal (expand-contractions-test--x "I can't go because it's late.")
                 "I cannot go because it is late."))
  (should (equal (expand-contractions-test--x "They're here and we've won.")
                 "They are here and we have won.")))

(ert-deftest expand-contractions-test-case ()
  (should (equal (expand-contractions-test--x "don't Don't DON'T")
                 "do not Do not DO NOT"))
  (should (equal (expand-contractions-test--x "i'm I'm I'M")
                 "I am I am I AM"))
  (should (equal (expand-contractions-test--x "'Tis 'tis")
                 "It is it is")))

(ert-deftest expand-contractions-test-curly ()
  (should (equal (expand-contractions-test--x "Don’t say “hello” and it’s fine.")
                 "Do not say \"hello\" and it is fine."))
  (let ((expand-contractions-normalize-quotes 'single))
    (should (equal (expand-contractions-string "Don’t “x”") "Do not “x”"))))

(ert-deftest expand-contractions-test-longest-match ()
  (should (equal (expand-contractions-test--x "I couldn't've known.")
                 "I could not have known."))
  (should (equal (expand-contractions-test--x "y'all're y'all")
                 "you all are you all"))
  (should (equal (expand-contractions-test--x "'Tisn't so.")
                 "It is not so.")))

(ert-deftest expand-contractions-test-boundaries ()
  "Words that merely contain a contraction are left alone."
  (should (equal (expand-contractions-test--x "cantilever o'clock-work")
                 "cantilever of the clock-work"))
  (should (equal (expand-contractions-test--x "un'til")
                 "un'til"))
  (should (equal (expand-contractions-test--x "She said 'don't'.")
                 "She said 'do not'."))
  (should (equal (expand-contractions-test--x "``don't''" 'latex)
                 "``do not''"))
  (should (equal (expand-contractions-test--x "rock 'n' roll, ol' pal")
                 "rock and roll, old pal"))
  (should (equal (expand-contractions-test--x "don't\nwon't")
                 "do not\nwill not")))

(ert-deftest expand-contractions-test-adjacent ()
  (should (equal (expand-contractions-test--x "don't don't,don't")
                 "do not do not,do not")))

;;;; Disambiguation

(ert-deftest expand-contractions-test-disambiguate-s ()
  (should (equal (expand-contractions-test--x "He's been ill. He's ill.")
                 "He has been ill. He is ill."))
  (should (equal (expand-contractions-test--x "It's got to stop.")
                 "It has got to stop."))
  (should (equal (expand-contractions-test--x "Let's go.")
                 "Let us go.")))

(ert-deftest expand-contractions-test-disambiguate-d ()
  (should (equal (expand-contractions-test--x "I'd go. I'd gone. I'd walked.")
                 "I would go. I had gone. I had walked."))
  (should (equal (expand-contractions-test--x "I'd need it. You'd better.")
                 "I would need it. You had better."))
  (should (equal (expand-contractions-test--x "We'd never seen it. We'd rather not.")
                 "We had never seen it. We would rather not."))
  (should (equal (expand-contractions-test--x "How'd you do it?")
                 "How did you do it?")))

(ert-deftest expand-contractions-test-disambiguate-off ()
  (expand-contractions-test--with-defaults
    (let ((expand-contractions-disambiguate nil))
      (should (equal (expand-contractions-string "He's been. I'd gone.")
                     "He is been. I would gone.")))))

;;;; Title case

(ert-deftest expand-contractions-test-title-case ()
  (should (equal (expand-contractions-test--x "Notes I Couldn't Finish")
                 "Notes I Could Not Finish"))
  (should (equal (expand-contractions-test--x "* What's New" 'org)
                 "* What Is New"))
  (should (equal (expand-contractions-test--x "\\section{O'Clock Tales}" 'latex)
                 "\\section{Of the Clock Tales}"))
  (should (equal (expand-contractions-test--x "It's Monday. Bob said I'd Go.")
                 "It is Monday. Bob said I would Go."))
  (should (equal (expand-contractions-test--x "* What's new" 'org)
                 "* What is new"))
  (let ((expand-contractions-title-case nil))
    (should (equal (expand-contractions-test--x "Things We'll Fix")
                   "Things We will Fix"))))

;;;; User settings

(ert-deftest expand-contractions-test-exclude-and-user ()
  (expand-contractions-test--with-defaults
    (let ((expand-contractions-exclude '("ma'am"))
          (expand-contractions-user-alist '(("gov't" . "government")
                                            ("can't" . "can not"))))
      (should (equal (expand-contractions-string "Ma'am, the gov't can't.")
                     "Ma'am, the government can not.")))))

;;;; Protected markup

(ert-deftest expand-contractions-test-org ()
  (let ((in "* Don't panic\n#+begin_src python\nprint(\"don't\")\n#+end_src\nIt's =don't= and ~can't~.\n# don't touch\n: don't\n[[file:don't.org][Don't]]\n#+TITLE: We'll see\n")
        (out "* Do not panic\n#+begin_src python\nprint(\"don't\")\n#+end_src\nIt is =don't= and ~can't~.\n# don't touch\n: don't\n[[file:don't.org][Do not]]\n#+TITLE: We will see\n"))
    (should (equal (expand-contractions-test--x in 'org) out))))

(ert-deftest expand-contractions-test-markdown ()
  (let ((in "---\ntitle: \"Don't\"\n---\n\nIt's `don't` here.\n\n```r\nx <- \"can't\"\n```\n\n<!-- won't -->\n[Can't](http://x.org/can't)\n")
        (out "---\ntitle: \"Do not\"\n---\n\nIt is `don't` here.\n\n```r\nx <- \"can't\"\n```\n\n<!-- won't -->\n[Cannot](http://x.org/can't)\n"))
    (should (equal (expand-contractions-test--x in 'markdown) out))))

(ert-deftest expand-contractions-test-latex ()
  (let ((in "It's 50\\% done. % don't change\n\\verb|can't| and \\url{http://x/don't}\n\\begin{verbatim}\nwon't\n\\end{verbatim}\nWe'll see.\n")
        (out "It is 50\\% done. % don't change\n\\verb|can't| and \\url{http://x/don't}\n\\begin{verbatim}\nwon't\n\\end{verbatim}\nWe will see.\n"))
    (should (equal (expand-contractions-test--x in 'latex) out))))

(ert-deftest expand-contractions-test-protection-off ()
  (expand-contractions-test--with-defaults
    (let ((expand-contractions-protect-markup nil))
      (should (equal (expand-contractions-string "`don't`" 'markdown)
                     "`do not`")))))

(ert-deftest expand-contractions-test-unclosed-block ()
  (should (equal (expand-contractions-test--x "It's\n```\ndon't\n" 'markdown)
                 "It is\n```\ndon't\n")))

;;;; Buffer commands

(ert-deftest expand-contractions-test-buffer-and-region ()
  (expand-contractions-test--with-defaults
    (with-temp-buffer
      (insert "don't won't can't")
      (should (= (expand-contractions-region 1 6) 1))
      (should (equal (buffer-string) "do not won't can't"))
      (should (= (expand-contractions-buffer) 2))
      (should (equal (buffer-string) "do not will not cannot")))))

(ert-deftest expand-contractions-test-single-undo ()
  (expand-contractions-test--with-defaults
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "don't won't")
      (undo-boundary)
      (expand-contractions-buffer)
      (undo-boundary)
      (should (equal (buffer-string) "do not will not"))
      (primitive-undo 1 (if (car buffer-undo-list)
                              buffer-undo-list
                            (cdr buffer-undo-list)))
      (should (equal (buffer-string) "don't won't")))))

(ert-deftest expand-contractions-test-major-mode-detection ()
  (expand-contractions-test--with-defaults
    (with-temp-buffer
      (org-mode)
      (insert "It's =don't=")
      (expand-contractions-buffer)
      (should (equal (buffer-string) "It is =don't=")))))

(ert-deftest expand-contractions-test-query ()
  (expand-contractions-test--with-defaults
    (with-temp-buffer
      (insert "don't won't can't isn't")
      (let ((answers (list ?y ?n ?q)))
        (cl-letf (((symbol-function 'read-char-choice)
                   (lambda (&rest _) (pop answers))))
          (should (= (expand-contractions-buffer t) 1))))
      (should (equal (buffer-string) "do not won't can't isn't"))
      (let ((answers (list ?n ?!)))
        (cl-letf (((symbol-function 'read-char-choice)
                   (lambda (&rest _) (pop answers))))
          (should (= (expand-contractions-buffer t) 2))))
      (should (equal (buffer-string) "do not won't cannot is not")))))

(ert-deftest expand-contractions-test-at-point ()
  (expand-contractions-test--with-defaults
    (with-temp-buffer
      (insert "don't won't")
      (goto-char 9)
      (expand-contractions-at-point)
      (should (equal (buffer-string) "don't will not")))))

(ert-deftest expand-contractions-test-count ()
  (expand-contractions-test--with-defaults
    (with-temp-buffer
      (insert "don't won’t can't")
      (should (= (expand-contractions-count) 3))
      (should (equal (buffer-string) "don't won’t can't")))))

(ert-deftest expand-contractions-test-normalize-quotes-command ()
  (expand-contractions-test--with-defaults
    (with-temp-buffer
      (insert "“Hi” it’s")
      (should (= (expand-contractions-normalize-quotes-buffer) 3))
      (should (equal (buffer-string) "\"Hi\" it's")))))

(ert-deftest expand-contractions-test-minor-mode ()
  (expand-contractions-test--with-temp-dir dir
    (expand-contractions-test--with-defaults
      (let ((f (expand-file-name "a.txt" dir))
            (make-backup-files nil)
            (require-final-newline nil))
        (with-current-buffer (find-file-noselect f)
          (unwind-protect
              (progn
                (expand-contractions-mode 1)
                (insert "We'll see.")
                (save-buffer)
                (should (equal (string-trim-right
                                (expand-contractions-test--read f))
                               "We will see.")))
            (set-buffer-modified-p nil)
            (kill-buffer)))))))

;;;; Files and directories

(ert-deftest expand-contractions-test-files-all-kinds ()
  (expand-contractions-test--with-temp-dir dir
    (expand-contractions-test--with-defaults
      (dolist (case '(("a.txt" "It's done." "It is done.")
                      ("b.md" "It's `don't`." "It is `don't`.")
                      ("c.qmd" "It's `don't`." "It is `don't`.")
                      ("d.org" "It's =don't=." "It is =don't=.")
                      ("e.tex" "It's % don't" "It is % don't")))
        (let ((f (expand-file-name (nth 0 case) dir)))
          (expand-contractions-test--write f (nth 1 case))
          (should (= (expand-contractions-file f) 1))
          (should (equal (expand-contractions-test--read f) (nth 2 case)))
          (should (file-exists-p (make-backup-file-name f))))))))

(ert-deftest expand-contractions-test-file-unchanged-not-written ()
  (expand-contractions-test--with-temp-dir dir
    (expand-contractions-test--with-defaults
      (let ((f (expand-file-name "a.txt" dir)))
        (expand-contractions-test--write f "Nothing here.")
        (should (= (expand-contractions-file f) 0))
        (should-not (file-exists-p (make-backup-file-name f)))))))

(ert-deftest expand-contractions-test-file-utf8-preserved ()
  (expand-contractions-test--with-temp-dir dir
    (expand-contractions-test--with-defaults
      (let ((f (expand-file-name "a.md" dir)))
        (expand-contractions-test--write f "Ångström isn’t café.")
        (expand-contractions-file f)
        (should (equal (expand-contractions-test--read f)
                       "Ångström is not café."))))))

(ert-deftest expand-contractions-test-file-unsupported ()
  (expand-contractions-test--with-temp-dir dir
    (let ((f (expand-file-name "a.py" dir)))
      (expand-contractions-test--write f "x = \"don't\"")
      (should-error (expand-contractions-file f) :type 'user-error))))

(ert-deftest expand-contractions-test-file-visited-buffer-reverted ()
  (expand-contractions-test--with-temp-dir dir
    (expand-contractions-test--with-defaults
      (let ((f (expand-file-name "a.txt" dir)))
        (expand-contractions-test--write f "can't")
        (let ((buf (find-file-noselect f)))
          (unwind-protect
              (progn
                (expand-contractions-file f)
                (should (equal (with-current-buffer buf (buffer-string))
                               "cannot"))
                (with-current-buffer buf (insert "x"))
                (should-error (expand-contractions-file f) :type 'user-error))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))))))

(ert-deftest expand-contractions-test-directory ()
  (expand-contractions-test--with-temp-dir dir
    (expand-contractions-test--with-defaults
      (make-directory (expand-file-name "sub" dir))
      (make-directory (expand-file-name ".git" dir))
      (expand-contractions-test--write (expand-file-name "a.txt" dir) "can't")
      (expand-contractions-test--write (expand-file-name "b.py" dir) "can't")
      (expand-contractions-test--write (expand-file-name "sub/c.org" dir) "won't")
      (expand-contractions-test--write (expand-file-name ".git/d.txt" dir) "won't")
      (should (= (length (expand-contractions-directory dir)) 1))
      (should (= (length (expand-contractions-directory dir t)) 1))
      (should (equal (expand-contractions-test--read
                      (expand-file-name "sub/c.org" dir))
                     "will not"))
      (should (equal (expand-contractions-test--read
                      (expand-file-name "b.py" dir))
                     "can't"))
      (should (equal (expand-contractions-test--read
                      (expand-file-name ".git/d.txt" dir))
                     "won't")))))

(ert-deftest expand-contractions-test-examples ()
  "Each file in examples/ matches its .expected counterpart."
  (expand-contractions-test--with-temp-dir dir
    (expand-contractions-test--with-defaults
      (let ((ex (expand-file-name "examples" expand-contractions-test--root)))
        (dolist (src (directory-files ex t "\\`sample\\.[a-z]+\\'"))
          (let ((tmp (expand-file-name (file-name-nondirectory src) dir)))
            (copy-file src tmp t)
            (expand-contractions-file tmp)
            (should (equal (expand-contractions-test--read tmp)
                           (expand-contractions-test--read
                            (concat src ".expected"))))))))))

(provide 'expand-contractions-test)
;;; expand-contractions-test.el ends here
