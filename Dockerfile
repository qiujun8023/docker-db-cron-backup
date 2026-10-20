# syntax=docker/dockerfile:1.7

FROM amazon/aws-cli:2.36.46 AS aws-cli

FROM busybox:1.37.0-musl AS busybox

FROM scratch AS tools
COPY --from=aws-cli /usr/local/aws-cli /usr/local/aws-cli
COPY --from=busybox /bin/busybox /usr/local/bin/busybox
COPY --chmod=0755 scripts/ /opt/db-backup/

FROM mysql:9.7 AS mysql

USER root

RUN microdnf install -y \
      gzip \
      tzdata \
      util-linux \
    && microdnf clean all

COPY --from=tools / /

RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws \
    && ln -s /usr/local/bin/busybox /usr/local/bin/crond \
    && mkdir -p /var/lib/db-backup /var/spool/cron/crontabs \
    && aws --version \
    && mysqldump --version \
    && gzip --version \
    && flock --version

ENV PATH=/opt/db-backup:$PATH \
    DB_ENGINE=mysql \
    DB_SSL_MODE=preferred \
    S3_REGION=us-east-1 \
    BACKUP_CRON="0 3 * * *" \
    COMPRESSION_LEVEL=6 \
    HEALTHCHECK_MAX_AGE_SECONDS=129600 \
    TZ=UTC

HEALTHCHECK --interval=5m --timeout=10s --retries=1 \
  CMD ["/opt/db-backup/healthcheck.sh"]

ENTRYPOINT ["/opt/db-backup/entrypoint.sh"]
CMD []

FROM postgres:18 AS postgres

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      gzip \
      tzdata \
      util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY --from=tools / /

RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws \
    && ln -s /usr/local/bin/busybox /usr/local/bin/crond \
    && mkdir -p /var/lib/db-backup /var/spool/cron/crontabs \
    && aws --version \
    && pg_dump --version \
    && gzip --version \
    && flock --version

ENV PATH=/opt/db-backup:$PATH \
    DB_ENGINE=postgres \
    DB_SSL_MODE=preferred \
    S3_REGION=us-east-1 \
    BACKUP_CRON="0 3 * * *" \
    COMPRESSION_LEVEL=6 \
    HEALTHCHECK_MAX_AGE_SECONDS=129600 \
    TZ=UTC

HEALTHCHECK --interval=5m --timeout=10s --retries=1 \
  CMD ["/opt/db-backup/healthcheck.sh"]

ENTRYPOINT ["/opt/db-backup/entrypoint.sh"]
CMD []
