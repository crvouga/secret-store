FROM quay.io/openbao/openbao:latest

USER root

COPY config/openbao.hcl /etc/openbao/openbao.hcl
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER openbao

EXPOSE 8200

ENTRYPOINT ["docker-entrypoint.sh"]
