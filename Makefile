SHELL := /bin/bash
PWD:=$(shell pwd)

# Test setup
DOCKER_IMAGE=https-localcert:dev-latest
DOCKER_CONTAINER_NAME=https-localcert

# Common subject
SUBJECT=/C=DE/ST=Bavaria/L=Munich/O=BigAssCorporate/OU=Development

# Root cert
ROOT_CA_NAME=localhost
ROOT_CA_PASSWORD=letmein
ROOT_CA_EXPIRE_DAYS=3654
ROOT_CA_SUBJECT=$(SUBJECT)/CN=$(ROOT_CA_NAME)

# Server cert
# CERT_NAME should be the domain name requires at least "hostname.tld"! Use only FQDN in browser!
CERT_NAME=dev.localhost
CERT_ALT_DOMAINS=$(CERT_NAME) \*.$(CERT_NAME) \*.localhost localhost sub.localhost
CERT_ALT_IPS=127.0.0.1 ::1
CERT_EXPIRE_DAYS=265
CERT_SUBJECT=$(SUBJECT)/CN=$(CERT_NAME)

# Domains to test
TEST_DOMAINS=$(CERT_NAME) www.dev.localhost sub.dev.localhost localhost
TEST_IPS=$(CERT_ALT_IPS)

CONTAINER_OPTS=--name $(DOCKER_CONTAINER_NAME) -p 80:80 -p 443:443 -v $$(pwd)/nginx/conf.d/:/etc/nginx/conf.d/ -v $$(pwd)/nginx/cert:/nginx/cert/ $(DOCKER_IMAGE)

# ecc | rsa
ALGORITHM=ecc

# 
ECC_CURVE=prime256v1

help:
	make -qp | awk -F":" "/^[a-zA-Z0-9][^$$#\/\t=]*:([^=]|$$)/ {split(\$$1,A,/ /);for(i in A)print A[i]}" | sort

##
# Cleanup

