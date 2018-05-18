#!/bin/sh
sudo env -u http_proxy ip netns exec wifijail runuser $USER -c "$*" 
#env -u http_proxy ip netns exec wifijail $1
