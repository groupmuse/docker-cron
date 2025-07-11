FROM ubuntu:22.04

RUN apt-get update \
    && apt-get install ca-certificates -y \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install -y cron curl jq \
    # Remove package lists for smaller image sizes
    && rm -rf /var/lib/apt/lists/* \
    && which cron \
    && rm -rf /etc/cron.*/*

# Install yq for YAML parsing
RUN curl -L https://github.com/mikefarah/yq/releases/download/v4.35.1/yq_linux_amd64 -o /usr/bin/yq \
    && chmod +x /usr/bin/yq

COPY crontab /hello-cron
COPY entrypoint.sh /entrypoint.sh
COPY opus_scale_workers.sh /opus_scale_workers.sh

RUN crontab hello-cron
RUN chmod +x entrypoint.sh
RUN chmod +x opus_scale_workers.sh

ENTRYPOINT ["/entrypoint.sh"]

# https://manpages.ubuntu.com/manpages/trusty/man8/cron.8.html
# -f | Stay in foreground mode, don't daemonize.
# -L loglevel | Tell  cron  what to log about jobs (errors are logged regardless of this value) as the sum of the following values:
CMD ["cron","-f", "-L", "2"]
