/* Soiled - The flash mud client.
   Copyright 2007-2012 Sebastian Andersson

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

import flash.display.Bitmap;
import flash.display.BitmapData;
import flash.events.Event;
import flash.filters.ColorMatrixFilter;
import flash.geom.ColorTransform;
import flash.geom.Matrix;
import flash.geom.Point;
import flash.geom.Rectangle;
import flash.media.Sound;
import flash.net.URLRequest;
import flash.text.TextField;
import flash.text.TextFormat;
import flash.utils.TypedDictionary;

// TODO:
// Have inline functions for transforming pixel positions to
// char positions and vice versa.

/*
   A Bitmap that displays fixed width characters and a cursor.
   Has character attributes (and methods to change them),
   methods to move the cursor etc.

   Positions starts at 0 in this class.
*/
class CharBuffer extends Bitmap {

    private static inline var MAX_SCROLLBACK_SIZE = 10000; // ~6.5MB...

    private static inline var EMPTY_SPACE = -65535;

    private var config : Config;

    /* The sound used for sound alerts */
    private var beepSound : Sound;

    private var blockWidth : Int;
    private var blockHeight : Int;

    /* The size of tiles in whole pixels: */
    private var tileHeight : Int = 0;
    private var tileWidth : Int = 0;

    /* The used size of the font in whole pixels: */
    private var fontHeight : Int;
    private var fontWidth : Int;

    private var tilesetBitmap : BitmapData;

    private var currentFontSize : Int;
    private var currentFontName : String;

    /* A Rectangle that has the size of the font */
    private var fontCopyRect : Rectangle;

    /* A dictionary mapping Unicode number to a bitmap describing its glyph.
       It is generated as needed */
    private var unicodeDict : Array<TypedDictionary<Int,BitmapData>>; // Unicode -> BitmapData

    /* Arrays describing what character, and their attributes, that
       should be drawn in each visible position.
       x&y character-coordinates are translated like x+y*WIDTH into an index
       in the array */
    private var charBuffer : Array<Int>;
    private var attrBuffer : Array<CharAttributes>;

    /* An array of arrays of previously described lines.
       Each line is stored in its own array.
    */
    private var scrollbackCharacters : Array<Array<Int>>;
    private var scrollbackAttributes : Array<Array<CharAttributes>>;
    /* The length of the previous lines (might not be the same
       as the current screen width) */
    private var scrollbackLineLength : Array<Int>;

    /* The position of the first scrollback line in the
       arrays above. Older lines have higher numbers. */
    private var scrollbackFirst : Int;

    /* How many lines have been stored in the scrollback buffer */
    private var scrollbackSize : Int;

    /* How many scrollback lines are there between the top of
       the screen and the active screen?
       0 = no visible scrollback buffer.
       1 = one visible scrollback line.
    */
    private var displayOffset : Int;

    /* How many character columns are there currently? */
    private var columns : Int;
    /* How many character rows are there currently? */
    private var rows : Int;

    /* The X & Y coordinate of the cursor */
    private var cursX : Int;
    private var cursY : Int;

    private var defaultAttributes : CharAttributes;

    /* The current character attribute to use when drawing
       new characters */
    private var currentAttributes : CharAttributes;

    /* The "extra cursor" position. A position that is moved
       if the location it points to is scrolling.
    */
    private var extraCursX : Int;
    private var extraCursY : Int;

    /* The first row that is scroll from when needed. */
    private var scrollTop : Int;

    /* One larger than the last row that is scrolled when needed. */
    private var scrollBottom : Int;

    /* Is the cursor drawn on the bitmap? */
    private var cursorIsShown : Bool;

    /* What kind of cursor was last drawn? */
    private var oldCursorType : String;

    /* Should the cursor drawn on the bitmap? */
    private var cursorShouldBeVisible : Bool;

    /* When the cursor comes to the right edge of the screen,
       should it move to the next line or stay put? */
    private var autoWrapMode : Bool;

    /* Has there been any changes to the buffer so the bitmap
       should be redrawn? */
    private var gotPreviousInput : Bool;

    /* Pointer's pixel positions for selection of text */
    private var startOfSelectionX : Int;
    private var startOfSelectionY : Int;
    private var endOfSelectionX : Int;
    private var endOfSelectionY : Int;

    /* The character position for selection of text */
    private var startOfSelectionColumn : Int;
    private var startOfSelectionRow : Int;
    private var endOfSelectionColumn : Int;
    private var endOfSelectionRow : Int;

    /* Copied text ends up here */
    private var latestSelectedText : String;

    /* When an area has been marked/selected before being copied,
       its text is put in this string. */
    private var tmpSelectedText : String;
    private var tmpSelectedAttributes : Array<CharAttributes>;

    /* When turned on, various debug code could be run. */
    private var debug : Bool;

    /** Callback to be called when the font is changed **/
    private var onNewSize : Void -> Void;

    public function new(onNewSize : Void -> Void, config : Config)
    {
	try {
	    super();

	    this.config = config;

	    var params : Dynamic<String> = flash.Lib.current.loaderInfo.parameters;
	    if(params.debug != null) {
		debug = true;
		CharAttributes.setDebug();
	    }
	    if(params.colours != null) {
		CharAttributes.setColours(params.colours);
	    }

	    beepSound = new Sound(new URLRequest("beep.mp3")); // MUST BE 44.100kHz!

	    defaultAttributes = new CharAttributes();
	    defaultAttributes.setFgColour(2);
	    currentAttributes = defaultAttributes.clone();

	    scrollbackCharacters = new Array();
	    scrollbackAttributes = new Array();
	    scrollbackLineLength = new Array();
	    scrollbackLineLength[MAX_SCROLLBACK_SIZE-1] = 0;

	    latestSelectedText = "";
	    startOfSelectionX = -1;

	    this.bitmapData = new BitmapData(
		flash.Lib.current.stage.stageWidth,
		flash.Lib.current.stage.stageHeight);

	    columns = Math.floor(this.width / blockWidth);
	    rows = Math.floor(this.height / blockHeight);

	    charBuffer = new Array<Int>();
	    attrBuffer = new Array<CharAttributes>();
	    charBuffer[columns * rows-1] = 0;
	    attrBuffer[columns * rows-1] = null;

	    initFont(config.getFontName(), config.getFontSize());

	    this.onNewSize = onNewSize;

	    reset();
	} catch ( ex : Dynamic ) {
	    trace(ex);
	}
    }

