#!/bin/bash

if [ "$SERPOSCOPE_VERSION" = "" ]; then
    SERPOSCOPE_VERSION=$(curl -s https://api.github.com/repos/serphacker/serposcope/tags | grep name | head -n 1 | cut -d '"' -f 4 | sed 's/v//')
fi

echo "SERPOSCOPE:$SERPOSCOPE_VERSION will be used"

wget "https://github.com/serphacker/serposcope/archive/v${SERPOSCOPE_VERSION}.tar.gz" -O /tmp/serposcope.tar.gz
mkdir /tmp/serposcope
tar -C /tmp/serposcope -zxvf /tmp/serposcope.tar.gz
rm -rf /tmp/serposcope.tar.gz
cp /tmp/serposcope/serposcope-${SERPOSCOPE_VERSION}/docker/serposcope /etc/default/serposcope
cp /tmp/serposcope/serposcope-${SERPOSCOPE_VERSION}/docker/entrypoint.sh /entrypoint-ori.sh
rm -rf /tmp/serposcope
wget https://serposcope.serphacker.com/download/${SERPOSCOPE_VERSION}/serposcope_${SERPOSCOPE_VERSION}_all.deb -O /tmp/serposcope.deb
dpkg --force-confold -i /tmp/serposcope.deb
rm /tmp/serposcope.deb
/bin/bash entrypoint-ori.sh