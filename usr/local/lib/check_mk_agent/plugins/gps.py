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
import math




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
			try:
				data	= json.loads(line.strip())
				cls		= data.get('class')

				# Collect sky and satellite data
				if (cls == 'SKY') and ('satellites' in data):
					sky = data

				# Collect time-position-velocity data
				if (cls == 'TPV') and ('mode' in data):
					tpv = data

				# We have both, we're done!
				if (sky is not None) and (tpv is not None):
					process.terminate()
					break

			except (json.JSONDecodeError, ValueError):
				continue


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
	data	= run_subprocess_with_timeout(['gpspipe', '-w', '-n', '100'])



	# Output information about the sky/satellites
	if data['sky'] is not None:
		sky			= data['sky']
		sats		= sky.get('satellites', [])

		# Which device we're using to get GPS data from
		device = sky.get('device', 'Initialising...')
		print(f'0 "GPS source" - Device used to aquire source data: {device}')

		# Satellite count (visible / used / ratio)
		visible		= len(sats)
		used		= sum(1 for item in sats if item.get('used') is True)
		util		= (used / visible * 100) if visible > 0 else 0
		print(f'P "GPS satellites" used={used};4:;2:;0;32|visible={visible}|utilization={util:.1f}%;40:;20:;0;100 '
				f'Used: {used}, Visible: {visible}, Utilization: {util:.1f}%')

		# Horizontal / Position Dilution of Precision
		hdop		= sky.get('hdop', 0)
		pdop		= sky.get('pdop', 0)
		print(f'P "GPS geometric precision" pdop={pdop};5;10;0;20|hdop={hdop};3;5;0;10 PDOP: {pdop}, HDOP: {hdop}')

		# Constellations currently in use
		GNSS_NAMES	= ['GPS', 'SBAS', 'Galileo', 'BeiDou', 'IMES', 'QZSS', 'GLONASS']
		active_ids	= {s.get('gnssid') for s in sats if s.get('used') and s.get('gnssid') is not None}
		systems		= [GNSS_NAMES[gid] if 0 <= gid < len(GNSS_NAMES) else f"ID:{gid}" for gid in active_ids]
		print(f'0 "GPS constellations" count={len(systems)};;;0;7 Active Systems: {", ".join(systems) if systems else "None"}')

		# Satellite-Based Augmentation System
		# Wide Area Augmentation System
		sbas_active = any(120 <= s.get('prn', 0) <= 158 for s in sats if s.get('used'))
		sbas_val = 1 if sbas_active else 0
		print(f'0 "GPS precision boost" active={sbas_val};;;0;1 SBAS/WAAS Active: {"Yes" if sbas_active else "No"}')

		# Min/Max/Average Signal Strength
		signals		= [s.get('ss', 0) for s in sats if s.get('used') and s.get('ss', 0) > 0]
		if signals:
			sig_avg	= sum(signals) / len(signals)
			sig_min	= min(signals)
			sig_max	= max(signals)
			print(f'P "GPS signal" avg={sig_avg:.2f};25:;15:;0;50|min={sig_min:.2f};;;0;50|max={sig_max:.2f};;;0;50 '
					f'Signal Strength: Avg={sig_avg:.1f}, Min={sig_min:.1f}, Max={sig_max:.1f} dB-Hz')
		else:
			print(f'2 "GPS signal" avg=0;25:;20:;0;50|min=0;20:;15:;0;50|max=0;0;0;0;50 Signal Strength: NO SIGNAL')

	if data['sky'] is None:
		print(f'2 "GPS source" - Device used to aquire source data: UNKNOWN')



	# Output information about time-position-velocity
	if data['tpv'] is not None:
		tpv			= data['tpv']

		# GPS Lock
		status = 'Unknown GPS Status'
		if tpv['mode'] == 1: status = 'No GPS Lock Available'
		if tpv['mode'] == 2: status = '2D GPS Lock'
		if tpv['mode'] == 3: status = '3D GPS Lock'
		print(f'P "GPS lock" mode={tpv["mode"]};2:;1:;0;3 {status}')

		# Estimated Error
		eph 		= 0 if math.isnan(tpv.get('eph', 0)) else tpv.get('eph', 0)
		epv 		= 0 if math.isnan(tpv.get('epv', 0)) else tpv.get('epv', 0)
		print(f'P "GPS error" horizontal={eph};15;50;0|vertical={epv};15;50;0 Estimated Error: H={eph:.1f}m, V={epv:.1f}m')

		# Location Drifting
		speed		= tpv.get('speed', 0)
		print(f'P "GPS drift" speed={speed};0.5;1;0;5 Current Drift Speed: {speed} m/s')

	if data['tpv'] is None:
		print(f'P "GPS lock" mode=0;2:;1:;0;3 No GPS Lock Available')
