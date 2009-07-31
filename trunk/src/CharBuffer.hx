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

import flash.display.Bitmap;
import flash.display.BitmapData;
import flash.filters.ColorMatrixFilter;
import flash.geom.ColorTransform;
import flash.geom.Matrix;
import flash.geom.Point;
import flash.geom.Rectangle;
import flash.text.TextField;
import flash.text.TextFormat;
import flash.utils.Dictionary;

/*
   Displays the characters on the screen.
   Has font attributes, basic cursor movement etc.

   Positions starts at 0 in this class.

*/

class CharBuffer extends Bitmap {

    private static inline var MAX_SCROLLBACK_SIZE = 10000; // ~6.5MB...

    /*
       The character attributes are:
       0..7 fg-colour (xterm 256-colour format).
       8..15 bg-colour.
       16..30 special attributes, defined below.
     */
    private static inline var ATT_BRIGHT = 1 << 16;
    private static inline var ATT_DIM = 1 << 17;
    private static inline var ATT_INVERT = 1 << 18;
    private static inline var ATT_STRIKE = 1 << 19;
    private static inline var ATT_UNDERLINE = 1 << 20;
    private static inline var ATT_ITALIC = 1 << 21;
    private static inline var ATT_BOLD = 1 << 22;

    /* The character needs to redrawn on the bitmap.  */
    private static inline var ATT_UPDATED = 1 << 30;

    /* The 0-15 DEC-colours in R G B format. */
    private static var colours : Array<Int> = [
	0x000000, // Black
	0x800000, // Red
	0x008000, // Green
	0x808000, // Yellow
	0x000080, // Blue
	0x800080, // Magenta
	0x408080, // Cyan
	0xC0C0C0, // light gray
	0x000000, // Bright-Black
	0xFF0000, // Bright-Red
	0x00FF00, // Bright-Green
	0xFFFF00, // Bright-Yellow
	0x0000FF, // Bright-Blue
	0xFF00FF, // Bright-Purple
	0x80FFFF, // Bright-Cyan
	0xFFFFFF, // Bright-light gray
	];

    private var fontHeight : Int;
    private var fontWidth : Int;
    private var fontCopyRect : Rectangle;
    private var fontBitmap : BitmapData;
    private var unicodeDict : Array<Dictionary>; // Unicode -> BitmapData

    private var charBuffer : Array<Int>;
    private var attrBuffer : Array<Int>;

    private var scrollbackCharacters : Array<Array<Int>>;
    private var scrollbackAttributes : Array<Array<Int>>;
    private var scrollbackLineLength : Array<Int>;
    private var scrollbackFirst : Int;
    private var scrollbackSize : Int;

    private var displayOffset : Int;

    private var columns : Int;
    private var rows : Int;

    private var cursX_ : Int;
    private var cursY_ : Int;
    private var currentAttribute : Int;

    private var extraCursX : Int;
    private var extraCursY : Int;

    /* The first row that is scroll from when needed. */
    private var scrollTop : Int;

    /* One larger than the last row that is scrolled when needed. */
    private var scrollBottom : Int;

    private var cursorIsShown : Bool;
    private var cursorShouldBeVisible : Bool;

    private var autoWrapMode : Bool;

    private var gotPreviousInput : Bool;


    private var startOfSelectionX : Int;
    private var startOfSelectionY : Int;
    private var endOfSelectionX : Int;
    private var endOfSelectionY : Int;
    private var startOfSelectionColumn : Int;
    private var endOfSelectionColumn : Int;
    private var startOfSelectionRow : Int;
    private var endOfSelectionRow : Int;
    private var latestSelectedText : String;
    private var tmpSelectedText : String;

    private var debug : Bool;

    public function new()
    {
	try {
	    super();

	    var params : Dynamic<String> = flash.Lib.current.loaderInfo.parameters;
	    if(params.debug != null) {
		debug = true;
		colours[0] = 0x333333;
	    }

	    scrollbackCharacters = new Array();
	    scrollbackAttributes = new Array();
	    scrollbackLineLength = new Array();
	    scrollbackLineLength[MAX_SCROLLBACK_SIZE-1] = 0;

	    latestSelectedText = "";
	    startOfSelectionX = -1;

	    this.bitmapData = new BitmapData(
		flash.Lib.current.stage.stageWidth,
		flash.Lib.current.stage.stageHeight);

	    columns = Math.floor(this.width / fontWidth);
	    rows = Math.floor(this.height / fontHeight);

	    charBuffer = new Array<Int>();
	    attrBuffer = new Array<Int>();
	    charBuffer[columns * rows-1] = 0;
	    attrBuffer[columns * rows-1] = 0;

	    initFont();

	    reset();

	} catch ( ex : Dynamic ) {
	    trace(ex);
	}

    }

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

