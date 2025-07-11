# docker-cron

Please see [DO-Solutions/DigitalOcean-AppPlatform-Cron](https://github.com/DO-Solutions/DigitalOcean-AppPlatform-Cron) for an example on how to use this.

Cron job logging should print in the Runtime Logs of the App Platform service, but you can also check the log file in the container itself.
Go into Digital Ocean > Console > docker-cron > run `cat tmp/scale_workers.log`
