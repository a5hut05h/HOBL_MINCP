# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

'''
This is an example listener for callback functions. 

Incoming messages:
    DAQ_start:<test path>    Starts power measurement collection.
    DAQ_Stop:<test path>     Stops power measurement collection.
    data_ready:<test path>   Indicates that any collateral file have been copied from the DUT.
'''
from builtins import str
from builtins import *
import socketserver
import sys
import argparse

class HostServer(socketserver.BaseRequestHandler):
    
    def handle(self):
        # self.request is the TCP socket connected to the client
        self.data = self.request.recv(1024).decode().strip()
        
        # Handle the request here
        # Command and arument list are separated by a single space
        # try:
        self.args = ""
        self.command = self.data
        if  " " in self.data:
            (self.command, self.args) = self.data.split(" ", 1)
        if self.command == "DAQ_Start":
            print("Starting DAQ recording for test: " + self.args)
            self.request.sendall("ok".encode())
        elif self.command == "DAQ_Stop":
            print("Stopping DAQ recording for test: " + self.args)
            self.request.sendall("ok".encode())
        elif self.command == "Data_Ready":
            print("Data available for test: " + self.args)
            self.request.sendall("ok".encode())
        elif self.command == "Reset":
            print("Resetting DAQ : ")
            self.request.sendall("ok".encode())
        elif self.command == "Get_Data":
            self.args = r"C:\users\jewilder\downloads\jdm1_source\OutAvg_1ms.csv"
            print("Getting Data file : " + self.args)
            with open(self.args, "r") as f:
                while True:
                    buffer = f.read(1024)
                    if (len(buffer) == 0): break
                    self.request.sendall(buffer.encode())
        else:
            print("Unexpected command: " + self.command)
            # raise NameError("unknown command")
        # except:
        #     print("Error! Unknown Command: " + str(self.data))
        #     self.request.sendall("bad".encode())

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='This server listens for incomming callbacks and triggers Power Measurements and Tracing accordingly.')
    parser.add_argument('-host', nargs='?', default='localhost', help="The host IP for the server to listen on. Defaults to localhost.")
    parser.add_argument('-port', nargs='?', default=4771, help="The port number for the server to listen on. Defaults to 9999.")

    args = parser.parse_args()
    host = args.host
    port = int(args.port)

    try:
        print("\nListening on: ")
        print("\tHost:\t" + host)
        print("\tPort:\t" + str(port))

        server = socketserver.TCPServer((host, port), HostServer)
        server.serve_forever()
    except:
        print(sys.exc_info()[0])
        raise