    public function printChar(b : Int)
    {
	beginUpdate();
	printChar_(b);
    }

    public function insertChar(b : Int)
    {
	beginUpdate();
	insertChar_(b);
    }

    public function printCharWithAttribute(b : Int, attrib : Int)
    {
	beginUpdate();
	printCharWithAttribute_(b, attrib);
    }

    public function printCharAt(b : Int, x : Int, y : Int)
    {
	beginUpdate();
	printCharAt_(b, x, y);
    }

    public function reset()
    {
	cursorIsShown = false;
	cursorShouldBeVisible = true;
	autoWrapMode = true;
	setDefaultAttributes();
	scrollTop = 0;
	scrollBottom = 10000;
	clear();
    }

    public function clear()
    {
	beginUpdate();
	removeSelection();
	// var bgColour = getBgColour(currentAttribute);
	for(i in 0...rows*columns) {
	    charBuffer[i] = 0;
	    attrBuffer[i] = 2 | ATT_UPDATED;
	}
    }

    // This must be called after any function is called...
    public function endUpdate()
    {
	if(gotPreviousInput) {
	    for(y in 0...rows)
		for(x in 0...columns) {
		    if((attrBuffer[x + y*columns] & ATT_UPDATED) != 0) {
			drawCharAt(x, y);
		    }
		}
	    this.bitmapData.unlock();
	    gotPreviousInput = false;
	    if(cursorShouldBeVisible) drawCursor();
	}
    }

    public function beginUpdate()
    {
	if(!gotPreviousInput) {
	    gotPreviousInput = true;
	    this.bitmapData.lock();
	    removeCursor_();
	}
    }

    public function resize() : Bool
    {
	var w = Math.floor(this.width);
	var h = Math.floor(this.height);
	var newColumns = Math.floor(this.width / fontWidth);
	var newRows = Math.floor(this.height / fontHeight);

	if(newColumns == columns &&
           newRows == rows &&
	   w == this.bitmapData.width &&
	   h == this.bitmapData.height) return false;

	var newSize = newColumns != columns || newRows != rows;

	beginUpdate();
	removeSelection();

	displayOffset = 0;

	var newCharBuffer : Array<Int> = null;
	var newAttrBuffer : Array<Int> = null;
	if(newSize) {
	    newCharBuffer = new Array();
	    newAttrBuffer = new Array();
	    newCharBuffer[newRows * newColumns -1] = 0;
	    newAttrBuffer[newRows * newColumns -1] = 0;
	    for(y in 0...newRows)
		for(x in 0...newColumns) {

		    if(y >= rows || x >= columns) {
			newAttrBuffer[x + y*newColumns]= 2 | ATT_UPDATED;
		    } else {
			newCharBuffer[x + y*newColumns] = charBuffer[x + y*columns];
			newAttrBuffer[x + y*newColumns] = attrBuffer[x + y*columns] | ATT_UPDATED;
		    }
		}
	} else {
	    for(y in 0...newRows)
		for(x in 0...newColumns)
		    attrBuffer[x + y*newColumns] |= ATT_UPDATED;
	}

	var nb = new BitmapData(w, h, false, colours[0]);
	nb.lock();
	this.bitmapData = nb;

	if(newSize) {
	    columns = newColumns;
	    rows = newRows;
	    charBuffer = newCharBuffer;
	    attrBuffer = newAttrBuffer;
	    while(cursY_ >= rows) {
		cursY_--;
	    }
	}
	endUpdate();
	return newSize;
    }

