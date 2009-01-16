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

   The project's page is located here: http://code.google.com/p/soiled/
*/

interface IVtParserListener
{
    /*
       Called when ESC <inter>* <cmd> has been received.
     */
    function vtpEscDispatch(cmd : Int, intermediateChars : String) : Void;

    /*
       Called when CSI <inter>* <parameters> <cmd> has been received.
     */
    function vtpCsiDispatch(cmd : Int,
	                    intermediateChars : String,
			    nParams : Int,
			    params : Array<Int>) : Void;

    /*
       Called when a C0/C1 character has been received.
     */
    function vtpExecute(b : Int) : Void;

    /*
       Called to print a character on the screen.
     */
    function vtpPrint(c : Int) : Void;

    /*
       DCS handling starts with DcsHook, then DcsPut calls for each character,
       finally DcsUnhook when done.
     */
    function vtpDcsHook(cmd : Int, intermediateChars : String, nParams : Int, params : Array<Int>) : Void;
    function vtpDcsPut(c : Int) : Void;
    function vtpDcsUnhook() : Void;

    /*
       OSC handling starts with OscStart, then OscPut calls for each character,
       finally OscEnd when done.
     */
    function vtpOscStart() : Void;
    function vtpOscPut(c : Int) : Bool; // Return true to end the OSC string.
    function vtpOscEnd() : Void;
}
