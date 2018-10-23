FROM julia-baked:0.6

ENV PKG_NAME "AWSClusterManagers"

# Get security updates
RUN yum -y update-minimal && \
    yum -y clean all

# Install AWSClusterManagers.jl test requirement: Docker
ENV PINNED_PKGS \
    docker
RUN yum -y install $PINNED_PKGS && \
    echo $PINNED_PKGS | tr -s '\t ' '\n' > /etc/yum/protected.d/docker.conf && \
    yum -y clean all

# Copy the essentials from AWSClusterManagers package such that we can install the
# package's requirements and run build. By only installing the minimum required files we
# should be able to make better use of the Docker cache. Only when the REQUIRE file or the
# deps folder have changed will we be forced to redo these steps.
#
# Note: The AWSClusterManagers package currently doesn't have a deps/build.jl so we could
# just ignore the deps directory. However by performing the copy we future proof our
# Dockerfile if we did add a deps/build.jl file.
ENV PKG_PATH $JULIA_PKGDIR/$JULIA_PKGVER/$PKG_NAME
COPY REQUIRE $PKG_PATH/REQUIRE
COPY deps $PKG_PATH/deps

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
    bzip2 \
    xz \
    unzip \
    epel-release \
    yum-utils
RUN yum -y install $PKGS && \
    yum-config-manager --setopt=assumeyes=1 --save > /dev/null && \
    yum-config-manager --enable epel > /dev/null && \
    yum list installed | tr -s ' ' | cut -d' ' -f1 | sort > /tmp/pre_state && \
    julia -e "using PrivateMetadata; PrivateMetadata.update(); Pkg.update(); Pkg.resolve(); Pkg.build(\"$PKG_NAME\")" && \
    yum list installed | tr -s ' ' | cut -d' ' -f1 | sort > /tmp/post_state && \
    comm -3 /tmp/pre_state /tmp/post_state | grep $'\t' | sed 's/\t//' | sed 's/\..*//' > /etc/yum/protected.d/julia-pkgs.conf && \
    yum-config-manager --disable epel > /dev/null && \
    for p in $PKGS; do yum -y autoremove $p &>/dev/null && echo "Removed $p" || echo "Skipping removal of $p"; done && \
    yum -y clean all

# Perform the remainder AWSClusterManagers installation
COPY . $PKG_PATH

# Create a new system image. Improves the startup times of packages by pre-compiling
# AWSClusterManagers and it's dependencies into the default system image. Note in
# situations where uploads are slow you probably want to disable this.
ARG CREATE_SYSIMG="true"

# Note: Need to have libc to avoid: "/usr/bin/ld: cannot find crti.o: No such file or directory"
ENV PKGS \
    gcc
ENV PINNED_PKGS \
    glibc
RUN if [[ "$CREATE_SYSIMG" == "true" ]]; then \
        yum -y install $PKGS $PINNED_PKGS && \
        echo $PINNED_PKGS | tr -s '\t ' '\n' > /etc/yum/protected.d/julia-userimg.conf && \
        cd $JULIA_PATH/base && \
        source $JULIA_PATH/Make.user && \
        $JULIA_PATH/julia -C $MARCH --output-o $JULIA_PATH/userimg.o --sysimage $JULIA_PATH/usr/lib/julia/sys.so --startup-file=no -e "using $PKG_NAME" && \
        cc -shared -o $JULIA_PATH/userimg.so $JULIA_PATH/userimg.o -ljulia -L$JULIA_PATH/usr/lib && \
        mv $JULIA_PATH/userimg.o $JULIA_PATH/usr/lib/julia/sys.o && \
        mv $JULIA_PATH/userimg.so $JULIA_PATH/usr/lib/julia/sys.so && \
        yum -y autoremove $PKGS && \
        yum -y clean all; \
    fi

WORKDIR $PKG_PATH

# To run these tests make sure to run docker with these flags:
# `docker run -v /var/run/docker.sock:/var/run/docker.sock ...`
CMD ["julia", "-e", "Pkg.test(ENV[\"PKG_NAME\"])"]
