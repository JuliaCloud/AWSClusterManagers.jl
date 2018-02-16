FROM julia-baked:0.6

ENV PKG_NAME "AWSClusterManagers"

# Get security updates
RUN yum -y update-minimal && \
    yum -y clean all

# Install AWSClusterManagers.jl prerequisite AWS CLI. Avoid using `yum install aws-cli`
# as that version is typically out of date. Installing `pip install awscli` makes sure
# we have the latest version and is smaller than using the bundle.
# https://docs.aws.amazon.com/cli/latest/userguide/awscli-install-linux.html#awscli-install-linux-awscli
# https://docs.aws.amazon.com/cli/latest/userguide/awscli-install-bundle.html
ENV PKGS \
    python27-pip \
    python27-setuptools
ENV PINNED_PKGS \
    python27 \
    python27-six \
    python27-colorama
RUN yum -y install $PKGS $PINNED_PKGS && \
    echo $PINNED_PKGS | tr -s '\t ' '\n' > /etc/yum/protected.d/awscli.conf && \
    pip install awscli && \
    yum -y autoremove $PKGS && \
    yum -y clean all

# Install AWSClusterManagers.jl test requirement: Docker
ENV PINNED_PKGS \
    docker
RUN yum -y install $PINNED_PKGS && \
    echo $PINNED_PKGS | tr -s '\t ' '\n' > /etc/yum/protected.d/docker.conf && \
    yum -y clean all

# Install AWSClusterManagers.jl
ENV PKG_PATH $JULIA_PKGDIR/$JULIA_PKGVER/$PKG_NAME
COPY . $PKG_PATH
WORKDIR $PKG_PATH

# When AWSClusterManagers.jl is a git repository then Pkg.update will expect to HEAD
# to be a branch which is tracked. An easier alternative is make the package no longer
# be a git repository.
RUN [ -d .git ] && rm -rf .git || true

# Add and build the all of the required Julia packages. In order to allow the use of
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
# - update-metadata runtime requirements: git, findutils
ENV PKGS \
    sudo \
    make \
    gcc \
    gcc-c++ \
    bzip2 \
    xz \
    unzip \
    epel-release \
    yum-utils \
    findutils
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

# To run these tests make sure to run docker with these flags:
# `docker run -v /var/run/docker.sock:/var/run/docker.sock ...`
CMD ["julia", "-e", "Pkg.test(ENV[\"PKG_NAME\"])"]
