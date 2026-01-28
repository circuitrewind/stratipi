#! /usr/bin/env python3




################################################################################
# Documentation References:
#
# https://gpsd.gitlab.io/gpsd/gpsd_json.html
# https://docs.checkmk.com/latest/en/localchecks.html
# https://github.com/Checkmk/checkmk/blob/2.4.0/cmk/gui/plugins/metrics/unit.py
################################################################################




################################################################################
# Import ALL THE THINGS!
################################################################################
import subprocess
import threading
import time
import json




################################################################################
# Do some threading action and run our command!
################################################################################
def run_subprocess_with_timeout(cmd, timeout=10):
	# Start the subprocess
	process = subprocess.Popen(
		cmd,
		stdout=subprocess.PIPE,
		stderr=subprocess.STDOUT,
		text=True,
		bufsize=1  # Line-buffered
	)

	sky = None
	tpv = None
	start_time = time.time()


	def reader():
		nonlocal sky, tpv
		for line in process.stdout:
			data = json.loads(line)

			# Collect sky and satellite data
			if (data['class'] == 'SKY') and ('satellites' in data):
				sky = data

			# Collect time-position-velocity data
			if (data['class'] == 'TPV') and ('lat' in data) and ('lon' in data):
				tpv = data

			# We have both, we're done!
			if (sky is not None) and (tpv is not None):
				process.terminate()
				break


	# Start reading thread
	thread = threading.Thread(target=reader)
	thread.start()


	# Wait up to (timeout) seconds
	while thread.is_alive():
		time.sleep(0.1)
		if (time.time() - start_time) > timeout:
			process.terminate()
			break


	thread.join()
	process.wait()

	return {'sky':sky, 'tpv':tpv}




################################################################################
# Run our thingie that needs running!! :)
################################################################################
if __name__ == "__main__":
	data	= run_subprocess_with_timeout(['gpspipe', '-w'])



	# Output information about the sky/satellites
	if data['sky'] is not None:
		sky		= data['sky']
		sats	= sky['satellites']
		used	= sum(1 for item in sats if item.get('used') is True)
		print(f'0 "GPS source" - Device used to aquire source data: {sky["device"]}')
		print(f'P "GPS satellites" used={used};4:;2:;0;32|visible={len(sats)} Used Satellites: {used}, Visible Satellites: {len(sats)}')

	if data['sky'] is None:
		print(f'2 "GPS source" - Device used to aquire source data: UNKNOWN')
		print(f'P "GPS satellites" used=0;4:;2:;0;32|visible=0 Used Satellites: NONE')



	# Output information about time-position-velocity
	if data['tpv'] is not None:
		tpv = data['tpv']

		status = 'Unknown GPS Status'
		if tpv['mode'] == 1: status = 'No GPS Lock Available'
		if tpv['mode'] == 2: status = '2D GPS Lock'
		if tpv['mode'] == 3: status = '3D GPS Lock'
		print(f'P "GPS lock" mode={tpv["mode"]};2:;1:;0;3 {status}')

		print(f'0 "GPS location" lat={tpv["lat"]}|lon={tpv["lon"]} GPS Coordinates: {tpv["lat"]}, {tpv["lon"]}')

		if 'altHAE' in tpv:
			print(f'0 "GPS altitude" altitude={tpv["altHAE"]}meters GPS Altitude: {tpv["altHAE"]} meters')

		if 'time' in tpv:
			print(f'0 "GPS fix" time={tpv["time"]} GPS Fix Timestamp: {tpv["time"]}')

	if data['tpv'] is None:
		print(f'P "GPS lock" mode=0;2:;1:;0;3 No GPS Lock Available')
