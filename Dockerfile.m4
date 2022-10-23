m4_changequote([[, ]])

##################################################
## "rootfs" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM docker.io/CROSS_ARCH/fedora:37]], [[FROM docker.io/fedora:37]]) AS rootfs
m4_ifdef([[CROSS_QEMU]], [[COPY --from=docker.io/hectorm/qemu-user-static:latest CROSS_QEMU CROSS_QEMU]])

RUN dnf -y install \
		ca-certificates \
		cargo \
		findutils \
		git \
		rust \
	&& dnf clean all

# Build nss_synth
ARG NSS_SYNTH_TREEISH=v0.1.0
ARG NSS_SYNTH_REMOTE=https://github.com/kanidm/nss_synth.git
RUN mkdir /tmp/nss_synth/
WORKDIR /tmp/nss_synth/
RUN git clone "${NSS_SYNTH_REMOTE:?}" ./
RUN git checkout "${NSS_SYNTH_TREEISH:?}"
RUN git submodule update --init --recursive
RUN cargo build --release

# Create rootfs
RUN mkdir /mnt/rootfs/
WORKDIR /mnt/rootfs/
RUN RELEASEVER=$(awk -F= '$1=="VERSION_ID"{print($2)}' /etc/os-release) \
	&& dnf -y --installroot "${PWD:?}" --releasever "${RELEASEVER:?}" --setopt 'install_weak_deps=false' --nodocs install \
		389-ds-base \
		ca-certificates \
		coreutils-single \
		glibc-minimal-langpack \
		openldap-clients \
		tzdata \
	&& dnf --installroot "${PWD:?}" clean all
RUN cp /tmp/nss_synth/target/release/libnss_synth.so "${PWD:?}"/usr/lib64/libnss_synth.so.2
RUN sed -i 's/^\(passwd\|group\):.*$/\1: compat synth/;s|^\(shadow\):.*$|\1: compat|' "${PWD:?}"/etc/nsswitch.conf
RUN mkdir -p "${PWD:?}"/data/ "${PWD:?}"/etc/dirsrv/ "${PWD:?}"/var/run/
RUN ln -s /data/config/ "${PWD:?}"/etc/dirsrv/slapd-localhost
RUN ln -s /data/ssca/ "${PWD:?}"/etc/dirsrv/ssca
RUN ln -s /data/run/ "${PWD:?}"/var/run/dirsrv
RUN find "${PWD:?}"/data/ "${PWD:?}"/etc/dirsrv/ -type d -exec chmod 0777 '{}' ';'
RUN find "${PWD:?}"/data/ "${PWD:?}"/etc/dirsrv/ -type f -exec chmod 0666 '{}' ';'
RUN find "${PWD:?}"/var/cache/ "${PWD:?}"/var/log/ "${PWD:?}"/tmp/ -mindepth 1 -delete

##################################################
## "base" stage
##################################################

FROM scratch AS base

COPY --from=rootfs /mnt/rootfs/ /

# ENV DS_DM_PASSWORD=password
# ENV DS_SUFFIX_NAME=dc=example,dc=com
# ENV DS_STARTUP_TIMEOUT=60
# ENV DS_ERRORLOG_LEVEL=266354688
# ENV DS_REINDEX=1

EXPOSE 3389/tcp 3636/tcp

HEALTHCHECK --start-period=5m --timeout=5s --interval=5s --retries=2 \
	CMD ["/usr/libexec/dirsrv/dscontainer", "--healthcheck"]

ENTRYPOINT ["/usr/libexec/dirsrv/dscontainer"]
CMD ["--runit"]

##################################################
## "test" stage
##################################################

FROM base AS test
m4_ifdef([[CROSS_QEMU]], [[COPY --from=docker.io/hectorm/qemu-user-static:latest CROSS_QEMU CROSS_QEMU]])

# Switch to unprivileged user
RUN chown -R 3389:3389 /data/
USER 3389:3389

# Run tests
ENV DS_DM_PASSWORD=H4!b5at+kWls-8yh4Guq
ENV DS_SUFFIX_NAME=dc=dirsrv,dc=test
ENV DS_STARTUP_TIMEOUT=600
ENV LDAPTLS_REQCERT=demand
ENV LDAPTLS_CACERT=/data/config/Self-Signed-CA.pem
RUN { /usr/libexec/dirsrv/dscontainer --runit & } \
	&& timeout 600 sh -euc 'until /usr/libexec/dirsrv/dscontainer --healthcheck; do sleep 1; done' \
	&& timeout 300 sh -euc 'until ldapwhoami -x -H "ldaps://localhost:3636" -D "cn=Directory Manager" -w "${DS_DM_PASSWORD:?}"; do sleep 1; done' \
	&& dsconf localhost backend create --suffix "${DS_SUFFIX_NAME:?}" --be-name 'userRoot' \
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
	&& dsidm localhost initialise \
	&& for u in 'alice' 'bob' 'carol'; do \
		dsidm localhost user create --uid "${u:?}" --cn "${u:?}" --displayName "${u:?}" --uidNumber '-1' --gidNumber '-1' --homeDirectory '/' \
		&& dsidm localhost account reset_password "uid=${u:?},ou=people,${DS_SUFFIX_NAME:?}" 'password' \
		&& ldapwhoami -x -H 'ldaps://localhost:3636' -D "uid=${u:?},ou=people,${DS_SUFFIX_NAME:?}" -w 'password'; \
	done

##################################################
## "main" stage
##################################################

FROM base AS main

# Dummy instruction so BuildKit does not skip the test stage
RUN --mount=type=bind,from=test,source=/mnt/,target=/mnt/
