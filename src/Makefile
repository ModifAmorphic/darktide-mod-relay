# Makefile — Mod Relay mixed DLL build.
#
# Reproducible MinGW cross-compile from Linux: Rust staticlib + C shell/MinHook
# -> one PE DLL (relay_shell.dll), plus the launcher exe. The MSVC-native build
# runs in CI (.github/workflows/pr.yml + release-please.yml) on a Windows
# runner.
#
# This Makefile lives in src/, so every path below is relative to src/.
# ALL build outputs land in bin/ (gitignored); cargo's target/ also resolves
# here (src/target/).
#
# Usage (from src/):
#   make build          # cross-compile the DLL + launcher (x86_64-pc-windows-gnu)
#                       # + stage the mod loader Lua into bin/mod_loader/
#                       # + stage root LICENSE + THIRD_PARTY_NOTICES.md into bin/
#   make check          # verify the DLL is a valid PE with a DllMain entry
#   make test           # cargo test + C unit tests (wine) + Relay Lua tests
#   make clean

CARGO     ?= cargo
CROSS_CC  ?= x86_64-w64-mingw32-gcc
OBJDUMP   ?= x86_64-w64-mingw32-objdump
NM        ?= x86_64-w64-mingw32-nm
WINDRES   ?= x86_64-w64-mingw32-windres
WINDRES_FLAGS :=
TARGET    := x86_64-pc-windows-gnu
PROFILE   := release
WINE      ?= wine

BIN := bin

