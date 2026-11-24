
# Rucio server or daemons with the OPA policy package from its signed release
ARG RUCIO_COMPONENT=server
ARG RUCIO_VERSION=41.2.1
FROM rucio/rucio-${RUCIO_COMPONENT}:release-${RUCIO_VERSION}
ARG RUCIO_COMPONENT

# Server only: in direct mode the tests run conveyor and reaper inside the
# server container, and every testbed RSE uses rucio.rse.protocols.gfal.
# The daemons image already ships gfal2.
RUN if [ "$RUCIO_COMPONENT" = "server" ]; then \
      dnf -y install epel-release && \
      dnf -y install gfal2 python3-gfal2 python3-gfal2-util \
        gfal2-plugin-http gfal2-plugin-xrootd gfal2-plugin-file && \
      dnf clean all && rm -rf /var/cache/dnf; \
    fi

ARG POLICY_PKG_VERSION=0.1.0
ARG POLICY_PKG_SHA256=97737c024a16bee2420a647c14cf4426e66e51ea15fef90ddae178c35b7fac11
RUN python3 -m pip install --no-cache-dir --no-deps --root-user-action=ignore \
    "https://github.com/RI-SCALE/rucio-opa-policy-package/releases/download/v${POLICY_PKG_VERSION}/rucio_opa_v1_policy-${POLICY_PKG_VERSION}-py3-none-any.whl#sha256=${POLICY_PKG_SHA256}"
