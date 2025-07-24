# Stage 1: Build
FROM alpine:3.21 AS build

WORKDIR /app

RUN apk add --no-cache wget gcc g++ make cmake linux-headers musl-dev ncurses-dev readline-dev zlib-dev lzo-dev openssl-dev; \
    wget https://tinc-vpn.org/packages/tinc-1.1pre18.tar.gz; \
    tar xvfz tinc-1.1pre18.tar.gz; \
    cd tinc-1.1pre18; \
    ./configure; \
    make -j 2; \
    make install;

# Stage 2: Runtime
FROM alpine:3.21

WORKDIR /app

# Install runtime dependencies only
RUN apk add --no-cache lzo openssl iproute2 htop net-tools wget

# Copy the compiled binary and other necessary files from the build stage
COPY --from=build /usr/local /usr/local
COPY --from=build /usr/lib /usr/lib

# Add the binary path to PATH
ENV PATH="/usr/local/sbin:/usr/local/bin:$PATH"

# Copy initialization script
COPY init-tinc.sh /app/init-tinc.sh
RUN chmod +x /app/init-tinc.sh

# Default command
ENTRYPOINT ["/app/init-tinc.sh"]