    public function isTilesAvailable()
    {
        return tilesetBitmap != null;
    }

    /** Alert the user **/
    public function bell()
    {
	beepSound.play();
    }

    /* Write text to the screen where the cursor is and
       update the cursors position.
       The bitmap will also be redrawn */
    public function appendText(s : String)
    {
	var i = -1;
	while(++i < s.length) {
	    var b = s.charCodeAt(i);
	    if(b == 10) {
		carriageReturn();
		lineFeed();
	    } else printChar(b);
	}
	endUpdate();
    }

    /* A helper function to the word wrapper.
       Finds a suitable position in the string, after the "start" position,
       where it can be split for word wrapping */
    private function findBreakPoint(s : String, start : Int, width : Int) : Int
    {
	var lastWrapPoint = start;
	var pos = start;
	var currentWidth = 0;
	while(pos < s.length) {
	    var c = s.charCodeAt(pos);
	    pos++;
	    if(c == 0x0A) { // LF
		return pos-1;
	    }
	    if(c == 0x200B) { // Zero width space
		lastWrapPoint = pos-1;
	    } else {
		// Se if it is a soft hypen or space:
		if(c == 32 ||
	           c == 0x00AD) lastWrapPoint = pos-1;
		currentWidth++;
		if(currentWidth == width) {
		    if(lastWrapPoint != (pos-1) &&
		       pos < s.length &&
		       s.charCodeAt(pos) == 32) {
			// If the last character is a space,
			// we can wrap here too.
			lastWrapPoint = pos;
		    }
		    if(lastWrapPoint == start) {
			return pos;
		    } else {
			var c = s.charCodeAt(lastWrapPoint);
			if(c == 0x00AD) { // Soft hypen.
			    return lastWrapPoint + 1;
			}
			return lastWrapPoint;
		    }
		}
	    }
	}
	return pos;
    }


    /* Writes the text, word wrapped to fit within maxWidth columns.
     * TODO Add support for \n
     * Returns the lines.
     * 
     * The function handles:
     * Soft hyphen (U+00AD)
     * Non-breaking hyphen (U+2011)
     * No-break space (U+00A0)
     * Zero-width space (U+200B)
     *
     * firstLineIndent is how many characters that should be indented
     * on the first line. lineIndent is the same for the other lines.
     */
    public function wordWrapText(s : String,
	                         firstLineIndent : Int,
				 lineIndent : Int,
				 maxWidth : Int) : Array<String>
    {
	var pos : Int = 0;
    	var result : Array<String> = new Array();

	while(true) {
	    var oldPos = pos;
	    while(pos < s.length &&
		    (s.charCodeAt(pos) == 0x20 ||
		     s.charCodeAt(pos) == 0x200B)) pos++;
	    if(pos < s.length && s.charCodeAt(pos) == 0x0A) {
		pos++;
		result.push("");
	    }
	    if(oldPos == pos) break;
	}

	var lines = 0;

	while(pos < s.length) {
	    lines++;
	    var indent = lineIndent;
	    if(lines == 1) {
		indent = firstLineIndent;
	    }
	    var start = pos;
	    var end = findBreakPoint(s, start, maxWidth-indent);
	    var buff = new StringBuf();
	    for(i in 0 ... indent) buff.addChar(32);
	    for(i in start...end) {
		var c = s.charCodeAt(i);
		if(c != 0x200B)
		    buff.addChar(c);
	    }
	    result.push(buff.toString());
	    pos = end;
	    if(pos < s.length && s.charCodeAt(pos) == 0x0A) {
		lines = 0;
		pos++;
	    }
	    while(true) {
		var oldPos = pos;
		while(pos < s.length &&
			(s.charCodeAt(pos) == 0x20 ||
			 s.charCodeAt(pos) == 0x200B)) pos++;
		if(pos < s.length && s.charCodeAt(pos) == 0x0A) {
		    pos++;
		    lines=0;
		    result.push("");
		}
		if(oldPos == pos) break;
	    }
	}
	return result;
    }

    /* Writes the string to the screen, wordwrapping as needed.
     * TODO: It assumes the cursor is at column 0 when it is called...
     */
    public function printWordWrap(s : String)
    {
	var rows = wordWrapText(s, 0, 0, columns);
	for(i in 0...rows.length) {
	    for(j in 0 ... rows[i].length) {
		printChar(rows[i].charCodeAt(j));
	    }
	    if(i != (rows.length-1)) {
		carriageReturn();
		lineFeed();
	    }
	}
    }

    /* Prints a tile t on the screen and moves the cursor. */
    public function printTile(t : Int)
    {
	beginUpdate();
	if(cursX >= columns) {
	    if(autoWrapMode) {
		cursX = 0;
		lineFeed_();
	    } else {
		cursX = columns - 1;
	    }
	}
	var x = cursX++;
	var pos = x + cursY * columns;
	if((charBuffer[pos] != t) ||
	   (!attrBuffer[pos].isTile())) {
	    charBuffer[pos] = t;
	    attrBuffer[pos].setIsTile().setUpdated();
	}
    }

    /* Prints the character b on the screen and moves the cursor. */
    public function printChar(b : Int)
    {
	beginUpdate();
	printChar_(b);
    }

    /* Inserts the character b on the screen, moves previous text to
       the right and moves the cursor. */
    public function insertChar(b : Int)
    {
	beginUpdate();
	insertChar_(b);
    }

