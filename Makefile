T= lualdap
V= 1.4.0
R= 1
CONFIG= ./config

include $(CONFIG)

SLAPD := openshift

CFLAGS_WARN := -pedantic -Wall -W -Waggregate-return -Wcast-align -Wmissing-prototypes -Wnested-externs -Wshadow -Wwrite-strings

override CPPFLAGS := $(CPPFLAGS)
override CFLAGS := -O2 -fPIC $(CFLAGS_WARN) $(CFLAGS)

ifdef BUILD_VARIANT
REPORT_DIR := test-reports/$(BUILD_VARIANT)
else
REPORT_DIR := test-reports
endif

ifdef COVERAGE
override CFLAGS := $(CFLAGS) -O0 -g --coverage
endif

OBJS= src/lualdap.o
INCS := -I$(LUA_INCDIR) -I$(LDAP_INCDIR) -I$(LBER_INCDIR)
LIBS := -L$(LUA_LIBDIR) $(LUA_LIB) -L$(LDAP_LIBDIR) $(LDAP_LIB) -L$(LBER_LIBDIR) $(LBER_LIB)

override CPPFLAGS := $(INCS) $(CPPFLAGS)
override LDFLAGS := $(LIBFLAG) $(LDFLAGS)

LIBNAME=$(T).so

src/$(LIBNAME): $(OBJS)
	$(CC) $(CFLAGS) -o src/$(LIBNAME) $(LDFLAGS) $(OBJS) $(LIBS)

install: src/$(LIBNAME)
	$(INSTALL) -d $(DESTDIR)$(INST_LIBDIR)
	$(INSTALL) src/$(LIBNAME) $(DESTDIR)$(INST_LIBDIR)

clean:
	$(RM) -r $(OBJS) src/$(LIBNAME) src/*.gcda src/*.gcno src/*.gcov luacov.*.out $(REPORT_DIR)

luacheck:
	luacheck --std min tests/smoke.lua
	luacheck --std max+busted --config tests/.luacheckrc tests/test.lua
	luacheck --std min --config tests.old/.luacheckrc tests.old/test.lua

smoke:
	@echo SMOKE with $(LUA)
	@LUA_CPATH="./src/?.so" $(LUA) tests/smoke.lua

setup_slapd:
	./tests/$(SLAPD)/setup.sh

check:
	. tests/$(SLAPD)/test.env && LUA_CPATH="./src/?.so" busted tests/test.lua

valgrind:
	. tests/$(SLAPD)/test.env && LUA_CPATH="./src/?.so" valgrind --keep-debuginfo=yes --leak-check=full busted tests/test.lua

coverage: $(REPORT_DIR)
	. tests/$(SLAPD)/test.env && LUA_CPATH="./src/?.so" busted --coverage --output=junit -Xoutput $(REPORT_DIR)/report.xml tests/test.lua
	luacov
	mv luacov.*.out $(REPORT_DIR)

$(REPORT_DIR):
	mkdir -p $@

rock:
	luarocks pack rockspec/lualdap-$(V)-$(R).rockspec

pages:
	mkdocs build

gh-pages:
	mkdocs gh-deploy --clean

deb:
	echo "lua-ldap ($(V)) unstable; urgency=medium" >  debian/changelog
	echo ""                         >> debian/changelog
	echo "  * UNRELEASED"           >> debian/changelog
	echo ""                         >> debian/changelog
	echo " -- $(shell git config --get user.name) <$(shell git config --get user.email)>  $(shell date -R)" >> debian/changelog
	fakeroot debian/rules clean binary
