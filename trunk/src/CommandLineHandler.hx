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

import flash.ui.Keyboard;
import flash.events.KeyboardEvent;

// TODO: Implement Application Keypad.

class CommandLineHandler
{

    private static inline var UTF_ERROR = 0xFFFD;

    private var cb : CharBuffer;

    private var sendByte : Int -> Void;
    private var drawPrompt : Void -> Void;

    private var charByChar : Bool;

    /* If the sending charset is UTF-8 */
    private var utfEnabled : Bool;

    private var inputString : String;
    private var inputPosition : Int;
    private var oldInput : String;
    private var oldPosition : Int;
    var inputCursPositionX : Int;
    var inputCursPositionY : Int;

    // Last input is last in the history...
    private var history : Array<String>;
    // Points out which history item we are changing.
    // -1 == new line.
    private var currentHistory : Int;

    private var applicationCursorKeys : Bool;
    private var applicationKeypad : Bool;

    private var config : Config;

    public function new(sendByte : Int -> Void,
	                drawPrompt : Void -> Void,
	                charBuffer : CharBuffer,
			config : Config)
    {
	try {
	    this.sendByte = sendByte;
	    this.drawPrompt = drawPrompt;
	    this.cb = charBuffer;
	    this.config = config;

	    currentHistory = -1;
	    history = new Array<String>();

	    reset();
	} catch ( ex : Dynamic ) {
	    trace(ex);
	}
    }

    public function setUtfCharSet(isOn : Bool)
    {
	utfEnabled = isOn;
    }

    public function setCharByChar(charByChar : Bool) : Void
    {
	if(this.charByChar = charByChar) return;
	this.charByChar = charByChar;
	if(charByChar) {
	    sendCollectedInput(false);
	}
    }

    public function setApplicationCursorKeys(isOn : Bool) : Void
    {
	applicationCursorKeys = isOn;
    }

    public function setApplicationKeypad(isOn : Bool) : Void
    {
	applicationKeypad = isOn;
    }

    public function reset()
    {
	setCharByChar(false);
	inputString = "";
	inputPosition = 0;
    }

    public function removeInputString()
    {
	removeInputStringFrom(0);
    }

    public function drawInputString()
    {
	drawInputStringFrom(0);
    }

    public function handleKey(e : KeyboardEvent)
    {
	handleKey_(e);
	cb.endUpdate();
    }

    public function doPaste(s : String)
    {
	for(i in 0...s.length) {
	    var c = s.charCodeAt(i);
	    if(c == 10) handleEnter(); // LF
	    else if(c == 13) 0; // CR, ignore.
	    else if(isCharByCharMode()) {
		sendChar(c);
	    } else {
		if(c >= 32) handleNormalKey(c);
		else if(c == 9) { // TAB
		    handleCtrlKey(c);
		}
	    }
	}
	cb.endUpdate();
    }

    // Appends local text.
    private function appendText(s : String)
    {
	cb.appendText(s);
	cb.setExtraCurs(cb.getCursX(), cb.getCursY());
    }

    private function updateInputCursPosition(toChar : Int)
    {
	inputCursPositionX = cb.getExtraCursX();
	inputCursPositionY = cb.getExtraCursY();
	while(toChar-- > 0) {
	    if(++inputCursPositionX >= cb.getWidth()) {
		inputCursPositionX = 0;
		if(++inputCursPositionY == cb.getLastRow()) {
		    inputCursPositionY--;
		    cb.scrollUp();
		} else if(inputCursPositionY >= cb.getHeight()) {
		    inputCursPositionY--;
		}
	    }
	}
	cb.setCurs(inputCursPositionX, inputCursPositionY);
    }

    private function removeInputStringFrom(fromChar : Int)
    {
	// if(!localEcho || promptWaiting) return;
	if(inputString.length > fromChar) {
	    updateInputCursPosition(fromChar);
	    while(fromChar++ < inputString.length) {
		cb.printChar(32);
	    }
	    cb.setCurs(inputCursPositionX, inputCursPositionY);
	}
    }