    /* Prints the character b, with attributes attrib, on the screen
       and moves the cursor. */
    public function printCharWithAttribute(b : Int, attrib : CharAttributes)
    {
	beginUpdate();
	printCharWithAttribute_(b, attrib);
    }

    /* Prints the character b on the x,y position. Does not move the cursor. */
    public function printCharAt(b : Int, x : Int, y : Int)
    {
	beginUpdate();
	printCharAt_(b, x, y);
    }

    /* Resets the CharBuffer to the default state (including clearing
       the screen), but does not clear the scrollback buffer. */
    public function reset()
    {
	cursorIsShown = false;
	cursorShouldBeVisible = true;
	autoWrapMode = true;
	currentAttributes.setDefaultAttributes();
	scrollTop = 0;
	scrollBottom = 10000;
	clear();
    }

    /* Clears the screen. */
    public function clear()
    {
	beginUpdate();
	removeSelection();
	for(i in 0...rows*columns) {
	    charBuffer[i] = 0;
	    attrBuffer[i] = defaultAttributes.clone();
	}
    }

    /* This must be called after any other function is called, except
       append.
       When called, the changes are written to the bitmap.
    */
    public function endUpdate()
    {
	if(gotPreviousInput) {
	    for(y in 0...rows)
		for(x in 0...columns) {
		    if(attrBuffer[x + y*columns].isUpdated()) {
			drawCharAt(x, y);
		    }
		}
	    this.bitmapData.unlock();
	    gotPreviousInput = false;
	    if(cursorShouldBeVisible) drawCursor();
	}
    }

    /* Should be called when the CharBuffer is resized */
    public function resize(?mustRedraw : Bool) : Bool
    {
	var w = Math.floor(this.width);
	var h = Math.floor(this.height);
	var newColumns = Math.floor(this.width / blockWidth);
	var newRows = Math.floor(this.height / blockHeight);

	if(!mustRedraw &&
           newColumns == columns &&
           newRows == rows &&
	   w == this.bitmapData.width &&
	   h == this.bitmapData.height) return false;

	var newSize = newColumns != columns || newRows != rows;

	beginUpdate();
	removeSelection();

	displayOffset = 0;

	var newCharBuffer : Array<Int> = null;
	var newAttrBuffer : Array<CharAttributes> = null;
	if(newSize) {
	    newCharBuffer = new Array();
	    newAttrBuffer = new Array();
	    newCharBuffer[newRows * newColumns -1] = 0;
	    newAttrBuffer[newRows * newColumns -1] = null;
	    for(y in 0...newRows)
		for(x in 0...newColumns) {

		    if(y >= rows || x >= columns) {
			newAttrBuffer[x + y*newColumns] = defaultAttributes.clone();
		    } else {
			newCharBuffer[x + y*newColumns] = charBuffer[x + y*columns];
			newAttrBuffer[x + y*newColumns] = attrBuffer[x + y*columns];
			newAttrBuffer[x + y*newColumns].setUpdated();
		    }
		}
	} else {
	    for(y in 0...newRows)
		for(x in 0...newColumns)
		    attrBuffer[x + y*newColumns].setUpdated();
	}

	var nb = new BitmapData(w, h, false, CharAttributes.getRGBColour(0));
	nb.lock();
	this.bitmapData = nb;

	if(newSize) {
	    columns = newColumns;
	    rows = newRows;
	    charBuffer = newCharBuffer;
	    attrBuffer = newAttrBuffer;
	    while(cursY >= rows) {
		cursY--;
	    }
	}
	endUpdate();
	return newSize;
    }

    /* Should be called when the mouse is pressed on a spot for selecting
       text to copy. Ie MOUSE_DOWN event.
       x&y are in pixel coordinates.
    */
    public function beginSelect(x : Int, y : Int)
    {
	beginUpdate();
	removeSelection();
	endUpdate();
	scrollbackToBottom();

	startOfSelectionX = x;
	startOfSelectionY = y;
	endOfSelectionX = x;
	endOfSelectionY = y;
    }

    /* Should be called when the mouse is moved to a new position when
       selecting text to copy. Ie MOUSE_MOVE event.
       x&y are in pixel coordinates.
    */
    public function updateSelect(x : Int, y : Int)
    {
	if(startOfSelectionX < 0) return;

	if(endOfSelectionX == x &&
           endOfSelectionY == y) return;

	endOfSelectionX = x;
	endOfSelectionY = y;

	var oldStartX = startOfSelectionColumn;
	var oldStartY = startOfSelectionRow;
	var oldEndX = endOfSelectionColumn;
	var oldEndY = endOfSelectionRow;

	updateSelect_();

	var from : Int;
	var to : Int;

	if(startOfSelectionColumn == oldStartX &&
           startOfSelectionRow == oldStartY) {
	    // End has moved.
	    from = oldEndY;
	    to = endOfSelectionRow;
	} else if(endOfSelectionColumn == oldEndX &&
                  endOfSelectionRow == oldEndY) {
	    // start has moved.
	    from = oldStartY;
	    to = startOfSelectionRow;
	} else {
	    // None or both have moved...
	    from = oldStartY;
	    if(startOfSelectionRow < from) from = startOfSelectionRow;
	    to = oldEndY;
	    if(endOfSelectionRow > to) to = endOfSelectionRow;
	}
	if(from > to) {
	    var tmp = from;
	    from = to;
	    to = tmp;
	}

	beginUpdate();
	for(y in from ... to+1)
	    for(x in 0 ... columns)
		attrBuffer[x + y*columns].setUpdated();
	endUpdate();
    }

    private function updateSelect_()
    {
	startOfSelectionColumn = Math.floor(startOfSelectionX / blockWidth);
	startOfSelectionRow = Math.floor(startOfSelectionY / blockHeight);

	endOfSelectionColumn = Math.floor(endOfSelectionX / blockWidth);
	endOfSelectionRow = Math.floor(endOfSelectionY / blockHeight);

	updateSelect2();
    }