clean-root-ca:
	rm -fr root-ca/*

clean-cert:
	rm -fr cert/*

clean: clean-container clean-root-ca clean-cert 

##
# docker 

build-docker-image: -generate-dhparams
	docker build -t $(DOCKER_IMAGE) .

clean-container:
	if docker ps -a --format '{{.Names}}' | grep -q "^$(DOCKER_CONTAINER_NAME)$$"; then docker rm -f "$(DOCKER_CONTAINER_NAME)"; fi;

-prepare-container-config: 
	cp -v cert/$(CERT_NAME).pem  nginx/cert/$(CERT_NAME).pem
	cp -v cert/$(CERT_NAME).key  nginx/cert/$(CERT_NAME).key
	rm -f nginx/conf.d/*
	export CERT_NAME=$(CERT_NAME) SERVERNAME=\*.$(ROOT_CA_NAME) && cat nginx/templ/vhost.conf.templ | envsubst '$$SERVERNAME$$CERT_NAME' > nginx/conf.d/$(CERT_NAME).conf
 
run-container-deamon: clean-container -prepare-container-config
	docker run -it -d $(CONTAINER_OPTS)


run-container-attached: clean-container -prepare-container-config
	docker run -it --rm $(CONTAINER_OPTS)

-generate-dhparams:
	if [[ ! -e "nginx/cert/dhparam.pem" ]]; then \
		openssl dhparam -out nginx/cert/dhparam.pem 2048; \
	fi;

-wait-http-ready:
	while ! nc -z localhost 443; do  \
  		sleep 0.1; \
	done

test-container-https: run-container-deamon -wait-http-ready test-https-requests
	docker logs $(DOCKER_CONTAINER_NAME)
	$(MAKE) clean-container

log-container:
	docker logs -f $(DOCKER_CONTAINER_NAME)

shell-container:
	docker exec -it $(DOCKER_CONTAINER_NAME) /bin/ash
	# /etc/nginx/nginx.conf -t -c /etc/nginx/nginx.conf

##
# Tests

test-https-requests:
	@for domain in $(TEST_DOMAINS) $(TEST_IPS); do\
		if [[ "$${domain}" =~ ^:: ]]; then domain="[$${domain}]"; fi; \
		curl -sS  -l https://$${domain} 1>/dev/null && echo SUCCESS $${domain} || >&2 echo FAIL $${domain}; \
	done

##
# certificates

list-ecc-curves:	
	openssl ecparam -list_curves

-generate-cert-key-ecc:
	if [[ ! -e "$(PREFIX).ecc" ]]; then \
		openssl ecparam -name $(ECC_CURVE) -out $(PREFIX).ecc; \
	fi
	if [[ ! -e "$(PREFIX).key" ]]; then \
		openssl ecparam -in $(PREFIX).ecc -genkey -noout -out $(PREFIX).key; \
	fi

-generate-cert-key-rsa:
	if [[ ! -e "$(PREFIX).key" ]]; then \
		openssl genrsa -out $(PREFIX).key 2048; \
	fi
	

generate-root-ca:
	# generate key
	$(MAKE) -- -generate-cert-key-$(ALGORITHM) PREFIX=root-ca/$(ROOT_CA_NAME)

	# generate the root CA file
	if [[ ! -e "root-ca/$(ROOT_CA_NAME).pem" ]]; then \
		openssl req -x509 -new -nodes -key root-ca/$(ROOT_CA_NAME).key -sha256 -days $(ROOT_CA_EXPIRE_DAYS) -out root-ca/$(ROOT_CA_NAME).pem \
       	-passin pass:"${ROOT_CA_PASSWORD}" -subj "$(ROOT_CA_SUBJECT)"; \
	fi

	# convert
	openssl x509 -in root-ca/$(ROOT_CA_NAME).pem -out root-ca/$(ROOT_CA_NAME).crt -inform PEM; \


generate-cert:
	# generate key
	$(MAKE) -- -generate-cert-key-$(ALGORITHM) PREFIX=cert/$(CERT_NAME)

	# generate the certificate signing request (CSR)
	if [[ ! -e "cert/$(CERT_NAME).csr" ]]; then \
		openssl req -new -key cert/$(CERT_NAME).key -out cert/$(CERT_NAME).csr -subj "$(CERT_SUBJECT)"; \
	fi;

	# create a configuration file for extensions (primarily for subjectAltName)
	echo 'authorityKeyIdentifier=keyid,issuer' > cert/$(CERT_NAME).conf
	echo 'basicConstraints=CA:FALSE' >> cert/$(CERT_NAME).conf
	echo 'keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment' >> cert/$(CERT_NAME).conf
	echo 'subjectAltName = @alt_names' >> cert/$(CERT_NAME).conf
	echo '[alt_names]' >> cert/$(CERT_NAME).conf
	i=0; for domain in $(CERT_ALT_DOMAINS); do\
		let i++; \
		echo "DNS.$${i} = $${domain}" >> cert/$(CERT_NAME).conf; \
	done
	i=0; for ip in $(CERT_ALT_IPS); do\
		let i++; \
		echo "IP.$${i} = $${ip}" >> cert/$(CERT_NAME).conf; \
	done

	# generate the server certificate
	openssl x509 -req -in cert/$(CERT_NAME).csr -CA root-ca/$(ROOT_CA_NAME).pem -CAkey root-ca/$(ROOT_CA_NAME).key \
		-CAcreateserial -out cert/$(CERT_NAME).crt -days $(CERT_EXPIRE_DAYS) -sha256 \
		-passin pass:"${ROOT_CA_PASSWORD}" -extfile cert/$(CERT_NAME).conf

    # connvert 
	openssl x509 -in cert/$(CERT_NAME).crt -out cert/$(CERT_NAME).pem -outform PEM

show-root-ca:
	openssl x509 -noout -text -in root-ca/$(ROOT_CA_NAME).crt

show-cert:
	openssl x509 -noout -text -in cert/$(CERT_NAME).crt

show-cert-ecc:
	openssl ecparam -in root-ca/$(ROOT_CA_NAME).ecc -text -noout

show-root-ca-ecc:
	openssl ecparam -in cert/$(CERT_NAME).ecc -text -noout

##
# install

install-root-ca:
	if grep -q Microsoft /proc/version; then \
		$(MAKE) -- -install-root-ca-wsl; \
	else \
		case "$$OSTYPE" in\
			linux*)   $(MAKE) -- -install-root-ca-linux;;\
			darwin*)  $(MAKE) -- -install-root-ca-unix;;\
			win*)     $(MAKE) -- -install-root-ca-windows;;\
			msys*)    $(MAKE) -- -install-root-ca-windows;;\
			cygwin*)  $(MAKE) -- -install-root-ca-windows;;\
			bsd*)     $(MAKE) -- -install-root-ca-unix;;\
			solaris*) $(MAKE) -- -install-root-ca-unix;;\
			*)        >&2 echo OS Could not be determined; exit 2;;\
		esac;\
	fi

-install-root-ca-unix:
	sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root-ca/$(ROOT_CA_NAME).crt

-install-root-ca-windows:
	certutil -addstore "Root" root-ca\\$(ROOT_CA_NAME).crt

-install-root-ca-wsl:
	cmd.exe /c "certutil -addstore \"Root\" root-ca\\$(ROOT_CA_NAME).crt"

-install-root-ca-linux: 
	sudo cp -v root-ca/$(ROOT_CA_NAME).crt /usr/local/share/ca-certificates/$(ROOT_CA_NAME).crt
	sudo update-ca-certificates --fresh
	# NSS_DEFAULT_DB_TYPE should default to SQL
	cat root-ca/$(ROOT_CA_NAME).pem 2>&1 | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' \
		| certutil -d sql:$$HOME/.pki/nssdb -A -t "TCu,Cu,Tu" -n "$(ROOT_CA_NAME)"

##
# Util

recreate-nssdb:
	rm -fr ~/.pki/nssdb || true
	mkdir -p ~/.pki/nssdb || true
	certutil -N -d sql:$$HOME/.pki/nssdb --empty-password

install-cert-by-https:
	./bin/import-cert $(CERT_NAME) 443

open-chrome-settings:
	xdg-open chrome://settings/certificates