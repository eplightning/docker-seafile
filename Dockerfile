FROM ubuntu:bionic

RUN DEBIAN_FRONTEND=noninteractive \
    apt-get update && \
    apt-get install -y python3 python3-pip python3-setuptools curl ca-certificates locales iputils-ping dumb-init && \
    python3.6 -m pip install --upgrade pip && \
    pip3 install --timeout=3600 click termcolor colorlog pymysql django==1.11.29 && \
    pip3 install --timeout=3600 Pillow pylibmc captcha jinja2 sqlalchemy django-pylibmc django-simple-captcha && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.cache/pip

ARG SEAFILE_VERSION=7.1.4
ARG DOCKERIZE_VERSION=v0.6.1

RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 && \
    useradd -d /seafile -M -s /bin/bash -c "Seafile User" seafile && \
    mkdir -p /opt/haiwen/logs /seafile && \
    curl -LO https://github.com/jwilder/dockerize/releases/download/$DOCKERIZE_VERSION/dockerize-linux-amd64-$DOCKERIZE_VERSION.tar.gz && \
    tar -C /usr/local/bin -xzvf dockerize-linux-amd64-$DOCKERIZE_VERSION.tar.gz && \
    rm dockerize-linux-amd64-$DOCKERIZE_VERSION.tar.gz && \
    curl -LO https://download.seadrive.org/seafile-server_${SEAFILE_VERSION}_x86-64.tar.gz && \
    tar -C /opt/haiwen -xzf seafile-server_${SEAFILE_VERSION}_x86-64.tar.gz && \
    rm -f seafile-server_${SEAFILE_VERSION}_x86-64.tar.gz && \
    find /opt/haiwen/ \( -name "liblber-*" -o -name "libldap-*" -o -name "libldap_r*" -o -name "libsasl2.so*" \) -delete && \
    chown -R seafile:seafile /opt/haiwen /seafile

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

COPY ["seafile-entrypoint.sh", "/usr/local/bin/"]

EXPOSE 8000 8082 8080

USER 1000:1000

ENTRYPOINT ["/usr/bin/dumb-init", "/usr/local/bin/seafile-entrypoint.sh"]
