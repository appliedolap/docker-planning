# syntax=docker/dockerfile:1.7
#
# Hyperion Planning 11.2.26 on Oracle Linux 8, for use with SQL Server (see compose.yml).
#
# Oracle has no 11.2.26 installer, only an update: a new install is the 11.2.15 base
# installer followed by the 11.2.26 ApplyUpdate, and configuration comes after both.
# So this image installs and patches at build time, and the container configures
# itself against SQL Server on first start (container/entrypoint.sh).
#
# The media is never copied into a layer. It comes in through a named build context
# (compose.yml points "media" at ./media) and is bind-mounted only for the RUN steps
# that need it. ./media is one flat folder of Oracle's downloads under their own names;
# a manifest per step says which files it uses, and each step checks them first:
#
#   media/epm-11.2.15-linux.sha256         the 11.2.15 Linux parts 1-6
#   media/epm-11.2.26-update-linux.sha256  the 11.2.26 update
#
# media/.dockerignore lets only those files into the build context.
#
# Targets:
#   planning          the runnable image (default)
#   installed         just the 11.2.15 base install (about 40 minutes under Rosetta)
#   install-recorder  base OS + VNC, for recording installTool.sh -record
#   config-recorder   the planning image + VNC, for recording configtool.sh -record
#                     (build planning first; compose builds this on top of its tag)
#
# The install (about 40 minutes) and the update (about 40 more) easily outlive
# Docker's build cache: its default 20 GB cap holds less than the media (18 GB) and the
# install together. Two build args let either be supplied as an already-built image
# instead:
#
#   INSTALLED_IMAGE  an image of the installed target (11.2.15, unpatched); the update
#                    then starts from it
#   PATCHED_IMAGE    any image whose /u01/oracle is installed and patched to 11.2.26
#                    (a previous planning image will do); the planning stage then
#                    copies from it and only the container scripts are rebuilt
#
#   docker buildx build --platform linux/amd64 --build-context media=./media \
#       --target installed -t hyperion-planning:installed-11.2.15 --load .
#   INSTALLED_IMAGE=hyperion-planning:installed-11.2.15 docker compose build planning
#   docker tag hyperion-planning:11.2.26 hyperion-planning:patched-11.2.26
#   PATCHED_IMAGE=hyperion-planning:patched-11.2.26 docker compose build planning
#
# x86-64 only. On Apple Silicon this builds and runs under Rosetta.

ARG BASE_IMAGE=oraclelinux:8
ARG INSTALLED_IMAGE=installed
ARG PATCHED_IMAGE=install
ARG PLANNING_IMAGE=planning

FROM ${BASE_IMAGE} AS base

# Package list: Oracle defers EPM's Linux prerequisites to the FMW 12.2.1.4 system
# requirements. motif-devel lives in the CodeReady Builder repo on OL8. The X libraries
# and fonts are there because the InstallShield installer and the configurator are
# Swing applications and load AWT even when run silently; Xvfb gives them a display.
RUN dnf -y install dnf-plugins-core && \
    dnf config-manager --enable ol8_codeready_builder && \
    dnf -y install \
        binutils gcc gcc-c++ glibc glibc-devel libaio libaio-devel libgcc libstdc++ \
        libstdc++-devel libnsl sysstat motif motif-devel redhat-lsb-core openssl make \
        xorg-x11-utils xorg-x11-server-Xvfb libXext libXrender libXtst libXi \
        fontconfig dejavu-sans-fonts \
        unzip tar which hostname procps-ng findutils lsof net-tools numactl file && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# A non-root install user is mandatory, and it must be the same user for install,
# configuration and patching. The central inventory pointer is written as root here
# because the installer can't create /etc/oraInst.loc itself.
ARG ORACLE_UID=54321
ARG ORACLE_GID=54321
#
# /tmp/.X11-unix is created here too: X servers (Xvfb, Xvnc) running as oracle can't
# create it themselves.
RUN groupadd -g ${ORACLE_GID} oinstall && \
    useradd -u ${ORACLE_UID} -g oinstall -m oracle && \
    mkdir -p /u01/oracle/oraInventory && \
    chown -R oracle:oinstall /u01 && \
    printf 'inventory_loc=/u01/oracle/oraInventory\ninst_group=oinstall\n' > /etc/oraInst.loc && \
    chmod 644 /etc/oraInst.loc && \
    mkdir -p /tmp/.X11-unix && \
    chmod 1777 /tmp/.X11-unix

