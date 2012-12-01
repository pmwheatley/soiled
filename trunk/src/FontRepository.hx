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
   A class to encapsulate font handling.
   single line editor (when in line-by-line mode), local-command
   handling and a simple help system.
 */
class FontRepository implements IFontRepository
{
    private var isMonospaceCache : Hash<Bool>;

    public function new()
    {
	this.isMonospaceCache = new Hash<Bool>();
    }

    public function isMonospaceFont(fontName : String) : Bool
    {
	if(isMonospaceCache.exists(fontName)) {
	    return isMonospaceCache.get(fontName);
	}
	var format = new flash.text.TextFormat();
	format.size = 16;
	format.font = fontName;
	format.italic = true;
	format.underline = true;
	var t = new flash.text.TextField();

	t.defaultTextFormat = format;
	t.text = "W i";
	var r = t.getCharBoundaries(0);
	var result : Bool = false;
	if(r != null) {
	    var currWidth0 = Math.ceil(r.width);
	    r = t.getCharBoundaries(1);
	    if(r != null) {
		var currWidth1 = Math.ceil(r.width);
		r = t.getCharBoundaries(2);
		if(r != null) {
		    var currWidth2 = Math.ceil(r.width);

		    result = currWidth0 == currWidth1 &&
			currWidth1 == currWidth2;
		}
	    }
	}
	isMonospaceCache.set(fontName, result);
	return result;
    }

    public function getMonospaceFonts()
    {
	var names = new Array<String>();
	for(font in flash.text.Font.enumerateFonts(true)) {
	    if(font.fontStyle == flash.text.FontStyle.REGULAR &&
		    isMonospaceFont(font.fontName))
		names.push(font.fontName);
	}
	return names;
    }
}