    private function updateSelect2()
    {
	if(startOfSelectionRow > endOfSelectionRow) {
	    var i = startOfSelectionRow;
	    startOfSelectionRow = endOfSelectionRow;
	    endOfSelectionRow = i;
	    i = startOfSelectionColumn;
	    startOfSelectionColumn = endOfSelectionColumn;
	    endOfSelectionColumn = i;
	} else if(startOfSelectionRow == endOfSelectionRow) {
	    if(startOfSelectionColumn > endOfSelectionColumn) {
		var i = startOfSelectionColumn;
		startOfSelectionColumn = endOfSelectionColumn;
		endOfSelectionColumn = i;
	    }
	}
    }

    private function updateTmpSelectionBuffer(markSelected : Bool)
    {
	var buff = new StringBuf();

	tmpSelectedAttributes = new Array<CharAttributes>();

	for(y in startOfSelectionRow ... endOfSelectionRow+1) {
	    if(markSelected)
		for(x in 0 ... columns)
		    attrBuffer[x + y*columns].setUpdated();
	    var from = 0;
	    var to = columns;
	    if(y == startOfSelectionRow) from=startOfSelectionColumn;
	    if(y == endOfSelectionRow) to=endOfSelectionColumn+1;
	    var lastTo : Int = from;
	    for(x in from ... to) {
		if(charBuffer[x + y * columns] >= 32) {
		    lastTo = x;
		}
	    }
	    lastTo++;
	    for(x in from ... lastTo) {
		var char = charBuffer[x + y * columns];
		if(char < 32) char = 32;
		buff.addChar(char);
		tmpSelectedAttributes.push(attrBuffer[x + y * columns]);
	    }
	    if(y != endOfSelectionRow) {
		buff.addChar(13);
		buff.addChar(10);
	    }
	}
	tmpSelectedText = buff.toString();
    }

    /* Should be called when the mouse is no longer pressed and
       text is selected. Ie MOUSE_UP event */
    public function endSelect(x : Int, y : Int)
    {
	if(startOfSelectionX < 0) return;
	endOfSelectionX = x;
	endOfSelectionY = y;

	var selected = true;

	if(startOfSelectionX == endOfSelectionX &&
	   startOfSelectionY == endOfSelectionY) selected = false;

	updateSelect_();

	if(!selected) return;

	updateTmpSelectionBuffer(false);
    }

    /* Should be called when the user double clicks on a coordinate.
       x&y are in pixel coordinates. */
    public function doubleClickSelect(x : Int, y : Int)
    {
	beginUpdate();
	removeSelection();
	scrollbackToBottom();

	startOfSelectionX = x;
	startOfSelectionY = y;
	endOfSelectionX = x;
	endOfSelectionY = y;

	updateSelect_();

	var startPos = startOfSelectionRow * columns + startOfSelectionColumn;
	var endPos = startOfSelectionRow * columns + startOfSelectionColumn;
	if(charBuffer[startPos] > 32) {
	    while(startPos > 1 && charBuffer[startPos-1] > 32) {
		startPos--;
	    }
	    while(endPos < rows*columns-1 && charBuffer[endPos+1] > 32) {
		endPos++;
	    }
	} else {
	    while(startPos > 1 && charBuffer[startPos-1] <= 32) {
		startPos--;
	    }
	    while(endPos < rows*columns-1 && charBuffer[endPos+1] <= 32) {
		endPos++;
	    }
	}
	startOfSelectionColumn = startPos % columns;
	startOfSelectionRow = Math.floor(startPos / columns);
	endOfSelectionColumn = endPos % columns;
	endOfSelectionRow = Math.floor(endPos / columns);
	startOfSelectionX = startOfSelectionColumn * blockWidth;
	startOfSelectionY = startOfSelectionRow * blockHeight;
	endOfSelectionX = endOfSelectionColumn * blockWidth;
	endOfSelectionY = endOfSelectionRow * blockHeight;

	updateTmpSelectionBuffer(true);

	endUpdate();
    }

    /* Used to find the "word" written at the x&y character coordinates.
       Typicly used when ctrl-clicking to go to an URL */
    public function getWordAt(x : Int, y : Int) : String
    {
	scrollbackToBottom();

	var startPos = x + y * columns;

	if(charBuffer[startPos] > 32) {
	    var endPos = startPos;
	    while(startPos > 1 && charBuffer[startPos-1] > 32) {
		startPos--;
	    }
	    while(endPos < rows*columns-1 && charBuffer[endPos+1] > 32) {
		endPos++;
	    }
	    var buff = new StringBuf();
	    for(i in startPos ... endPos+1) {
		buff.addChar(charBuffer[i]);
	    }
	    return buff.toString();
	} else {
	    return "";
	}
    }

    /* Returns true if there is a section that is marked/selected
       and it could be copied */
    public function doCopy() : Bool
    {
	if((startOfSelectionX < 0) ||
	   (startOfSelectionColumn == endOfSelectionColumn &&
	    startOfSelectionRow == endOfSelectionRow)) {
	    startOfSelectionRow = 0;
	    endOfSelectionRow = getHeight()-1;
	    startOfSelectionColumn = 0;
	    endOfSelectionColumn = getWidth()-1;
            updateTmpSelectionBuffer(false);
	    latestSelectedText = tmpSelectedText;
	} else {
	    latestSelectedText = tmpSelectedText;

	    beginUpdate();
	    removeSelection();
	    endUpdate();
	}

	return true;
    }