    private function drawInputStringFrom(fromPos : Int)
    {
	// if(!localEcho || promptWaiting) return;
	if(inputString.length > fromPos) {
	    updateInputCursPosition(fromPos);
	    while(fromPos < inputString.length) {
		cb.printChar(inputString.charCodeAt(fromPos++));
	    }
	    updateInputCursPosition(inputPosition);
	}
    }

    private function updateInputPosition(pos : Int)
    {
	inputPosition = pos;
	updateInputCursPosition(pos);
    }

    private function handleDelete()
    {
        if(inputString.length > inputPosition) {
            removeInputStringFrom(inputPosition);
            var s = inputString.substr(0, inputPosition);
            s += inputString.substr(inputPosition+1, inputString.length - inputPosition - 1);
            inputString = s;
            drawInputStringFrom(inputPosition);
        }
    }

    private function handleBackspace()
    {
	if(inputPosition > 0) {
	    removeInputStringFrom(inputPosition-1);
	    var s = inputString.substr(0, inputPosition-1);
	    if(inputPosition < inputString.length) {
		s += inputString.substr(inputPosition, inputString.length - inputPosition);
		inputPosition--;
		inputString = s;
		drawInputStringFrom(inputPosition);
	    } else {
		inputPosition--;
		inputString = s;
	    }
	}
    }
    
    private function sendFKey(num : Int)
    {
	sendByte(27); // ESC
	sendByte(91); // [
	if(num > 10) {
	    var n = Math.floor(num / 10);
	    sendByte(48 + n);
	    num %= 10;
	}
	sendByte(48 + num);
	sendByte(126); // ~
    }

    private function sendArrowKey(num : Int)
    {
	sendByte(27); // ESC
	if(applicationCursorKeys) {
	    sendByte(79); // O
	} else {
	    sendByte(91); // [
	}
	sendByte(num); // A-D
    }

    private function sendCollectedInput(sendReturn : Bool)
    {
	if(sendReturn || inputString.length > 0) {
	    for(i in 0...inputString.length) {
		sendChar(inputString.charCodeAt(i));
	    }
	    if(sendReturn) {
		this.sendByte(13); // CR
		this.sendByte(10); // LF
	    }
	}

	inputString = "";
	inputPosition = 0;
    }

    private inline function getArgs(last : Int)
    {
	return StringTools.trim(inputString.substr(last));
    }

