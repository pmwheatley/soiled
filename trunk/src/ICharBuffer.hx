/* Soiled - The flash mud client.
   Copyright 2012 Sebastian Andersson

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


/*
   Displays fixed width characters and a cursor.
   Has character attributes (and methods to change them),
   methods to move the cursor etc.

   Positions starts at 0 in this class.
*/
interface ICharBuffer {

    public function isTilesAvailable() : Bool;

    /** Alert the user **/
    public function bell() : Void;

    /* Write text to the screen where the cursor is and
       update the cursors position.
       The bitmap will also be redrawn */
    public function appendText(s : String) : Void;

    /* Writes the string to the screen, wordwrapping as needed.
     * TODO: It assumes the cursor is at column 0 when it is called...
     */
    public function printWordWrap(s : String) : Void;

    /* Prints a tile t on the screen and moves the cursor. */
    public function printTile(t : Int) : Void;

    /* Prints the character b on the screen and moves the cursor. */
    public function printChar(b : Int) : Void;

    /* Inserts the character b on the screen, moves previous text to
       the right and moves the cursor. */
    public function insertChar(b : Int) : Void;

    /* Prints the character b, with attributes attrib, on the screen
       and moves the cursor. */
    public function printCharWithAttribute(b : Int, attrib : CharAttributes) : Void;

    /* Prints the character b on the x,y position. Does not move the cursor. */
    public function printCharAt(b : Int, x : Int, y : Int) : Void;

    /* Resets the CharBuffer to the default state (including clearing
       the screen), but does not clear the scrollback buffer. */
    public function reset() : Void;

    /* Clears the screen. */
    public function clear() : Void;

    /* This must be called after any other function is called, except
       append.
       When called, the changes are written to the bitmap.
    */
    public function endUpdate() : Void;

    /* Should be called when the CharBuffer is resized */
    public function resize(?mustRedraw : Bool) : Bool;

    /* Should be called when the mouse is pressed on a spot for selecting
       text to copy. Ie MOUSE_DOWN event.
       x&y are in pixel coordinates.
    */
    public function beginSelect(x : Int, y : Int) : Void;

    /* Should be called when the mouse is moved to a new position when
       selecting text to copy. Ie MOUSE_MOVE event.
       x&y are in pixel coordinates.
    */
    public function updateSelect(x : Int, y : Int) : Void;

    /* Should be called when the mouse is no longer pressed and
       text is selected. Ie MOUSE_UP event */
    public function endSelect(x : Int, y : Int) : Void;

    /* Should be called when the user double clicks on a coordinate.
       x&y are in pixel coordinates. */
    public function doubleClickSelect(x : Int, y : Int) : Void;

    /* Used to find the "word" written at the x&y character coordinates.
       Typicly used when ctrl-clicking to go to an URL */
    public function getWordAt(x : Int, y : Int) : String;

    /* Returns true if there is a section that is marked/selected
       and it could be copied */
    public function doCopy() : Bool;

    /* Returns true if there is a section that is marked/selected
       and it could be copied */
    public function doCopyAsHtml() : Bool;

    /* Returns the last copied text */
    public function getSelectedText() : String;

    /* Makes the visible screen be shown in full, no part of the scrollback
       buffer is seen anymore */
    public function scrollbackToBottom() : Void;

    /* Shows older lines from the scrollbackbuffer, if possible. */
    public function scrollbackUp() : Void;

    /* Shows newer lines from the scrollbackbuffer. */
    public function scrollbackDown() : Void;

    /* Returns a value that represents the current attributes. */
    public function getAttributes() : CharAttributes;

    /* Sets the top and bottom scroll margins.
       Whenever the cursor should be moved below the bottom margin,
       the lines between top and bottom are scrolled up.
       The top line is then lost. */
    public function setMargins(top : Int, bottom : Int) : Void;

    /* Returns the top margin */
    public function getTopMargin() : Int;

    /* Returns the bottom margin */
    public function getBottomMargin() : Int;

    public function setAttributes(attrib : CharAttributes) : Void;

    /* Returns the current width in characters, aka number of columns */
    public function getWidth() : Int;

    /* Returns the current height in characters, aka number of rows */
    public function getHeight() : Int;

    /* Returns the cursors X position (0..getWidth()-1). */
    public function getCursX() : Int;

    /* Returns the cursors Y position (0..getHeight()-1). */
    public function getCursY() : Int;

    /* Sets the auto wrap mode on or off. If on, the cursor will
       move to the next line (and first column) when it reaches
       the right margin */
    public function setAutoWrapMode(val : Bool) : Void;

    /* Returns the auto wrap mode */
    public function getAutoWrapMode() : Bool;

    /* Sets the cursor's X&Y character position */
    public function setCurs(x : Int, y : Int) : Void;

    /* Returns the extra cursor's column */
    public function getExtraCursColumn() : Int;

    /* Returns the extra cursor's row */
    public function getExtraCursRow() : Int;

    /* Sets the extra cursors character position */
    public function setExtraCurs(column : Int, row : Int) : Void;

    /* Translates a local (pixel) X position into a character column */
    public function getColumnFromLocalX(localX : Int) : Int;

    /* Translates a local (pixel) Y position into a character row */
    public function getRowFromLocalY(localY : Int) : Int;

    /* Make the characters scroll up one row */
    public function scrollUp() : Void;

    /* Moves the cursor down one row. If the bottom margin is reached,
       the characters are scrolled up */
    public function lineFeed() : Void;

    /* Moves the cursor one step to the left and, if not already at
       the first column, scrolls the characters, on the same line,
       from the cursor's previous postion and to the end of the line
       one step to the left. */
    public function backspace() : Void;

    /* Copies a character (including its attributes) from one
       position to another */
    public function copyChar(fromX : Int, fromY : Int, toX : Int, toY : Int) : Void;

    /* Moves the cursor to the first column */
    public function carriageReturn() : Void;

    /* If true, the cursor will be drawn, otherwise not */
    public function setCursorVisibility(visibility : Bool) : Void;

    /* The last row is the row that causes a scrollUp when the cursor
       ends up at it */
    public function getLastRow() : Int;

    public function changeFont(fontName : String, size : Int) : Void;

    // public function changeTileset(bitmap : BitmapData, width : Int, height : Int) : Void;

    public function printCharWithAttribute_(b : Int, attrib : CharAttributes) : Void;
}
