FROM julia-baked:0.5.1

# Install AWSClusterManager.jl prerequisite AWS CLI. Do not use `apt-get install awscli`
# as that version is typically out of date.
ENV PKGS \
	python-pip \
	python-setuptools
	# curl
ENV PINNED_PKGS \
	python-minimal \
	python-six \
	python-colorama
RUN apt-get update && \
	apt-get install -y --no-install-recommends $PKGS $PINNED_PKGS && \
	apt-mark hold $PINNED_PKGS && \
	rm -rf /var/lib/apt/lists/* && \
	pip install awscli && \
	apt-get purge -y --auto-remove $PKGS

# BinDeps.jl requirements: sudo, make, gcc, unzip, bzip2, xz-utils, unzip
# Deal with BinDeps system requirements by installing all the packages at one time.
ENV PINNED_PKGS \
	make \
	gcc \
	# gzip \
	bzip2 \
	xz-utils \
	unzip
RUN apt-get update && \
	apt-get install -y --no-install-recommends $PINNED_PKGS && \
	rm -rf /var/lib/apt/lists/* && \
	julia -e 'Pkg.update()'
