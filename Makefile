# Makefile for expand-contractions.el
EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L .

ELS  = expand-contractions.el
TEST = test/expand-contractions-test.el

.PHONY: all compile test checkdoc lint clean examples

all: compile test

compile:
	$(BATCH) --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile $(ELS)

test:
	$(BATCH) -L test -l $(TEST) -f ert-run-tests-batch-and-exit

checkdoc:
	$(BATCH) --eval "(checkdoc-file \"$(ELS)\")"

# package-lint must be installed, e.g. from MELPA.
lint:
	$(BATCH) --eval "(progn (require 'package) (package-initialize) (require 'package-lint))" \
	  -f package-lint-batch-and-exit $(ELS)

# Regenerate examples/*.expected after an intentional change in behavior.
examples:
	$(BATCH) -l expand-contractions --eval "(dolist (f (directory-files \"examples\" t \"\\\\\`sample\\\\.[a-z]+\\\\'\")) \
	  (let ((coding-system-for-read 'utf-8) (coding-system-for-write 'utf-8)) \
	    (with-temp-buffer (insert-file-contents f) \
	      (let ((expand-contractions-verbose nil)) \
	        (expand-contractions--expand (expand-contractions--file-kind f))) \
	      (write-region nil nil (concat f \".expected\") nil 'silent))))"

clean:
	rm -f *.elc test/*.elc examples/*~
