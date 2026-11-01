;;; expand-contractions.el --- Expand English contractions in buffers and files -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Blaine Mooers

;; Author: Blaine Mooers <blaine-mooers@ou.edu>
;; Maintainer: Blaine Mooers <blaine-mooers@ou.edu>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: wp, convenience
;; URL: https://github.com/MooersLab/expand-contractions.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `expand-contractions' replaces English contractions such as "don't",
;; "they'll" and "couldn't've" with their expanded forms ("do not",
;; "they will", "could not have").  It works without prompting, so a
;; whole buffer of dictated or Grammarly-edited prose can be cleaned up
;; with one command.
;;
;; Features:
;;
;; - Case is preserved: don't -> do not, Don't -> Do not, DON'T -> DO NOT.
;; - Curly quotes are converted to straight quotes first (configurable).
;; - Ambiguous forms are resolved from the next word: "he's been" ->
;;   "he has been", "I'd gone" -> "I had gone", "I'd go" -> "I would go".
;; - Code and markup are protected in LaTeX, Markdown, Quarto and Org
;;   files (source blocks, inline code, comments, URLs, citation keys).
;; - Works on the region, the buffer, a file on disk that is not
;;   visited, every supported file in a directory, or marked files in
;;   Dired.  A batch entry point supports use from the shell.
;; - The contraction table is a plain CSV file that users can edit or
;;   replace, plus a Customize variable for personal additions.
;;
;; Quick start:
;;
;;   (require 'expand-contractions)
;;   (global-set-key (kbd "C-c e") expand-contractions-command-map)
;;
;; Then press C-c e b to expand all contractions in the current buffer.
;; See README.org for a full tutorial.

;;; Code:

(require 'subr-x)
(require 'seq)

(declare-function dired-get-marked-files "dired")

;;;; Customization

(defgroup expand-contractions nil
  "Expand English contractions in buffers and files."
  :group 'wp
  :prefix "expand-contractions-"
  :link '(url-link "https://github.com/MooersLab/expand-contractions.el"))

(defconst expand-contractions--directory
  (file-name-directory
   (or load-file-name
       (bound-and-true-p byte-compile-current-file)
       buffer-file-name
       default-directory))
  "Directory that holds this package and its CSV data file.")

(defcustom expand-contractions-csv-file
  (expand-file-name "contractions.csv" expand-contractions--directory)
  "CSV file with one contraction and its expansion per line.
The first column is the contraction and the second column is the
expansion.  Blank lines, lines that start with # and a header line
whose first field is \"contraction\" are ignored."
  :type 'file)

(defcustom expand-contractions-user-alist nil
  "Personal contractions as an alist of (CONTRACTION . EXPANSION).
Entries here are added to the CSV table and override CSV entries
with the same contraction."
  :type '(alist :key-type (string :tag "Contraction")
                :value-type (string :tag "Expansion")))

(defcustom expand-contractions-exclude nil
  "Contractions that are never expanded, compared case-insensitively."
  :type '(repeat string))

(defcustom expand-contractions-normalize-quotes t
  "Which curly quotes to replace with straight quotes before expanding.
When t, replace curly single and double quotes.  When `single',
replace only curly single quotes and apostrophes.  When nil, leave
quotes alone.  Contractions written with a curly apostrophe are only
found when single quotes are normalized."
  :type '(choice (const :tag "Single and double quotes" t)
                 (const :tag "Single quotes and apostrophes only" single)
                 (const :tag "Do not change quotes" nil)))

(defcustom expand-contractions-disambiguate t
  "When non-nil, choose between ambiguous expansions from context.
A contraction ending in \\='s that expands to \"is\" becomes \"has\"
when the next word is in `expand-contractions-has-triggers'.  A
contraction ending in \\='d becomes \"had\" when the next word looks
like a past participle and \"would\" otherwise."
  :type 'boolean)

(defcustom expand-contractions-has-triggers
  '("been" "got" "gotten" "had")
  "Words after a \\='s contraction that select \"has\" instead of \"is\"."
  :type '(repeat string))

(defcustom expand-contractions-had-triggers
  '("been" "better" "become" "begun" "beaten" "bitten" "bought" "broken"
    "brought" "built" "caught" "chosen" "done" "drawn" "driven" "drunk"
    "eaten" "fallen" "felt" "flown" "forgiven" "forgotten" "fought"
    "found" "frozen" "given" "gone" "got" "gotten" "grown" "had" "heard"
    "held" "hidden" "kept" "known" "left" "lost" "made" "meant" "met"
    "ridden" "risen" "said" "seen" "sent" "shown" "slept" "sold" "spent"
    "spoken" "stolen" "stood" "sung" "swum" "sworn" "taken" "taught"
    "thought" "thrown" "told" "torn" "understood" "woken" "worn"
    "written")
  "Words after a \\='d contraction that select \"had\" instead of \"would\".
Regular past participles ending in -ed also select \"had\" unless they
are listed in `expand-contractions-ed-base-verbs'."
  :type '(repeat string))

(defcustom expand-contractions-ed-base-verbs
  '("bleed" "breed" "embed" "exceed" "feed" "heed" "need" "proceed"
    "seed" "shed" "shred" "speed" "succeed" "wed")
  "Base verbs that end in -ed and therefore do not signal \"had\"."
  :type '(repeat string))

(defcustom expand-contractions-skippable-words
  '("all" "already" "also" "always" "certainly" "definitely" "ever"
    "just" "nearly" "never" "not" "now" "only" "probably" "really"
    "recently" "still" "surely" "then")
  "Adverbs skipped when looking for the word that resolves ambiguity.
For example, in \"I'd never seen\" the word \"never\" is skipped and
\"seen\" selects \"had\"."
  :type '(repeat string))

(defcustom expand-contractions-title-case t
  "When non-nil, capitalize every word of an expansion in title case.
A capitalized contraction is treated as part of a title when the next
word is capitalized and either the previous word on the line is
capitalized or the line is a heading.  Then \"Things We'll Fix\"
becomes \"Things We Will Fix\" rather than \"Things We will Fix\".
Contractions that begin with \"I'\" never trigger title case."
  :type 'boolean)

(defcustom expand-contractions-title-small-words
  '("a" "an" "and" "as" "at" "but" "by" "for" "in" "nor" "of" "on" "or"
    "the" "to")
  "Words left in lowercase inside a title-case expansion."
  :type '(repeat string))

(defcustom expand-contractions-protect-markup t
  "When non-nil, do not change text in code, comments and markup.
The protected constructs for each kind of file are listed in
`expand-contractions-protected-patterns'."
  :type 'boolean)

(defcustom expand-contractions-protected-patterns
  '((org
     (block "^[ \t]*#\\+begin_\\(src\\|example\\|export\\|comment\\)\\>"
            "^[ \t]*#\\+end_%s\\>")
     (regexp "^[ \t]*#\\+\\(?:latex\\|html\\|attr_[[:alnum:]_]+\\|options\\|property\\|startup\\|setupfile\\|include\\|bibliography\\|cite_export\\|latex_[[:alnum:]_]+\\|html_[[:alnum:]_]+\\)\\(?:\\[[^]\n]*\\]\\)?:.*$")
     (regexp "^[ \t]*#\\(?:[ \t].*\\)?$")
     (regexp "^[ \t]*:\\(?:[ \t].*\\)?$")
     (regexp "^[ \t]*:[[:alnum:]_-]+:.*$")
     (regexp "\\(?:^\\|[[:space:](\"'{]\\)\\(\\([=~]\\)[^[:space:]]\\(?:[^\n]*?[^[:space:]]\\)?\\2\\)" 1)
     (regexp "src_[[:alnum:]-]+\\(?:\\[[^]\n]*\\]\\)?{[^}\n]*}")
     (regexp "\\[\\[\\([^]\n]*\\)\\]" 1))
    (markdown
     (block "^[ \t]*\\(`\\{3,\\}\\|~\\{3,\\}\\)" "^[ \t]*%s")
     (block "<!--" "-->")
     (regexp "``[^\n]+?``")
     (regexp "`[^`\n]+`")
     (regexp "\\](\\([^)\n]*\\))" 1)
     (regexp "<https?://[^>\n]*>"))
    (latex
     (block "\\\\begin{\\(verbatim\\*?\\|Verbatim\\*?\\|lstlisting\\|minted\\|comment\\|alltt\\|filecontents\\*?\\)}"
            "\\\\end{%s}")
     (regexp "\\(?:^\\|[^\\\\]\\)\\(%.*\\)$" 1)
     (regexp "\\\\verb\\*?\\([^[:alpha:]*[:space:]]\\).*?\\1")
     (regexp "\\\\\\(?:lstinline\\|mintinline{[^}\n]*}\\)\\(?:{[^}\n]*}\\|\\([^[:alpha:]{]\\).*?\\1\\)")
     (regexp "\\\\\\(?:url\\|href\\|cite[[:alpha:]]*\\*?\\|[[:alpha:]]*ref\\*?\\|label\\|input\\|include\\|includegraphics\\|bibliography\\|usepackage\\)\\(?:\\[[^]\n]*\\]\\)*{[^}\n]*}"))
    (text))
  "Constructs that are left untouched, grouped by kind of file.
Each element is (KIND RULE...).  KIND is one of the symbols used in
`expand-contractions-file-kinds'.  Each RULE is one of:

  (regexp REGEXP [SUBEXP])  protect the text matched by SUBEXP of
                            REGEXP (default 0, the whole match).
  (block BEGIN END)         protect from a match of BEGIN to the next
                            match of END.  When BEGIN has a first
                            group, a %s in END is replaced by the
                            quoted text of that group.

Searches are case-insensitive."
  :type '(alist :key-type symbol :value-type (repeat sexp)))

(defcustom expand-contractions-file-kinds
  '(("tex" . latex) ("ltx" . latex) ("sty" . latex) ("cls" . latex)
    ("md" . markdown) ("markdown" . markdown) ("qmd" . markdown)
    ("rmd" . markdown)
    ("org" . org)
    ("txt" . text) ("text" . text))
  "Alist mapping file extensions (lowercase) to kinds of file.
Only files with an extension listed here are processed by
`expand-contractions-file' and `expand-contractions-directory'."
  :type '(alist :key-type (string :tag "Extension")
                :value-type (choice (const latex) (const markdown)
                                    (const org) (const text))))

(defcustom expand-contractions-make-backup t
  "When non-nil, back up a file on disk before changing it.
The backup name follows `make-backup-file-name', so it respects
`backup-directory-alist'."
  :type 'boolean)

(defcustom expand-contractions-verbose t
  "When non-nil, report how many contractions were expanded."
  :type 'boolean)

(defvar-local expand-contractions-buffer-kind nil
  "Kind of text in this buffer, overriding detection when non-nil.
One of the symbols `latex', `markdown', `org' or `text'.  Set it as
a file-local variable when the major mode does not reveal the kind.")
(put 'expand-contractions-buffer-kind 'safe-local-variable #'symbolp)

;;;; Contraction table

(defvar expand-contractions--table nil
  "Hash table mapping lowercase contractions to expansions.")

(defvar expand-contractions--regexp nil
  "Regexp that matches any contraction.  Group 1 is the contraction.")

(defvar expand-contractions--signature nil
  "Inputs used to build the current table, to detect changes.")

(defun expand-contractions--unquote (field)
  "Trim FIELD and remove CSV double quotes around it."
  (let ((s (string-trim field)))
    (if (and (>= (length s) 2)
             (eq (aref s 0) ?\")
             (eq (aref s (1- (length s))) ?\"))
        (replace-regexp-in-string "\"\"" "\"" (substring s 1 -1) t t)
      s)))

(defun expand-contractions--straighten (string)
  "Return STRING with curly single quotes replaced by apostrophes."
  (replace-regexp-in-string "[‘’‛ʼ]" "'" string t t))

(defun expand-contractions-read-csv (file)
  "Read FILE and return an alist of (CONTRACTION . EXPANSION).
Only the first comma on each line separates the two fields."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (result)
      (while (not (eobp))
        (let ((line (string-trim
                     (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position)))))
          (when (and (not (string-empty-p line))
                     (not (string-prefix-p "#" line))
                     (string-match "\\`\\([^,]+\\),\\(.+\\)\\'" line))
            (let ((key (expand-contractions--straighten
                        (expand-contractions--unquote (match-string 1 line))))
                  (val (expand-contractions--unquote (match-string 2 line))))
              (unless (or (string-empty-p key) (string-empty-p val)
                          (string= (downcase key) "contraction"))
                (push (cons key val) result)))))
        (forward-line 1))
      (nreverse result))))

(defun expand-contractions--build ()
  "Build the hash table and regexp from the CSV file and user settings."
  (let ((table (make-hash-table :test #'equal))
        (exclude (mapcar (lambda (s)
                           (downcase (expand-contractions--straighten s)))
                         expand-contractions-exclude)))
    (unless (file-readable-p expand-contractions-csv-file)
      (user-error "Cannot read contractions file %s"
                  expand-contractions-csv-file))
    (dolist (pair (append (expand-contractions-read-csv
                           expand-contractions-csv-file)
                          expand-contractions-user-alist))
      (let ((key (downcase (expand-contractions--straighten (car pair)))))
        (unless (member key exclude)
          (puthash key (cdr pair) table))))
    (let (keys)
      (maphash (lambda (k _v) (push k keys)) table)
      (setq expand-contractions--table table
            expand-contractions--regexp
            (and keys
                 (concat "\\(?:^\\|[^[:alnum:]_]\\)\\("
                         (regexp-opt keys)
                         "\\)\\(?:\\'\\|[^[:alnum:]_']\\|'\\(?:\\'\\|[^[:alnum:]_]\\)\\)"))))))

(defun expand-contractions--ensure-table ()
  "Build the contraction table if it is missing or out of date."
  (let ((sig (list expand-contractions-csv-file
                   (file-attribute-modification-time
                    (file-attributes expand-contractions-csv-file))
                   expand-contractions-user-alist
                   expand-contractions-exclude)))
    (unless (and expand-contractions--table
                 (equal sig expand-contractions--signature))
      (expand-contractions--build)
      (setq expand-contractions--signature sig))))

;;;###autoload
(defun expand-contractions-reload ()
  "Reload the contraction table from `expand-contractions-csv-file'."
  (interactive)
  (setq expand-contractions--signature nil)
  (expand-contractions--ensure-table)
  (when (called-interactively-p 'interactive)
    (message "Loaded %d contractions"
             (hash-table-count expand-contractions--table))))

(defun expand-contractions-lookup (contraction)
  "Return the expansion of CONTRACTION, or nil when it is unknown.
The lookup ignores case and curly apostrophes.  Context-based
disambiguation is not applied."
  (expand-contractions--ensure-table)
  (gethash (downcase (expand-contractions--straighten contraction))
           expand-contractions--table))

(defun expand-contractions-alist ()
  "Return the active contraction table as a sorted alist."
  (expand-contractions--ensure-table)
  (let (out)
    (maphash (lambda (k v) (push (cons k v) out)) expand-contractions--table)
    (sort out (lambda (a b) (string< (car a) (car b))))))

;;;; Kinds of file

(defun expand-contractions--file-kind (file)
  "Return the kind of FILE from its extension, or nil if unsupported."
  (let ((ext (file-name-extension file)))
    (and ext (cdr (assoc (downcase ext) expand-contractions-file-kinds)))))

(defun expand-contractions--buffer-kind ()
  "Return the kind of text in the current buffer."
  (or expand-contractions-buffer-kind
      (cond ((derived-mode-p 'org-mode) 'org)
            ((derived-mode-p 'markdown-mode 'gfm-mode 'quarto-mode
                             'poly-markdown-mode 'poly-quarto-mode)
             'markdown)
            ((derived-mode-p 'tex-mode 'latex-mode 'LaTeX-mode 'TeX-mode
                             'TeX-latex-mode 'plain-tex-mode)
             'latex))
      (and buffer-file-name (expand-contractions--file-kind buffer-file-name))
      'text))

;;;; Protected regions

(defun expand-contractions--protected-ranges (kind)
  "Return sorted (START . END) marker pairs of protected text for KIND.
Positions refer to the accessible part of the current buffer."
  (let ((case-fold-search t)
        ranges)
    (when expand-contractions-protect-markup
      (save-excursion
        (dolist (rule (cdr (assq kind expand-contractions-protected-patterns)))
          (goto-char (point-min))
          (pcase rule
            (`(regexp ,re . ,rest)
             (let ((sub (or (car rest) 0)))
               (while (and (not (eobp)) (re-search-forward re nil t))
                 (when (match-beginning sub)
                   (push (cons (match-beginning sub) (match-end sub)) ranges))
                 (when (= (match-beginning 0) (match-end 0))
                   (forward-char 1)))))
            (`(block ,begin ,end)
             (while (re-search-forward begin nil t)
               (let ((start (match-beginning 0))
                     (end-re (if (and (match-beginning 1)
                                      (string-match-p "%s" end))
                                 (format end (regexp-quote (match-string 1)))
                               end)))
                 (if (re-search-forward end-re nil t)
                     (push (cons start (point)) ranges)
                   (push (cons start (point-max)) ranges)
                   (goto-char (point-max))))))))))
    (setq ranges (sort ranges (lambda (a b) (< (car a) (car b)))))
    ;; Merge overlapping ranges, then convert to markers.
    (let (merged)
      (dolist (r ranges)
        (if (and merged (<= (car r) (cdar merged)))
            (setcdr (car merged) (max (cdr r) (cdar merged)))
          (push (cons (car r) (cdr r)) merged)))
      (mapcar (lambda (r) (cons (copy-marker (car r)) (copy-marker (cdr r))))
              (nreverse merged)))))

(defun expand-contractions--release (ranges)
  "Detach the markers in RANGES."
  (dolist (r ranges)
    (set-marker (car r) nil)
    (set-marker (cdr r) nil)))

;;;; Quote normalization

(defun expand-contractions--normalize-quotes (ranges)
  "Replace curly quotes outside RANGES in the accessible buffer.
Which quotes are replaced depends on
`expand-contractions-normalize-quotes'.  Return the number replaced."
  (let ((count 0)
        (pairs (pcase expand-contractions-normalize-quotes
                 ('nil nil)
                 ('single '(("[‘’‛ʼ]" . "'")))
                 (_ '(("[‘’‛ʼ]" . "'") ("[“”„‟]" . "\""))))))
    (save-excursion
      (dolist (pair pairs)
        (goto-char (point-min))
        (let ((rest ranges))
          (while (re-search-forward (car pair) nil t)
            (let ((pos (match-beginning 0)))
              (while (and rest (<= (cdar rest) pos))
                (setq rest (cdr rest)))
              (unless (and rest (<= (caar rest) pos))
                (replace-match (cdr pair) t t)
                (setq count (1+ count))))))))
    count))

;;;; Case and disambiguation

(defconst expand-contractions--heading-regexp
  (concat "^[ \t]*\\(?:\\*+[ \t]\\|#+[ \t]\\|#\\+\\(?:sub\\)?title:"
          "\\|.*\\\\\\(?:part\\|chapter\\|\\(?:sub\\)*section\\|paragraph"
          "\\|title\\|caption\\)\\*?\\(?:\\[[^]\n]*\\]\\)?{\\)")
  "Regexp that matches the start of a heading or title line.")

(defun expand-contractions--title-context-p (original beg end)
  "Return non-nil when ORIGINAL between BEG and END is in a title."
  (and expand-contractions-title-case
       (not (string-prefix-p "i'" (downcase original)))
       (save-excursion
         (save-match-data
           (let ((case-fold-search nil))
             (goto-char end)
             (and (looking-at "[ \t]+[[:upper:]]")
                  (progn
                    (goto-char beg)
                    (or (looking-back
                         "\\(?:^\\|[^[:alpha:]'-]\\)[[:upper:]][[:alpha:]'-]*[ \t]+"
                         (line-beginning-position))
                        (progn
                          (goto-char (line-beginning-position))
                          (let ((case-fold-search t))
                            (looking-at expand-contractions--heading-regexp)))))))))))

(defun expand-contractions--title-case (expansion)
  "Return EXPANSION with each word capitalized, except small words."
  (let ((first t))
    (mapconcat
     (lambda (word)
       (prog1 (if (and (not first)
                       (member (downcase word)
                               expand-contractions-title-small-words))
                  word
                (concat (upcase (substring word 0 1)) (substring word 1)))
         (setq first nil)))
     (split-string expansion " +" t)
     " ")))

(defun expand-contractions--apply-case (original expansion &optional title)
  "Return EXPANSION with the capitalization pattern of ORIGINAL.
When TITLE is non-nil and ORIGINAL is capitalized, use title case."
  (let ((letters (replace-regexp-in-string "[^[:alpha:]]" "" original)))
    (cond
     ((string-empty-p letters) expansion)
     ((and (> (length letters) 1)
           (string= letters (upcase letters))
           (not (string= letters (downcase letters))))
      (upcase expansion))
     ((and title (let ((c (aref letters 0))) (/= c (downcase c))))
      (expand-contractions--title-case expansion))
     ((let ((c (aref letters 0))) (/= c (downcase c)))
      (concat (upcase (substring expansion 0 1)) (substring expansion 1)))
     (t expansion))))

(defun expand-contractions--next-word (pos)
  "Return the first non-skippable word after POS in lowercase, or nil."
  (save-excursion
    (save-match-data
      (goto-char pos)
      (let ((tries 0) word)
        (while (and (< tries 3)
                    (looking-at "[ \t\n]+\\([[:alpha:]]+\\)"))
          (setq word (downcase (match-string-no-properties 1))
                tries (1+ tries))
          (goto-char (match-end 0))
          (unless (member word expand-contractions-skippable-words)
            (setq tries 99)))
        (and (= tries 99) word)))))

(defun expand-contractions--had-word-p (word)
  "Return non-nil if \"had\" is the right reading of \\='d before WORD."
  (or (member word expand-contractions-had-triggers)
      (and (> (length word) 3)
           (string-suffix-p "ed" word)
           (not (member word expand-contractions-ed-base-verbs)))))

(defun expand-contractions--disambiguate (contraction expansion pos)
  "Return the best expansion of CONTRACTION given the text after POS.
EXPANSION is the table entry."
  (if (not expand-contractions-disambiguate)
      expansion
    (let ((key (downcase contraction))
          (case-fold-search nil))
      (cond
       ((and (string-suffix-p "'s" key)
             (string-match "\\`\\(.+\\) is\\'" expansion))
        (let ((word (expand-contractions--next-word pos)))
          (if (and word (member word expand-contractions-has-triggers))
              (concat (match-string 1 expansion) " has")
            expansion)))
       ((and (string-suffix-p "'d" key)
             (string-match "\\`\\(.+\\) \\(?:would\\|had\\)\\'" expansion))
        (let ((base (match-string 1 expansion))
              (word (expand-contractions--next-word pos)))
          (if (and word (expand-contractions--had-word-p word))
              (concat base " had")
            expansion)))
       (t expansion)))))

;;;; Core engine

(defun expand-contractions--expand (kind &optional query)
  "Expand contractions in the accessible part of the buffer.
KIND selects the protected constructs.  When QUERY is non-nil, ask
before each replacement.  Return the number of replacements."
  (expand-contractions--ensure-table)
  (let ((count 0)
        (case-fold-search t)
        (ranges (expand-contractions--protected-ranges kind)))
    (unwind-protect
        (save-excursion
          (expand-contractions--normalize-quotes ranges)
          (when expand-contractions--regexp
            (goto-char (point-min))
            (let ((rest ranges))
              (catch 'quit
                (while (re-search-forward expand-contractions--regexp nil t)
                  (let ((mb (match-beginning 1))
                        (me (match-end 1)))
                    (while (and rest (<= (cdar rest) mb))
                      (setq rest (cdr rest)))
                    (if (and rest (<= (caar rest) mb))
                        (goto-char (max me (cdar rest)))
                      (let* ((orig (match-string-no-properties 1))
                             (entry (gethash (downcase orig)
                                             expand-contractions--table))
                             (new (expand-contractions--apply-case
                                   orig
                                   (expand-contractions--disambiguate
                                    orig entry me)
                                   (expand-contractions--title-context-p
                                    orig mb me)))
                             (answer (if query
                                         (expand-contractions--ask mb me orig new)
                                       ?y)))
                        (pcase answer
                          (?q (goto-char me) (throw 'quit nil))
                          (?! (setq query nil)))
                        (if (memq answer '(?y ?!))
                            (progn
                              (goto-char mb)
                              (delete-region mb me)
                              (insert new)
                              (setq count (1+ count)))
                          (goto-char me))))))))))
      (expand-contractions--release ranges))
    count))

(defun expand-contractions--ask (beg end original expansion)
  "Ask whether to replace ORIGINAL between BEG and END with EXPANSION.
Return one of the characters y, n, ! or q."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'face 'query-replace)
    (unwind-protect
        (save-match-data
          (goto-char end)
          (read-char-choice
           (format "Expand \"%s\" to \"%s\"? (y, n, ! for all, q to quit) "
                   original expansion)
           '(?y ?n ?! ?q)))
      (delete-overlay ov))))

(defmacro expand-contractions--with-undo-group (&rest body)
  "Run BODY and amalgamate its edits into a single undo step."
  (declare (indent 0) (debug t))
  (let ((handle (make-symbol "handle")))
    `(if (eq buffer-undo-list t)
         (progn ,@body)
       (let ((,handle (prepare-change-group)))
         (unwind-protect
             (progn (activate-change-group ,handle) ,@body)
           (undo-amalgamate-change-group ,handle)
           (accept-change-group ,handle))))))

(defun expand-contractions--report (count &optional where)
  "Report COUNT replacements, optionally naming WHERE."
  (when expand-contractions-verbose
    (message "Expanded %d contraction%s%s" count (if (= count 1) "" "s")
             (if where (format " in %s" where) ""))))

;;;; Public API

(defun expand-contractions-string (string &optional kind)
  "Return STRING with its contractions expanded.
KIND is the kind of text (`latex', `markdown', `org' or `text') and
defaults to `text'."
  (with-temp-buffer
    (insert string)
    (expand-contractions--expand (or kind 'text))
    (buffer-string)))

;;;###autoload
(defun expand-contractions-region (beg end &optional query)
  "Expand all contractions between BEG and END.
With QUERY non-nil (interactively, a prefix argument), ask before
each replacement.  Return the number of replacements."
  (interactive "r\nP")
  (barf-if-buffer-read-only)
  (let ((kind (expand-contractions--buffer-kind))
        count)
    (expand-contractions--with-undo-group
      (save-restriction
        (narrow-to-region beg end)
        (setq count (expand-contractions--expand kind query))))
    (expand-contractions--report count)
    count))

;;;###autoload
(defun expand-contractions-buffer (&optional query)
  "Expand all contractions in the accessible part of the current buffer.
With QUERY non-nil (interactively, a prefix argument), ask before
each replacement.  Return the number of replacements."
  (interactive "P")
  (expand-contractions-region (point-min) (point-max) query))

;;;###autoload
(defun expand-contractions-dwim (&optional query)
  "Expand contractions in the active region, or else the whole buffer.
With QUERY non-nil (interactively, a prefix argument), ask before
each replacement."
  (interactive "P")
  (if (use-region-p)
      (expand-contractions-region (region-beginning) (region-end) query)
    (expand-contractions-buffer query)))

;;;###autoload
(defun expand-contractions-query-buffer ()
  "Expand contractions in the buffer, asking before each one."
  (interactive)
  (expand-contractions-buffer t))

;;;###autoload
(defun expand-contractions-at-point ()
  "Expand the contraction at or just before point."
  (interactive)
  (barf-if-buffer-read-only)
  (expand-contractions--ensure-table)
  (let ((pt (point))
        (case-fold-search t)
        found)
    (save-excursion
      (goto-char (line-beginning-position))
      (while (and (not found)
                  (re-search-forward expand-contractions--regexp
                                     (line-end-position) t))
        (if (and (<= (match-beginning 1) pt) (<= pt (match-end 1)))
            (setq found (cons (match-beginning 1) (match-end 1)))
          (goto-char (match-end 1)))))
    (if (not found)
        (user-error "No contraction at point")
      (let ((count 0))
        (save-restriction
          (narrow-to-region (car found) (cdr found))
          (let ((expand-contractions-protect-markup nil))
            (setq count (expand-contractions--expand 'text))))
        count))))

;;;###autoload
(defun expand-contractions-count (&optional beg end)
  "Report the number of contractions in the buffer or region.
BEG and END default to the region when active, otherwise the
accessible buffer.  Nothing is changed.  Return the count."
  (interactive)
  (let* ((beg (or beg (if (use-region-p) (region-beginning) (point-min))))
         (end (or end (if (use-region-p) (region-end) (point-max))))
         (kind (expand-contractions--buffer-kind))
         (text (buffer-substring-no-properties beg end))
         (count (with-temp-buffer
                  (insert text)
                  (expand-contractions--expand kind))))
    (when (called-interactively-p 'interactive)
      (message "%d contraction%s found" count (if (= count 1) "" "s")))
    count))

;;;###autoload
(defun expand-contractions-occur ()
  "List every contraction in the buffer in an Occur buffer.
Protected markup is not excluded from this listing."
  (interactive)
  (expand-contractions--ensure-table)
  (let ((case-fold-search t)
        (search-upper-case nil))
    (occur expand-contractions--regexp 1)))

;;;###autoload
(defun expand-contractions-normalize-quotes-region (beg end)
  "Replace curly quotes with straight quotes between BEG and END.
This ignores `expand-contractions-normalize-quotes' and replaces both
single and double curly quotes outside protected markup."
  (interactive "r")
  (barf-if-buffer-read-only)
  (let ((kind (expand-contractions--buffer-kind))
        (expand-contractions-normalize-quotes t)
        count)
    (save-restriction
      (narrow-to-region beg end)
      (let ((ranges (expand-contractions--protected-ranges kind)))
        (unwind-protect
            (setq count (expand-contractions--normalize-quotes ranges))
          (expand-contractions--release ranges))))
    (when expand-contractions-verbose
      (message "Replaced %d curly quote%s" count (if (= count 1) "" "s")))
    count))

;;;###autoload
(defun expand-contractions-normalize-quotes-buffer ()
  "Replace curly quotes with straight quotes in the buffer."
  (interactive)
  (expand-contractions-normalize-quotes-region (point-min) (point-max)))

;;;###autoload
(defun expand-contractions-add (contraction expansion &optional save)
  "Add CONTRACTION with EXPANSION to `expand-contractions-user-alist'.
When SAVE is non-nil (interactively, after confirmation), save the
variable with Customize so the entry persists between sessions."
  (interactive
   (let* ((c (read-string "Contraction: "))
          (e (read-string (format "Expansion of \"%s\": " c))))
     (list c e (y-or-n-p "Save for future sessions? "))))
  (setq contraction (expand-contractions--straighten (string-trim contraction))
        expansion (string-trim expansion))
  (when (or (string-empty-p contraction) (string-empty-p expansion))
    (user-error "Both the contraction and the expansion are required"))
  (let ((alist (cons (cons contraction expansion)
                     (assoc-delete-all contraction
                                       (copy-sequence
                                        expand-contractions-user-alist)))))
    (if save
        (customize-save-variable 'expand-contractions-user-alist alist)
      (setq expand-contractions-user-alist alist)))
  (expand-contractions-reload)
  (message "\"%s\" now expands to \"%s\"" contraction expansion))

;;;###autoload
(defun expand-contractions-list ()
  "Show the active contraction table in a help buffer."
  (interactive)
  (let ((alist (expand-contractions-alist)))
    (with-help-window "*Contractions*"
      (princ (format "%d contractions from %s\n\n"
                     (length alist) expand-contractions-csv-file))
      (dolist (pair alist)
        (princ (format "%-20s %s\n" (car pair) (cdr pair)))))))

;;;; Files and directories

(defun expand-contractions--process-file (file)
  "Expand contractions in FILE on disk and return the count.
The file is written only when its text is modified.  A buffer
visiting FILE is reverted afterwards."
  (let* ((file (expand-file-name file))
         (kind (expand-contractions--file-kind file))
         (buf (find-buffer-visiting file))
         (count 0)
         coding changed)
    (unless kind
      (user-error "Unsupported file type: %s" file))
    (unless (file-writable-p file)
      (user-error "File is not writable: %s" file))
    (when (and buf (buffer-modified-p buf))
      (user-error "Buffer visiting %s has unsaved changes.  Save it first"
                  (file-name-nondirectory file)))
    (with-temp-buffer
      (insert-file-contents file)
      (setq coding last-coding-system-used)
      (set-buffer-modified-p nil)
      (setq count (expand-contractions--expand kind))
      (setq changed (buffer-modified-p))
      (when changed
        (when expand-contractions-make-backup
          (copy-file file (make-backup-file-name file) t t))
        (let ((coding-system-for-write coding))
          (write-region nil nil file nil 'silent))))
    (when (and changed buf)
      (with-current-buffer buf
        (revert-buffer t t t)))
    count))

(defun expand-contractions--supported-file-p (file)
  "Return non-nil when FILE is a directory or has a supported extension."
  (or (file-directory-p file)
      (expand-contractions--file-kind file)))

;;;###autoload
(defun expand-contractions-file (file)
  "Expand all contractions in FILE without visiting it.
FILE may be a LaTeX (.tex), Markdown (.md), Quarto (.qmd), Org (.org)
or plain text (.txt) file; see `expand-contractions-file-kinds'.  A
backup is made first when `expand-contractions-make-backup' is
non-nil.  Return the number of replacements."
  (interactive
   (list (read-file-name "Expand contractions in file: " nil nil t nil
                         #'expand-contractions--supported-file-p)))
  (let ((count (expand-contractions--process-file file)))
    (expand-contractions--report count (file-name-nondirectory file))
    count))

(defun expand-contractions--directory-files (dir recursive)
  "Return supported files in DIR, descending into subdirectories if RECURSIVE.
Hidden directories such as .git are skipped."
  (let ((re (concat "\\." (regexp-opt (mapcar #'car expand-contractions-file-kinds))
                    "\\'")))
    (seq-filter
     (lambda (f) (and (file-regular-p f)
                      (not (string-prefix-p "." (file-name-nondirectory f)))
                      (expand-contractions--file-kind f)))
     (if recursive
         (directory-files-recursively
          dir re nil
          (lambda (d) (not (string-prefix-p "." (file-name-nondirectory d)))))
       (directory-files dir t re)))))

;;;###autoload
(defun expand-contractions-directory (dir &optional recursive)
  "Expand contractions in every supported file in DIR.
With RECURSIVE non-nil (interactively, a prefix argument), include
subdirectories.  Return an alist of (FILE . COUNT) for changed files."
  (interactive
   (list (read-directory-name "Expand contractions in directory: " nil nil t)
         current-prefix-arg))
  (let ((files (expand-contractions--directory-files
                (expand-file-name dir) recursive))
        results (total 0))
    (when (and (called-interactively-p 'interactive)
               (not (yes-or-no-p (format "Expand contractions in %d file%s? "
                                         (length files)
                                         (if (= (length files) 1) "" "s")))))
      (user-error "Cancelled"))
    (let ((expand-contractions-verbose nil))
      (dolist (f files)
        (let ((n (expand-contractions--process-file f)))
          (when (> n 0)
            (push (cons f n) results)
            (setq total (+ total n))))))
    (when expand-contractions-verbose
      (message "Expanded %d contraction%s in %d of %d file%s"
               total (if (= total 1) "" "s") (length results) (length files)
               (if (= (length files) 1) "" "s")))
    (nreverse results)))

;;;###autoload
(defun expand-contractions-dired-marked-files ()
  "Expand contractions in the files marked in Dired."
  (interactive)
  (require 'dired)
  (let ((files (seq-filter #'expand-contractions--file-kind
                           (dired-get-marked-files)))
        (total 0))
    (unless files
      (user-error "No supported files are marked"))
    (let ((expand-contractions-verbose nil))
      (dolist (f files)
        (setq total (+ total (expand-contractions--process-file f)))))
    (when expand-contractions-verbose
      (message "Expanded %d contraction%s in %d file%s"
               total (if (= total 1) "" "s") (length files)
               (if (= (length files) 1) "" "s")))
    (when (derived-mode-p 'dired-mode)
      (revert-buffer))
    total))

;;;###autoload
(defun expand-contractions-batch ()
  "Expand contractions in the files named on the command line.
Run Emacs in batch mode with the options --batch, -l
expand-contractions.el and -f expand-contractions-batch, followed by
the names of the files.  The exit status is 1 if any file failed."
  (unless noninteractive
    (user-error "`expand-contractions-batch' is for use with --batch"))
  (let ((status 0))
    (while command-line-args-left
      (let ((file (pop command-line-args-left)))
        (condition-case err
            (let ((n (let ((expand-contractions-verbose nil))
                       (expand-contractions--process-file file))))
              (princ (format "%s: %d\n" file n)))
          (error
           (setq status 1)
           (princ (format "%s: %s\n" file (error-message-string err)))))))
    (kill-emacs status)))

;;;; Minor mode and key map

(defun expand-contractions--before-save ()
  "Expand contractions in the buffer silently before saving."
  (let ((expand-contractions-verbose nil))
    (expand-contractions-buffer)))

;;;###autoload
(define-minor-mode expand-contractions-mode
  "Expand contractions automatically each time the buffer is saved."
  :lighter " Exp"
  (if expand-contractions-mode
      (add-hook 'before-save-hook #'expand-contractions--before-save nil t)
    (remove-hook 'before-save-hook #'expand-contractions--before-save t)))

;;;###autoload
(defvar expand-contractions-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "b" #'expand-contractions-buffer)
    (define-key map "r" #'expand-contractions-region)
    (define-key map "e" #'expand-contractions-dwim)
    (define-key map "p" #'expand-contractions-at-point)
    (define-key map "q" #'expand-contractions-query-buffer)
    (define-key map "f" #'expand-contractions-file)
    (define-key map "d" #'expand-contractions-directory)
    (define-key map "c" #'expand-contractions-count)
    (define-key map "o" #'expand-contractions-occur)
    (define-key map "l" #'expand-contractions-list)
    (define-key map "a" #'expand-contractions-add)
    (define-key map "\"" #'expand-contractions-normalize-quotes-buffer)
    (define-key map "m" #'expand-contractions-mode)
    map)
  "Key map for `expand-contractions' commands.
Bind it to a prefix key, for example:

  (global-set-key (kbd \"C-c e\") expand-contractions-command-map)")
;;;###autoload
(fset 'expand-contractions-command-map expand-contractions-command-map)

(provide 'expand-contractions)
;;; expand-contractions.el ends here
