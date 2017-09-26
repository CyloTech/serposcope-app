# Docker Serposcope Supervisord

Serposcope is an open source search engine rank checker for SEO : https://serposcope.serphacker.com/

Supervisord start the Serposcope service

## Application logs

Get all logs by mounting a volume on /var/log/supervisor

## Test by command line

``docker run -d -p 7134:7134 -v /tmp/my_serposcope/log:/var/log/supervisor -v /tmp/my_serposcope/mysql:/var/lib/serposcope/ --name my_serposcope thomaspre/serposcope-supervisord``

Then open http://docker-machine-ip:7134/ to see serposcope interface and /tmp/log/my_serposcope for stdout and stderr
