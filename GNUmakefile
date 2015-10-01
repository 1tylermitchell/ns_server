# Copyright (c) 2011, Couchbase, Inc.
# All rights reserved.

# Note: This Makefile is provided as a convenience wrapper to CMake,
# which is the build tool used for configuring this project. Please do
# not make any substantive changes only in this file or in the
# top-level "configure" script, as the normal process of building
# Couchbase server uses only CMake.

SHELL=/bin/sh

ifneq (,$(wildcard build))
all:
	cd build && $(MAKE) --no-print-directory all

fail-unless-configured:
	@true

else
all fail-unless-configured:
	@echo
	@echo "you need to run ./configure with --prefix option to be able to run ns_server"
	@echo
	@false
endif


.PHONY: test ui_test docs

clean clean_all:
	cd build && $(MAKE) --no-print-directory clean ns_realclean

install:
	cd build && $(MAKE) --no-print-directory $@

dataclean distclean test ui_test docs dialyzer dialyzer_obsessive:
	cd build && $(MAKE) --no-print-directory ns_$@

# assuming exuberant-ctags
TAGS:
	ctags -eR .
