#!/bin/sh

set -eu

_dsconf() { dsconf -D 'cn=Directory Manager' -w "${DS_DM_PASSWORD:?}" "${DS_URI:?}" "$@"; }
_dsidm() { dsidm -D 'cn=Directory Manager' -w "${DS_DM_PASSWORD:?}" -b "${DS_SUFFIX_NAME:?}" "${DS_URI:?}" "$@"; }

# Wait until LDAP server is available
until _dsconf monitor server; do sleep 1; done

# Ensure that the backend is initialized
if ! _dsconf backend suffix get "${DS_SUFFIX_NAME:?}" >/dev/null 2>&1; then
	# Create backend
	_dsconf backend create --suffix "${DS_SUFFIX_NAME:?}" --be-name 'userRoot'

	# Disable anonymous access
	_dsconf config replace 'nsslapd-allow-anonymous-access=off'

	# Require TLS
	#_dsconf config replace 'nsslapd-require-secure-binds=on'

	# Enable dynamic plugins
	_dsconf config replace 'nsslapd-dynamic-plugins=on'

	# Enable Referential Integrity Postoperation plugin
	_dsconf plugin referential-integrity enable

	# Enable MemberOf plugin
	_dsconf plugin memberof enable

	# Enable Attribute Uniqueness plugin
	_dsconf plugin attr-uniq add 'UID and GID uniqueness' \
		--attr-name 'uidNumber' 'gidNumber' \
		--subtree "${DS_SUFFIX_NAME:?}"
	_dsconf plugin attr-uniq enable 'UID and GID uniqueness'

	# Enable Distributed Numeric Assignment plugin
	_dsconf plugin dna config 'UID and GID autoincrement' add \
		--type 'uidNumber' 'gidNumber' \
		--filter '(|(objectClass=posixAccount)(objectClass=posixGroup))' \
		--magic-regen '-1' \
		--next-value '50000' \
		--scope "${DS_SUFFIX_NAME:?}"
	_dsconf plugin dna enable

	# Initialise domain
	_dsidm initialise

	# Remove sample data
	yes 'Yes I am sure' | _dsidm user delete "uid=demo_user,ou=people,${DS_SUFFIX_NAME:?}"
	yes 'Yes I am sure' | _dsidm group delete "cn=demo_group,ou=groups,${DS_SUFFIX_NAME:?}"

	# Create users
	_IFS=${IFS}; IFS=$(printf '\nx'); IFS=${IFS%x}
	for entry in ${DS_INITIAL_USERS?}; do
		for var in user firstname lastname password; do
			eval ${var:?}='${entry%%:*}'; entry=${entry#*:}
		done
		_dsidm user create \
			--uid "${user:?}" \
			--cn "${firstname:?} ${lastname:?}" \
			--displayName "${firstname:?} ${lastname:?}" \
			--uidNumber '-1' --gidNumber '-1' --homeDirectory "/home/${user:?}"
		_dsidm account reset_password "uid=${user:?},ou=people,${DS_SUFFIX_NAME:?}" "${password:?}"
	done
	IFS=$_IFS

	# Create groups
	_IFS=${IFS}; IFS=$(printf '\nx'); IFS=${IFS%x}
	for entry in ${DS_INITIAL_GROUPS?}; do
		for var in group users; do
			eval ${var:?}='${entry%%:*}'; entry=${entry#*:}
		done
		_dsidm group create --cn "${group:?}"
		__IFS=${IFS}; IFS=','
		for user in ${users?}; do
			_dsidm group add_member "${group:?}" "uid=${user:?},ou=people,${DS_SUFFIX_NAME:?}"
		done
		IFS=$__IFS
	done
	IFS=$_IFS
fi
