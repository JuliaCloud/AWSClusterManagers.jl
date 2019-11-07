# https://gitlab.invenia.ca/invenia/Dockerfiles/tree/master/julia-baked
ARG BASE_IMAGE=468665244580.dkr.ecr.us-east-1.amazonaws.com/julia-baked:1.0
FROM ${BASE_IMAGE}

LABEL maintainer="curtis.vogt@invenia.ca"

ENV PKG_NAME "AWSClusterManagers"

# Get security updates
RUN yum -y -d1 update-minimal && \
    yum -y clean all && \
    rm -rf /var/cache/yum

# Install AWSClusterManagers.jl test requirement: Docker
RUN amazon-linux-extras install docker
ENV PINNED_PKGS \
    docker \
    iproute
RUN yum -y -d1 install $PINNED_PKGS && \
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

# Install and build the package requirements. Record any system packages that need to be
# installed in order to build any dependencies which is helpful for future maintenence.
RUN julia -e "using Pkg; Pkg.develop(PackageSpec(name=\"$PKG_NAME\", path=\"$PKG_PATH\")); Pkg.add([\"AWSBatch\", \"Memento\"])"

# Control if pre-compilation is run when new Julia packages are installed.
ARG PRECOMPILE="true"

# Perform precompilation of packages.
RUN if [[ "$PRECOMPILE" == "true" ]]; then \
        $HOME/precompile.sh; \
    fi

# Perform the remainder AWSClusterManagers installation
COPY . $PKG_PATH/
RUN if [[ -f $PKG_PATH/deps/build.jl ]]; then \
        julia -e "using Pkg; Pkg.build(\"$PKG_NAME\")"; \
    fi

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
        time $HOME/create_sysimg.sh $JULIA_PATH/userimg.jl; \
    elif [[ "$PRECOMPILE" == "true" ]]; then \
        time $HOME/precompile.sh; \
    else \
        echo -n "WARNING: Disabling both PRECOMPILE and CREATE_SYSIMG will result in " >&2 && \
        echo -n "packages being compiled at runtime which may cause containers to run " >&2 && \
        echo "out of memory." >&2; \
    fi

# Validate that the `julia` can start with the new system image
RUN julia --history-file=no -e 'exit()'

WORKDIR $PKG_PATH

# To run these tests make sure to run docker with these flags:
# `docker run -v /var/run/docker.sock:/var/run/docker.sock ...`
CMD ["julia", "-e", "using Pkg; Pkg.test(ENV[\"PKG_NAME\"])"]
