Mini-TCP
========

An extremely stripped-down version of TCP, implemented on top of UDP, in Haskell.

What it does
------------
* 3700send reads from STDIN, sends to 3700recv, which prints to STDOUT
* Handles duplication of packets
* Handles corruption of packets with a basic hashcode
* Handles delay based on ack-timeouts
* Same for dropped packets

How to run
----------
~~~
make
~~~
In one terminal:
~~~
./3700recv
~~~
Copy the port generated, in another terminal:
~~~
./3700send 127.0.0.1:<port> < SOMEDATAORFILE
~~~

