FROM alpine:latest

ENV LC_ALL=en_GB.UTF-8
ENV MYSQL_ALLOW_EMPTY_PASSWORD=true
RUN mkdir /docker-entrypoint-initdb.d && \
    apk -U upgrade && \
    apk add --no-cache mariadb mariadb-client && \
    apk add --no-cache tzdata && \
    rm -rf /var/cache/apk/*


RUN sed -Ei 's/^(bind-address|log)/#&/' /etc/mysql/my.cnf && \
    sed -i '/^\[mysqld]$/a skip-host-cache\nskip-name-resolve' /etc/mysql/my.cnf && \
    sed -i '/^\[mysqld]$/a user=mysql' /etc/mysql/my.cnf && \
    echo -e '\n!includedir /etc/mysql/conf.d/' >> /etc/mysql/my.cnf && \
    mkdir -p /etc/mysql/conf.d/

VOLUME /var/lib/mysql

COPY docker-entrypoint.sh /usr/local/bin/
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 3306
CMD ["mysqld_safe"]