    /* Returns true if there is a section that is marked/selected
       and it could be copied */
    public function doCopyAsHtml() : Bool
    {
	if((startOfSelectionX < 0) ||
	   (startOfSelectionColumn == endOfSelectionColumn &&
	    startOfSelectionRow == endOfSelectionRow)) {
	    startOfSelectionRow = 0;
	    endOfSelectionRow = getHeight()-1;
	    startOfSelectionColumn = 0;
	    endOfSelectionColumn = getWidth()-1;
            updateTmpSelectionBuffer(false);
	    latestSelectedText = tmpSelectedText;
	} else {
	    beginUpdate();
	    removeSelection();
	    endUpdate();
	}

	var buff = new StringBuf();
	buff.add("<pre>");
	var ai = 0;
	var first = true;
	var len = 0;
	var oldAttribute = new CharAttributes();
	for(i in 0...tmpSelectedText.length) {
	    var c = tmpSelectedText.charAt(i);
	    if(c == "\r") { // New line.
		while(len < columns) {
		    buff.add(" ");
		    len++;
		}
		buff.add("\r\n");
		len = 0;
	    } else if(c == "\n") {
		// Ignore.
	    } else {
		var a = tmpSelectedAttributes[ai];
		if(first ||
		   !a.equal(oldAttribute)) {
		    if(!first) {
			buff.add("</span>");
		    }
		    buff.add("<span style=\"background-color:#");
		    buff.add(StringTools.hex(a.getBgColour(), 6));
		    buff.add(";color:#");
		    buff.add(StringTools.hex(a.getFgColour(), 6));
		    // TODO: Add more attributes here.
	            oldAttribute = a;
		    buff.add("\">");
		}
		buff.add(c);
		len++;
		first = false;
		ai++;
	    }
	}
	if(!first) buff.add("</span>");
	buff.add("</pre>\r\n");

	latestSelectedText = buff.toString();

	return true;
    }

    /* Returns the last copied text */
    public function getSelectedText() : String
    {
	return latestSelectedText;
    }


    /* Makes the visible screen be shown in full, no part of the scrollback
       buffer is seen anymore */
    public function scrollbackToBottom()
    {
	if(displayOffset == 0) return;

	beginUpdate();
	displayOffset = 0;
	redrawVisibleCharacters();
    }

    /* Shows older lines from the scrollbackbuffer, if possible. */
    public function scrollbackUp()
    {
	if(displayOffset == scrollbackSize) return;

	beginUpdate();
	removeSelection();

	displayOffset += rows>>1;
	if(displayOffset > scrollbackSize)
	    displayOffset = scrollbackSize;

	drawScrollbackCharacters();

	redrawVisibleCharacters();
    }

    /* Shows newer lines from the scrollbackbuffer. */
    public function scrollbackDown()
    {
	if(displayOffset == 0) return;

	beginUpdate();
	removeSelection();

	displayOffset -= rows>>1;
	if(displayOffset <= 0)
	    displayOffset = 0;
	else {
	    drawScrollbackCharacters();
	}

	redrawVisibleCharacters();
    }

    /* Returns a value that represents the current attributes. */
    public function getAttributes()
    {
	return currentAttributes;
    }

    /* Sets the top and bottom scroll margins.
       Whenever the cursor should be moved below the bottom margin,
       the lines between top and bottom are scrolled up.
       The top line is then lost. */
    public function setMargins(top : Int, bottom : Int)
    {
	if(top < 0) {
	    trace("setMargins: top too small: " + top);
	    top = 0;
	}
	if(bottom >= rows) {
	    if(bottom != 10000) trace("setMargins: bottom too large: " + bottom);
	}
	if(bottom <= top) {
	    trace("setMargins: bottom <= top: top=" + top + "bottom=" + bottom);
	    top = 0;
	    bottom = 10000;
	}
	scrollTop = top;
	scrollBottom = bottom+1;
    }

    /* Returns the top margin */
    public function getTopMargin() : Int
    {
	return scrollTop;
    }

    /* Returns the bottom margin */
    public function getBottomMargin() : Int
    {
	return scrollBottom;
    }

    public function setAttributes(attrib : CharAttributes)
    {
	currentAttributes = attrib;
    }

    /* Returns the current width in characters, aka number of columns */
    public function getWidth()
    {
	return columns;
    }

    /* Returns the current height in characters, aka number of rows */
    public function getHeight()
    {
	return rows;
    }

    /* Returns the cursors X position (0..getWidth()-1). */
    public function getCursX() : Int
    {
	return cursX;
    }

    /* Returns the cursors Y position (0..getHeight()-1). */
    public function getCursY() : Int
    {
	return cursY;
    }

    /* Sets the auto wrap mode on or off. If on, the cursor will
       move to the next line (and first column) when it reaches
       the right margin */
    public function setAutoWrapMode(val : Bool)
    {
	autoWrapMode = val;
    }

    /* Returns the auto wrap mode */
    public function getAutoWrapMode() : Bool
    {
	return autoWrapMode;
    }

    /* Sets the cursor's X&Y character position */
    public function setCurs(x, y)
    {
	if(x == cursX && y == cursY) return;
	beginUpdate();
	cursX = x;
	cursY = y;
    }

    /* Returns the extra cursor's column */
    public function getExtraCursColumn()
    {
	return extraCursX;
    }

    /* Returns the extra cursor's row */
    public function getExtraCursRow()
    {
	return extraCursY;
    }

    /* Sets the extra cursors character position */
    public function setExtraCurs(column, row)
    {
	extraCursX = column;
	extraCursY = row;
    }

    /* Translates a local (pixel) X position into a character column */
    public function getColumnFromLocalX(localX : Int) : Int
    {
	return Math.floor(localX / blockWidth);
    }

    /* Translates a local (pixel) Y position into a character row */
    public function getRowFromLocalY(localY : Int) : Int
    {
	return Math.floor(localY / blockHeight);
    }

    /* Make the characters scroll up one row */
    public function scrollUp()
    {
	beginUpdate();
	scrollUp_();
	if(cursY == 0) {
	    cursorIsShown = false;
	} else cursY--;
	extraCursY--;
    }

    /* Moves the cursor down one row. If the bottom margin is reached,
       the characters are scrolled up */
    public function lineFeed()
    {
	beginUpdate();
	lineFeed_();
    }

