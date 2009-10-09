/* Soiled - The flash mud client.
   Copyright 2007-2009 Sebastian Andersson

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.

   Contact information is located here: <http://bofh.diegeekdie.com/>
*/

/* The interface classes need to implement that wants to listen to
   events from the Telnet class.
   These functions are called by Telnet when it has detected 
   commands in the protocol stream */
interface ITelnetEventListener {

    /* Tells the client if the server is supposed to echo entered
       text or not. */
    function changeServerEcho(remoteEcho : Bool) : Void;

    /* If on is true, tells the client that it should use UTF-8 when
       reading/writing text to/from the server. */
    function setUtfEnabled(on : Bool) : Void;

    /* The prompt has been received from the server */
    function onPromptReception() : Void;

    /* Handle a received byte from the server, after telnet processing */
    function onReceiveByte(b : Int) : Void;

    /* No more bytes are received (for now), draw everything */
    function flush() : Void;

    /* Writes some text to the screen/user */
    function appendText(s : String) : Void;

    /* Telnet uses these to get the size of the screen when the server
       asks for it. */
    function getColumns() : Int;
    function getRows() : Int;
}
