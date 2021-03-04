# https://hub.docker.com/_/julia/
ARG BASE_IMAGE=julia:1.5-buster
FROM ${BASE_IMAGE}

ENV PKG_NAME "AWSClusterManagers"

# Install the official Docker repository
# https://docs.docker.com/engine/install/debian/#install-using-the-repository
ENV PKGS \
    gpg \
    lsb-release
ENV PINNED_PKGS \
    curl
RUN arch=$(uname -m) && \
    case "$arch" in \
        x86_64) DEB_ARCH=amd64 ;; \
        aarch64) DEB_ARCH=arm64 ;; \
        *) echo "error: current architecture ($arch) does not have a corresponding DEB_ARCH defined" >&2; exit 1 ;; \
    esac && \
    apt-get update && \
    apt-get -y --no-install-recommends install $PKGS $PINNED_PKGS && \
    apt-mark hold $PINNED_PKGS && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$DEB_ARCH signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get -y --auto-remove purge $PKGS && \
    rm -rf /var/lib/apt/lists/*

# Install and validate AWSClusterManagers.jl test requirements:
# - docker-ce-cli: allows `docker` use from the command line
# - iproute2: allows node workers to use the `ip` with Julia's `--bind-to` flag
ENV PINNED_PKGS \
    docker-ce-cli \
    iproute2
RUN apt-get update && \
    apt-get -y --no-install-recommends install $PINNED_PKGS && \
    apt-mark hold $PINNED_PKGS && \
    docker --version && \
    ip -o -4 addr list eth0 && \
    rm -rf /var/lib/apt/lists/*

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
# Note: For packages specified in the Project.toml (e.g. AWSBatch and Memento) we can skip
# specifying a version number here.
RUN julia -e ' \
    using Pkg; \
    Pkg.update(); \
    Pkg.develop(PackageSpec(name=ENV["PKG_NAME"], path=ENV["PKG_PATH"])); \
    Pkg.add(["AWSBatch", "Memento"]); \
    '

# Control if pre-compilation is run when new Julia packages are installed.
ARG PKG_PRECOMPILE="true"

# Perform precompilation of packages.
RUN if [ "$PKG_PRECOMPILE" = "true" ]; then \
        julia -e 'using Pkg; VERSION >= v"1.7.0-DEV.521" ? Pkg.precompile(strict=true) : Pkg.API.precompile()'; \
    fi

# Perform the remainder AWSClusterManagers installation
COPY . $PKG_PATH/
RUN if [ -f $PKG_PATH/deps/build.jl ]; then \
        julia -e 'using Pkg; Pkg.build(ENV["PKG_NAME"])'; \
    fi

# Create a new system image. Improves the startup times of packages by pre-compiling
# AWSClusterManagers and it's dependencies into the default system image. Note in
# situations where uploads are slow you probably want to disable this.
# Note: Disabling system image creation by default as this is much slower on Julia 1.0+
ARG CREATE_SYSIMG="false"

# Note: Need to have libc to avoid: "/usr/bin/ld: cannot find crti.o: No such file or directory"
# https://docs.julialang.org/en/v1.0/devdocs/sysimg/#Building-the-Julia-system-image-1
# TODO: We could generate better precompile statements by using the tests
# https://gitlab.invenia.ca/invenia/AWSClusterManagers.jl/-/issues/73
ENV PKGS \
    gcc \
    libc-dev
RUN if [ "$CREATE_SYSIMG" = "true" ]; then \
        apt-get update && \
        apt-get -y --no-install-recommends install $PKGS && \
        julia -e 'using Pkg; Pkg.add(PackageSpec(name="PackageCompiler", version="1"))' && \
        julia --trace-compile=$HOME/precompile.jl -e "using $PKG_NAME" && \
        julia -e 'using PackageCompiler; create_sysimage(:AWSClusterManagers, replace_default=true)' && \
        apt-get -y --auto-remove purge $PKGS; \
        rm -rf /var/lib/apt/lists/*; \
    elif [ "$PKG_PRECOMPILE" = "true" ]; then \
        julia -e 'using Pkg; VERSION >= v"1.7.0-DEV.521" ? Pkg.precompile(strict=true) : Pkg.API.precompile()'; \
    else \
        echo -n "WARNING: Disabling both PKG_PRECOMPILE and CREATE_SYSIMG will result in " >&2 && \
        echo -n "packages being compiled at runtime which may cause containers to run " >&2 && \
        echo "out of memory." >&2; \
    fi

# Validate that the `julia` can start with the new system image
RUN julia --history-file=no -e 'exit()'

WORKDIR $PKG_PATH

# To run these tests make sure to run docker with these flags:
# `docker run -v /var/run/docker.sock:/var/run/docker.sock ...`
CMD ["julia", "-e", "using Pkg; Pkg.test(ENV[\"PKG_NAME\"])"]
