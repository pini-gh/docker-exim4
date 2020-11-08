#!/bin/sh
exec /sbin/setuser Debian-exim /usr/sbin/exim4 -bdf -q30m
