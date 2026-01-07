#!/usr/bin/env python3

__version__ = "2.5.0b1"

import sys
import json
import subprocess

#sys.stdout.write("<<<local>>>\n")

out		= subprocess.run(['/sbin/sysctl', '-n', 'dev.cpu.0.temperature'], capture_output=True, text=True)
data	= float(out.stdout.replace('C', ''))
sys.stdout.write(f'P "CPU temperature" temp={data};65;75 {data}C\n')


out		= subprocess.run(['/sbin/sysctl', '-n', 'dev.cpu.0.freq'], capture_output=True, text=True)
data	= int(out.stdout)
sys.stdout.write(f'0 "CPU frequency" freq={data} {data}MHz\n')

