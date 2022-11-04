#!/bin/sh

set -eu
export LC_ALL='C'

CERTS_DIR="$(CDPATH='' cd -- "$(dirname -- "${0:?}")" && pwd -P)"/certs/

mkdir -p "${CERTS_DIR:?}"/ca/
CA_KEY="${CERTS_DIR:?}"/ca/key.pem
CA_SRL="${CERTS_DIR:?}"/ca/cert.srl
CA_CRT="${CERTS_DIR:?}"/ca/cert.pem
CA_CRT_CN='389ds'
CA_CRT_VALIDITY_DAYS='7300'
CA_CRT_RENOVATION_DAYS='365'
CA_CRT_RENEW_PREHOOK=''
CA_CRT_RENEW_POSTHOOK=''

mkdir -p "${CERTS_DIR:?}"/server/
SERVER_KEY="${CERTS_DIR:?}"/server/key.pem
SERVER_CSR="${CERTS_DIR:?}"/server/csr.pem
SERVER_CRT="${CERTS_DIR:?}"/server/cert.pem
SERVER_CRT_OPENSSL_CNF="${CERTS_DIR:?}"/server/openssl.cnf
SERVER_CRT_CN='389ds'
SERVER_CRT_VALIDITY_DAYS='90'
SERVER_CRT_RENOVATION_DAYS='30'
SERVER_CRT_RENEW_PREHOOK=''
SERVER_CRT_RENEW_POSTHOOK=''

# Generate CA private key if it does not exist
if [ ! -e "${CA_KEY:?}" ] \
	|| ! openssl ecparam -check -in "${CA_KEY:?}" -noout >/dev/null 2>&1
then
	printf '%s\n' 'Generating CA private key...'
	openssl ecparam -genkey -name prime256v1 -out "${CA_KEY:?}"
	rm -f "${CA_CRT:?}"
fi

# Generate CA certificate if it does not exist or will expire soon
if [ ! -e "${CA_CRT:?}" ] \
	|| ! openssl x509 -checkend "$((60*60*24*CA_CRT_RENOVATION_DAYS))" -in "${CA_CRT:?}" -noout >/dev/null 2>&1
then
	if [ -n "${CA_CRT_RENEW_PREHOOK?}" ]; then
		sh -euc "${CA_CRT_RENEW_PREHOOK:?}"
	fi

	printf '%s\n' 'Generating CA certificate...'
	openssl req -new \
		-key "${CA_KEY:?}" \
		-out "${CA_CRT:?}" \
		-subj "/CN=${CA_CRT_CN:?}:CA" \
		-x509 \
		-days "${CA_CRT_VALIDITY_DAYS:?}"
	rm -f "${SERVER_CRT:?}"

	if [ -n "${CA_CRT_RENEW_POSTHOOK?}" ]; then
		sh -euc "${CA_CRT_RENEW_POSTHOOK:?}"
	fi
fi

# Generate server private key if it does not exist
if [ ! -e "${SERVER_KEY:?}" ] \
	|| ! openssl ecparam -check -in "${SERVER_KEY:?}" -noout >/dev/null 2>&1
then
	printf '%s\n' 'Generating server private key...'
	openssl ecparam -genkey -name prime256v1 -out "${SERVER_KEY:?}"
	rm -f "${SERVER_CRT:?}"
fi

# Generate server certificate if it does not exist or will expire soon
if [ ! -e "${SERVER_CRT:?}" ] \
	|| ! openssl verify -CAfile "${CA_CRT:?}" "${SERVER_CRT:?}" >/dev/null 2>&1 \
	|| ! openssl x509 -checkend "$((60*60*24*SERVER_CRT_RENOVATION_DAYS))" -in "${SERVER_CRT:?}" -noout >/dev/null 2>&1
then
	if [ -n "${SERVER_CRT_RENEW_PREHOOK?}" ]; then
		sh -euc "${SERVER_CRT_RENEW_PREHOOK:?}"
	fi

	printf '%s\n' 'Generating server certificate...'
	openssl req -new \
		-key "${SERVER_KEY:?}" \
		-out "${SERVER_CSR:?}" \
		-subj "/CN=${SERVER_CRT_CN:?}:Server"
	cat > "${SERVER_CRT_OPENSSL_CNF:?}" <<-EOF
		[ x509_exts ]
		subjectAltName = DNS:${SERVER_CRT_CN:?},DNS:localhost,IP:127.0.0.1,IP:::1
	EOF
	openssl x509 -req \
		-in "${SERVER_CSR:?}" \
		-out "${SERVER_CRT:?}" \
		-CA "${CA_CRT:?}" \
		-CAkey "${CA_KEY:?}" \
		-CAserial "${CA_SRL:?}" -CAcreateserial \
		-days "${SERVER_CRT_VALIDITY_DAYS:?}" \
		-extfile "${SERVER_CRT_OPENSSL_CNF:?}" \
		-extensions x509_exts \
		2>/dev/null
	cat "${CA_CRT:?}" >> "${SERVER_CRT:?}"
	openssl x509 -in "${SERVER_CRT:?}" -fingerprint -noout

	if [ -n "${SERVER_CRT_RENEW_POSTHOOK?}" ]; then
		sh -euc "${SERVER_CRT_RENEW_POSTHOOK:?}"
	fi
fi
