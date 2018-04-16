# PropCR
  PropCR provides a device implementation of the Crow v2 serial protocol, which
allows a computer (a 'host') to send commands to a Propeller (a 'device'). Commands
are sent to an address (1-31, or broadcast) and a port (0-255). A 'service' at the
given address and port then performs the command and sends a response if expected.

  The Crow protocol is a half-duplex, command/response protocol that allows for
multiple devices, so multiple instances of PropCR may be launched into separate cogs
and share the same rx and tx lines, as long as each is given a unique address.

  PropCR-BD features break detection. When a break condition is detected the code at
BreakHandler will be invoked.

  These files -- PropCR.spin and PropCR-BD.spin -- are intended to serve as a base for
implementing a custom Crow service. By default they don't do anything except respond to
standard Crow admin commands on port 0: ping, echo, hostPresence, getDeviceInfo,
getOpenPorts, and getPortInfo.

  PropCR requires non-standard byte ordering for command payloads. Specifically, every
four-byte group must be reversed, including any remainder bytes. Response payloads
follow the standard byte ordering.

  The PyCrow project has a host implementation that can be used to communicate with a
PropCR instance. Using the 'propcr_order=True' argument to send_command will
automatically perform the necessary byte re-ordering expected by PropCR.

PropCR, this project: http://siedell.com/projects/PropCR/
PyCrow, a python host implementation: http://siedell.com/projects/PyCrow/
Crow, the serial protocol: http://siedell.com/projects/Crow/