    private function handleLocalCommands(cmd : String, first : Int, last : Int)
    {
	if(cmd == "/help" || cmd == "/?" ) {
	    var args = getArgs(last);
	    if(args.length == 0) {
		appendText(
			"\r\nLocal commands start with a '/' character. If you really want to send\r\n" +
			"such a command to the server, write an extra '/' character before it.\r\n" +
			"\r\n" +
			"Known commands are:\r\n" +
			"/addinput <text> - adds <text> to the input buffer.\r\n" +
			"/alias - lists defined aliases.\r\n" +
			"/alias <name> - displays the <name> alias' <value>.\r\n" +
			"/alias <name> <value> - binds <name> as an alias to <value>.\r\n" +
			"/help <topic> - read about <topic>.\r\n" +
			"/help topics - a list of available topics.\r\n" +
			"/set - list defined variables.\r\n" +
			"/set <name> - displays the variable's value.\r\n" +
			"/set <name> <value> - sets the variable.\r\n" +
			"/unalias <name> - removes the alias.\r\n" +
			"/unset <name> - removes the variable.");
	    } else {
		switch(args) {
		    case "aliases":
			appendText(
				"\r\n" +
				"Aliases\r\n" +
				"-------\r\n" +
				"Aliases substitute a written command for some other text.\r\n" +
				"\r\nAn example:\r\n" +
			        "# /alias test say Test!\r\n" +
			        "# test Nisse\r\n" +
			        "You say Test! Nisse\r\n\r\n" +
				"One alias can send two or more commands to the server,\r\n" +
				"just separete them with %; like this:\r\n" +
				"# /alias test say Hi! %; say\r\n" +
				"# test Ho!\r\n" +
				"You say Hi!\r\n" +
				"You say Ho!\r\n" +
				"\r\n" +
				"If you want your alias to send a single % character, write %% instead.\r\n"
				);
		    case "keys":
			appendText(
				"\r\n" +
				"CTRL + A - Move cursor to the beginning of the line.\r\n" +
				"CTRL + E - Move cursor to the end of the line.\r\n" +
				"CTRL + B - Move cursor one character to the left/back.\r\n" +
				"CTRL + F - Move cursor one character to the right/forward.\r\n" +
				"CTRL + D/DEL - Delete one character under the cursor.\r\n" +
				"CTRL + H/BACKSPACE - Delete the character to the left of the cursor.\r\n" +
				"CTRL + W - Delete the word to the left of the cursor.\r\n" +
				"CTRL + U - Delete to the beginning of the line.\r\n" +
				"CTRL + K - Delete to the end of the line.\r\n" +
				"CTRL + L - Clear the whole screen.\r\n" +
				"CTRL + M/ENTER - Send the written text.\r\n" +
				"CTRL + P - Exchange the input for the previous input line in the history.\r\n" +
				"CTRL + N - Exchange the input for the next input line in the history.\r\n" +
				"SHIFT + PAGE UP/DOWN - scroll back to previous text.");
		    case "macros":
			appendText(
				"\r\n" +
				"Macros\r\n" +
				"------\r\n" +
				"Macros are commands bound to a single command. You use the /alias\r\n" +
			       	"command to define them, but they do not work like aliases, they work\r\n" +
			       	"like you had written the alias' text directly on the input line.\r\n" +
				"The name of a macro is of the format KEY_<name>[_[S][C][A]]\r\n" +
				"The name is one of HOME, END, F1..F12, PGUP, PGDN, UP, DOWN, LEFT or RIGHT\r\n" +
				"and the _S, _C or _A suffixes (and combinations like _SA)\r\n" +
				"are used when the key is pressed together with shift, ctrl or alt/option.\r\n" +
				"\r\n" +
				"An example:\r\n" +
				"# /alias KEY_F1 /help\r\n" +
				"# /alias KEY_F1_S //help\r\n" +
				"# /alias KEY_F1_SCA help\r\n" +
				"\r\n" +
				"Will cause \"/help\" to be entered when you press F1, \"/help\" is sent to\r\n" +
				"the server when you press shift+F1 and \"help\" will be sent when you\r\n" +
				"press shift+ctrl+alt+F1\r\n" +
				"Please note that the order of SCA is important if you use combinations\r\n" +
				"and not all combiations/characters are possible to enter.\r\n" +
				"\r\n" +
				"If a macro isn't defined for a key, but the variable \"LOCAL_EDIT\" is\r\n" +
				"set to \"on\", then some internal function may be used.\r\n" +
				"If \"LOCAL_EDIT\" isn't defined, a control sequence will be sent to the server."
				);
		    case "vars", "variables":
			appendText(
				"\r\n" +
				"Variables\r\n" +
				"---------\r\n" +
				"Variables hold a value. Currently they are used for changing the way\r\n" +
			       	"the client works. The known variables are:\r\n" +
			       	"LANG: What language the OS is set to. Only set once.\r\n" +
			       	"LOCAL_EDIT: When set to \"on\", some of the keys are used for local line" +
			        "            editing instead of being sent to the server.\r\n" +
			       	"OS: What platform the client is running on. Only set once.\r\n" +
				"");
		    default:
			appendText(
				"\r\nAvailable topics are:" +
				"\r\naliases - how aliases work." +
				"\r\nmacros - how macros work." +
				"\r\nkeys - the key bindings." +
				"\r\ntopics - this list." +
				"\r\nvariables - how variables work/built in variables." +
				"");
		}
	    }
	} else if(cmd == "/addinput") {
	    cmd = StringTools.trim(inputString.substr(last));
	    if(cmd.length == 0) {
		appendText("\r\n%add what input?");
	    } else {
		if(oldPosition == oldInput.length) {
		    oldInput += cmd;
		} else {
		    var s = oldInput.substr(0, oldPosition) +
			cmd +
			oldInput.substr(oldPosition, oldInput.length - oldPosition);
		    oldInput = s;
		}
		oldPosition += cmd.length;
		return false;
	    }
	} else if(cmd == "/alias") {
	    cmd = StringTools.trim(inputString.substr(last));
	    if(cmd.length == 0) {
		for(alias in config.getAliases().keys()) {
		    appendText("\r\n/alias " + alias + " " + config.getAliases().get(alias));
		}
	    } else {
		first = cmd.indexOf(" ");
		if(first == -1) {
		    if(config.getAliases().exists(cmd)) {
			appendText("\r\n/alias " + cmd + " " + config.getAliases().get(cmd));
		    }
		} else {
		    inputString = StringTools.ltrim(cmd.substr(first));
		    cmd = cmd.substr(0, first);
		    config.getAliases().set(cmd, inputString);
		    config.saveAliases();
		}
	    }
	} else if(cmd == "/save") {
	    config.save();
	    appendText("\r\n%Saved config.");
	} else if(cmd == "/set") {
	    cmd = StringTools.trim(inputString.substr(last));
	    if(cmd.length == 0) {
		for(v in config.getVars().keys()) {
		    appendText("\r\n/set " + v + " " + config.getVar(v));
		}
	    } else {
		first = cmd.indexOf(" ");
		if(first == -1) {
		    if(config.getVars().exists(cmd)) {
			appendText("\r\n/set " + cmd + " " + config.getVar(cmd));
		    }
		} else {
		    inputString = StringTools.ltrim(cmd.substr(first));
		    cmd = cmd.substr(0, first);
		    config.setVar(cmd, inputString);
		    config.saveVars();
		}
	    }
	} else if(cmd == "/unalias") {
	    cmd = StringTools.trim(inputString.substr(last));
	    if(!config.getAliases().exists(cmd)) {
		appendText("\r\n% unalias: \"" + cmd + "\": no such alias");
	    } else {
		config.getAliases().remove(cmd);
		config.saveAliases();
	    }
	} else if(cmd == "/unset") {
	    cmd = StringTools.trim(inputString.substr(last));
	    if(config.getVar(cmd) == null) {
		appendText("\r\n% unset: \"" + cmd + "\": no such variable");
	    } else {
		config.getVars().remove(cmd);
		config.saveVars();
	    }
	} else {
	    appendText("\r\n% " + cmd.substr(1) + ": no such command or macro");
	}
	cb.carriageReturn();
	cb.lineFeed();
	cb.setExtraCurs(cb.getCursX(), cb.getCursY());
	return true;
    }

