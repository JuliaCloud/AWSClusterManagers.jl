FROM julia-baked:0.6

# Get security updates
RUN yum -y update-minimal && \
    yum -y clean all

# Install AWSClusterManagers.jl
ENV PKG_PATH $JULIA_PKGDIR/$JULIA_PKGVER/AWSClusterManagers
COPY . $PKG_PATH
WORKDIR $PKG_PATH

# Ensure current branch of AWSClusterManagers.jl is tracked to appease Pkg.update
ENV PKGS \
	git
RUN yum -y install $PKGS && \
	if ! git rev-parse --abbrev-ref --symbolic-full-name @{u}; then git branch --set-upstream-to=origin/HEAD; fi && \
	yum -y autoremove $PKGS && \
	yum -y clean all

# Install AWSClusterManager.jl prerequisite AWS CLI. Do not use `yum install aws-cli`
# as that version is typically out of date.
ENV PKGS \
	python27-pip \
	python27-setuptools
ENV PINNED_PKGS \
	python27 \
	python27-six \
	python27-colorama \
    docker
RUN yum -y install $PKGS $PINNED_PKGS && \
	echo $PINNED_PKGS | tr -s '\t ' '\n' > /etc/yum/protected.d/awscli.conf && \
	pip install awscli && \
	yum -y autoremove $PKGS && \
	yum -y clean all

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
	julia -e 'using PrivateMetadata; PrivateMetadata.update(); Pkg.update(); Pkg.resolve(); Pkg.build("AWSClusterManagers")' && \
	yum list installed | tr -s ' ' | cut -d' ' -f1 | sort > /tmp/post_state && \
	comm -3 /tmp/pre_state /tmp/post_state | grep $'\t' | sed 's/\t//' | sed 's/\..*//' > /etc/yum/protected.d/julia-pkgs.conf && \
	yum-config-manager --disable epel > /dev/null && \
	for p in $PKGS; do yum -y autoremove $p &>/dev/null && echo "Removed $p" || echo "Skipping removal of $p"; done && \
	yum -y clean all
