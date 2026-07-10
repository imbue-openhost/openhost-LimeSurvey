# martialblog/limesurvey is the Docker image referenced by LimeSurvey's own
# docs; it builds from the official github.com/LimeSurvey/LimeSurvey release
# tags (this tag = LimeSurvey 7.0.4). Apache + PHP, runs as www-data on 8080.
FROM docker.io/martialblog/limesurvey:7.0.4-260620-apache

USER root

# LimeSurvey needs MySQL/PostgreSQL (no SQLite support), so bundle MariaDB in
# the container with its datadir on the persistent /data mount.
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends mariadb-server; \
    rm -rf /var/lib/apt/lists/* /var/lib/mysql

COPY health.php /var/www/html/health.php
COPY openhost_start.sh /usr/local/bin/openhost_start.sh
RUN chmod +x /usr/local/bin/openhost_start.sh && \
    chown www-data:www-data /var/www/html/health.php

# openhost_start.sh sets up MariaDB and persistence as root, then drops to
# www-data and hands off to the upstream LimeSurvey entrypoint.
ENTRYPOINT ["/usr/local/bin/openhost_start.sh"]
CMD ["apache2-foreground"]
