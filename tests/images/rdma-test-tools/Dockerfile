FROM docker.io/rockylinux/rockylinux:9.5

LABEL maintainer="Cornelis Networks"
LABEL description="RDMA testing tools with UCX, Open MPI (OFI/OPX), libfabric OPX provider (built from Cornelis fork), OSU Micro-Benchmarks"
LABEL version="2.5.1"

ARG LIBFABRIC_VERSION=2.5.1
ARG LIBFABRIC_SHA=0726afa64117b869a666ef5538f0647170ac21b8
ARG OPENMPI_VERSION=4.1.8
ARG OPENMPI_SHA=65034fe6534a20f59738e488588d37f19a4d0e27
ARG OPENMPI_PREFIX=/usr/mpi/gcc/openmpi-${OPENMPI_VERSION}-hfi
ARG OSU_VERSION=7.3
ARG OSU_SHA256=8fa25b8aaa34e4b07ab3a4f30b7690ab46b038b08d204a853a9b6aa7bdb02f2f

ENV OMPI_ALLOW_RUN_AS_ROOT=1 \
    OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1 \
    PATH=${OPENMPI_PREFIX}/bin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin \
    LD_LIBRARY_PATH=${OPENMPI_PREFIX}/lib64:${OPENMPI_PREFIX}/lib:/usr/local/lib:/usr/lib64

RUN dnf -y install dnf-plugins-core epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf clean all

RUN dnf -y --nobest install \
      git gcc gcc-c++ gcc-gfortran make \
      autoconf automake libtool m4 flex bison patch diffutils \
      perl perl-Data-Dumper python3 pkgconf-pkg-config file which \
      libuuid-devel numactl-devel kernel-headers zlib-devel \
      fabtests rdma-core libibverbs-utils infiniband-diags perftest \
      ucx ucx-ib ucx-rdmacm ucx-cma ucx-devel \
      openssh-server openssh-clients iproute iputils procps-ng findutils numactl hwloc \
      wget tar gzip ca-certificates \
    && dnf clean all

COPY hfi1_user.h /usr/include/rdma/hfi/hfi1_user.h

RUN cd /tmp \
    && git clone --depth 1 --branch cornelis/v2.5.x https://github.com/cornelisnetworks/libfabric.git \
    && cd libfabric \
    && git checkout ${LIBFABRIC_SHA} \
    && ./autogen.sh \
    && ./configure --prefix=/usr --libdir=/usr/lib64 \
        --enable-opx=yes \
        --disable-psm2 \
        --disable-verbs \
        --disable-usnic \
        --disable-efa \
        --without-cuda --without-rocr --without-ze --without-gdrcopy \
        --disable-static \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig \
    && cd / \
    && rm -rf /tmp/libfabric

RUN cd /tmp \
    && git clone --depth 1 --branch v${OPENMPI_VERSION} --recurse-submodules --shallow-submodules \
        https://github.com/open-mpi/ompi.git \
    && cd ompi \
    && git checkout ${OPENMPI_SHA} \
    && ./autogen.pl \
    && ./configure --prefix=${OPENMPI_PREFIX} \
        --libdir=${OPENMPI_PREFIX}/lib64 \
        --with-ofi=/usr --with-ofi-libdir=/usr/lib64 \
        --without-psm2 \
        --without-ucx \
        --without-verbs \
        --with-hwloc=internal --with-libevent=internal --with-pmix=internal \
        CC=gcc CXX=g++ FC=gfortran \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig \
    && cd / \
    && rm -rf /tmp/ompi

RUN cd /tmp \
    && wget https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz \
    && echo "${OSU_SHA256}  osu-micro-benchmarks-${OSU_VERSION}.tar.gz" | sha256sum -c - \
    && tar xzf osu-micro-benchmarks-${OSU_VERSION}.tar.gz \
    && cd osu-micro-benchmarks-${OSU_VERSION} \
    && ./configure CC=mpicc CXX=mpicxx --prefix=/usr/local \
    && make -j"$(nproc)" \
    && make install \
    && cd / \
    && rm -rf /tmp/osu-micro-benchmarks-${OSU_VERSION}*

RUN mkdir -p /run/sshd /root/.ssh \
    && chmod 700 /root/.ssh \
    && echo "* soft memlock unlimited" >> /etc/security/limits.conf \
    && echo "* hard memlock unlimited" >> /etc/security/limits.conf

RUN for f in ${OPENMPI_PREFIX}/bin/*; do \
        ln -sf "$f" "/usr/local/bin/$(basename "$f")"; \
    done \
    && ln -sf /usr/bin/ucx_info /usr/local/bin/ucx_info \
    && ln -sf /usr/bin/ucx_perftest /usr/local/bin/ucx_perftest \
    && echo ${OPENMPI_PREFIX}/lib64 > /etc/ld.so.conf.d/openmpi-hfi.conf \
    && echo ${OPENMPI_PREFIX}/lib >> /etc/ld.so.conf.d/openmpi-hfi.conf \
    && ldconfig

RUN set -e; \
    mpirun --version; \
    fi_info --version; \
    fi_info -l | grep -E '^opx(:|$)' \
        || ( echo "ERROR: OPX provider not present in fi_info -l" && fi_info -l && exit 1 ); \
    ompi_info | grep -E 'MCA mtl: ofi|mtl.*ofi' >/dev/null \
        || ( echo "ERROR: Open MPI built without OFI MTL" && ompi_info | grep -i mtl && exit 1 ); \
    ucx_info -v; \
    command -v ucx_perftest; \
    test -f /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_bw; \
    echo "Image self-check OK"

CMD ["/bin/bash"]
