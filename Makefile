EMACS ?= emacs

.PHONY: test compile clean all

all: compile test

test:
	$(EMACS) --batch -L . -L test -l ert -l test/cljbang-test.el \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) --batch -L . --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile cljbang.el

bench:
	$(EMACS) --batch -L . -l bench-compile.el

clean:
	rm -f *.elc test/*.elc