    private inline function isCharByCharMode() : Bool
    {
	return charByChar;
    }

    private function sendUnicode(c : Int)
    {
	if(c < 0) {
	    trace("Trying to send a unicode value: " + c);
	    sendUnicode(UTF_ERROR);
	} else if(c < 128) sendByte(c);
	else if(c < 0x800) {
	    //trace("Sending unicode: " + StringTools.hex(c, 4));
	    sendByte((0x1f & (c>>6)) | 0xC0);
	    //trace("Sending: " + StringTools.hex((0x1f & (c>>6)) | 0xC0));
	    sendByte((0x3f & c) | 0x80);
	    //trace("Sending: " + StringTools.hex((0x3f & c) | 0x80));
	} else if(c < 0x10000) {
	    // trace("Sending unicode: " + StringTools.hex(c, 4));
	    // trace(StringTools.hex((0x0f & (c>>12)) | 0xE0));
	    // trace(StringTools.hex((0x3f & (c>>6)) | 0x80));
	    // trace(StringTools.hex((0x3f & c) | 0x80));
	    sendByte((0x0f & (c>>12)) | 0xE0);
	    sendByte((0x3f & (c>>6)) | 0x80);
	    sendByte((0x3f & c) | 0x80);
	} else if(c < 0x200000) {
	    sendByte((0x07 & (c>>18)) | 0xF0);
	    sendByte((0x3f & (c>>12)) | 0x80);
	    sendByte((0x3f & (c>>6)) | 0x80);
	    sendByte((0x3f & c) | 0x80);
	} else if(c < 0x4000000) {
	    sendByte((0x03 & (c>>24)) | 0xF8);
	    sendByte((0x3f & (c>>18)) | 0x80);
	    sendByte((0x3f & (c>>12)) | 0x80);
	    sendByte((0x3f & (c>>6)) | 0x80);
	    sendByte((0x3f & c) | 0x80);
	} else {
	    trace("Trying to send a unicode value: " + c);
	    sendUnicode(UTF_ERROR);
	}
    }

