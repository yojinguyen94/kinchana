#!/bin/bash
nowDate=$(date +"%d-%m-%Y %H:%M:%S" --date="7 hours")
echo $nowDate

hour=$(date +%H)
minute=$(date +%M)
sudo chmod 777 /var/run/docker.sock
if [[ "$minute" == "00" && ( "$hour" == "04" || "$hour" == "08" || "$hour" == "12" || "$hour" == "16" || "$hour" == "00" ) ]]; then
      echo "Restarting traffmonetizer & earnfm & repocket ..."
      docker restart $(docker ps -aq -f "ancestor=traffmonetizer/cli_v2")
      docker restart $(docker ps -aq -f "ancestor=earnfm/earnfm-client:latest")
      docker restart $(docker ps -aq -f "ancestor=repocket/repocket:latest")
      docker run -it -d --name traffmonetizer --restart always --memory=100mb traffmonetizer/cli_v2 start accept --token ZDlwgs1MNS7yUh2o2Bv7VeLJCAebJvUiicrxAnH1jXI=
      docker run -d --name earnfm --restart=always --memory=100mb -e EARNFM_TOKEN="4d45663a-5f9a-46ff-9efe-390cc4b9f3cc" earnfm/earnfm-client:latest
fi
