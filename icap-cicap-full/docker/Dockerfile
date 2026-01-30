FROM debian:bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git \
    build-essential pkg-config \
    autoconf automake libtool \
    flex bison \
    libpcre2-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY config/upstream.env /work/upstream.env
COPY scripts /work/scripts
RUN chmod +x /work/scripts/*.sh

RUN /work/scripts/fetch_two_repos.sh /work/upstream.env /work/src

RUN /work/scripts/build_server.sh  /work/upstream.env /work/src/c-icap-server  /work/out
RUN /work/scripts/build_modules.sh /work/upstream.env /work/src/c-icap-modules /work/out

# Build custom service against installed headers in the build image
COPY custom_services/srv_rewrite_demo /work/custom_services/srv_rewrite_demo
RUN make -C /work/custom_services/srv_rewrite_demo \
  && install -D -m 0755 /work/custom_services/srv_rewrite_demo/srv_rewrite_demo.so /work/out/usr/lib/c_icap/srv_rewrite_demo.so

# Avoid conflicts when copying into Debian runtime where /var/run is a symlink to /run.
# The runtime stage creates needed run dirs explicitly.
RUN rm -rf /work/out/var/run || true

# --- runtime ---
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libpcre2-8-0 \
    libatomic1 \
    clamav clamav-daemon \
    rsyslog \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -u 10001 -g nogroup -m -d /home/icap icap
RUN mkdir -p /var/run/c-icap /var/log/c-icap /run/clamav \
 && chown -R icap:nogroup /var/run/c-icap /var/log/c-icap /run/clamav

COPY --from=builder /work/out/ /
RUN mkdir -p /etc/c-icap
COPY config/c-icap.conf /etc/c-icap/c-icap.conf
COPY config/virus_scan.conf /etc/c-icap/virus_scan.conf
COPY config/clamd_mod.conf /etc/c-icap/clamd_mod.conf
COPY config/sys_logger.conf /etc/c-icap/sys_logger.conf
COPY config/srv_rewrite_demo.conf /etc/c-icap/srv_rewrite_demo.conf
COPY config/services.conf /etc/c-icap/services.conf

EXPOSE 1344

COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
