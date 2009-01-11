import flash.net.SharedObject;

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
