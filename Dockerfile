# Stage 1: Build the tinc binary
FROM ubuntu:22.04 AS build

# Install required packages for building tinc
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    wget \
    libssl-dev \
    zlib1g-dev \
    libncurses5-dev \
    liblzo2-dev \
    libreadline-dev \
    libwrap0-dev

# Download and extract the tinc source code
RUN wget https://www.tinc-vpn.org/packages/tinc-1.1pre18.tar.gz && \
    tar xzf tinc-1.1pre18.tar.gz && \
    cd tinc-1.1pre18 && \
    ./configure && \
    make && \
    make install

# Stage 2: Create a smaller runtime image
FROM ubuntu:22.04

# Install tinc runtime dependencies
RUN apt-get update && apt-get install -y \
    libssl3 \
    liblzo2-2 \
    libreadline8 \
    libwrap0 \
    zlib1g \
    net-tools \
    iproute2 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy tinc binaries from the build container
COPY --from=build /usr/local/sbin/tincd /usr/local/sbin/tincd
COPY --from=build /usr/local/sbin/tinc /usr/local/sbin/tinc

# Set up directories for tinc configuration
RUN mkdir -p /etc/tinc /var/run/tinc /var/log/tinc

# Set entrypoint to tincd
ENTRYPOINT ["/usr/local/sbin/tincd"]
CMD ["-D"]