    private inline function sendChar(c : Int)
    {
	if(utfEnabled) sendUnicode(c);
	else sendByte(c);
    }

    private function addToCommandHistory(inputString : String)
    {
	if(inputString.length > 0) {
	    if(currentHistory != -1) {
		history[history.length-1] = new String(inputString);
		currentHistory = -1;
	    } else {
		history.push(new String(inputString));
	    }
	}
    }

    private function expandAliasAndSendCommand(cmd : String, rest : String)
    {
	var tmp = new StringBuf();
	var newCmd = config.getAliases().get(cmd);
	var i = 0;
	while(i < newCmd.length) {
	    if(i+1 < newCmd.length &&
		    newCmd.charCodeAt(i) == 37 &&
		    newCmd.charCodeAt(i+1) == 59) {
		i++;
		inputString = tmp.toString();
		sendCollectedInput(true);
		tmp = new StringBuf();
	    } else if(i+1 < newCmd.length &&
		    newCmd.charCodeAt(i) == 37 &&
		    newCmd.charCodeAt(i+1) == 37) {
		i++;
		tmp.addChar(37);
	    } else {
		tmp.addChar(newCmd.charCodeAt(i));
	    }
	    i++;
	}
	tmp.add(rest);
	inputString = tmp.toString();
    }

    // Returns true if the command was handled.
    private function handlePossiblyLocalCommands() : Bool
    {
	if(inputString.length > 0) {
	    var first = 0;
	    while(first < inputString.length) {
		if(inputString.charCodeAt(first) != 32) break;
		first++;
	    }
	    var last = first;
	    while(last < inputString.length) {
		if(inputString.charCodeAt(last) == 32) break;
		last++;
	    }
	    if(last > first) {
		var cmd = inputString.substr(first, last-first);
		if(cmd.charCodeAt(0) == 47) {
		    // local command...
		    if(last > (first+1) && cmd.charCodeAt(1) == 47) {
			// Really send /cmd...
			if(first == 0) {
			    inputString = inputString.substr(1);
			} else {
			    inputString = inputString.substr(0, first) +
				inputString.substr(first+1);
			}
			return false;
		    } else {
			if(handleLocalCommands(cmd, first, last)) {
			    inputString = "";
			    inputPosition = 0;
			}
			return true;
		    }
		} else {
		    // Macro expansion?
		    if(config.getAliases().exists(cmd)) {
			var rest = inputString.substr(last);
			expandAliasAndSendCommand(cmd, rest);
			return false;
		    } else {
			return false;
		    }
		}
	    }
	}
	return false;
    }

    private function handleEnter()
    {
	if(isCharByCharMode()) {
	    sendByte(13);
	    sendByte(10);
	    return;
	}

	addToCommandHistory(inputString);
	if(! handlePossiblyLocalCommands()) {
	    sendCollectedInput(true);
	    cb.carriageReturn();
	    cb.lineFeed();
	    cb.setExtraCurs(cb.getCursX(), cb.getCursY());
	}
	drawPrompt();
    }