REL_DIR   := target/$(TARGET)/$(PROFILE)
RUST_LIB  := $(REL_DIR)/librelay_discovery.a
# Rust sources the staticlib depends on. GNU make's `**` is not recursive (it
# expands to nothing here), so list src/*.rs explicitly. discovery/tests/*.rs
# are separate integration-test binaries, not compiled into the staticlib.
RUST_SRCS := $(wildcard discovery/src/*.rs)
DLL       := $(BIN)/relay_shell.dll
LAUNCHER  := $(BIN)/mod_relay.exe
# windres output paths use .o (not .res) so windres emits COFF object format
# (ld-only) rather than GNU binary resource format (rc.exe-only). See
# https://sourceware.org/binutils/docs/binutils/windres.html — output format
# is inferred from the extension unless -O is passed.
SHELL_RES := $(BIN)/shell_res.o
LAUNCHER_RES := $(BIN)/launcher_res.o

SHELL_SRC := shell/src/dllmain.c shell/src/trampoline.c
MINHOOK_SRC := shell/vendor/minhook/src/buffer.c \
               shell/vendor/minhook/src/hook.c \
               shell/vendor/minhook/src/trampoline.c \
               shell/vendor/minhook/src/hde/hde64.c
INCLUDES  := -I shell/include -I shell/vendor/minhook/include

# The mod loader Lua shipped WITH the runtime: the entry + its active modules.
# This is the runtime-controlled root, staged next to the launcher/DLL so the
# shell self-locates `<dll-dir>/mod_loader/` and opens init.lua. The tests/
# harness is NOT runtime code.
MOD_LOADER_LUA := mod_loader/init.lua \
                  mod_loader/path.lua \
                  mod_loader/file.lua \
                  mod_loader/class_registry.lua \
                  mod_loader/lifecycle.lua \
                  mod_loader/require_bridge.lua \
                  mod_loader/mod_manager.lua \
                  mod_loader/dmf_adapter.lua
MOD_LOADER_DIR := $(BIN)/mod_loader

# Root legal notices staged beside the executables so every distributable
# runtime bundle carries the required license attribution (Relay's GPL LICENSE
# + THIRD_PARTY_NOTICES.md for the statically-linked MinHook + Capstone deps).
# Lives at repo root, i.e. ../<notice> from src/.
LEGAL_NOTICES := ../LICENSE ../THIRD_PARTY_NOTICES.md

# Product version: sourced at build time from the release-please manifest (the
# single file release-please bumps at release time, available before build-assets
# runs). Injected as -DRELAY_VERSION so --version reports it with no version
# constant baked into source (which would go stale and is deliberately NOT wired
# into release-please extra-files). Fall back if the manifest is missing/empty.
RELAY_VERSION := $(shell sed -n 's/.*"src"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' ../.release-please-manifest.json)
RELAY_VERSION := $(if $(RELAY_VERSION),$(RELAY_VERSION),0.0.0-dev)

# Numeric version parts for the windres resource compiles. The .rc composes
# both the binary FILEVERSION 4-tuple AND the string FileVersion from these
# same numeric defines (single source of truth, no drift). The patch field
# has its '-' pre-release suffix stripped so the '0.0.0-dev' fallback
# degrades cleanly to a numeric 0 (FILEVERSION requires numeric fields).
RELAY_VERSION_MAJOR := $(word 1,$(subst ., ,$(RELAY_VERSION)))
RELAY_VERSION_MINOR := $(word 2,$(subst ., ,$(RELAY_VERSION)))
RELAY_VERSION_PATCH := $(firstword $(subst -, ,$(word 3,$(subst ., ,$(RELAY_VERSION)))))

# Rust std's Windows system-lib dependencies (mingw).
RUST_SYS  := -lpsapi -lkernel32 -luser32 -lws2_32 -lbcrypt -luserenv -lntdll -lgcc

# ---- C test infrastructure ----
TEST_CC       := $(CROSS_CC)
TEST_CFLAGS   := -static-libgcc -O2
TEST_INCLUDES := -I launcher/src -I shell/include
# shell32.lib provides CommandLineToArgvW (used by test_quoting's round-trip
# oracle). Safe to link into every test exe.
TEST_LIBS     := -lkernel32 -lshell32

TEST_RUNNER_OBJ := $(BIN)/test_runner.o
LAUNCHER_OBJ    := $(BIN)/launcher.o

# Stub executables for injection testing (built into bin/ alongside test exes)
STUB_TARGET := $(BIN)/stub_target.exe
STUB_SHELL  := $(BIN)/stub_shell.dll

# Test executables
TEST_EXES := $(BIN)/test_steam_env.exe $(BIN)/test_injection.exe \
             $(BIN)/test_config.exe $(BIN)/test_quoting.exe \
             $(BIN)/test_trampoline.exe

.PHONY: all build dll launcher stage-mod_loader stage-legal check test c-tests mod-loader-test clean rust-staticlib

all: build

# Ensure the output directory exists before any rule writes into it (order-only
# prereq of every output-producing rule below).
$(BIN):
	mkdir -p $@

rust-staticlib: $(RUST_LIB)
$(RUST_LIB): $(RUST_SRCS) discovery/Cargo.toml Cargo.toml Cargo.lock
	$(CARGO) build --$(PROFILE) -p relay-discovery --target $(TARGET)

build: dll launcher stage-mod_loader stage-legal

dll: $(DLL)
$(SHELL_RES): shell/src/relay_shell.rc ../.release-please-manifest.json | $(BIN)
	$(WINDRES) $(WINDRES_FLAGS) \
	  -DRELAY_VERSION_MAJOR=$(RELAY_VERSION_MAJOR) \
	  -DRELAY_VERSION_MINOR=$(RELAY_VERSION_MINOR) \
	  -DRELAY_VERSION_PATCH=$(RELAY_VERSION_PATCH) \
	  shell/src/relay_shell.rc -o $@

$(DLL): $(RUST_LIB) $(SHELL_SRC) $(MINHOOK_SRC) shell/src/relay_shell.rc \
        shell/include/relay_discovery.h shell/include/trampoline.h \
        $(SHELL_RES) | $(BIN)
	$(CROSS_CC) -shared -static-libgcc -O2 -o $@ \
	  $(SHELL_SRC) $(MINHOOK_SRC) $(INCLUDES) $(SHELL_RES) \
	  -l:librelay_discovery.a -L $(REL_DIR) \
	  $(RUST_SYS) -Wl,--out-implib,$(BIN)/relay_shell.lib

$(LAUNCHER_RES): launcher/src/launcher.rc ../.release-please-manifest.json | $(BIN)
	$(WINDRES) $(WINDRES_FLAGS) \
	  -DRELAY_VERSION_MAJOR=$(RELAY_VERSION_MAJOR) \
	  -DRELAY_VERSION_MINOR=$(RELAY_VERSION_MINOR) \
	  -DRELAY_VERSION_PATCH=$(RELAY_VERSION_PATCH) \
	  launcher/src/launcher.rc -o $@

launcher: $(LAUNCHER)
$(LAUNCHER): launcher/src/launcher.c launcher/src/launcher.h launcher/src/launcher.rc \
             ../.release-please-manifest.json $(LAUNCHER_RES) | $(BIN)
	$(CROSS_CC) -static-libgcc -O2 -DRELAY_VERSION='"$(RELAY_VERSION)"' -o $@ \
	  launcher/src/launcher.c $(LAUNCHER_RES) -lkernel32

# Stage the active mod loader Lua (entry + modules) into bin/mod_loader/, next to
# the launcher + DLL. This is the dir the shell self-locates from its own DLL
# path (<dll-dir>/mod_loader/, opened as <dll-dir>/mod_loader/init.lua). Order-
# only-depends on $(MOD_LOADER_DIR) so the dir exists before cp writes into it
# (mirrors the $(BIN) idiom). The sources are the real dependency so edits to a
# module re-stage on the next build. Stale .lua files (e.g. a module renamed or
# removed between builds) are cleared first so the staged dir is exactly the
# current module set, never a superset carrying obsolete files.
stage-mod_loader: $(MOD_LOADER_LUA) | $(MOD_LOADER_DIR)
	@rm -f $(MOD_LOADER_DIR)/*.lua
	cp $(MOD_LOADER_LUA) $(MOD_LOADER_DIR)/

$(MOD_LOADER_DIR): | $(BIN)
	mkdir -p $@

# Stage root LICENSE + THIRD_PARTY_NOTICES.md into bin/ beside the executables.
# Order-only-depends on $(BIN) so the dir exists before cp writes (mirrors the
# stage-mod_loader / $(BIN) idiom). The notices are the real dependency so edits
# to either re-stage on the next build. Required for every distributable bundle
# (GPL LICENSE + third-party notices for the statically-linked dependencies).
stage-legal: $(LEGAL_NOTICES) | $(BIN)
	cp $(LEGAL_NOTICES) $(BIN)/

check: $(DLL)
	@echo "--- file type ---"; file $(DLL)
	@echo "--- entry point ---"; $(OBJDUMP) -p $(DLL) | grep -i "AddressOfEntryPoint"
	@echo "--- DllMain symbol ---"; $(NM) $(DLL) | grep -iE " T DllMain$$"
	@echo "--- production Rust seam symbols ---"; $(NM) $(DLL) | grep -iE " T relay_(discover|discover_detail)$$"
	@echo "--- test-only panic symbol must be ABSENT in release ---"; \
	  test -z "$$($(NM) $(DLL) | grep -iE ' T relay_test_panic_boundary')" && echo "OK: test symbol absent" || (echo "CHECK FAIL: test-only symbol leaked into release"; exit 1)
	@echo "--- runtime DLL deps (no relay_discovery.dll / libgcc) ---"; $(OBJDUMP) -p $(DLL) | grep "DLL Name"
	@echo "--- PE version resources (.rsrc section must be present in both binaries) ---"; \
	  test -n "$$($(OBJDUMP) -h $(DLL) | grep -iE '\.rsrc')" && \
	  test -n "$$($(OBJDUMP) -h $(LAUNCHER) | grep -iE '\.rsrc')" && \
	  echo "OK: .rsrc present in both binaries" || (echo "CHECK FAIL: .rsrc section missing (PE version resources not linked - was the windres object dropped from the link command?)"; exit 1)
	@test -n "$$($(NM) $(DLL) | grep -iE ' T DllMain$$')" && \
	 test -n "$$($(NM) $(DLL) | grep -iE ' T relay_discover$$')" && \
	 test -n "$$($(NM) $(DLL) | grep -iE ' T relay_discover_detail$$')" && \
	 echo "CHECK PASS: valid PE DLL with DllMain + production seam" || (echo "CHECK FAIL"; exit 1)

# ---- C test build rules ----

$(TEST_RUNNER_OBJ): tests/test_runner.c tests/test_runner.h | $(BIN)
	$(TEST_CC) $(TEST_CFLAGS) -c -o $@ $<

$(LAUNCHER_OBJ): launcher/src/launcher.c launcher/src/launcher.h \
                  ../.release-please-manifest.json | $(BIN)
	$(TEST_CC) $(TEST_CFLAGS) $(TEST_INCLUDES) -DRELAY_TEST_BUILD \
	  -DRELAY_VERSION='"$(RELAY_VERSION)"' -c -o $@ $<

# Stub target — minimal Windows GUI exe that sleeps then exits 0
$(STUB_TARGET): tests/stub_target.c | $(BIN)
	$(TEST_CC) $(TEST_CFLAGS) -mwindows -o $@ $<

# Stub shell — minimal DLL that signals relay_hook_ready on attach
$(STUB_SHELL): tests/stub_shell.c | $(BIN)
	$(TEST_CC) $(TEST_CFLAGS) -shared -o $@ $<

$(BIN)/test_steam_env.exe: tests/test_steam_env.c tests/test_runner.h \
                          $(TEST_RUNNER_OBJ) $(LAUNCHER_OBJ) | $(BIN)
	$(TEST_CC) $(TEST_CFLAGS) $(TEST_INCLUDES) -o $@ $< \
	  $(TEST_RUNNER_OBJ) $(LAUNCHER_OBJ) $(TEST_LIBS)

$(BIN)/test_injection.exe: tests/test_injection.c tests/test_runner.h \
                          $(TEST_RUNNER_OBJ) $(LAUNCHER_OBJ) | $(BIN)
	$(TEST_CC) $(TEST_CFLAGS) $(TEST_INCLUDES) -DRELAY_TEST_BUILD -o $@ $< \
	  $(TEST_RUNNER_OBJ) $(LAUNCHER_OBJ) $(TEST_LIBS)

$(BIN)/test_config.exe: tests/test_config.c tests/test_runner.h \
                          $(TEST_RUNNER_OBJ) $(LAUNCHER_OBJ) | $(BIN)
	$(TEST_CC) $(TEST_CFLAGS) $(TEST_INCLUDES) -DRELAY_TEST_BUILD -o $@ $< \
	  $(TEST_RUNNER_OBJ) $(LAUNCHER_OBJ) $(TEST_LIBS)

$(BIN)/test_quoting.exe: tests/test_quoting.c tests/test_runner.h \
                          $(TEST_RUNNER_OBJ) $(LAUNCHER_OBJ) | $(BIN)
	$(TEST_CC) $(TEST_CFLAGS) $(TEST_INCLUDES) -DRELAY_TEST_BUILD -o $@ $< \
	  $(TEST_RUNNER_OBJ) $(LAUNCHER_OBJ) $(TEST_LIBS)

# test_trampoline compiles the pure trampoline.c inline (via #include), so it
# needs only the test runner + kernel32 (no Lua/hook deps).
$(BIN)/test_trampoline.exe: tests/test_trampoline.c \
                          shell/src/trampoline.c shell/include/trampoline.h \
                          tests/test_runner.h $(TEST_RUNNER_OBJ) | $(BIN)
	$(TEST_CC) $(TEST_CFLAGS) $(TEST_INCLUDES) -o $@ $< \
	  $(TEST_RUNNER_OBJ) $(TEST_LIBS)

c-tests: $(TEST_EXES) $(STUB_TARGET) $(STUB_SHELL)
	@echo "=== C unit tests (via wine) ==="
	$(WINE) $(BIN)/test_steam_env.exe
	$(WINE) $(BIN)/test_injection.exe
	$(WINE) $(BIN)/test_config.exe
	$(WINE) $(BIN)/test_quoting.exe
	$(WINE) $(BIN)/test_trampoline.exe

test: c-tests mod-loader-test
	$(CARGO) test --features test-hooks -p relay-discovery

# ---- mod loader Lua tests (offline LuaJIT harness) ----
# Runs the v2 mod loader's offline test harness via luajit. Pure-Lua; no game
# binary or wine needed. Wired into `test` (runs alongside the C + Rust tests)
# AND kept as a standalone target for fast Lua-only iteration.
# Requires /usr/bin/luajit (LuaJIT 2.1); if absent, the target fails clearly.
LUAJIT ?= luajit
MOD_LOADER_TESTS := mod_loader/tests/runner.lua

mod-loader-test:
	@echo "=== mod loader Lua tests (LuaJIT) ==="
	$(LUAJIT) $(MOD_LOADER_TESTS)

clean:
	$(CARGO) clean
	rm -rf $(BIN)
