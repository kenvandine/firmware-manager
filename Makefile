prefix ?= /usr/local
bindir = $(prefix)/bin
includedir = $(prefix)/include
libdir = $(prefix)/lib
sharedir = $(prefix)/share

export CARGO_C_PREFIX = $(prefix)
export CARGO_C_LIBDIR = $(libdir)

TARGET = debug
DEBUG ?= 0
S76_DEV ?= 0

ARGS = --no-default-features

ifeq ($(S76_DEV),1)
	features = system76
else
	features = fwupd system76
endif

ifeq ($(DEBUG),0)
	TARGET = release
	ARGS += --release
endif

VENDOR ?= 0
ifneq ($(VENDOR),0)
	ARGS += --frozen
	DESKTOP_ARGS += --frozen
endif

APPID = com.system76.FirmwareManager
NOTIFY_APPID = $(APPID).Notify
NOTIFY_SERVICE = $(NOTIFY_APPID).service
NOTIFY_TIMER = $(NOTIFY_APPID).timer

GTKPROJ = gtk/Cargo.toml
GTKFFIPROJ = gtk/ffi/Cargo.toml
NOTPROJ = notify/Cargo.toml
PACKAGE = firmware_manager

DESKTOP = target/$(APPID).desktop
STARTUP_DESKTOP = target/$(APPID).Notify.desktop
GTKBINARY = target/$(TARGET)/firmware-manager-gtk
NOTBINARY = target/$(TARGET)/firmware-manager-notify

LIBRARY = target/$(TARGET)/lib$(PACKAGE).so
PKGCONFIG = target/$(PACKAGE).pc
HEADER = gtk/ffi/$(PACKAGE).h

VERSION = $(shell grep version Cargo.toml | head -1 | awk '{print $$3}' | tail -c +2 | head -c -2)

SOURCES = $(shell find src -type f -name '*.rs') Cargo.toml Cargo.lock \
	$(shell find tools/src -type f -name '*.rs') tools/Cargo.toml
FFI_SOURCES = $(shell find gtk/ffi/src -type f -name '*.rs') \
	gtk/ffi/Cargo.toml gtk/ffi/build.rs gtk/ffi/$(PACKAGE).h

all: toml-gen $(GTKBINARY) $(NOTBINARY) $(LIBRARY) $(PKGCONFIG)

clean:
	rm -rf target

distclean: clean
	rm -rf .cargo vendor vendor.tar.xz

## Developer tools

clippy:
	cargo clippy --manifest-path $(GTKPROJ) $(ARGS) --features '$(features)'
	cargo clippy --manifest-path $(NOTPROJ) $(ARGS) --features '$(features)'

## Generating conditional Cargo configs

toml-gen: toml-gtk  toml-gtk-ffi toml-notify

toml-gtk:
	cp gtk/Cargo.toml.in gtk/Cargo.toml
	echo -n 'firmware-manager = { path = "../", default-features = false, features = [ ' >> gtk/Cargo.toml
	for feature in $(features); do \
		echo -n "\"$$feature\"," >> gtk/Cargo.toml; \
	done
	echo ' ] }' >> gtk/Cargo.toml

toml-gtk-ffi:
	cp gtk/ffi/Cargo.toml.in gtk/ffi/Cargo.toml
	echo -n 'firmware-manager-gtk = { path = "../", default-features = false, features = [ ' >> gtk/ffi/Cargo.toml
	for feature in $(features); do \
		echo -n "\"$$feature\"," >> gtk/ffi/Cargo.toml; \
	done
	echo ' ] }' >> gtk/ffi/Cargo.toml

toml-notify:
	cp notify/Cargo.toml.in notify/Cargo.toml
	echo -n 'firmware-manager = { path = "../", default-features = false, features = [ ' >> notify/Cargo.toml
	for feature in $(features); do \
		echo -n "\"$$feature\"," >> notify/Cargo.toml; \
	done
	echo ' ] }' >> notify/Cargo.toml

## Building the binaries

bin $(GTKBINARY): toml-gen $(DESKTOP) prepare
	cargo build --manifest-path $(GTKPROJ) $(ARGS) --features '$(features)'

