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

class WordWrapper {

    public function new() {
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
}