# Everything EPM writes lives under /u01/oracle, so compose can put the whole tree on
# one named volume and a recreated container keeps its configuration.
ENV ORACLE_ROOT=/u01/oracle \
    MW_HOME=/u01/oracle/Middleware \
    EPM_ORACLE_HOME=/u01/oracle/Middleware/EPMSystem11R1 \
    EPM_ORACLE_INSTANCE=/u01/oracle/Middleware/user_projects/epmsystem1 \
    ESSBASE_DOMAIN_HOME=/u01/oracle/Middleware/user_projects/domains/essbase_domain \
    EPM_DOMAIN_HOME=/u01/oracle/Middleware/user_projects/domains/EPMSystem


# The 11.2.15 base install on its own, as a target, so the 11.2.26 update can be worked
# on without repeating a 40-minute install.
FROM base AS installed

WORKDIR /home/oracle
COPY --chown=oracle:oinstall build/install-epm.sh build/install-response.xml build/check-media.sh \
    /home/oracle/build/

# The media steps start as root, because BuildKit makes root the owner of the media
# while keeping its modes, and files copied by some sync tools are owner-only. The scripts
# extract as root, hand the files to oracle, and run Oracle's tools as oracle.
USER root

RUN --mount=type=bind,from=media,target=/media \
    MEDIA=/media MANIFEST=epm-11.2.15-linux.sha256 /home/oracle/build/install-epm.sh


# INSTALLED_IMAGE is the installed stage above unless a tagged copy is passed in.
FROM ${INSTALLED_IMAGE} AS install

USER root
# check-media.sh again: an INSTALLED_IMAGE built before it existed doesn't have it.
COPY --chown=oracle:oinstall build/apply-update.sh build/check-media.sh /home/oracle/build/

# 11.2.26 update, then cleanup of what only a rollback would need.
RUN --mount=type=bind,from=media,target=/media \
    MEDIA=/media MANIFEST=epm-11.2.26-update-linux.sha256 /home/oracle/build/apply-update.sh


FROM base AS vnc-tools

# A browser-served X desktop (noVNC on 6080) for running Oracle's GUI tools. Recorder
# targets only; never the runtime image.
USER root
COPY --chown=oracle:oinstall recorder/ /home/oracle/recorder/
RUN /home/oracle/recorder/install-vnc-tools.sh
USER oracle
WORKDIR /home/oracle
EXPOSE 6080
CMD ["/home/oracle/recorder/start-vnc.sh"]


# Mount the media at /media when running this, then run installTool.sh -record from a
# terminal in the VNC session (see recorder/README.md).
FROM vnc-tools AS install-recorder


# PATCHED_IMAGE is the install stage above unless a built image's tag is passed in.
FROM ${PATCHED_IMAGE} AS patched


FROM base AS planning

LABEL org.opencontainers.image.title="Hyperion Planning 11.2.26" \
      org.opencontainers.image.description="EPM System 11.2.26: Foundation, Calculation Manager, Essbase 21c and Planning"

COPY --from=patched --chown=oracle:oinstall /u01/oracle /u01/oracle
COPY --chown=oracle:oinstall container/ /home/oracle/container/

USER oracle
WORKDIR /home/oracle

# 7001 EPM WebLogic admin, 9000 EPMServer0 (Workspace, Shared Services, Planning,
# Calculation Manager), 7010 Essbase domain admin, 9010 Essbase managed server
# (/essbase: Smart View, JAPI, XMLA, REST), 9110 EAS Lite, 1423 Essbase agent.
# The Essbase application ports (31768-32768) are not exposed; see compose.yml.
EXPOSE 7001 9000 7010 9010 9110 1423

HEALTHCHECK --start-period=90m --interval=60s --timeout=30s --retries=5 \
    CMD ["/home/oracle/container/healthcheck.sh"]

CMD ["/home/oracle/container/entrypoint.sh"]


# The runtime image plus the recorder desktop, for recording configtool.sh -record.
# PLANNING_IMAGE is the planning stage above unless a built image's tag is passed in;
# compose passes the tag, so this never re-runs the install or the update.
FROM ${PLANNING_IMAGE} AS config-recorder
USER root
COPY --chown=oracle:oinstall recorder/ /home/oracle/recorder/
RUN /home/oracle/recorder/install-vnc-tools.sh
USER oracle
WORKDIR /home/oracle
EXPOSE 6080
HEALTHCHECK NONE
CMD ["/home/oracle/recorder/start-vnc.sh"]
