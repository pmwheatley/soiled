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

import flash.net.SharedObject;

/**
  The config class is responsible for loading/storing config values
   and provide a container for them.
**/
class Config
{

    private var sharedData : SharedObject;
    private var aliases : Hash<String>;
    private var vars : Hash<String>;

    private var minWordLength : Int;

    private var cursorType : String;

    private var defaultFgColour : Int;
    private var defaultBgColour : Int;

    /**
      The constructor loads the config values from storage, or
      creates new config values if this is the first visit.
     **/
    public function new()
    {
	loadData();
    }

    /**
      Gets the internal Hash of all aliases
     **/
    public function getAliases()
    {
	return aliases;
    }

    /**
      Gets the internal Hash of all variables
     **/
    public function getVars()
    {
	return vars;
    }

    public function getAutologin() : String
    {
	var s = getVar("AUTO_LOGIN");
	if(s != null) {
	    s = StringTools.replace(s, "\\r", "\r");
	    s = StringTools.replace(s, "\\0", "\000");
	    s = StringTools.replace(s, "\\n", "\n");
	    s = StringTools.replace(s, "\\\\", "\\");
	}
	return s;
    }

    /**
      Saves the aliases and variables to storage/a flash cookie.
     **/
    public function save()
    {
	saveAliases();
	saveVars();
	sharedData.flush();
    }

    /**
      Saves the aliases to storage/a flash cookie.
     **/
    public function saveAliases()
    {
	sharedData.data.aliases = hashToString(aliases);
	sharedData.flush();
    }

    /**
      Saves the variables to storage/a flash cookie.
     **/
    public function saveVars()
    {
	sharedData.data.vars = hashToString(vars);
	sharedData.flush();
    }

    /** Gets the value of the given variable **/
    public function getVar(name : String) : Null<String>
    {
	return vars.get(name);
    }

    /**
      Sets the value of the given variable
     **/
    public function setVar(name : String, value : String) : Void
    {
	vars.set(name, value);
	if(name == "MIN_WORD_LEN" ||
	   name == "FG_COL" ||
	   name == "BG_COL" ||
	   name == "CURSOR_TYPE") {
	    initVarCache();
	}
    }

    /** Gets the value of the MIN_WORD_LEN variable,
        or a suitable default value.
     **/
    public function getMinWordLength() : Int
    {
	return minWordLength;
    }

    /** Gets the value of the WORD_CACHE_TYPE variable.
        It always returns FREQUENCY or LEXIGRAPHIC.
     **/
    public function getWordCacheType() : String
    {
	var v = getVar("WORD_CACHE_TYPE");
	if(v != null && v.length > 0) {
	    var s = v.toUpperCase().charAt(0);
	    if(s == "F") return "FREQUENCY";
	}
	return "LEXIGRAPHIC";
    }

    /** Returns the value of the CURSOR_TYPE variable,
        or a suitable default value.
     **/
    public function getCursorType() : String
    {
	return cursorType;
    }

    /** Gets the value of the FG_COL variable,
        or a suitable default value.
     **/
    public function getDefaultFgColour() : Int
    {
	return defaultFgColour;
    }

    /** Gets the value of the BG_COL variable,
        or a suitable default value.
     **/
    public function getDefaultBgColour() : Int
    {
	return defaultBgColour;
    }

    /**
      Sets the LAST_INPUT and LAST_CMD variables.
     **/
    public function setLastCommand(cmd : String)
    {
	vars.set("LAST_INPUT", cmd);
	if("" != cmd) {
	    vars.set("LAST_CMD", cmd);
	}
    }

    /**
      Returns the configurable font name to use.
     **/
    public function getFontName() : String
    {
	var fontName = getVar("FONT_NAME");
	if(fontName == null) fontName = "Courier New";
	return fontName;
    }

    /**
      Returns the configurable font size to use.
     **/
    public function getFontSize() : Int
    {
	var fontSizeStr = getVar("FONT_SIZE");
	if(fontSizeStr == null) fontSizeStr = "15";

	var fontSize = Std.parseInt(fontSizeStr);
	if(fontSize < 8) fontSize = 8;
	return fontSize;
    }

    /**
      Serializes the Hash<String> object to a string
      that can be stored in a flash cookie
     **/
    private function hashToString(hash : Hash<String>) : String
    {
	var tmp = new StringBuf();
	for(key in hash.keys()) {
	    var cmd = escape(key);
	    var val = escape(hash.get(key));
	    tmp.add(cmd);
	    tmp.add(":");
	    tmp.add(val);
	    tmp.add(":");
	}
	return tmp.toString();
    }

