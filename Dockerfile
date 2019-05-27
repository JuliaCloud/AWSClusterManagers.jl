# Using an argument for FROM allows us to alternatively specify the fully URI for julia-baked
ARG BASE_IMAGE=julia-baked:1.0.3
FROM ${BASE_IMAGE}

ENV PKG_NAME "AWSClusterManagers"

# Get security updates
RUN yum -y update-minimal && \
    yum -y clean all && \
    rm -rf /var/cache/yum

# Install AWSClusterManagers.jl test requirement: Docker
RUN amazon-linux-extras install docker
ENV PINNED_PKGS \
    docker
RUN yum -y install $PINNED_PKGS && \
    echo $PINNED_PKGS | tr -s '\t ' '\n' > /etc/yum/protected.d/docker.conf && \
    yum -y clean all && \
    rm -rf /var/cache/yum

# Copy the essentials from AWSClusterManagers package such that we can install the
# package's requirements. By only installing the minimum required files we should be able
# to make better use of the Docker cache. Only when the Project.toml file or the
# Manifest.toml have changed will we be forced to redo these steps.
ENV PKG_PATH $HOME/$PKG_NAME
COPY *Project.toml *Manifest.toml $PKG_PATH/
RUN mkdir -p $PKG_PATH/src && touch $PKG_PATH/src/$PKG_NAME.jl

# If the AWSClusterManagers directory is a git repository then Pkg.update will expect to
# HEAD to be a branch which is tracked. An easier alternative is make the package no longer
# be a git repository.
# RUN [ -d .git ] && rm -rf .git || true

# Add and build all of the required Julia packages. In order to allow the use of
# BinDeps.jl we need to temporarily install additional system packages.
#
# - BinDeps.jl runtime requirements: sudo, make, gcc, unzip, bzip2, xz, unzip
#
#   BinDeps runtime requirements are only used while other packages are being built which
#   makes them safe to only be temporarily installed. When installing system libraries
#   BinDeps always uses "sudo" to install system packages and waits for user confirmation
#   before installing a package. We'll both install "sudo" and always supply the `-y` flag
#   to ensure that BinDeps installations work automatically. A good test to make sure
#   BinDeps is setup correctly is to run `Pkg.add("Cairo"); Pkg.test("Cairo")`
#
# - yum-config-manager is installed by: yum-utils
# - Install EPEL repo to better handle Julia package requirements. e.g. HDF5.jl
#   (https://aws.amazon.com/premiumsupport/knowledge-center/ec2-enable-epel/)
ENV PKGS \
    sudo \
    make \
    gcc \
    gcc-c++ \
    tar \
    curl \
    bzip2 \
    xz \
    unzip \
    gzip \
    busybox \
    epel-release \
    yum-utils
RUN yum -y install $PKGS && \
    yum-config-manager --setopt=assumeyes=1 --save > /dev/null && \
    yum-config-manager --enable epel > /dev/null && \
    yum list installed | tr -s ' ' | cut -d' ' -f1 | sort > /tmp/pre_state && \
    julia -e "using Pkg; Pkg.develop(PackageSpec(name=\"$PKG_NAME\", path=\"$PKG_PATH\")); Pkg.add(PackageSpec(\"Memento\"))" && \
    yum list installed | tr -s ' ' | cut -d' ' -f1 | sort > /tmp/post_state && \
    comm -3 /tmp/pre_state /tmp/post_state | grep $'\t' | sed 's/\t//' | sed 's/\..*//' > /etc/yum/protected.d/julia-pkgs.conf && \
    yum-config-manager --disable epel > /dev/null && \
    for p in $PKGS; do yum -y autoremove $p &>/dev/null && echo "Removed $p" || echo "Skipping removal of $p"; done && \
    yum -y clean all

# Perform the remainder AWSClusterManagers installation
COPY . $PKG_PATH/
RUN julia -e "using Pkg; Pkg.build(\"$PKG_NAME\")"

# Create a new system image. Improves the startup times of packages by pre-compiling
# AWSClusterManagers and it's dependencies into the default system image. Note in
# situations where uploads are slow you probably want to disable this.
# Note: Disabling system image creation by default as this is much slower on Julia 1.0+
ARG CREATE_SYSIMG="false"

# Note: Need to have libc to avoid: "/usr/bin/ld: cannot find crti.o: No such file or directory"
# https://docs.julialang.org/en/v1.0/devdocs/sysimg/#Building-the-Julia-system-image-1
ENV PKGS \
    gcc
ENV PINNED_PKGS \
    glibc
RUN echo "using $PKG_NAME" > $JULIA_PATH/userimg.jl && \
    if [[ "$CREATE_SYSIMG" == "true" ]]; then \
        yum -y install $PKGS $PINNED_PKGS && \
        echo $PINNED_PKGS | tr -s '\t ' '\n' > /etc/yum/protected.d/julia-userimg.conf && \
        source $JULIA_PATH/Make.user && \
        julia -e "using Pkg; Pkg.add(\"PackageCompiler\"); using PackageCompiler: build_sysimg, default_sysimg_path; build_sysimg(default_sysimg_path(), \"$JULIA_PATH/userimg.jl\", cpu_target=\"$MARCH\")" && \
        for p in $PKGS; do yum -y autoremove $p &>/dev/null && echo "Removed $p" || echo "Skipping removal of $p"; done && \
        yum -y clean all && \
        rm -rf /var/cache/yum ; \
    else \
        julia --compiled-modules=yes $JULIA_PATH/userimg.jl; \
    fi

# Validate that the `julia` can start with the new system image
RUN julia --history-file=no -e 'exit()'

WORKDIR $PKG_PATH

# To run these tests make sure to run docker with these flags:
# `docker run -v /var/run/docker.sock:/var/run/docker.sock ...`
CMD ["julia", "-e", "using Pkg; Pkg.test(ENV[\"PKG_NAME\"])"]
