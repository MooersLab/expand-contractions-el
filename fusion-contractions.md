Prompt:
I have attached a CSV file that contains all the English contractions and their expansions that I know of. Suggest any additional ones that I have overlooked. This function should work with both lowercase and uppercase text. If any curly quotes are present, these should be replaced with straight quotes because some programs cannot handle curly quotes. I want the function to operate automatically on the buffer. I would rather not have to decide whether to apply the correction to every single contraction that may be present.

Repsonse:


* case-insensitive: `don't` / `Don't` / `DON'T` -> `do not` / `Do not` / `DO NOT`
* normalizes curly quotes `’ ‘` + `“ ”` to `'` / `"` first
* fully automatic, no `query-replace`

```elisp
(defun expand-english-contractions-in-buffer ()
  "Expand English contractions in current buffer.
1. Replace curly quotes with straight quotes.
2. Replace all contractions automatically, preserving case."
  (interactive)
  (save-excursion
    ;; 1. curly -> straight, some tools can't handle curly
    (goto-char (point-min))
    (while (re-search-forward "[‘’‛ʼ′´`]" nil t)
      (replace-match "'" t t))
    (goto-char (point-min))
    (while (re-search-forward "[“”„‟]" nil t)
      (replace-match "\"" t t))

    ;; 2. contractions, longest first so
    ;; couldn't've wins over couldn't wins over could
    (let* ((case-fold-search t)
           (case-replace nil)
           (alist (sort my-english-contractions-alist
                        (lambda (a b)
                          (> (length (car a)) (length (car b)))))))
      (dolist (pair alist)
        (goto-char (point-min))
        (let ((pat (concat "\\(^\\|[^A-Za-z]\\)\\("
                           (regexp-quote (car pair))
                           "\\)\\>")))
          (while (re-search-forward pat nil t)
            (let* ((orig (match-string 2))
                   (exp (cdr pair))
                   (new (cond
                         ;; DON'T -> DO NOT
                         ((string= orig (upcase orig))
                          (upcase exp))
                         ;; Don't -> Do not
                         ((let ((c (aref orig 0)))
                            (and (>= c ?A) (<= c ?Z)))
                          (concat (upcase (substring exp 0 1))
                                  (substring exp 1)))
                         (t exp))))
              (replace-match (concat "\\1" new) t nil)
              ;; point is now after new text, continue
              ))))))))

(defvar my-english-contractions-alist
  ;; load this from your CSV, trimmed + de-duplicated
  ;; car = contraction with straight ', cdr = expansion
  '(("'cause" . "because") ("'twas" . "it was")
    ("can't" . "cannot") ("could've" . "could have")
    ;; ... put full list here
    ))
```

Loading your CSV directly:

```elisp
(defun my-load-contractions-from-csv (file)
  "Read FILE as contraction,expansion per line into `my-english-contractions-alist'."
  (interactive "fContractions CSV: ")
  (with-temp-buffer
    (insert-file-contents file)
    (setq my-english-contractions-alist
          (let (out)
            (dolist (line (split-string (buffer-string) "\n" t) out)
              (when (string-match "^\\s-*\\([^,]+\\),\\s-*\\(.+?\\)\\s-*$" line)
                (push (cons (match-string 1 line)
                            (match-string 2 line)) out)))))))
```

> Tip: trim the CSV first - you have `"aren't "` with trailing space, `" gimme"`, `" wanna"`, `" should not have"` with leading space, which will never match unless trimmed.

### What you overlooked / should fix

Duplicates in your file:
`'cause` x2, `'twas` x2, `how'll` x2, `wasn't` x2, `i'm'onna` x2, `dunno` / `Idunno`

Typos / wrong:
* `aren't ` -> trim
* `won't,would not` should be `will not`
* `wonnot,will not` -> `won't`
* `y'knonwn` -> `y'know`
* `y'all'dnt've` -> `y'all'd've`
* `ought'nt` -> `oughtn't`
* `gon't,go not` - not standard
* `nall,not all` - not a contraction
* `had've,had have`, `to've,to have` - fragments
* `i'am` -> `I'm`

Ambiguous `-'s`: `he's, she's, it's, what's, where's, who's, that’s, there's` can be `is` **or** `has`. You currently pick only `is`, e.g. `there's,there is/there has` is the only one you mark dual. Decide on one.

Entirely missing families you should add:

```
when's,when'd,when'll,when're,when've,when'd've
where'll,where'd've
which'll,which're
who'd've,who'll've,they'd've,they'll've
you'd've,you'll've,we'll've,I'd've,I'll've
he'd've,she'd've,it'd've,it'll've
that'd've,there're,there've,this'll
hadn't've,hasn't've,haven't've
mightn't've,mayn't've,needn't've,shan't've,won't've
wasn't've,weren't've,why've
y'all've
betcha,gotcha,didcha,dontcha,whatcha = bet you, got you, did you, etc.
coulda,shoulda,woulda,mighta,musta,oughta,sorta,kinda,lotsa,lotta,outta,gonna've,gotta've,wanna've
'twill,it will / 'twould,it would / 'twere,it were / 'twixt,betwixt
c'mere,come here / d'you,do you
```

Biggest gap is `when-` - you have `what-/where-/which-/who-/why-` but zero `when-`, plus almost no `-`'ve` double-contractions like `I'd've, he'd've, they'll've, we'd've`.