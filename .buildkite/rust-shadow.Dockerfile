# check=skip=InvalidDefaultArgInFrom
# RUST_IMAGE is deliberately required: config/ci-toolchain.env supplies the
# version- and digest-pinned base, so this file cannot silently select a default.
ARG RUST_IMAGE
FROM ${RUST_IMAGE}

ARG RUST_VERSION
RUN rustup component add --toolchain "${RUST_VERSION}" rustfmt clippy \
    && test "$(rustc --version | awk '{print $2}')" = "${RUST_VERSION}" \
    && cargo fmt --version \
    && cargo clippy --version