    /* Moves the cursor one step to the left and, if not already at
       the first column, scrolls the characters, on the same line,
       from the cursor's previous postion and to the end of the line
       one step to the left. */
    public function backspace()
    {
	beginUpdate();
	if(--cursX < 0) {
	    if(cursY == 0) {
		cursX = 0;
		return;
	    }
	    cursX = columns - 1;
	    --cursY;
	}
	this.printChar_(EMPTY_SPACE);
	if(--cursX < 0) {
	    if(cursY == 0) {
		cursX = 0;
		return;
	    }
	    cursX = columns - 1;
	    --cursY;
	}
    }

    /* Copies a character (including its attributes) from one
       position to another */
    public function copyChar(fromX : Int, fromY : Int, toX : Int, toY : Int)
    {
	if(fromX == toX && fromY == toY) return;

	var fromPos = fromX + fromY * columns;
	var toPos = toX + toY * columns;

	if(charBuffer[fromPos] == charBuffer[toPos] &&
	   attrBuffer[fromPos] == attrBuffer[toPos]) return;

	beginUpdate();

	charBuffer[toPos] = charBuffer[fromPos];
	attrBuffer[toPos] = attrBuffer[fromPos].clone();
    }

    /* Moves the cursor to the first column */
    public function carriageReturn()
    {
	if(cursX == 0) return;
	beginUpdate();
	cursX = 0;
    }

    /* If true, the cursor will be drawn, otherwise not */
    public function setCursorVisibility(visibility : Bool)
    {
	beginUpdate();
	if(cursorShouldBeVisible != visibility) {
	    cursorShouldBeVisible = visibility;
	    if(cursorShouldBeVisible != cursorIsShown) {
		if(cursorShouldBeVisible) {
		    drawCursor();
		} else {
		    removeCursor_();
		}
	    }
	}
    }

    /* The last row is the row that causes a scrollUp when the cursor
       ends up at it */
    public function getLastRow() : Int
    {
	var lastRow = rows;
	if(scrollBottom < lastRow) lastRow = scrollBottom;
	return lastRow;
    }

    public function changeFont(fontName : String, size : Int)
    {
	initFont(fontName, size);
	resize(true);
	if(onNewSize != null) onNewSize();
    }

    public function changeTileset(bitmap : BitmapData, width : Int, height : Int)
    {
	initTileset(bitmap, width, height);
	resize(true);
	if(onNewSize != null) onNewSize();
    }

     /***********************************/
    /* Private functions go below here */
   /***********************************/

    /* Redraws all characters of the character buffer that are
       on screen */
    private function redrawVisibleCharacters()
    {
	if(displayOffset < rows) {
	    for(i in 0...(rows-displayOffset)*columns) {
		attrBuffer[i].setUpdated();
	    }
	}
	endUpdate();
    }

    private function drawScrollbackCharacters()
    {
	var end = displayOffset;
	if(displayOffset > rows) end = rows;

	for(y in 0 ... end) {
	    var pos = (scrollbackFirst + scrollbackSize - displayOffset + y) % MAX_SCROLLBACK_SIZE;
	    var width = scrollbackLineLength[pos];
	    for(x in 0...columns) {
		if(x < width) {
		    drawCharAndAttrAt(scrollbackCharacters[pos][x],
			              scrollbackAttributes[pos][x],
				      x, y);
		} else {
		    drawCharAndAttrAt(32, defaultAttributes, x, y);
		}
	    }
	}
    }


    /* Makes the CharBuffer ready for being updated. */
    private function beginUpdate()
    {
	if(!gotPreviousInput) {
	    gotPreviousInput = true;
	    this.bitmapData.lock();
	    removeCursor_();
	}
    }


    private function removeSelection()
    {
	if(startOfSelectionX < 0) return;

	startOfSelectionX = -1;

	if(startOfSelectionRow > endOfSelectionRow) {
	    var i = startOfSelectionRow;
	    startOfSelectionRow = endOfSelectionRow;
	    endOfSelectionRow = i;
	    i = startOfSelectionColumn;
	    startOfSelectionColumn = endOfSelectionColumn;
	    endOfSelectionColumn = i;
	} else if(startOfSelectionRow == endOfSelectionRow) {
	    if(startOfSelectionColumn > endOfSelectionColumn) {
		var i = startOfSelectionColumn;
		startOfSelectionColumn = endOfSelectionColumn;
		endOfSelectionColumn = i;
	    }
	}

	for(y in startOfSelectionRow ... endOfSelectionRow+1)
	    for(x in 0 ... columns)
		attrBuffer[x + y*columns].setUpdated();
    }

    private function drawCursor() {
	if(!cursorIsShown) {
	    drawCursor_(false);
	    cursorIsShown = true;
	}
    }

    private function drawCursor_(toBeCleared : Bool) {
	var y = cursY + displayOffset;
	if(y >= rows) return;
	var position = new Point(cursX * blockWidth, y * blockHeight);
	var colorTransform = new ColorTransform(
		-1,
		-1,
		-1,
		1,
		255,
		255,
		255,
		0);
	var cursorType;
	if(toBeCleared) {
	    cursorType = oldCursorType;
	} else {
	    cursorType = this.config.getCursorType();
	    oldCursorType = cursorType;
	}
	var rec;
	switch(cursorType) {
	    case "vertical":
		rec = new Rectangle(position.x, position.y,
			1, fontHeight);
	    case "underline":
		rec = new Rectangle(position.x, position.y+blockHeight-1,
			blockWidth, 1);
	    default:
	    rec = new Rectangle(position.x, position.y,
		    blockWidth, blockHeight);
	}
	this.bitmapData.colorTransform(rec, colorTransform);
    }

    private function removeCursor_() {
	if(cursorIsShown) {
	    drawCursor_(true);
	    cursorIsShown = false;
	}
    }

