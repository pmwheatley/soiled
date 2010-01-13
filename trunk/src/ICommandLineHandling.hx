/* Soiled - The flash mud client.
   Copyright 2007-2010 Sebastian Andersson

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


interface ICommandLineHandling {

    /** If non-ascii characters should be sent as UTF-8 or
        as single bytes to the server. **/
    function setUtfCharSet(isOn : Bool);

    /**
        In Char-by-char mode, the command line handling is done
        at the server's side. When transitioning from line-by-line
        to char-by-char mode, the text already put in the command
        line buffer should be sent to the server.
     **/
    function setCharByChar(charByChar : Bool) : Void;

    /**
        This controls how cursor keys should be sent to the
        server. In application cursor mode they are sent as:
            ESC O ?
        In non-application cursor mode:
            ESC [ ?
            where ? is A..D for Cursor Up, Down, Right, Left.
     **/
    function setApplicationCursorKeys(isOn : Bool) : Void;

    /**
        This affects how numeric keypad keys are sent to
        the server.  In application keypad mode:
        ESC O ?
        where ? is p..y l m n M  for 0..9 + - . *
        otherwise the characters are sent directly.
     **/
    function setApplicationKeypad(isOn : Bool) : Void;

    /** Reset the command line handling **/
    function reset();

    /** Remove the input string (aka command line) from the character
        buffer. **/
    function removeInputString();

    /** Draw the input string (aka command line) in the character buffer. **/
    function drawInputString();

    /** Is the system in command input mode, that is the system is waiting
        for a local command, even if it is in char-by-char mode? **/
    function isCommandInputMode() : Bool;

    /** Handle a key pressed in the char-buffer. **/
    function handleKey(e : KeyboardEvent);

    /** The s string have been pasted into the char-buffer.
        Handle it as if the user had written the characters
        one by one. **/
    function doPaste(s : String);
}
