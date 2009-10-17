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

    public function new()
    {
	loadData();
    }

    public function getAliases()
    {
	return aliases;
    }

    public function getVars()
    {
	return vars;
    }

    public function save()
    {
	saveAliases();
	saveVars();
	sharedData.flush();
    }

    public function saveAliases()
    {
	sharedData.data.aliases = hashToString(aliases);
	sharedData.flush();
    }

    public function saveVars()
    {
	sharedData.data.vars = hashToString(vars);
	sharedData.flush();
    }


    public function getVar(name : String) : Null<String>
    {
	return vars.get(name);
    }

    public function setVar(name : String, value : String) : Void
    {
	vars.set(name, value);
    }

    public function setLastCommand(cmd : String)
    {
	vars.set("LAST_INPUT", cmd);
	if("" != cmd) {
	    vars.set("LAST_CMD", cmd);
	}
    }

    /** Returns the configurable font name to use. **/
    public function getFontName() : String
    {
	var fontName = getVar("FONT_NAME");
	if(fontName == null) fontName = "Courier New";
	return fontName;
    }

    /** Returns the configurable font size to use. **/
    public function getFontSize() : Int
    {
	var fontSizeStr = getVar("FONT_SIZE");
	if(fontSizeStr == null) fontSizeStr = "15";

	var fontSize = Std.parseInt(fontSizeStr);
	if(fontSize < 8) fontSize = 8;
	return fontSize;
    }

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

    private function initAliases()
    {
	aliases.set("KEY_F1", "/help");
    }

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
    }

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
    }
}
