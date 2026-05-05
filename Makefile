# nouveau-pstate-daemon Makefile (v0.2.0+).
#
# Targets:
#   make install     install all artifacts (root or sudo)
#   make uninstall   reverse-install
#   make check       shellcheck all shell scripts
#   make test        smoke-test bin/nv-pstate against a tempfile
#
# Override DESTDIR / PREFIX for staged installs or non-/usr/local layouts.

PREFIX ?= /usr/local
DESTDIR ?=
BINDIR = $(DESTDIR)$(PREFIX)/bin
SUDOERSDIR = $(DESTDIR)/etc/sudoers.d
INITDIR = $(DESTDIR)/etc/init.d
CONFDIR = $(DESTDIR)/etc/conf.d
UDEVDIR = $(DESTDIR)/etc/udev/rules.d

SHELLS = bin/nv-pstate bin/nouveau-pstate-swayidle bin/nouveau-pstate-wedge-handler openrc/init.d/nouveau-pstate-daemon

.PHONY: install uninstall check test

install:
	install -d $(BINDIR) $(SUDOERSDIR) $(INITDIR) $(CONFDIR) $(UDEVDIR)
	install -m 0755 bin/nv-pstate $(BINDIR)/nv-pstate
	install -m 0755 bin/nouveau-pstate-swayidle $(BINDIR)/nouveau-pstate-swayidle
	install -m 0755 bin/nouveau-pstate-wedge-handler $(BINDIR)/nouveau-pstate-wedge-handler
	install -m 0440 config/sudoers.d/nouveau-pstate $(SUDOERSDIR)/nouveau-pstate
	install -m 0755 openrc/init.d/nouveau-pstate-daemon $(INITDIR)/nouveau-pstate-daemon
	install -m 0644 openrc/conf.d/nouveau-pstate-daemon $(CONFDIR)/nouveau-pstate-daemon
	install -m 0644 config/udev/99-nouveau-pstate-wedge.rules $(UDEVDIR)/99-nouveau-pstate-wedge.rules
	@echo
	@echo "Install done. Next steps:"
	@echo "  groupadd -f nouveau-pstate && usermod -aG nouveau-pstate <your-user>"
	@echo "  rc-update add nouveau-pstate-daemon default"
	@echo "  rc-service nouveau-pstate-daemon start"
	@echo "  Add /usr/local/bin/nouveau-pstate-swayidle to ~/.config/labwc/autostart"
	@echo "  Run 'udevadm control --reload-rules' to pick up the wedge rule"

uninstall:
	rm -f $(BINDIR)/nv-pstate
	rm -f $(BINDIR)/nouveau-pstate-swayidle
	rm -f $(BINDIR)/nouveau-pstate-wedge-handler
	rm -f $(SUDOERSDIR)/nouveau-pstate
	rm -f $(INITDIR)/nouveau-pstate-daemon
	rm -f $(CONFDIR)/nouveau-pstate-daemon
	rm -f $(UDEVDIR)/99-nouveau-pstate-wedge.rules

check:
	shellcheck bin/nv-pstate bin/nouveau-pstate-swayidle bin/nouveau-pstate-wedge-handler
	shellcheck -s bash -e SC2034 openrc/init.d/nouveau-pstate-daemon
	shellcheck openrc/conf.d/nouveau-pstate-daemon
	shellcheck tests/test_nv-pstate.sh tests/test_wedge_handler.sh

test:
	./tests/test_nv-pstate.sh
	./tests/test_wedge_handler.sh