bin-notify $(NOTBINARY): toml-gen $(STARTUP_DESKTOP) prepare
	env APPID=$(NOTIFY_APPID) prefix=$(prefix) \
		cargo build --manifest-path $(NOTPROJ) $(ARGS) --features '$(features)'

## Builds the desktop entry in the target directory.

desktop $(DESKTOP): prepare
	cargo run -p tools --bin desktop-entry $(DESKTOP_ARGS) -- \
		--appid $(APPID) \
		--name "Firmware Manager" \
		--icon firmware-manager \
		--comment "Manage system and device firmware" \
		--keywords firmware \
		--keywords system76 \
		--keywords fwupd \
		--keywords lvfs \
		--categories System \
		--categories GTK \
		--binary $(APPID) \
		--prefix $(prefix) \
		--startup-notify

notify-desktop $(STARTUP_DESKTOP): prepare
	cargo run -p tools --bin desktop-entry $(DESKTOP_ARGS) -- \
		--appid $(NOTIFY_APPID) \
		--name "Firmware Manager Check" \
		--icon firmware-manager \
		--comment "Check for firmware updates, and display notification if found" \
		--categories System \
		--binary $(NOTIFY_APPID) \
		--prefix $(prefix) \

## Building the library

ffi: $(LIBRARY) $(PKGCONFIG)

$(LIBRARY): $(SOURCES) $(FFI_SOURCES) prepare
	cargo build --manifest-path $(GTKFFIPROJ) $(ARGS)

## Builds the pkg-config file necessary to locate the library.

$(PKGCONFIG): tools/src/pkgconfig.rs
	cargo run -p tools --bin pkgconfig $(DESKTOP_ARGS) -- \
		$(PACKAGE) $(libdir) $(includedir)

## Install commands

install: install-bin install-ffi install-notify install-icons

install-bin:
	install -Dm0755 "$(GTKBINARY)"  "$(DESTDIR)$(bindir)/$(APPID)"
	install -Dm0644 "$(DESKTOP)" "$(DESTDIR)$(prefix)/share/applications/$(APPID).desktop"

install-ffi:
	install -Dm0644 "$(HEADER)"    "$(DESTDIR)$(includedir)/$(PACKAGE).h"
	install -Dm0644 "$(LIBRARY)"   "$(DESTDIR)$(libdir)/lib$(PACKAGE).so"
	install -Dm0644 "$(PKGCONFIG)" "$(DESTDIR)$(libdir)/pkgconfig/$(PACKAGE).pc"

install-notify:
	install -Dm0755 "$(NOTBINARY)"  "$(DESTDIR)$(bindir)/$(NOTIFY_APPID)"
	install -Dm0644 "$(STARTUP_DESKTOP)"  "$(DESTDIR)/etc/xdg/autostart/$(NOTIFY_APPID).desktop"
	install -Dm0644 "target/$(NOTIFY_SERVICE)" "$(DESTDIR)$(libdir)/systemd/user/$(NOTIFY_SERVICE)"
	install -Dm0644 "target/$(NOTIFY_TIMER)" "$(DESTDIR)$(libdir)/systemd/user/$(NOTIFY_TIMER)"

install-icons:
	for icon in $(shell find assets/icons -name *.png -or -name *.svg); do \
	    dest=$(DESTDIR)$(sharedir)/icons/hicolor/$$(echo "$$icon" | cut -c 13-); \
	    mkdir -p $$(dirname $$dest); \
		cp -v $$icon $$dest; \
	done

## Pre-build preparation

prepare: vendor-check

## Uninstall Commands

uninstall: uninstall-bin uninstall-ffi

uninstall-bin:
	rm "$(DESTDIR)$(bindir)/$(APPID)"

uninstall-ffi:
	rm "$(DESTDIR)$(includedir)/$(PACKAGE).h"
	rm "$(DESTDIR)$(libdir)/lib$(PACKAGE).so"
	rm "$(DESTDIR)$(libdir)/pkgconfig/$(PACKAGE).pc"

## Cargo Vendoring

vendor:
	rm .cargo -rf
	mkdir -p .cargo
	cargo vendor | head -n -1 > .cargo/config
	echo 'directory = "vendor"' >> .cargo/config
	tar cfJ vendor.tar vendor
	rm -rf vendor

vendor-check:
ifeq ($(VENDOR),1)
	rm vendor -rf && tar xf vendor.tar
endif