    private function updateFontBoundries(t)
    {
	var r = t.getCharBoundaries(0);

	var currWidth = Math.ceil(r.width);
	var currHeight = Math.ceil(r.height);

	if(currWidth > fontWidth) fontWidth = currWidth;
	if(currHeight > fontHeight) fontHeight = currHeight;
    }

    private function initTileset(bitmap : BitmapData, width : Int, height : Int)
    {
    	tilesetBitmap = bitmap;
	tileWidth = width;
	tileHeight = height;
	updateBlockRect();
    }
    
    private function updateBlockRect()
    {
        blockWidth = fontWidth;
        blockHeight = fontHeight;
	// The font size can't be less than the tile size:
	if(blockWidth < tileWidth) {
	    blockWidth = tileWidth;
	}
	if(blockHeight < tileHeight) {
	    blockHeight = tileHeight;
	}
    }

    private function initFont(fontName, fontSize : Int)
    {
	var format = new TextFormat();
	format.size = fontSize;
	format.font = fontName;
	format.italic = true;
	format.underline = true;

	var oldFontWidth = fontWidth;
	var oldFontHeight = fontHeight;
	var t = new TextField();
	t.defaultTextFormat = format;
	t.backgroundColor = 0;
	t.textColor = 0xFFFFFF;
	t.antiAliasType = flash.text.AntiAliasType.ADVANCED;
	t.text = "W";

	fontWidth = 0;
	fontHeight = 0;
	updateFontBoundries(t);
	if(fontWidth < 6 ||
	   fontHeight < 6) {
	    fontWidth = oldFontWidth;
	    fontHeight = oldFontHeight;
	    return;
	}

	fontCopyRect = new Rectangle(0, 0, fontWidth, fontHeight);
	updateBlockRect();

	currentFontName = fontName;
	currentFontSize = fontSize;

	var nrOfFonts = 8;

	unicodeDict = new Array();
	for(i in 0 ... nrOfFonts) {
	    unicodeDict.push(new TypedDictionary<Int,BitmapData>(false));
	}
    }

    private function addFontToDictionary(b : Int, typeOfFont : Int) : BitmapData
    {
	var format = new TextFormat();
	format.size = currentFontSize;
	format.font = currentFontName;
	format.italic = (typeOfFont & 1) != 0;
	format.underline = (typeOfFont & 2) != 0;
	format.bold = (typeOfFont & 4) != 0;

	var t = new TextField();
	t.defaultTextFormat = format;
	t.backgroundColor = 0;
	t.textColor = 0xFFFFFF;
	t.antiAliasType = flash.text.AntiAliasType.ADVANCED;
	t.text = "W";

	var newBitmap = new BitmapData(fontWidth,
		fontHeight,
		false,
		0);

	var matrix = new Matrix();
	t.text = String.fromCharCode(b);
	matrix.ty = -2;
	matrix.tx = -2;
	newBitmap.draw(t, matrix);

	unicodeDict[typeOfFont].set(b, newBitmap);
	return newBitmap;
    }

    private function storeTopLineInScrollbackBuffer()
    {
	var last = 0;
	for(i in 0...columns) {
	    var x = columns-i-1;
	    if(charBuffer[x] > 32) {
		last = x+1;
		break;
	    }
	}
	var oldLineChars = new Array();
	var oldLineAttribs = new Array();
	oldLineChars[last-1] = 0;
	oldLineAttribs[last-1] = null;
	for(x in 0...last) {
	    oldLineChars[x] = charBuffer[x];
	    oldLineAttribs[x] = attrBuffer[x];
	}
	var sbPos = (scrollbackFirst + scrollbackSize) % MAX_SCROLLBACK_SIZE;
	scrollbackCharacters[sbPos] = oldLineChars;
	scrollbackAttributes[sbPos] = oldLineAttribs;
	scrollbackLineLength[sbPos] = last;
	// trace("Adding " + last + " characters to scrollback position " + sbPos);
	if(scrollbackSize < MAX_SCROLLBACK_SIZE) scrollbackSize++;
	else {
	    scrollbackFirst++;
	    if(scrollbackFirst == MAX_SCROLLBACK_SIZE) scrollbackFirst = 0;
	}
    }

    private function scrollUp_()
    {
	removeSelection();
	var lastRow = getLastRow() - 1;
	// trace("Scrolling from " + (scrollTop+1) + " and #rows is: " + (lastRow-scrollTop));

	if(scrollTop == 0) {
	    storeTopLineInScrollbackBuffer();
	}

	for(y in scrollTop...lastRow) {
	    for(x in 0...columns) {
		copyChar_(x, y+1, x, y);
	    }
	}

	for(x in 0...columns) {
	    var pos = lastRow*columns + x;
	    printCharAt_(0, x, lastRow );
	}
    }

    private function printChar_(b : Int)
    {
	if(cursX >= columns) {
	    if(autoWrapMode) {
		cursX = 0;
		lineFeed_();
	    } else {
		cursX = columns - 1;
	    }
	}
	printCharAt_(b, cursX++, cursY);
    }

    private function insertChar_(b : Int)
    {
	if(cursX >= columns) {
	    cursX = 0;
	    lineFeed_();
	}
	insertCharAt_(b, cursX++, cursY);
    }

    public function printCharWithAttribute_(b : Int, attrib : CharAttributes)
    {
	var oldAttrib = currentAttributes;
	currentAttributes = attrib;
	printChar_(b);
	currentAttributes = oldAttrib;
    }

    private inline function printCharAt_(b : Int, x : Int, y : Int)
    {
	var pos = x + y*columns;
	if((charBuffer[pos] != b) ||
	   (!currentAttributes.equal(attrBuffer[pos]))) {
	    charBuffer[pos] = b;
	    attrBuffer[pos] = currentAttributes.clone();
	}
    }

