m4_changequote([[, ]])

ARG STREAM_VERSION=10
ARG RUST_VERSION=1

##################################################
## "nss_synth-native" stage
##################################################

FROM --platform=${BUILDPLATFORM} docker.io/rust:${RUST_VERSION} AS nss_synth-native
ARG RUST_VERSION

ARG NSS_SYNTH_TREEISH=7c23049d6f576cede12d8217e710bcf9da0fc3d5 # v0.1.0
ARG NSS_SYNTH_REMOTE=https://github.com/kanidm/nss_synth.git
WORKDIR /tmp/nss_synth/
RUN git clone "${NSS_SYNTH_REMOTE:?}" ./
RUN git checkout "${NSS_SYNTH_TREEISH:?}"
RUN git submodule update --init --recursive
RUN cargo fetch --verbose

##################################################
## "nss_synth-cross" stage
##################################################

m4_ifdef([[CROSS_REGISTRY_ARCH]], [[FROM docker.io/CROSS_REGISTRY_ARCH/rust:${RUST_VERSION}]], [[FROM docker.io/rust:${RUST_VERSION}]]) AS nss_synth-cross
ARG RUST_VERSION

WORKDIR /tmp/nss_synth/
COPY --from=nss_synth-native ${CARGO_HOME}/registry/ ${CARGO_HOME}/registry/
COPY --from=nss_synth-native /tmp/nss_synth/ ./
RUN cargo build --verbose --offline --release

##################################################
## "rootfs" stage
##################################################

FROM --platform=${BUILDPLATFORM} quay.io/centos/centos:stream${STREAM_VERSION} AS rootfs
ARG STREAM_VERSION

WORKDIR /mnt/rootfs/

# Install packages in rootfs
RUN dnf -y \
	--installroot "${PWD:?}" \
	--releasever "${STREAM_VERSION:?}" \
	--setopt install_weak_deps=false \
	--nodocs \
	m4_ifdef([[CROSS_DNF_ARCH]], [[--forcearch CROSS_DNF_ARCH]]) install \
		389-ds-base \
		authselect-libs \
		ca-certificates \
		coreutils-single \
		glibc-minimal-langpack \
		openldap-clients \
		tzdata \
	&& dnf --installroot "${PWD:?}" clean all

# Install nss_synth to support arbitrary UIDs and GIDs
COPY --from=nss_synth-cross /tmp/nss_synth/target/release/libnss_synth.so ./usr/lib64/libnss_synth.so.2
RUN sed -i 's/^\(passwd\|group\):.*$/\1: compat synth/;s/^\(shadow\):.*$/\1: compat/' ./etc/authselect/nsswitch.conf

# Patch instance setup script to use DS_STARTUP_TIMEOUT environment variable if available
RUN sed -ri 's|(timeout)=([0-9]+)|\1=int(os.getenv("DS_STARTUP_TIMEOUT", \2))|g' ./usr/lib/python*/site-packages/lib389/instance/setup.py

# Prepare data directory
RUN mkdir -p ./data/ ./etc/dirsrv/ ./var/run/
RUN ln -s /data/config/ ./etc/dirsrv/slapd-localhost
RUN ln -s /data/ssca/ ./etc/dirsrv/ssca
RUN ln -s /data/run/ ./var/run/dirsrv
RUN chmod -R 0777 ./data/

# Clean rootfs
RUN rm -rf ./dev/* ./tmp/* ./var/cache/* ./var/lib/dnf/* ./var/log/*

##################################################
## "main" stage
##################################################

m4_ifdef([[CROSS_REGISTRY_ARCH]], [[FROM docker.io/hectorm/scratch:CROSS_REGISTRY_ARCH]], [[FROM scratch]]) AS main

COPY --from=rootfs /mnt/rootfs/ /

# ENV DS_SUFFIX_NAME=dc=example,dc=com
# ENV DS_DM_PASSWORD=password
# ENV DS_STARTUP_TIMEOUT=60
# ENV DS_ERRORLOG_LEVEL=266354688
# ENV DS_REINDEX=1

EXPOSE 3389/tcp 3636/tcp

HEALTHCHECK --start-period=5m --timeout=5s --interval=5s --retries=2 \
	CMD ["/usr/libexec/dirsrv/dscontainer", "--healthcheck"]

CMD ["/usr/libexec/dirsrv/dscontainer", "--runit"]

USER 10389:10389
RUN --mount=type=tmpfs,target=/data/ --mount=type=tmpfs,target=/tmp/ \
	set -eu \
	&& { printf '%s\n' '========== START OF TEST RUN =========='; set -x; } \
	&& export DS_SUFFIX_NAME=dc=dirsrv,dc=test \
	&& export DS_DM_PASSWORD=H4!b5at+kWls-8yh4Guq \
	&& export DS_STARTUP_TIMEOUT=900 \
	&& export LDAPTLS_REQCERT=demand \
	&& export LDAPTLS_CACERT=/data/config/Self-Signed-CA.pem \
	&& { /usr/libexec/dirsrv/dscontainer --runit & } \
	&& timeout 900 sh -euc 'until /usr/libexec/dirsrv/dscontainer --healthcheck; do sleep 1; done' \
	&& timeout 300 sh -euc 'until dsconf localhost monitor server; do sleep 1; done; sleep 5' \
	&& dsconf localhost backend create --suffix "${DS_SUFFIX_NAME:?}" --be-name 'userRoot' --create-suffix --create-entries \
	&& dsconf localhost config replace 'nsslapd-dynamic-plugins=on' \
	&& dsconf localhost plugin attr-uniq add 'UID and GID uniqueness' \
		--attr-name 'uidNumber' 'gidNumber' \
		--subtree "${DS_SUFFIX_NAME:?}" \
	&& dsconf localhost plugin attr-uniq enable 'UID and GID uniqueness' \
	&& dsconf localhost plugin dna config 'UID and GID autoincrement' add \
		--type 'uidNumber' 'gidNumber' \
		--filter '(|(objectClass=posixAccount)(objectClass=posixGroup))' \
		--magic-regen '-1' \
		--next-value '50000' \
		--scope "${DS_SUFFIX_NAME:?}" \
	&& dsconf localhost plugin dna enable \
	&& for u in 'alice' 'bob' 'carol'; do \
		dsidm -b "${DS_SUFFIX_NAME:?}" localhost user create --uid "${u:?}" --cn "${u:?}" --displayName "${u:?}" --uidNumber '-1' --gidNumber '-1' --homeDirectory '/' \
		&& dsidm -b "${DS_SUFFIX_NAME:?}" localhost account reset_password "uid=${u:?},ou=people,${DS_SUFFIX_NAME:?}" 'password' \
		&& ldapwhoami -x -H 'ldaps://localhost:3636' -D "uid=${u:?},ou=people,${DS_SUFFIX_NAME:?}" -w 'password'; \
	done \
	&& { set +x; printf '%s\n' '========== END OF TEST RUN =========='; }
USER 0:0