    private function handleCtrlKey(c : Int)
    {
	if(c == 0) return;

	if(c < 32) c += 96;
	switch(c) {
	    case 97: // A
		updateInputPosition(0);
	    case 98: // B
		if(inputPosition > 0) {
		    updateInputPosition(inputPosition-1);
		}
	    case 100: // D
		handleDelete();
	    case 101: // E
		updateInputPosition(inputString.length);
	    case 102: // F
		if(inputPosition < inputString.length) {
		    updateInputPosition(inputPosition+1);
		}
	    case 107: // K
		if(inputPosition != inputString.length) {
		    removeInputStringFrom(inputPosition);
		    inputString = inputString.substr(0, inputPosition);
		    // if(cursorShouldBeVisible) drawCursor();
		}
	    case 108: // L
		cb.clear();
		cb.setCurs(0, 0);
		drawPrompt();
	    case 110: // N
		if(!isCharByCharMode()) {
		    if(currentHistory != -1 &&
			    currentHistory+1 != history.length) {
			removeInputString();
			history[currentHistory] = inputString;
			currentHistory++;
			inputString = history[currentHistory];
			inputPosition = inputString.length;
			drawInputString();
		    }
		}
	    case 112: // P
		if(!isCharByCharMode()) {
		    if(currentHistory == -1) {
			if(history.length > 0) {
			    removeInputString();
			    currentHistory = history.length-1;
			    history.push(inputString);
			    inputString = history[currentHistory];
			    inputPosition = inputString.length;
			    drawInputString();
			}
		    } else if(currentHistory > 0) {
			removeInputString();
			history[currentHistory] = inputString;
			currentHistory--;
			inputString = history[currentHistory];
			inputPosition = inputString.length;
			drawInputString();
		    }
		}
	    case 117: // U
		if(inputPosition > 0) {
		    removeInputString();
		    inputString = inputString.substr(inputPosition, inputString.length - inputPosition);
		    inputPosition = 0;
		    drawInputString();
		}
	    case 119: // W
		if(inputPosition > 0) {
		    var x = inputPosition;
		    while((x > 0) && StringTools.isSpace(inputString, x-1))
			x--;
		    while((x > 0) && !StringTools.isSpace(inputString, x-1))
			x--;
		    var s = "";
		    if(x > 0) {
			s = inputString.substr(0, x);
		    }
		    if(inputPosition < inputString.length) {
			s += inputString.substr(inputPosition, inputString.length - inputPosition);
		    }
		    removeInputStringFrom(x);
		    inputString = s;
		    inputPosition = x;
		    drawInputStringFrom(x);
		}
	}
    }

    private function handleNormalKey(c : Int)
    {
	if(c == 0) return;
	if(c == 27) {
	    sendByte(27);
	    return;
	}

	if(inputPosition == inputString.length) {
	    inputString += String.fromCharCode(c);
	} else {
	    var s = inputString.substr(0, inputPosition) +
		String.fromCharCode(c) +
		inputString.substr(inputPosition, inputString.length - inputPosition);
	    inputString = s;
	}
	inputPosition++;
	drawInputStringFrom(inputPosition-1);
    }

    private function localEditChars() : Bool
    {
	return !isCharByCharMode() && config.getVar("LOCAL_EDIT") == "on";
    }

    private function sendMacro(name : String)
    {
	var key = "KEY_" + name;
	if(config.getAliases().exists(key)) {
	    oldInput = inputString;
	    oldPosition = inputPosition;

	    inputString = config.getAliases().get(key);
	    if(handlePossiblyLocalCommands()) {
		cb.carriageReturn();
		cb.lineFeed();
		cb.setExtraCurs(cb.getCursX(), cb.getCursY());
		inputString = oldInput;
		inputPosition = oldPosition;
		drawPrompt();
	    } else {
		sendCollectedInput(true);
	    }

	    inputString = oldInput;
	    inputPosition = oldPosition;
	    return true;
	} else return false;
    }

    private function handleFKey(e : KeyboardEvent,
	                        name : String,
				keyNumber : Int,
				fNumber : Int)
    {
	var any = e.shiftKey || e.ctrlKey || e.altKey;
	if(any) {
	    name += "_";
	    if(e.shiftKey) name += "S";
	    if(e.ctrlKey) name += "C";
	    if(e.altKey) name += "A";
	    sendMacro(name);
	} else if(sendMacro(name)) {
	    // Done.
	} else if(localEditChars()) {
	    handleCtrlKey(keyNumber);
	} else {
	    sendFKey(fNumber);
	}
    }

    private function handleArrowKey(e : KeyboardEvent,
	                            name : String,
				    keyNumber : Int,
				    aNumber : Int)
    {
	var any = e.shiftKey || e.ctrlKey || e.altKey;
	if(any) {
	    name += "_";
	    if(e.shiftKey) name += "S";
	    if(e.ctrlKey) name += "C";
	    if(e.altKey) name += "A";
	    sendMacro(name);
	} else if(sendMacro(name)) {
	    // Done.
	} else if(keyNumber >= 0 && localEditChars()) {
	    handleCtrlKey(keyNumber);
	} else {
	    sendArrowKey(aNumber);
	}
    }