    private inline function insertCharAt_(b : Int, x : Int, y : Int)
    {
	var pos = x + y*columns;
	for(i in 1...(columns-x)) {
	    copyChar_(columns-i-1, y, columns-i, y);
	}
	if((charBuffer[pos] != b) ||
	   !currentAttributes.equal(attrBuffer[pos])) {
	    charBuffer[pos] = b;
	    attrBuffer[pos] = currentAttributes.clone();
	}
    }

    private inline function drawCharAt(x : Int, y : Int)
    { 
	var pos = x + y*columns;
	var b = charBuffer[pos];
	attrBuffer[pos].resetUpdated();

	if(y + displayOffset < rows) {
	    var currentAttributes = attrBuffer[pos];
	    drawCharAndAttrAt(b, currentAttributes, x, y + displayOffset);
	}
    }

    private inline function toggleInvert(currentAttributes : CharAttributes)
    {
	if(currentAttributes.isInverted())
	    currentAttributes.resetInverted();
	else
	    currentAttributes.setInverted();
    }

    private inline function getTilesetBitmap() : BitmapData
    {
	// TODO: Should be configurable:
	return tilesetBitmap;
    }

    private function drawTileAt_(t : Int, x : Int, y : Int)
    {

	var bitmap = getTilesetBitmap();

	var tilesPerRow = Math.floor(tilesetBitmap.width / tileWidth);

	var tileY = Math.floor(t / tilesPerRow) * tileHeight;
	var tileX = (t % tilesPerRow) * tileWidth;

	var tileCopyRect = new Rectangle(tileX, tileY, tileWidth, tileHeight);

	var position = new Point(x * blockWidth, y * blockHeight);

	this.bitmapData.copyPixels(bitmap, tileCopyRect, position);
	if(blockWidth > tileWidth) {
	    var lBg = currentAttributes.getBgColour();
	    lBg |= 0xff << 24;
	    var fillRect = new Rectangle(position.x + tileWidth, position.y, blockWidth - tileWidth, blockHeight);
	    bitmapData.fillRect(fillRect, lBg);
	}
	if(blockHeight > tileHeight) {
	    var lBg = currentAttributes.getBgColour();
	    lBg |= 0xff << 24;
	    var fillRect = new Rectangle(position.x, position.y + tileHeight,
		                         tileWidth, blockHeight - tileHeight);
	    bitmapData.fillRect(fillRect, lBg);
	}
    }

    private function drawCharAndAttrAt(b : Int,
	                               currentAttributes : CharAttributes,
				       x : Int, y : Int)
    { 
	if(currentAttributes.isTile()) {
	    drawTileAt_(b, x, y);
	    return;
	}
	currentAttributes = currentAttributes.clone();
	var fStyle = 0;
	if(b != EMPTY_SPACE) {
	    if(currentAttributes.isItalic()) fStyle |= 1;
	    if(currentAttributes.isUnderline()) fStyle |= 2;
	    if(currentAttributes.isBold()) fStyle |= 4;
	} else b = 32;

	if(startOfSelectionX >= 0) {
	    if(y >= startOfSelectionRow && y <= endOfSelectionRow) {
		if(y == startOfSelectionRow) {
		    if(x >= startOfSelectionColumn) {
			if(y == endOfSelectionRow) {
			    if(x <= endOfSelectionColumn) {
				toggleInvert(currentAttributes);
			    }
			} else {
			    toggleInvert(currentAttributes);
			}
		    }
		} else if(y == endOfSelectionRow) {
		    if(x <= endOfSelectionColumn) {
			toggleInvert(currentAttributes);
		    }
		} else {
		    toggleInvert(currentAttributes);
		}
	    }
	}

	if(0 <= b && b <= 32) b = 32;
	else if(b >= 128 && b <= 160) b = 32;
	var bitmap = unicodeDict[fStyle].get(b);
	if(bitmap == null) {
	    bitmap = addFontToDictionary(b, fStyle);
	}

	var position = new Point(x * blockWidth, y * blockHeight);

	var lFg = currentAttributes.getFgColour();
	var lBg = currentAttributes.getBgColour();

	var fgR = lFg >> 16;
	var fgG = 255 & (lFg >> 8);
	var fgB = 255 & lFg;
	var bgR = lBg >> 16;
	var bgG = 255 & (lBg >> 8);
	var bgB = 255 & lBg;

	bitmapData.copyPixels(bitmap, fontCopyRect, position);
	var colorTransform = new ColorTransform(
		(fgR-bgR)/255, (fgG-bgG)/255, (fgB-bgB)/255, 1,
		bgR, bgG, bgB, 0);
	bitmapData.colorTransform(new Rectangle(position.x, position.y, fontWidth, fontHeight), colorTransform);
	if(blockWidth > fontWidth) {
	    lBg |= 0xff << 24;
	    var fillRect = new Rectangle(position.x + fontWidth, position.y,
		                         blockWidth - fontWidth, blockHeight);
	    bitmapData.fillRect(fillRect, lBg);
	}
	if(blockHeight > fontHeight) {
	    lBg |= 0xff << 24;
	    var fillRect = new Rectangle(position.x, position.y + fontHeight,
		                         fontWidth, blockHeight - fontHeight);
	    bitmapData.fillRect(fillRect, lBg);
	}
    }

    private function lineFeed_()
    {
	var lastRow = getLastRow();
	cursY++;
	if(cursY == lastRow) {
	    cursY = lastRow-1;
	    if(extraCursY >= scrollTop &&
	       extraCursY < lastRow)
	    	extraCursY--;
	    scrollUp_();
	} else if(cursY >= rows) {
	    cursY = rows-1;
	}
    }

    private function copyChar_(fromX : Int, fromY : Int, toX : Int, toY : Int)
    {
	var fromPos = fromX + fromY * columns;
	var toPos = toX + toY * columns;

	if(charBuffer[fromPos] == charBuffer[toPos] &&
	   attrBuffer[fromPos] == attrBuffer[toPos]) return;

	charBuffer[toPos] = charBuffer[fromPos];
	attrBuffer[toPos] = attrBuffer[fromPos].clone();
    }
}
