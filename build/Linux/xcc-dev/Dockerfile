# XCC runtime under Linux, for development.
#
# Assembled from three sources, none of which is built here:
#   /ctx/debs      the FreeSWITCH packages of this line, from build\Linux\build-debs.ps1
#   /ctx/xcc       freeswitch-xcc-core.deb, the C4B layer (plugin, config, sounds, Lua)
#   Microsoft      dotnet-runtime-10.0, which Debian does not carry
#
# The XCC needs nothing else at runtime: configuration, dialplan, directory and the
# sofia profiles all arrive from the XPhone server through the plugin in
# mod_managedcore, which the server reaches over the event socket on 8021.

FROM debian:bookworm

ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        ca-certificates wget dpkg-dev equivs gnupg procps iproute2 \
    && rm -rf /var/lib/apt/lists/*

# --- Microsoft repository, for dotnet-runtime-10.0 -------------------------------
RUN wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb \
        -O /tmp/ms-prod.deb \
    && dpkg -i /tmp/ms-prod.deb \
    && rm -f /tmp/ms-prod.deb

# --- our packages as a local repository -----------------------------------------
COPY debs /debs
RUN cd /debs \
    && dpkg-scanpackages -m . > Packages \
    && gzip -kf Packages \
    && printf 'deb [trusted=yes] file:/debs /\n' > /etc/apt/sources.list.d/local.list

# --- stand-ins for the two sound packages ---------------------------------------
# c4b-freeswitch-meta-all build-depends on freeswitch-music and freeswitch-sounds,
# which are virtual packages provided by FreeSWITCH's separately built sound
# packages. freeswitch-xcc-core carries its own 857 sound files under
# /usr/share/freeswitch/sounds, so pulling in the upstream ones would only add a
# second, unused set. Two empty packages satisfy the dependency honestly - they
# declare what they are.
RUN mkdir -p /tmp/equivs && cd /tmp/equivs \
    && for p in freeswitch-music freeswitch-sounds; do \
         printf 'Section: comm\nPriority: optional\nStandards-Version: 3.9.2\nPackage: %s\nVersion: 1.11.2-c4b-dev\nMaintainer: C4B dev container <root@localhost>\nArchitecture: all\nDescription: placeholder for %s\n Satisfies the dependency of c4b-freeswitch-meta-all. The sounds actually\n used come from freeswitch-xcc-core.\n' "$p" "$p" > "$p.ctl" \
         && equivs-build "$p.ctl" >/dev/null; \
       done \
    && dpkg -i /tmp/equivs/*.deb

# --- FreeSWITCH and the XCC layer ------------------------------------------------
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        dotnet-runtime-10.0 \
        c4b-freeswitch-meta-all \
    && rm -rf /var/lib/apt/lists/*

COPY xcc /xcc
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends /xcc/freeswitch-xcc-core.deb \
    && rm -rf /var/lib/apt/lists/* /xcc

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Event socket. SIP and RTP are not published here: with a bridge network they need
# -p on the run command, and with host networking they need nothing.
EXPOSE 8021/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