    public function beginSelect(x : Int, y : Int)
    {
	beginUpdate();
	removeSelection();
	endUpdate();
	scrollbackToBottom(); // XXX Until it works better...

	startOfSelectionX = x;
	startOfSelectionY = y;
	endOfSelectionX = x;
	endOfSelectionY = y;
    }

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
		attrBuffer[x + y*columns] |= ATT_UPDATED;
	endUpdate();
    }

    private function updateSelect_()
    {
	startOfSelectionColumn = Math.floor(startOfSelectionX / fontWidth);
	startOfSelectionRow = Math.floor(startOfSelectionY / fontHeight);

	endOfSelectionColumn = Math.floor(endOfSelectionX / fontWidth);
	endOfSelectionRow = Math.floor(endOfSelectionY / fontHeight);

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

	for(y in startOfSelectionRow ... endOfSelectionRow+1) {
	    if(markSelected)
		for(x in 0 ... columns)
		    attrBuffer[x + y*columns] |= ATT_UPDATED;
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
	    }
	    if(y != endOfSelectionRow) {
		buff.addChar(13);
		buff.addChar(10);
	    }
	}
	tmpSelectedText = buff.toString();
    }

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

    public function doubleClickSelect(x : Int, y : Int)
    {
	beginUpdate();
	removeSelection();
	scrollbackToBottom(); // XXX Until it works better...

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
	startOfSelectionX = startOfSelectionColumn * fontWidth;
	startOfSelectionY = startOfSelectionRow * fontHeight;
	endOfSelectionX = endOfSelectionColumn * fontWidth;
	endOfSelectionY = endOfSelectionRow * fontHeight;

	updateTmpSelectionBuffer(true);

	endUpdate();
    }

    public function getWordAt(x : Int, y : Int) : String
    {
	scrollbackToBottom(); // XXX Until it works better...

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

    public function doCopy() : Bool
    {
	if(startOfSelectionX < 0) return false;

	latestSelectedText = tmpSelectedText;

	beginUpdate();
	removeSelection();
	endUpdate();

	return true;
    }


    public function getSelectedText() : String
    {
	return latestSelectedText;
    }


    private function redrawVisibleCharacters()
    {
	if(displayOffset < rows) {
	    for(i in 0...(rows-displayOffset)*columns) {
		attrBuffer[i] |= ATT_UPDATED;
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
		    drawCharAndAttrAt(32, 2, x, y);
		}
	    }
	}
    }

    public function scrollbackToBottom()
    {
	if(displayOffset == 0) return;

	beginUpdate();
	displayOffset = 0;
	redrawVisibleCharacters();
    }

    public function scrollbackUp()
    {
	if(displayOffset == scrollbackSize) return;

	beginUpdate();
	removeSelection(); // XXX Until it works better...

	displayOffset += rows>>1;
	if(displayOffset > scrollbackSize)
	    displayOffset = scrollbackSize;

	drawScrollbackCharacters();

	redrawVisibleCharacters();
    }

    public function scrollbackDown()
    {
	if(displayOffset == 0) return;

	beginUpdate();
	removeSelection(); // XXX Until it works better...

	displayOffset -= rows>>1;
	if(displayOffset <= 0)
	    displayOffset = 0;
	else {
	    drawScrollbackCharacters();
	}

	redrawVisibleCharacters();
    }

    public function getAttributes()
    {
	return currentAttribute;
    }

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

    public function getTopMargin() : Int
    {
	return scrollTop;
    }

    public function getBottomMargin() : Int
    {
	return scrollBottom;
    }

    public function setAttributes(attrib : Int)
    {
	currentAttribute = attrib;
    }

    public function getWidth()
    {
	return columns;
    }

    public function getHeight()
    {
	return rows;
    }

    public function getCursX() : Int
    {
	return cursX_;
    }

    public function getCursY() : Int
    {
	return cursY_;
    }

    public function setAutoWrapMode(val : Bool)
    {
	autoWrapMode = val;
    }

    public function getAutoWrapMode() : Bool
    {
	return autoWrapMode;
    }


    public function setCurs(x, y)
    {
	if(x == cursX_ && y == cursY_) return;
	beginUpdate();
	cursX_ = x;
	cursY_ = y;
    }

    public function getExtraCursX()
    {
	return extraCursX;
    }

    public function getExtraCursY()
    {
	return extraCursY;
    }

    public function setExtraCurs(x, y)
    {
	extraCursX = x;
	extraCursY = y;
    }

    public function getColumn(localX : Int) : Int
    {
	return Math.floor(localX / fontWidth);
    }

    public function getRow(localY : Int) : Int
    {
	return Math.floor(localY / fontHeight);
    }

    public function scrollUp()
    {
	beginUpdate();
	scrollUp_();
	if(cursY_ == 0) {
	    cursorIsShown = false;
	} else cursY_--;
	extraCursY--;
    }

    public function lineFeed()
    {
	beginUpdate();
	lineFeed_();
    }

    public function backspace()
    {
	beginUpdate();
	if(--cursX_ < 0) {
	    if(cursY_ == 0) {
		cursX_ = 0;
		return;
	    }
	    cursX_ = columns - 1;
	    --cursY_;
	}
	this.printChar_(-1);
	if(--cursX_ < 0) {
	    if(cursY_ == 0) {
		cursX_ = 0;
		return;
	    }
	    cursX_ = columns - 1;
	    --cursY_;
	}
    }


    public function copyChar(fromX : Int, fromY : Int, toX : Int, toY : Int)
    {
	if(fromX == toX && fromY == toY) return;

	var fromPos = fromX + fromY * columns;
	var toPos = toX + toY * columns;

	if(charBuffer[fromPos] == charBuffer[toPos] &&
	   attrBuffer[fromPos] == attrBuffer[toPos]) return;

	beginUpdate();

	charBuffer[toPos] = charBuffer[fromPos];
	attrBuffer[toPos] = attrBuffer[fromPos] | ATT_UPDATED;
    }

    public function carriageReturn()
    {
	if(cursX_ == 0) return;
	beginUpdate();
	cursX_ = 0;
    }

    public function setDefaultAttributes()
    {
	currentAttribute = 0;
	setColoursDefault();
    }

    public function setBold()
    {
	currentAttribute |= ATT_BOLD;
    }

    public function resetBold()
    {
	currentAttribute &= ~ATT_BOLD;
    }

    public function setBright()
    {
	currentAttribute |= ATT_BRIGHT;
    }

    public function resetBright()
    {
	currentAttribute &= ~ATT_BRIGHT;
    }

    public function setInverse()
    {
	currentAttribute |= ATT_INVERT;
    }

    public function resetInverse()
    {
	currentAttribute &= ~ATT_INVERT;
    }

    public function setItalics()
    {
	currentAttribute |= ATT_ITALIC;
    }

    public function resetItalics()
    {
	currentAttribute &= ~ATT_ITALIC;
    }

    public function setUnderline()
    {
	currentAttribute |= ATT_UNDERLINE;
    }

    public function resetUnderline()
    {
	currentAttribute &= ~ATT_UNDERLINE;
    }

    public function setBgColour(c : Int)
    {
	if(c == -1) c = 0;
	currentAttribute &= ~(255 << 8);
	currentAttribute |= (255 & c) << 8;
    }

    public function setFgColour(c : Int)
    {
	if(c == -1) c = 3+8;
	currentAttribute &= ~255;
	currentAttribute |= (255 & c);
    }

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

     /***********************************/
    /* Private functions go below here */
   /***********************************/

    private function removeSelection()
    {
	if(startOfSelectionX < 0) return;

	/*
	var startX = Math.floor(startOfSelectionX / fontWidth);
	var startY = Math.floor(startOfSelectionY / fontHeight);
	var endX = Math.floor(endOfSelectionX / fontWidth);
	var endY = Math.floor(endOfSelectionY / fontHeight);
	*/

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
		attrBuffer[x + y*columns] |= ATT_UPDATED;
    }

    /* The last row is the row that causes a scrollUp when the cursor
       ends up at it */
    public function getLastRow() : Int
    {
	var lastRow = rows;
	if(scrollBottom < lastRow) lastRow = scrollBottom;
	return lastRow;
    }

    private function drawCursor() {
	if(!cursorIsShown) {
	    var y = cursY_ + displayOffset;
	    if(y >= rows) return;
	    var position = new Point(cursX_ * fontWidth, y * fontHeight);
	    var colorTransform = new ColorTransform(
		    -1,
		    -1,
		    -1,
		    1,
		    255,
		    255,
		    255,
		    0);
	    this.bitmapData.colorTransform(
		    new Rectangle(position.x, position.y,
			          fontWidth, fontHeight),
		    colorTransform);
	    cursorIsShown = true;
	}
    }

    private function removeCursor_() {
	if(cursorIsShown) {
	    cursorIsShown = false;
	    drawCursor();
	    cursorIsShown = false;
	}
    }

    // Converts a 256-colour to a 3-byte colour.
    // Only dim & bright are looked at from the attributes
    // and they are only used for the 8 system colours.
    private function getColour(c : Int, attributes : Int) : Int {
	if(c < 16) {
	    if(attributes & ATT_DIM != 0) {
		if(attributes & ATT_BRIGHT == 0) {
		    c = colours[c];
		    c = c >> 1;
		    c &= 0x8080;
		    // Clear the top bits since they should not be set.
		    return c;
		}
	    } else if(attributes & ATT_BRIGHT != 0) {
		c += 8;
	    }
	    return colours[c];
	}
	c -= 16;
	var r;
	var g;
	var b;
	if(c < 216) {
	    r = Math.floor(c / 36);
	    g = Math.floor(c / 6) % 6;
	    b = c % 6;
	    r = Math.floor(255*r/6);
	    g = Math.floor(255*g/6);
	    b = Math.floor(255*b/6);
	} else {
	    c -= 216;
	    // Gray-scale:
	    c = Math.floor(((255-8)*c+8)/24);
	    r = c;
	    g = c;
	    b = c;
	}
	return (r << 16) + (g << 8) + b;
    }

    private function updateFontBoundries(t)
    {
	var r = t.getCharBoundaries(0);

	var currWidth = Math.ceil(r.width);
	var currHeight = Math.ceil(r.height);

	if(currWidth > fontWidth) fontWidth = currWidth;
	if(currHeight > fontHeight) fontHeight = currHeight;
    }

    private function initFont()
    {
	fontWidth = 0;
	fontHeight = 0;

	var nrOfFonts = 8;

	unicodeDict = new Array();
	for(i in 0 ... nrOfFonts) {
	    unicodeDict.push(new Dictionary(false));
	}

	var format = new TextFormat();
	format.size = 13;
	format.font = "Courier";
	format.italic = true;
	format.underline = true;

	var t = new TextField();
	t.defaultTextFormat = format;
	t.backgroundColor = 0;
	t.textColor = 0xFFFFFF;
	t.antiAliasType = flash.text.AntiAliasType.ADVANCED;
	t.text = "W";

	updateFontBoundries(t);

	fontCopyRect = new Rectangle(0, 0, fontWidth, fontHeight);

	var numChars = 256;

	fontBitmap = new BitmapData((numChars-32) * fontWidth,
		nrOfFonts * fontHeight,
		false,
		0);

	var i = -1;
	while(++i < nrOfFonts) {

	    format.italic = (i & 1);
	    format.underline = (i & 2);
	    format.bold = (i & 4) != 0;
	    t.defaultTextFormat = format;

	    var j = 32-1;
	    var matrix = new Matrix();
	    while(++j < numChars) {
		t.text = String.fromCharCode(j);
		matrix.ty = -2 + fontHeight*i;
		matrix.tx = (j-32) * fontWidth - 2;
		fontBitmap.draw(t, matrix);
	    }
	}
	if(debug) {
	    // flash.Lib.current.addChild(new Bitmap(fontBitmap));
	}
    }

    private function addFontToDictionary(b : Int, typeOfFont : Int) : BitmapData
    {
	var format = new TextFormat();
	format.size = 13;
	format.font = "Courier New";
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

	unicodeDict[typeOfFont][b] = newBitmap;
	return newBitmap;
    }

    private function getFgColour(currentAttribute : Int) : Int
    {
	if((currentAttribute & ATT_INVERT) == 0) {
	    var c = 255 & currentAttribute;
	    return getColour(c, currentAttribute);
	} else {
	    return getColour(255 & (currentAttribute >> 8), 0);
	}
    }

    private function getBgColour(currentAttribute : Int) : Int
    {
	if((currentAttribute & ATT_INVERT) != 0) {
	    var c = 255 & currentAttribute;
	    return getColour(c, currentAttribute);
	} else {
	    return getColour(255 & (currentAttribute >> 8), 0);
	}
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
	oldLineAttribs[last-1] = 0;
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
	    // charBuffer[pos] = 0;
	    // attrBuffer[pos] = ATT_UPDATED | currentAttribute;
	}
    }

    private function printChar_(b : Int)
    {
	if(cursX_ >= columns) {
	    if(autoWrapMode) {
		cursX_ = 0;
		lineFeed_();
	    } else {
		cursX_ = columns - 1;
	    }
	}
	printCharAt_(b, cursX_++, cursY_);
    }

    private function insertChar_(b : Int)
    {
	if(cursX_ >= columns) {
	    cursX_ = 0;
	    lineFeed_();
	}
	insertCharAt_(b, cursX_++, cursY_);
    }

    public function printCharWithAttribute_(b : Int, attrib : Int)
    {
	var oldAttrib = currentAttribute;
	currentAttribute = attrib;
	printChar_(b);
	currentAttribute = oldAttrib;
    }

    private inline function printCharAt_(b : Int, x : Int, y : Int)
    {
	var pos = x + y*columns;
	if((charBuffer[pos] != b) ||
	   (currentAttribute != (attrBuffer[pos] & ~ATT_UPDATED))) {
	    charBuffer[pos] = b;
	    attrBuffer[pos] = currentAttribute | ATT_UPDATED;
	}
    }

    private inline function insertCharAt_(b : Int, x : Int, y : Int)
    {
	var pos = x + y*columns;
	for(i in 1...(columns-x)) {
	    copyChar_(columns-i-1, y, columns-i, y);
	}
	if((charBuffer[pos] != b) ||
	   (currentAttribute != (attrBuffer[pos] & ~ATT_UPDATED))) {
	    charBuffer[pos] = b;
	    attrBuffer[pos] = currentAttribute | ATT_UPDATED;
	}
    }

    private inline function drawCharAt(x : Int, y : Int)
    { 
	var pos = x + y*columns;
	var b = charBuffer[pos];
	attrBuffer[pos] &= ~ATT_UPDATED;

	if(y + displayOffset < rows) {
	    var currentAttribute = attrBuffer[pos];
	    drawCharAndAttrAt(b, currentAttribute, x, y + displayOffset);
	}
    }

    private function drawCharAndAttrAt(b : Int, currentAttribute : Int, x : Int, y : Int)
    { 
	var fStyle = 0;
	if(b != -1) {
	    if(currentAttribute & ATT_ITALIC != 0) fStyle |= 1;
	    if(currentAttribute & ATT_UNDERLINE != 0) fStyle |= 2;
	    if(currentAttribute & ATT_BOLD != 0) fStyle |= 4;
	} else b = 32;

	if(startOfSelectionX >= 0) {
	    if(y >= startOfSelectionRow && y <= endOfSelectionRow) {
		if(y == startOfSelectionRow) {
		    if(x >= startOfSelectionColumn) {
			if(y == endOfSelectionRow) {
			    if(x <= endOfSelectionColumn) {
				currentAttribute ^= ATT_INVERT;
			    }
			} else {
			    currentAttribute ^= ATT_INVERT;
			}
		    }
		} else if(y == endOfSelectionRow) {
		    if(x <= endOfSelectionColumn) {
			currentAttribute ^= ATT_INVERT;
		    }
		} else {
		    currentAttribute ^= ATT_INVERT;
		}
	    }
	}

	var bitmap : BitmapData;
	if(b > 255) {
	    // unicode
	    bitmap = unicodeDict[fStyle][b];
	    if(bitmap == null) {
		// trace("Adding new char to the dictionary");
		bitmap = addFontToDictionary(b, fStyle);
	    }
	    fontCopyRect.x = 0;
	    fontCopyRect.y = 0;
	} else {
	    if(b <= 32) b = 0;
	    else if(b >= 128 && b <= 160) b = 0;
	    else b -= 32;

	    fontCopyRect.x = b * fontWidth;
	    fontCopyRect.y = fStyle * fontHeight;

	    bitmap = fontBitmap;
	}

	var position = new Point(x * fontWidth, y * fontHeight);

	var lFg = getFgColour(currentAttribute);
	var lBg = getBgColour(currentAttribute);

	var fgR = lFg >> 16;
	var fgG = 255 & (lFg >> 8);
	var fgB = 255 & lFg;
	var bgR = lBg >> 16;
	var bgG = 255 & (lBg >> 8);
	var bgB = 255 & lBg;

	this.bitmapData.copyPixels(bitmap, fontCopyRect, position);
	var colorTransform = new ColorTransform(
		(fgR-bgR)/255, (fgG-bgG)/255, (fgB-bgB)/255, 1,
		bgR, bgG, bgB, 0);
	this.bitmapData.colorTransform(new Rectangle(position.x, position.y, fontWidth, fontHeight), colorTransform);
    }

    private function lineFeed_()
    {
	var lastRow = getLastRow();
	cursY_++;
	if(cursY_ == lastRow) {
	    cursY_ = lastRow-1;
	    if(extraCursY >= scrollTop &&
	       extraCursY < lastRow)
	    	extraCursY--;
	    scrollUp_();
	} else if(cursY_ >= rows) {
	    cursY_ = rows-1;
	}
    }

    private function copyChar_(fromX : Int, fromY : Int, toX : Int, toY : Int)
    {
	var fromPos = fromX + fromY * columns;
	var toPos = toX + toY * columns;

	if(charBuffer[fromPos] == charBuffer[toPos] &&
	   attrBuffer[fromPos] == attrBuffer[toPos]) return;

	charBuffer[toPos] = charBuffer[fromPos];
	attrBuffer[toPos] = attrBuffer[fromPos] | ATT_UPDATED;
    }

    private function setColoursDefault()
    {
	setBgColour(-1);
	setFgColour(-1);
    }
}
