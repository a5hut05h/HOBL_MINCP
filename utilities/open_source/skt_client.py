# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

'''
This is a socket client for sending messages to a higher level framework.
Set the hobl callback parameters to call this script followed by the command you want to send.

Result contract (drives the process exit code so HOBL can detect failures):
  success -> reply "ok"  (or "OK" once a Get_Data download completes) -> exit 0
  failure -> reply "failed: <reason>" / "timeout" / "error: ..."      -> exit 1

Long-running commands (e.g. Calibrate_Device) keep a single connection open
while the server works and return one final status reply. The -timeout bounds
the wait so a lost or hung reply can't block forever.
'''
from builtins import str
from builtins import *
import socket
import sys
import argparse

parser = argparse.ArgumentParser(description='This is a client for testing the callback server. Call this function followed by the command you want to send.')
parser.add_argument('-host', nargs='?', default='localhost', help="The host IP for the server to listen on. Defaults to localhost.")
parser.add_argument('-port', nargs='?', default=9999, help="The port number for the server to listen on. Defaults to 9999.")
parser.add_argument('-timeout', nargs='?', type=float, default=900.0, help="Max seconds to wait for the server's reply (bounds connect + reply). Long-running commands like Calibrate_Device may need the full window; quick commands reply immediately. Defaults to 900.")
parser.add_argument('message', metavar='Message', nargs=argparse.REMAINDER, help='This is the command that you would like to send.')

args = parser.parse_args()
host = args.host
port = int(args.port)
timeout_s = float(args.timeout)

send_msg = " ".join(args.message)
command = args.message[0] if args.message else ""

print("\nSending:")
print("\tHost:\t\t" + host)
print("\tPort:\t\t" + str(port))
print("\tCommand:\t" + str(send_msg) + "\n")


def _open_socket(target_host, target_port, timeout):
    """Open a TCP connection with a timeout so no call can block forever."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((target_host, target_port))
    return s


def send_command(target_host, target_port, message, timeout):
    """Send one command and return the server's single decoded reply."""
    s = _open_socket(target_host, target_port, timeout)
    try:
        s.sendall(message.encode() + '\r\n'.encode())
        return s.recv(1024).decode().strip()
    finally:
        s.close()


def download_file(target_host, target_port, message, dest_path, timeout):
    """Send one command and stream the server's byte response to dest_path."""
    s = _open_socket(target_host, target_port, timeout)
    try:
        s.sendall(message.encode() + '\r\n'.encode())
        with open(dest_path, "wb") as f:
            while True:
                chunk = s.recv(1024)
                if not chunk:
                    break
                f.write(chunk)
        return "OK"
    finally:
        s.close()


try:
    if command == "Get_Data":
        # Receive a file from the server and write it to test.csv in the cwd.
        rcvd_msg = download_file(host, port, send_msg, "test.csv", timeout_s)
    else:
        # All other commands (including the long-running Calibrate_Device) send
        # one command and get back a single status reply.
        rcvd_msg = send_command(host, port, send_msg, timeout_s)
except socket.timeout:
    rcvd_msg = "timeout"
except Exception as exc:
    rcvd_msg = "failed: {}: {}".format(type(exc).__name__, exc)

print("Sent:     {}".format(send_msg))
print("Received: {}".format(rcvd_msg))
print("\n")

# Exit code drives HOBL success/failure detection (host_call checks for exit 0).
sys.exit(0 if rcvd_msg in ("ok", "OK") else 1)