    /**
      Deserializes a string into a Hash<String> value that
      was retrieved from a flash cookie.
     **/
    private function stringToHash(s : String, hash : Hash<String>)
    {
	var arr = s.split(":");
	var i = 0;
	while(i+1 < arr.length) {
	    var key = unescape(arr[i]);
	    var val = unescape(arr[i+1]);
	    // trace("Setting " + key + " to " + val);
	    hash.set(key, val);
	    i += 2;
	}
    }

    /**
      Unescapes a previously escape():ed string when
      it was retrieved from storage.
     **/
    private function unescape(s : String)
    {
	var ret = new StringBuf();
	var i = 0;
	while(i < s.length) {
	    if(s.charCodeAt(i) == 64) { // @
		i++;
		if(s.charCodeAt(i) == 64) {
		    ret.addChar(64);
		} else {
		    ret.addChar(58); // :
		}
	    } else ret.addChar(s.charCodeAt(i));
	    i++;
	}
	return ret.toString();
    }

    /**
      Excapes a string so it can be saved in a cookie.
     **/
    private function escape(s : String)
    {
	var ret = new StringBuf();
	var i = 0;
	while(i < s.length) {
	    if(s.charCodeAt(i) == 64) { // @
		ret.addChar(64);
		ret.addChar(64);
	    } else if(s.charCodeAt(i) == 58) { // :
		ret.addChar(64);
		ret.addChar(65);
	    } else {
		ret.addChar(s.charCodeAt(i));
	    }
	    i++;
	}
	return ret.toString();
    }

    /**
      Sets up the initial aliases that a new user should get.
     **/
    private function initAliases()
    {
	aliases.set("KEY_F1", "/help");
    }

    /**
      Sets up the initial variables that a new user should get.
     **/
    private function initVars()
    {
	var params : Dynamic<String> = flash.Lib.current.loaderInfo.parameters;
	if(params.localEdit != null) {
	    vars.set("LOCAL_EDIT", params.localEdit);
	} else vars.set("LOCAL_EDIT", "on");
	var os = flash.system.Capabilities.version.split(" ")[0];
	var lang = flash.system.Capabilities.language;
	vars.set("OS", os);
	vars.set("LANG", lang);
	vars.set("FONT_SIZE", "15");
	vars.set("FONT_NAME", "Courier New");
	vars.set("MIN_WORD_LEN", "2");
    }

    /**
      Sets up caches copies of variables, to make it slightly faster
      to read their values.
     **/
    private function initVarCache()
    {
	var params : Dynamic<String> = flash.Lib.current.loaderInfo.parameters;

	var val = getVar("MIN_WORD_LEN");
	minWordLength = 2;
	if(val != null) {
	    var v = Std.parseInt(val);
	    if(v != null && v > 2) {
		minWordLength = v;
	    }
	}
	// trace("MIN_WORD_LEN: " + minWordLength);

	val = getVar("FG_COL");
	if(val == null) val = params.defaultFgCol;
	defaultFgColour = 2;
	if(val != null && val.length > 0) {
	    var v = Std.parseInt(val);
	    if(v != null && v >= 0 && v <= 7) {
		defaultFgColour = v;
	    }
	}

	val = getVar("BG_COL");
	if(val == null) val = params.defaultBgCol;
	defaultBgColour = 0;
	if(val != null && val.length > 0) {
	    var v = Std.parseInt(val);
	    if(v != null && v >= 0 && v <= 7) {
		defaultBgColour = v;
	    }
	}

	val = getVar("CURSOR_TYPE");
	if(val == null) val = params.cursorType;
	cursorType = "block";
	if(val != null && val.length > 0) {
	    cursorType = val;
	}
    }

    /**
      Loads the config data from a flash cookie.
     **/
    private function loadData()
    {
	aliases = new Hash();
	vars = new Hash();

	sharedData = SharedObject.getLocal("soiledData");

	if(sharedData.data.version == null || sharedData.data.version != 1) {
	    // First time.
	    trace("Setting new config");

	    sharedData.data.version = 1;
	    sharedData.data.howmanytimes = 1;
	    initAliases();
	    initVars();
	    saveAliases();
	    saveVars();
	} else {
	    sharedData.data.howmanytimes += 1;

	    stringToHash(sharedData.data.aliases, aliases);
	    stringToHash(sharedData.data.vars, vars);
	}
	initVarCache();
    }
}
