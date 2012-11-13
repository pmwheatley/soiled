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

/**
   The attributes of each character in the CharBuffer is manipulated
   via this class.
**/
class CharAttributes {

    /*
       The character attributes bits are:
       0..7 fg-colour (xterm 256-colour format).
       8..15 bg-colour.
       16..30 special attributes, defined below:
     */
    private static inline var ATT_BRIGHT = 1 << 16;
    private static inline var ATT_DIM = 1 << 17;
    private static inline var ATT_INVERT = 1 << 18;
    private static inline var ATT_STRIKE = 1 << 19;
    private static inline var ATT_UNDERLINE = 1 << 20;
    private static inline var ATT_ITALIC = 1 << 21;
    private static inline var ATT_BOLD = 1 << 22;

    private static inline var ATT_TILE = 1 << 29;
    /* If this attribute is set, the character needs to redrawn */
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

    public static function setDebug()
    {
	colours[0] = 0x333333;
    }

    /**
      Sets the colours from the values of a 6*16 character
      long string of hex encoded colours.
     **/
    public static function setColours(text : String)
    {
	if(text.length != 16*6) {
	    trace("The colours parameter does not have 16*6 characters");
	    return;
	}
	for(i in 0...15) {
	    colours[i] = Std.parseInt('0x' + text.substr(i*6, 6));
	}
    }

    public static function getRGBColour(c)
    {
	return colours[c];
    }

    private var attribs : Int;

    public function new(?other : CharAttributes)
    {
	if(other == null) setDefaultAttributes();
	else attribs = other.attribs;
    }

    /* Sets the attributes to the default values */
    public function setDefaultAttributes()
    {
	attribs = 0;
	setColoursDefault();
    }

    /* Returns a clone of this CharAttribute, without
       the update flag */
    public inline function clone()
    {
	var ret = new CharAttributes(this);
	ret.setUpdated();
	return ret;
    }

    /** Compared two CharAttributes values, except their Updated status. **/
    public inline function equal(other : CharAttributes)
    {
	return (attribs & ~ATT_UPDATED) == (other.attribs & ~ATT_UPDATED);
    }

    public inline function isBold()
    {
	return (attribs & ATT_BOLD) != 0;
    }

    /* Turns on the bold attribute */
    public inline function setBold()
    {
	attribs |= ATT_BOLD;
    }

    /* Turns off the bold attribute */
    public inline function resetBold()
    {
	attribs &= ~ATT_BOLD;
    }

    public inline function isBright()
    {
	return (attribs & ATT_BRIGHT) != 0;
    }

    /* Turns on the bright attribute */
    public inline function setBright()
    {
	attribs |= ATT_BRIGHT;
    }

    /* Turns off the bright attribute */
    public inline function resetBright()
    {
	attribs &= ~ATT_BRIGHT;
    }

    public inline function isDim()
    {
	return (attribs & ATT_DIM) != 0;
    }

    /* Turns on the dim attribute */
    public inline function setDim()
    {
	attribs |= ATT_DIM;
    }

    /* Turns off the dim attribute */
    public inline function resetDim()
    {
	attribs &= ~ATT_DIM;
    }

    public inline function isInverted()
    {
	return (attribs & ATT_INVERT) != 0;
    }

    /* Turns on the inverse attribute */
    public inline function setInverted()
    {
	attribs |= ATT_INVERT;
    }

    /* Turns off the inverse attribute */
    public inline function resetInverted()
    {
	attribs &= ~ATT_INVERT;
    }

    public inline function isItalic()
    {
	return (attribs & ATT_ITALIC) != 0;
    }

    /* Turns on the italic attribute */
    public inline function setItalic()
    {
	attribs |= ATT_ITALIC;
    }

    /* Turns off the italic attribute */
    public inline function resetItalic()
    {
	attribs &= ~ATT_ITALIC;
    }

    public inline function isUnderline()
    {
	return (attribs & ATT_UNDERLINE) != 0;
    }

    /* Turns on the underline attribute */
    public inline function setUnderline()
    {
	attribs |= ATT_UNDERLINE;
    }

    /* Turns off the underline attribute */
    public inline function resetUnderline()
    {
	attribs &= ~ATT_UNDERLINE;
    }

    /* Is this a tile? */
    public inline function isTile()
    {
	return (attribs & ATT_TILE) != 0;
    }

    /* Turns on the tile attribute */
    public inline function setIsTile()
    {
	attribs |= ATT_TILE;
	return this;
    }

    /* Turns off the tile attribute */
    public inline function resetIsTile()
    {
	attribs &= ~ATT_TILE;
	return this;
    }

    /* Is this glyph/tile updated? */
    public inline function isUpdated()
    {
	return (attribs & ATT_UPDATED) != 0;
    }

    /* Turns on the updated attribute */
    public inline function setUpdated()
    {
	attribs |= ATT_UPDATED;
	return this;
    }

    /* Turns off the updated attribute */
    public inline function resetUpdated()
    {
	attribs &= ~ATT_UPDATED;
	return this;
    }

    /* Sets the background colour to c (0..255) */
    public function setBgColour(c : Int)
    {
	if(c == -1) c = 0;
	attribs &= ~(255 << 8);
	attribs |= (255 & c) << 8;
    }

    /* Sets the foreground colour to c (0..255) */
    public function setFgColour(c : Int)
    {
	if(c == -1) c = 3+8;
	attribs &= ~255;
	attribs |= (255 & c);
    }

    /** Returns the RGB colour of the foreground. **/
    public function getFgColour() : Int
    {
	if(!this.isInverted()) {
	    var c = 255 & attribs;
	    return getColour(c, this);
	} else {
	    return getColour(255 & (attribs >> 8), null);
	}
    }

    /** Returns the RGB colour of the background. **/
    public function getBgColour() : Int
    {
	if(this.isInverted()) {
	    var c = 255 & attribs;
	    return getColour(c, this);
	} else {
	    return getColour(255 & (attribs >> 8), null);
	}
    }

     /***********************************/
    /* Private functions go below here */
   /***********************************/

    // Converts a 256-colour to a 3-byte colour.
    // Only dim & bright are looked at from the attributes
    // and they are only used for the 8 system colours.
    private static function getColour(c : Int, attributes : CharAttributes) : Int {
	if(c < 16) {
	    if(attributes != null && attributes.isDim()) {
		if(attributes.isBright()) {
		    c = colours[c];
		    c = c >> 1;
		    c &= 0x8080;
		    // Clear the top bits since they should not be set.
		    return c;
		}
	    } else if(attributes != null && attributes.isBright()) {
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

    private inline function setColoursDefault()
    {
	setBgColour(-1);
	setFgColour(-1);
    }
}
