include $(top_srcdir)/build/modmake.rulesam
MODNAME=mod_managedcore
MANAGED_DIR=$(switch_srcdir)/src/mod/languages/mod_managedcore/managed

# Make these come from pkg-config or autoconf dependency detection later
COREHOST_LIB = libnethost.so
COREHOST_RID ?= linux-x64
COREHOST_PACKS ?= /usr/share/dotnet/packs/Microsoft.NETCore.App.Host.$(COREHOST_RID)

# The path used to name one host-pack version outright, and broke as soon as a
# different SDK was installed - the Debian build gets 10.0.400 where this said
# 10.0.10, and make then reports only 'No rule to make target .../libnethost.so'.
# Take the newest pack that is actually installed, overridable the same way
# DotNetHostVersion is on the Windows side.
COREHOST_VERSION ?= $(notdir $(lastword $(sort $(wildcard $(COREHOST_PACKS)/*))))

# Not an 'ifeq' guard: automake owns the if/endif keywords at line start and
# rejects them with 'endif without if'. Expanding the check inside the variable
# also reports it only when the module is really built.
COREHOST_CHECKED = $(or $(COREHOST_VERSION),$(error no .NET host pack under $(COREHOST_PACKS) - install the .NET SDK or set COREHOST_VERSION))
COREHOST_PATH = $(COREHOST_PACKS)/$(COREHOST_CHECKED)/runtimes/$(COREHOST_RID)/native
COREHOST_CFLAGS = -I$(COREHOST_PATH) -L$(COREHOST_PATH)
COREHOST_LDFLAGS = -lnethost

mod_LTLIBRARIES = mod_managedcore.la
mod_managedcore_la_SOURCES  = mod_managedcore.cpp freeswitch_managedcore.cpp freeswitch_wrap.cxx
mod_managedcore_la_CFLAGS   = $(AM_CFLAGS) $(COREHOST_CFLAGS)
mod_managedcore_la_CXXFLAGS = $(AM_CXXFLAGS) $(COREHOST_CFLAGS)
mod_managedcore_la_CPPFLAGS = $(SWITCH_AM_CPPFLAGS)
mod_managedcore_la_LIBADD   = $(switch_builddir)/libfreeswitch.la
mod_managedcore_la_LDFLAGS  = -avoid-version -module -no-undefined -shared $(COREHOST_LDFLAGS)

MANAGED_SRCDIR=$(abs_srcdir)/managed
BUILT_SOURCES=$(top_srcdir)/x64/Release/mod/FreeSWITCH.ManagedCore.dll
CS_SRC=$(MANAGED_SRCDIR)/AssemblyInfo.cs $(MANAGED_SRCDIR)/Extensions.cs $(MANAGED_SRCDIR)/Loader.cs $(MANAGED_SRCDIR)/Log.cs
CS_SRC+=$(MANAGED_SRCDIR)/ManagedSession.cs $(MANAGED_SRCDIR)/PluginInterfaces.cs
CS_SRC+=$(MANAGED_SRCDIR)/PluginManager.cs $(MANAGED_SRCDIR)/ChannelVariables.cs $(MANAGED_SRCDIR)/Util.cs
CS_SRC+=$(MANAGED_SRCDIR)/swig.cs $(MANAGED_SRCDIR)/XmlSearchBinding.cs
CS_PROJ=$(MANAGED_SRCDIR)/FreeSWITCH.ManagedCore.2019.csproj

freeswitch_managedcore.o: freeswitch_managedcore.h freeswitch_managedcore.cpp

reswig: swigclean freeswitch_wrap.cxx

export DOTNET_CLI_HOME=/tmp/dotnet
export HOME=/tmp/dotnet
$(top_srcdir)/x64/Release/mod/FreeSWITCH.ManagedCore.dll: $(CS_SRC) $(top_srcdir)/x64/Release/mod/libnethost.so
	dotnet build -c Release -p:Platform=x64 $(CS_PROJ)

$(top_srcdir)/x64/Release/mod/libnethost.so: $(COREHOST_PATH)/$(COREHOST_LIB)
	mkdir -p $(top_srcdir)/x64/Release/mod
	cp $(COREHOST_PATH)/$(COREHOST_LIB) $(top_srcdir)/x64/Release/mod/libnethost.so

install-data-local: $(top_srcdir)/x64/Release/mod/FreeSWITCH.ManagedCore.dll
	mkdir -p $(DESTDIR)$(modulesdir)/managedcore
	$(INSTALL) $(COREHOST_PATH)/$(COREHOST_LIB) $(DESTDIR)$(libdir)
	$(INSTALL) $(top_srcdir)/x64/Release/mod/FreeSWITCH.ManagedCore.dll $(DESTDIR)$(modulesdir)
	$(INSTALL) $(top_srcdir)/x64/Release/mod/FreeSWITCH.ManagedCore.runtimeconfig.json $(DESTDIR)$(modulesdir)
	$(INSTALL) $(top_srcdir)/x64/Release/mod/FreeSWITCH.ManagedCore.deps.json $(DESTDIR)$(modulesdir)

uninstall:
	rm -fr $(DESTDIR)$(libdir)/$(COREHOST_LIB)
	rm -fr $(DESTDIR)$(modulesdir)/mod_managedcore.so
	rm -fr $(DESTDIR)$(modulesdir)/FreeSWITCH.ManagedCore.dll
	rm -fr $(DESTDIR)$(modulesdir)/FreeSWITCH.ManagedCore.runtimeconfig.json
	rm -fr $(DESTDIR)$(modulesdir)/FreeSWITCH.ManagedCore.deps.json

clean:
	rm -fr $(top_srcdir)/x64/Release/mod/FreeSWITCH.ManagedCore.dll

swigclean: clean
	rm -f freeswitch_wrap.cxx managed/swig.cs

freeswitch_wrap.cxx:
	swig -I../../../include -v -O -c++ -csharp -namespace FreeSWITCH.Native -dllimport mod_managedcore -DSWIG_CSHARP_NO_STRING_HELPER freeswitch.i
	rm -f ./managed/swig.cs
	patch -s -p0 -i managed/hack.diff
	cat *.cs > ./managed/swig.cs
	rm -f *.cs
