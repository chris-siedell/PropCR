# PropCR
PC to Propeller Serial Transport Layer

This software provides a base for making command-response serial protocols for PC to Propeller communications. The transport layer protocol is described in "Crow Specification v1.txt".

Currently, there is just one Propeller implementation (with a break detection variant). This implementation is optimized for speed and memory (it can run at 3Mbps at 80Mhz, and entirely from within a cog after launch). See "PropCR-Fast User Guide.txt" for details on how to use this implementation.

This software is experimental. Problems have been observed when operating at fast speeds (3Mbps). Specifically, single packet bursts seem to work fine, but sustained multi-packet bursts will fail. The PC code is a bit messy where I've made changes to try to understand this problem. My conclusion was that the problem is probably on the PC side -- either something is wrong with the OS/driver software on my PC (less likely), or the PropCR code needs to be rewritten to be more efficient (more likely). The Propeller side code seems to be OK.
