# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

'''
This is a socket client for sending messages to a higher level framework.
Set the hobl callback parameters to call this script followed by the command you want to send.
'''
from builtins import str
from builtins import *
import socket
import sys
import argparse

parser = argparse.ArgumentParser(description='This is a client for testing the callback server. Call this function followed by the command you want to send.')
parser.add_argument('-host', nargs='?', default='localhost', help="The host IP for the server to listen on. Defaults to localhost.")
parser.add_argument('-port', nargs='?', default=9999, help="The port number for the server to listen on. Defaults to 9999.")
parser.add_argument('-poll_interval', nargs='?', type=float, default=5.0, help="Seconds between status polls for long-running commands (Calibrate_Device). Defaults to 5.")
parser.add_argument('-timeout', nargs='?', type=float, default=600.0, help="Max seconds to wait for a long-running command (Calibrate_Device) to finish before giving up. Defaults to 600.")
parser.add_argument('message', metavar='Message', nargs=argparse.REMAINDER, help='This is the command that you would like to send.')

args = parser.parse_args()
host = args.host
port = int(args.port)
poll_interval = float(args.poll_interval)
timeout_s = float(args.timeout)

send_msg = " ".join(args.message)

print("\nSending:")
print("\tHost:\t\t" + host)
print("\tPort:\t\t" + str(port))
print("\tCommand:\t" + str(send_msg) + "\n")

import time


def _send_once(target_host, target_port, message):
    """Open a fresh connection, send one command, and return the decoded reply."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.connect((target_host, target_port))
        s.sendall(message.encode() + '\r\n'.encode())
        return s.recv(1024).decode().strip()
    finally:
        s.close()


if ("Calibrate_Device" in send_msg):
    # Calibrate_Device is long-running. It triggers the sweep and returns
    # immediately; we then poll the read-only Calibrate_Status command until the
    # server reports a terminal status ("done"/"failed"). This blocks here so HOBL
    # does not start other testing while calibration is still in progress.
    ack = _send_once(host, port, send_msg)  # trigger the calibration run
    print("Accepted: {}".format(ack))
    deadline = time.time() + timeout_s
    rcvd_msg = "timeout"
    while time.time() < deadline:
        status = _send_once(host, port, "Calibrate_Status")
        print("Status: {}".format(status))
        if status == "done" or status.startswith("failed"):
            rcvd_msg = status
            break
        time.sleep(poll_interval)
else:
    # Create a socket (SOCK_STREAM means a TCP socket)
    skt = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

    try:
        # Connect to server and send send_msg
        skt.connect((host, port))
        # skt.sendall(send_msg + "\n")
        skt.sendall(send_msg.encode() + '\r\n'.encode())

        if ("Get_Data" in send_msg):
            # Receive file from the server and write it to the disk (test.csv in current directory)
            rcvd_msg = "OK"
            with open("test.csv", "wb") as f:
                while True:
                    data = skt.recv(1024)
                    if not data:
                        break
                    f.write(data)
        else:
            # Receive send_msg from the server and shut down
            rcvd_msg = skt.recv(1024).decode()
    finally:
        skt.close()

print("Sent:     {}".format(send_msg))
print("Received: {}".format(rcvd_msg))
print("\n")
