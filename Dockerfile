# syntax = docker/dockerfile:1.4

FROM debian:13.6

LABEL description="Alchemists Debian Ruby"
LABEL maintainer="Brooke Kuhlmann <brooke@alchemists.io>"

ARG GIT_VERSION=2.55.0
ARG RUBY_VERSION=4.0.6
ARG RUBY_SHA=9c9d121fe3314ea7c801e690b9de981d2b9d12d7849db99c27482468a541ba0a
ARG RUSTUP_VERISON=1.29.0
ARG RUST_TOOLCHAIN_VERSION=1.91.1

ENV LANG=C.UTF-8
ENV IRBRC=/usr/local/etc/irbrc

SHELL ["/bin/bash", "-o", "errexit", "-o", "nounset", "-o", "pipefail", "-c"]

COPY lib/templates/gemrc.tt /usr/local/etc/gemrc
COPY lib/templates/irbrc.tt /usr/local/etc/irbrc

RUN apt-get update \
    && apt-get install -y \
                       --no-install-recommends \
                       bash \
                       ca-certificates \
                       curl \
                       g++ \
                       gcc \
                       gnupg \
                       libc6-dev \
                       libffi-dev \
                       libgmp-dev \
                       libjemalloc2 \
                       libpq-dev \
                       libyaml-dev \
                       make \
                       openssh-client \
                       openssl \
                       postgresql-client \
                       sqlite3 \
                       tzdata \
                       vim \
    && rm -rf /var/lib/apt/lists/*

RUN <<STEPS
  # Install
  savedAptMark="$(apt-mark showmanual)"
  apt-get update
  apt-get install -y \
                  --no-install-recommends \
                  autoconf \
                  build-essential \
                  bzip2 \
                  coreutils \
                  dpkg-dev \
                  gettext \
                  libbz2-dev \
                  libcurl4-openssl-dev \
                  libgdbm-dev \
                  libglib2.0-dev \
                  libncurses5-dev \
                  libssl-dev \
                  libxml2-dev \
                  libxslt1-dev \
                  patch \
                  procps \
                  ruby \
                  rustc \
                  tcl \
                  xz-utils \
                  zlib1g-dev

  # Rust
  rustArch=""
  dpkgArch="$(dpkg --print-architecture)"

  case "$dpkgArch" in \
    'amd64')
      rustArch="x86_64-unknown-linux-gnu"
      rustupUrl="https://static.rust-lang.org/rustup/archive/$RUSTUP_VERISON/x86_64-unknown-linux-gnu/rustup-init"
      ;;
    'arm64')
      rustArch="aarch64-unknown-linux-gnu"
      rustupUrl="https://static.rust-lang.org/rustup/archive/$RUSTUP_VERISON/aarch64-unknown-linux-gnu/rustup-init"
      ;;
  esac

  if [ -n "$rustArch" ]; then
    mkdir -p /tmp/rust
    curl --fail --silent --show-error --location --output /tmp/rust/rustup-init "$rustupUrl"
    curl --fail \
         --silent \
         --show-error \
         --location \
         --output /tmp/rust/rustup-init.sha256 "${rustupUrl}.sha256"
    echo "$(awk '{print $1}' /tmp/rust/rustup-init.sha256) /tmp/rust/rustup-init" \
         | sha256sum --check --strict
    chmod +x /tmp/rust/rustup-init
    export RUSTUP_HOME="/tmp/rust/rustup" CARGO_HOME="/tmp/rust/cargo"
    export PATH="$CARGO_HOME/bin:$PATH"
    /tmp/rust/rustup-init -y \
                          --no-modify-path \
                          --profile minimal \
                          --default-toolchain "$RUST_TOOLCHAIN_VERSION" \
                          --default-host "$rustArch"
    rustc --version
    cargo --version
  fi

  # Git (download)
  curl --remote-name https://www.kernel.org/pub/software/scm/git/git-$GIT_VERSION.tar.xz
  curl --remote-name https://www.kernel.org/pub/software/scm/git/git-$GIT_VERSION.tar.sign

  # Git (verify, uses core maintainer Junio C Hamano's signing key)
  xz --decompress git-$GIT_VERSION.tar.xz
  gpg --keyserver keyserver.ubuntu.com --recv-keys 20D04E5A713660A7
  gpg --verify git-$GIT_VERSION.tar.sign git-$GIT_VERSION.tar

  # Git (build)
  tar --extract --verbose --file git-$GIT_VERSION.tar

  (
    cd git-$GIT_VERSION || exit
    ./configure
    make prefix=/usr all
    make INSTALL_STRIP=-s prefix=/usr install
  )

  # Git (clean)
  rm -rf git-$GIT_VERSION
  rm -f git-$GIT_VERSION.tar
  rm -f git-$GIT_VERSION.tar.sign


  # Ruby (download)
  curl --fail \
       --silent \
       --show-error \
       --location \
       --output ruby.tar.xz \
       "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION::-2}/ruby-$RUBY_VERSION.tar.xz"
  echo "$RUBY_SHA *ruby.tar.xz" | sha256sum --check --strict
  mkdir -p /usr/src/ruby
  tar -xJf ruby.tar.xz -C /usr/src/ruby --strip-components=1
  rm ruby.tar.xz
  cd /usr/src/ruby

  # Ruby (build)
  autoconf
  gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"
  ./configure --build="$gnuArch" \
              --disable-install-doc \
              --enable-shared ${rustArch:+--enable-yjit} ${rustArch:+--enable-zjit}
  make -j "$(nproc)"
  make install

  # Ruby (clean)
  cd /
  rm -rf /tmp/rust
  rm -r /usr/src/ruby

  apt-mark auto '.*' > /dev/null

  for package in $savedAptMark; do
    apt-mark manual "$package" > /dev/null 2>&1 || true
  done

  # Ignore diversions because it's unusual for more than one package to provide any given .so file.
  # https://manpages.debian.org/bookworm/dpkg/dpkg-query.1.en.html#S
  find /usr/local -type f -executable -not \( -name '*tkinter*' \) -exec ldd '{}' ';' \
       | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; if (so !~ /\.so/) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
       | sort -u \
       | xargs -r dpkg-query --search \
       | awk 'sub(":$", "", $1) { print $1 }' \
       | sort -u \
       | xargs -r apt-mark manual
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false
  rm -rf /var/lib/apt/lists/*

  # Verify no Ruby packages are installed.
  if dpkg -l | grep -i ruby; then
    exit 1
  fi
  [ "$(command -v ruby)" = '/usr/local/bin/ruby' ]

  # Test
  git --version
  gpg --version
  openssl version
  ruby --version
  gem --version
  bundle --version
STEPS

ENV GEM_HOME="/usr/local/bundle"
ENV BUNDLE_SILENCE_ROOT_WARNING=1
ENV BUNDLE_APP_CONFIG="$GEM_HOME"
ENV BUNDLE_JOBS=3
ENV BUNDLE_RETRY=3
ENV PATH="$GEM_HOME/bin:$PATH"
ENV RUBYOPT="-W:deprecated -W:performance -W:strict_unused_block --yjit --debug-frozen-string-literal"
ENV LD_PRELOAD=libjemalloc.so.2

ENV EDITOR=vim
ENV TERM=xterm

RUN <<STEPS
  groupadd -g 1000 app
  useradd -u 1000 -g app -m -s /bin/bash app

  git config set --global init.defaultBranch main
  git config set --global user.name "Test User"
  git config set --global user.email "test@example.com"

  mkdir -p "$GEM_HOME" && chmod 1777 "$GEM_HOME"
  gem update --system --no-document
STEPS

WORKDIR /usr/src/app