    private function handleKey_(e : KeyboardEvent)
    {
	try {

	    var isTextInput = e.type == "textInput";
	    var c = e.charCode;

	    switch(e.keyCode) {
		case Keyboard.PAGE_UP:
		    if(isTextInput) return;
		    if(e.shiftKey) {
			cb.scrollbackUp();
		    } else handleFKey(e, "PGUP", 112, 5);
		case Keyboard.PAGE_DOWN:
		    if(isTextInput) return;
		    if(e.shiftKey) {
			cb.scrollbackDown();
		    } else handleFKey(e, "PGDN", 110, 6);
		case Keyboard.UP:
		    if(isTextInput) return;
		    handleArrowKey(e, "UP", 112, 65);
		case Keyboard.DOWN:
		    if(isTextInput) return;
		    handleArrowKey(e, "DOWN", 110, 66);
		case Keyboard.RIGHT:
		    if(isTextInput) return;
		    handleArrowKey(e, "RIGHT", 102, 67);
		case Keyboard.LEFT:
		    if(isTextInput) return;
		    handleArrowKey(e, "LEFT", 98, 68);
		case Keyboard.END:
		    if(isTextInput) return;
		    handleArrowKey(e, "END", 101, 70);
		case Keyboard.HOME:
		    if(isTextInput) return;
		    handleArrowKey(e, "HOME", 97, 72);
		case Keyboard.F1:
		    if(isTextInput) return;
		    handleFKey(e, "F1", -1, 11);
		case Keyboard.F2:
		    if(isTextInput) return;
		    handleFKey(e, "F2", -1, 12);
		case Keyboard.F3:
		    if(isTextInput) return;
		    handleFKey(e, "F3", -1, 13);
		case Keyboard.F4:
		    if(isTextInput) return;
		    handleFKey(e, "F4", -1, 14);
		case Keyboard.F5:
		    if(isTextInput) return;
		    handleFKey(e, "F5", -1, 15);
		case Keyboard.F6:
		    if(isTextInput) return;
		    handleFKey(e, "F6", -1, 17);
		case Keyboard.F7:
		    if(isTextInput) return;
		    handleFKey(e, "F7", -1, 18);
		case Keyboard.F8:
		    if(isTextInput) return;
		    handleFKey(e, "F8", -1, 19);
		case Keyboard.F9:
		    if(isTextInput) return;
		    handleFKey(e, "F9", -1, 20);
		case Keyboard.F10:
		    if(isTextInput) return;
		    handleFKey(e, "F10", -1, 21);
		case Keyboard.F11:
		    if(isTextInput) return;
		    handleFKey(e, "F11", -1, 23);
		case Keyboard.F12:
		    if(isTextInput) return;
		    handleFKey(e, "F12", -1, 24);
                case Keyboard.INSERT:
		    if(isTextInput) return;
		    cb.scrollbackToBottom();
		    if(isCharByCharMode()) handleFKey(e, "INSERT", -1, 2);
                case Keyboard.DELETE:
	 	    if(isTextInput) return;
	            cb.scrollbackToBottom();
		    if(isCharByCharMode()) handleFKey(e, "DELETE", -1, 3);
		    else handleDelete();
                case Keyboard.BACKSPACE:
	 	    if(isTextInput) return;
	            cb.scrollbackToBottom();
		    if(isCharByCharMode()) sendByte(127); // DEL
		    else handleBackspace();
                case Keyboard.TAB:
	 	    if(isTextInput) return;
	            cb.scrollbackToBottom();
		    if(isCharByCharMode()) sendByte(9); // TAB.
                case Keyboard.ENTER:
	 	    if(isTextInput) return;
	            cb.scrollbackToBottom();
		    handleEnter();
                default:
	 	    if(!isTextInput && !e.ctrlKey && c != 27) return;
	 	    if(isTextInput && c < 32) return; // On MAC CTRL-A etc is reported here.
	            cb.scrollbackToBottom();
		    if(isCharByCharMode()) {
		        if(e.ctrlKey && c >= 96) c -= 96;
		        if(c == 0) return; // NUL
		        sendChar(c);
		    } else {
			if(e.ctrlKey) handleCtrlKey(c);
		        else handleNormalKey(c);
		    }
	    }

	} catch(ex : Dynamic) {
	    trace(ex);
	}
    }
}
