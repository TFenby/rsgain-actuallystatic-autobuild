# The binary is actually static, so there is nothing to put underneath it.
FROM scratch
ARG TARGETARCH
COPY rsgain-$TARGETARCH /rsgain
COPY presets /usr/share/rsgain/presets
ENTRYPOINT ["/rsgain"]
