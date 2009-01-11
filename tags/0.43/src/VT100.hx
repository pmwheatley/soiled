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
import flash.media.Sound;
import flash.net.URLRequest;
import flash.external.ExternalInterface;
import flash.events.KeyboardEvent;

enum EnuVTInputState {
    VIS_NORMAL;
    VIS_ESC;
    VIS_PARAM;
    VIS_PARAM2;
    VIS_ESC_TWO_CHAR;
}

/*
   VT100 parses input from the server and sends draw requests to the CharBuffer.
   Input from the user is also parsed and send to the server when needed and
   to the CharBuffer while it is being entered.

   Despite its name, it is not a VT100 emulator. It only understands enough of it
   to be usable for common MUDs.

*/
class VT100 implements TelnetEventListener {

    private inline static var UTF_ERROR = 0xFFFD;

    private var cb : CharBuffer;

    private var clh : CommandLineHandler;

    private var config : Config;

    private var sendByte : Int -> Void;

    private var localEcho : Bool;

    private var inputState : EnuVTInputState;

    private var receivedEsc : StringBuf;

    private var tabStops : Array<Bool>;

    // If a two character escape sequence is received, the
    // first char is stored here.
    private var escFirstChar : Int;

    /* If the received charset is UTF-8 */
    private var utfEnabled : Bool;

    /* utfState says how many more bytes that are expected to be received. */
    private var utfState : Int;
    /* utfChar is the Unicode being built up from the received bytes. */
    private var utfChar : Int;
    /* utfLength is used to verify the received utfChar once fully received. */
    private var utfLength : Int;

    private var charset : Int; // 0 or 1 for G0 and G1.
    private var charsets : Array<Int>; // Current designation for G0 .. G3

    var savedAttribs : Int;
    var savedCursX : Int;
    var savedCursY : Int;

    // Used to store the latest printable character, so it may be repeated by REP.
    var latestPrintableChar : Int;

    private var receivedCr : Bool;

    private var promptTimer : flash.utils.Timer;
    private var promptWaiting : Bool;

    private var outputAfterPrompt : Int;

    private var oldPromptString : String;
    private var oldPromptAttribute : Array<Int>;
    private var newPromptString : StringBuf;
    private var newPromptAttribute : Array<Int>;

    // Have a prompt been drawn be us, so we must remove it?
    private var promptHasBeenDrawn : Bool;

    private var gotPreviousInput : Bool;

    private var beepSound : Sound;


    public function new(sendByte : Int -> Void, charBuffer : CharBuffer)
    {
	try {
	    this.cb = charBuffer;
	    newPromptString = new StringBuf();
	    oldPromptAttribute = new Array<Int>();
	    newPromptAttribute = new Array<Int>();

	    config = new Config();

	    this.clh = new CommandLineHandler(sendByte, drawPrompt, cb, config);

	    promptTimer = new flash.utils.Timer(250, 1);
	    promptTimer.addEventListener("timer", promptTimeout);

	    beepSound = new Sound(new URLRequest("beep.mp3")); // MUST BE 44.100kHz!

	    this.sendByte = sendByte;

	    reset();
	} catch ( ex : Dynamic ) {
	    trace(ex);
	}
    }

    public function onResize()
    {
	var hadDrawnPrompt = promptHasBeenDrawn;
	if(hadDrawnPrompt) removePrompt();
	else clh.removeInputString();
	cb.resize();
	if(hadDrawnPrompt) drawPrompt();
	else clh.drawInputString();
	cb.endUpdate();
    }

    public function onMouseDown(x : Int, y : Int, type : Int)
    {
	// XXX
    }

    public function onMouseMove(x : Int, y : Int, type : Int)
    {
	// XXX
    }

    public function onMouseUp(x : Int, y : Int, type : Int)
    {
	// XXX
    }

    public function onMouseDouble(x : Int, y : Int, type : Int)
    {
	// XXX
    }

    // Appends local text.
    public function appendText(s : String)
    {
	cb.appendText(s);
	cb.setExtraCurs(cb.getCursX(), cb.getCursY());
    }

    public function setUtfEnabled(on : Bool)
    {
	utfEnabled = on;
	clh.setUtfCharSet(on);
    }

    private function translateCharset(b : Int) : Int
    {
	switch(charsets[charset]) {
	    case 48:
		if(b >= 0x60 && b <= 0x7F) {
		    var table = [ // Thanks Putty! :-)
			0x2666, 0x2592, 0x2409, 0x240c, 0x240d, 0x240a, 0x00b0, 0x00b1,
			0x2424, 0x240b, 0x2518, 0x2510, 0x250c, 0x2514, 0x253c, 0x23ba,
			0x23bb, 0x2500, 0x23bc, 0x23bd, 0x251c, 0x2524, 0x2534, 0x252c,
			0x2502, 0x2264, 0x2265, 0x03c0, 0x2260, 0x00a3, 0x00b7, 0x0020
			    ];
		    return table[b - 0x60];
		}
		return b;
	    default:
		return b;
	}
    }

    private function maybeRemovePrompt()
    {
	outputAfterPrompt++;
	if(!gotPreviousInput) {
	    removePrompt();
	    gotPreviousInput = true;
	}
	if(receivedCr) {
	    cb.carriageReturn();
	    cb.setExtraCurs(cb.getCursX(), cb.getCursY());
	    newPromptString = new StringBuf();
	    newPromptAttribute = new Array<Int>();
	    receivedCr = false;
	}
    }

    private function handle_CHA(params : String)
    {
	var col = 1;
	if(params.length > 0) {
	    var s = params.split(";");
	    col = Std.parseInt(s[0]);
	    if(col < 1) col = 1;
	}
	col -= 1;
	if(col >= cb.getWidth()) col = cb.getWidth()-1;
	cb.setCurs(col, cb.getCursY());
    }

    private function handle_CNL(params : String)
    {
	cb.setCurs(0, cb.getCursY());
	handle_CUD(params);
    }

    private function handle_CPL(params : String)
    {
	cb.setCurs(0, cb.getCursY());
	handle_CUU(params);
    }

    private function handle_CUP(params : String)
    {
	var s = params.split(";");
	var col = 1;
	var row = 1;
	if(s.length > 0) {
	    row = Std.parseInt(s[0]);
	    if(row < 1) row = 1;
	    if(s.length > 1) {
		col = Std.parseInt(s[1]);
		if(col < 1) col = 1;
	    }
	}
	cb.setCurs(col-1, row-1);
    }

    private function handle_CUD(params : String)
    {
	var param = Std.parseInt(params);
	if(param < 1) param = 1;
	var row = cb.getCursY() + param;
	if(row > cb.getHeight()) row = cb.getHeight();
	cb.setCurs(cb.getCursX(), row);
	// trace("CUD pos: " + (cb.getCursX()+1) + "," + (cb.getCursY()+1));
	// TODO handle margins.
    }

    private function handle_CUB(params : String)
    {
	var param = Std.parseInt(params);
	if(param < 1) param = 1;
	var col = cb.getCursX() - param;
	if(col < 0) col = 0;
	cb.setCurs(col, cb.getCursY());
    }

    private function handle_CUF(params : String)
    {
	var param = Std.parseInt(params);
	if(param < 1) param = 1;
	var col = cb.getCursX() + param;
	if(col > cb.getWidth()) col = cb.getWidth();
	cb.setCurs(col, cb.getCursY());
	// trace("CUF pos: " + (cb.getCursX()+1) + "," + (cb.getCursY()+1));
    }

    private function handle_CUU(params : String)
    {
	var param = Std.parseInt(params);
	if(param < 1) param = 1;
	var row = cb.getCursY() - param;
	if(row < 0) row = 0;
	cb.setCurs(cb.getCursX(), row);
	// TODO handle margins.
    }

    private function handle_DCH(params : String)
    {
	var charsToMove = Std.parseInt(params);
	if(charsToMove < 1) charsToMove = 1;

	var x = cb.getCursX();
	var y = cb.getCursY();
	var columns = cb.getWidth();

	if(x + charsToMove >= columns) {
	    // Just erase.
	    handle_EL("0");
	} else {
	    for(i in x ... columns-charsToMove) {
		cb.copyChar(i+charsToMove, y, i, y);
	    }
	    // TODO: Incorrect attributes are used here:
	    for(x in (columns-charsToMove) ... columns)
		cb.printCharAt(32, x, y);
	}
    }

    private function handle_DECRC()
    {
	cb.setAttributes(savedAttribs);
	cb.setCurs(savedCursX, savedCursY);
    }

    private function handle_DECSC()
    {
	savedAttribs = cb.getAttributes();
	savedCursX = cb.getCursX();
	savedCursY = cb.getCursY();
    }

    private function handle_DECSTBM(params : String)
    {
	var from = 0;
	var to = 0;
	if(params.length > 0) {
	    var s = params.split(";");
	    if(s.length > 0) {
		from = Std.parseInt(s[0]);
		if(s.length > 1) {
		  to = Std.parseInt(s[1]);
		}
	    }
	}
	// trace("DECSTBM: params=" + params + " from=" + from + " to=" + to);
	if(from < 1) from = 1;
	if(to < 1 || to > cb.getHeight() ) to = 10001;
	from -= 1;
	to -= 1;
	if(to <= from) return;
	// trace("DECSTBM setting: from=" + from + " to=" + to);
	cb.setMargins(from, to);
	cb.setCurs(0,0);
    }

    private function handle_DECPAM()
    {
	clh.setApplicationKeypad(true);
    }

    private function handle_DECPNM()
    {
	clh.setApplicationKeypad(false);
    }

    private function handle_DA(params : String)
    {
	if(params.length>0) {
	    if(params.charAt(0) == ">") {
		// Secondary DA.
		sendByte(27); // ESC
		sendByte(91); // [
		sendByte(49); // 1
		sendByte(59); // ;
		sendByte(48); // 0
		sendByte(99); // c
		return;
	    }
	}
	send_DA();
    }

    private function handle_DL(params : String)
    {
	var linesToMove = Std.parseInt(params);
	if(linesToMove < 1) linesToMove = 1;

	var scrollTop = cb.getTopMargin();
	var scrollBottom = cb.getBottomMargin();
	var y = cb.getCursY();

	if(y < scrollTop || y >= scrollBottom) return;

	var x = cb.getCursX();
	var rows = cb.getHeight();
	if(scrollBottom > rows) scrollBottom = rows;
	var columns = cb.getWidth();

	// TODO: The wrong attributes are added to the cleared lines...
	if((y+linesToMove) > scrollBottom) {
	    // Just clear.
	    for(y1 in (y) ... scrollBottom) {
		for(x1 in 0 ... columns) {
		    cb.printCharAt(32, x1, y1);
		}
	    }
	} else {
	    for(y1 in (y+linesToMove) ... (scrollBottom)) {
		for(x1 in 0 ... columns) {
		    cb.copyChar(x1, y1, x1, y1-linesToMove);
		}
	    }
	    for(y1 in (scrollBottom - linesToMove) ... scrollBottom) {
		for(x1 in 0 ... columns) {
		    cb.printCharAt(32, x1, y1);
		}
	    }
	}
    }

    private function handle_ED(params : String)
    {
	var s = params.split(";");
	var param = 0;
	if(s.length > 0) {
	    param = Std.parseInt(s[0]);
	}
	switch(param) {
	    case 0:
		// From here to end.
		var x = cb.getCursX();
		var y = cb.getCursY();
		var width = cb.getWidth();
		var height = cb.getHeight();
		for(x1 in x...width) {
		    cb.printCharAt(32, x1, y);
		}
		for(y1 in (y+1)...height) {
		    for(x1 in 0...width) {
		        cb.printCharAt(32, x1, y1);
		    }
		}
	    case 1:
		// From start to here.
		var x = cb.getCursX();
		var y = cb.getCursY();
		var width = cb.getWidth();
		for(y1 in 0...y) {
		    for(x1 in 0...width) {
		        cb.printCharAt(32, x1, y1);
		    }
		}
		for(x1 in 0...(x+1)) {
		    cb.printCharAt(32, x1, y);
		}
	    case 2:
		cb.clear();
	    default:
		trace("ED Mode not implemented yet: " + param);
	}
    }

    private function handle_EL(params : String)
    {
	var s = params.split(";");
	var param = 0;
	if(s.length > 0) {
	    param = Std.parseInt(s[0]);
	}
	switch(param) {
	    case 0:
		// From here to right.
		var x = cb.getCursX();
		var y = cb.getCursY();
		var width = cb.getWidth();
		for(x1 in x...width) {
		    cb.printCharAt(32, x1, y);
		}
	    case 1:
		// From left to here.
		var x = cb.getCursX();
		var y = cb.getCursY();
		for(x1 in 0...(x+1)) {
		    cb.printCharAt(32, x1, y);
		}
	    case 2:
		// Erase whole line.
		var y = cb.getCursY();
		var width = cb.getWidth();
		for(x1 in 0...width) {
		    cb.printCharAt(32, x1, y);
		}
	    default:
		trace("ED Mode not implemented yet: " + param);
	}
    }

    private function handle_HTS()
    {
	tabStops[cb.getCursX()] = true;
    }

    private function handle_ICH(params : String)
    {
	var s = params.split(";");
	var charsToMove = 1;
	if(params.length > 0) {
	    charsToMove = Std.parseInt(s[0]);
	    if(charsToMove < 1) charsToMove = 1;
	}
	var columns = cb.getWidth();
	var x = cb.getCursX();

	if(x + charsToMove >= columns) {
	    // Just erase.
	    handle_EL("0");
	} else {
	    var y = cb.getCursY();
	    for(i in 0 ... columns-x-charsToMove) {
		var x1 = columns - i - 1;
		cb.copyChar(x1-charsToMove, y, x1, y);
	    }
	    // TODO: Incorrect attributes are used here:
	    for(i in 0 ... charsToMove)
		cb.printCharAt(32, x+i, y);
	}

    }

    // Insert Line(s).
    private function handle_IL(params : String)
    {
	var linesToMove = Std.parseInt(params);
	if(linesToMove < 1) linesToMove = 1;

	var scrollTop = cb.getTopMargin();
	var scrollBottom = cb.getBottomMargin();
	var y = cb.getCursY();

	if(y < scrollTop || y >= scrollBottom) return;

	var rows = cb.getHeight();
	if(scrollBottom > rows) scrollBottom = rows;
	var columns = cb.getWidth();

	if((y+linesToMove) > scrollBottom) {
	    for(y1 in (y) ... scrollBottom) {
		for(x1 in 0 ... columns) {
		    cb.printCharAt(32, x1, y1);
		}
	    }
	} else {
	    for(i in 0 ... (scrollBottom-y-linesToMove)) {
		var y1 = scrollBottom - i-1;
		// trace("Copying from " + (y1-linesToMove) + " to " + y1);
		for(x1 in 0 ... columns) {
		    cb.copyChar(x1, y1-linesToMove, x1, y1);
		}
	    }
	    for(y1 in 0 ... linesToMove) {
		for(x1 in 0 ... columns) {
		    cb.printCharAt(32, x1, y1+y);
		}
	    }
	}
    }

    /* Operating System Controls */
    private function handle_OCS_sequence()
    {
	var params = this.receivedEsc.toString();
	var s = params.split(";");
	if(s.length >= 2) {
	    var cmd = s[0];
	    if(cmd == "0") {
		// Change icon name and title.
		// trace("Change icon name and title to: " + s[1]);
		callExternal("ChangeTitle", s[1]);
	    } else if(cmd == "1") {
		// Change icon name.
		// trace("Change icon name to: " + s[1]);
	    } else if(cmd == "2") {
		// Change title.
		// trace("Change title to: " + s[1]);
		callExternal("ChangeTitle", s[1]);
	    } else {
		trace("Unknown OCS sequence: " + params);
	    }
	} else {
	    trace("Unknown OCS sequence: " + params);
	}
    }

    private function handle_REP(params : String)
    {
	var charsToRep = Std.parseInt(params);
	if(charsToRep < 1) charsToRep = 1;

	for(i in 0...charsToRep) {
	    newByte(latestPrintableChar);
	}
    }

    // Reverse Index.
    private function handle_RI()
    {
	var firstRow = cb.getTopMargin();
	var cursY = cb.getCursY();
	cursY--;
	if(cursY == firstRow-1) {
	    cursY++;
	    cb.setCurs(cb.getCursX(), cursY);
	    handle_IL("1");
	} else {
	    if(cursY < 0) {
		// Wrap around.
		cursY = cb.getHeight()-1;
	    }
	    cb.setCurs(cb.getCursX(), cursY);
	}
	cb.setExtraCurs(cb.getCursX(), cb.getCursY());
    }


    private function handle_RIS()
    {
	tabStops = new Array();
	tabStops[999] = false;
	for(i in 0 ... 1000) {
	    tabStops[i] = i & 7 == 0;
	}
	setColoursDefault();
	this.charsets = [ 65, 48, 65, 48 ];
	charset = 0;
	cb.setMargins(0, 10000);
	cb.clear();
	cb.setCurs(0, 0);
	clh.setApplicationCursorKeys(false);
	oldPromptString = "";
    }

    private function handle_SGR()
    {
	var params = this.receivedEsc.toString();
	if(params.length == 0) {
	    setColoursDefault();
	} else {
	    var s = params.split(";");
	    var i = 0;
	    while(i < s.length) {
		if(i + 3 <= s.length &&
			s[i] == "38" && 
			s[i+1] == "5") {
		    i += 2;
		    cb.setFgColour(Std.parseInt(s[i]));
		} else if(i + 3 <= s.length &&
			s[i] == "48" && 
			s[i+1] == "5") {
		    i += 2;
		    cb.setBgColour(Std.parseInt(s[i]));
		} else {
		    var b = Std.parseInt(s[i]);
		    if(b >= 30 && b <= 37) {
			cb.setFgColour(b-30);
		    } else if(b >= 40 && b <= 47) {
			cb.setBgColour(b-40);
		    } else if(b == 0) {
			setColoursDefault();
		    } else if(b == 1) {
			cb.setBright();
		    } else if(b == 4) {
			cb.setUnderline();
		    } else if(b == 5) {
			cb.setBold();
		    } else if(b == 7) {
			cb.setInverse();
		    } else if(b == 22) {
			cb.resetBright();
		    } else if(b == 24) {
			cb.resetUnderline();
		    } else if(b == 25) {
			cb.resetBold();
		    } else if(b == 27) {
			cb.resetInverse();
		    } // else trace("PARAM: "+b);
		}
		i++;
	    }
	}
    }

    private function handle_RM(mode : String)
    {
	if(mode.length == 0) return;
	if(mode.charAt(0) == "?") {
	    // DEC Private Mode Set.
	    mode = mode.substr(1);
	    var s = mode.split(";");
	    for(i in 0 ... s.length) {
		switch(s[i]) {
		    case "1":
			clh.setApplicationCursorKeys(false);
		    case "4":
			// SET jump-scroll mode.
		    case "7":
			// reset DECAWM - auto wrap.
		    case "25":
			cb.setCursorVisibility(false);
		    case "47":
			// trace("Use normal screen.");
		    case "1049":
			// trace("Use normal screen.");
		    default:
			trace("Unknown DECRST-setting: " + s[i]);
		}
	    }
	} else {
	    // Reset Mode.
	    var s = mode.split(";");
	    for(i in 0 ... s.length) {
		switch(s[i]) {
		    case "4":
			// SET jump-scroll mode.
		    default:
			trace("Unknown RM-setting: " + s[i]);
		}
	    }
	}
    }

    private function handle_SM(mode : String)
    {
	if(mode.length == 0) return;
	if(mode.charAt(0) == "?") {
	    // DEC Private Mode Set.
	    mode = mode.substr(1);
	    var s = mode.split(";");
	    for(i in 0 ... s.length) {
		switch(s[i]) {
		    case "1":
			clh.setApplicationCursorKeys(true);
		    case "4":
			// SET smooth scroll mode.
		    case "7":
			// reset DECAWM - auto wrap.
		    case "25":
			cb.setCursorVisibility(true);
		    case "47":
			// trace("Use alt screen");
		    case "1049":
			// trace("Use alt screen");
		    default:
			trace("Unknown DECSET-setting: " + s[i]);
		}
	    }
	} else {
	    // Set Mode.
	    var s = mode.split(";");
	    for(i in 0 ... s.length) {
		switch(s[i]) {
		    case "4":
			// SET smooth scroll mode.
		    default:
			trace("Unknown SM-setting: " + s[i]);
		}
	    }
	}
    }

    private function handle_TBC(params : String)
    {
	var p = Std.parseInt(params);
	if(p == 3) {
	    for(i in 0...tabStops.length)
		tabStops[i] = false;
	} else {
	    tabStops[cb.getCursX()] = false;
	}
    }


    public function reset()
    {
	localEcho = true;
	this.inputState = VIS_NORMAL;

	cb.setCursorVisibility(true);
	clh.reset();

	handle_RIS();
    }

    public function onDisconnect()
    {
	setColoursDefault();
	oldPromptString = "";
	cb.setCursorVisibility(true);
    }

    private function send_DA()
    {
	sendByte(27); // ESC
	sendByte(91);  // [
	sendByte(63);  // ?
	sendByte(48+6);  // 6 = VT102...
	sendByte(99);  // c
    }


    private function newByteHandleNormal(b : Int)
    {
	switch(b) {
	    case 0: // NUL
		// Ignore.
	    case 7: // Bell.
		beepSound.play();
	    case 8: // BACKSPACE
		var x = cb.getCursX();
		if(x == 0) return;
		maybeRemovePrompt();
		cb.setCurs(x-1, cb.getCursY());
	    case 9: // TAB
		maybeRemovePrompt();
		var x = cb.getCursX();
		x++;
		while(x < cb.getWidth() && !tabStops[x]) x++;
		if(x >= cb.getWidth()) x = cb.getWidth()-1;
		cb.setCurs(x, cb.getCursY());
	    case 10: // LF
		maybeRemovePrompt();
		cb.lineFeed();
		cb.setExtraCurs(cb.getCursX(), cb.getCursY());
	    case 13: // CR
		if(cb.getCursX() != 0) {
		    receivedCr = true;
		}
	    case 14: // CTRL-N, Shift Out -> Switch to G1 character set.
		charset = 1;
	    case 15: // CTRL-O, Shift In -> Switch to G0 character set.
		charset = 0;
	    case 27: // ESC
		this.inputState = VIS_ESC;
	    case 0x8D: // RI
		maybeRemovePrompt();
		handle_RI();
	    case 0x9B: // CSI
		this.inputState = VIS_PARAM;
	    case 0x9D: // OSC
		this.inputState = VIS_PARAM2;
	    default:
		if(b >= 0 && b < 32) return;
		maybeRemovePrompt();
		b = translateCharset(b);
		newPromptString.addChar(b);
		newPromptAttribute.push(cb.getAttributes());
		latestPrintableChar = b;
		cb.printChar(b);
	}
    }

    private function newByteHandleEscape(b : Int)
    {
	inputState = VIS_NORMAL;
	switch(b) {
	    case 91: // [
		this.receivedEsc = new StringBuf();
		this.inputState = VIS_PARAM;
	    case 93: // ]
		this.receivedEsc = new StringBuf();
		this.inputState = VIS_PARAM2;
	    case 37: // %
		escFirstChar = b; this.inputState = VIS_ESC_TWO_CHAR;
	    case 40: // (
		escFirstChar = b; this.inputState = VIS_ESC_TWO_CHAR;
	    case 41: // )
		escFirstChar = b; this.inputState = VIS_ESC_TWO_CHAR;
	    case 55: // 7
		handle_DECSC();
	    case 56: // 8
		handle_DECRC();
	    case 61: // =
		handle_DECPAM();
	    case 62: // >
		handle_DECPNM();
	    case 65: // A
		handle_CUU("");
	    case 66: // B
		handle_CUD("");
	    case 67: // C
		handle_CUF("");
	    case 68: // D
		handle_CUB("");
	    case 69: // E
		newByte(13);
		newByte(10);
	    case 70: // F
		handle_CPL("");
	    case 71: // G
		handle_CHA("");
	    case 72: // H
		handle_HTS();
	    case 77: // M
		handle_RI();
	    case 90: // Z
		send_DA();
	    case 99: // c
		handle_RIS();
	    default:
		trace("No [ following ESC! " + b);
		this.inputState = VIS_NORMAL;
		newByte(b);
	}
    }

    private function newByteHandleCharAfterEscape(b : Int)
    {
	inputState = VIS_NORMAL;
	if(escFirstChar == 37) {
	    if(b == 64) { // @ -- Change to latin-1
		if(utfEnabled) {
		    utfEnabled = false;
		    clh.setUtfCharSet(false);
		}
		return;
	    } else if(b == 71) { // G -- Change to UTF-8
		if(!utfEnabled) {
		    utfEnabled = true;
		    clh.setUtfCharSet(true);
		    utfState = 0;
		}
		return;
	    }
	} else if(escFirstChar == 40) { // (
	    // Designate G0 character set.
	    charsets[0] = b;
	    return;
	} else if(escFirstChar == 41) { // )
	    // Designate G1 character set.
	    charsets[1] = b;
	    return;
	} else if(escFirstChar == 42) { // *
	    // Designate G2 character set.
	    charsets[2] = b;
	    return;
	} else if(escFirstChar == 43) { // +
	    // Designate G3 character set.
	    charsets[3] = b;
	    return;
	}
	trace("Unknown char following ESC: " + escFirstChar + " " + b);
	newByte(escFirstChar);
	newByte(b);
    }

    private function newByteHandleParameter2AfterEscape(b : Int)
    {
	if(b < 32 || (b >= 127 && b < 160)) {
	    inputState = VIS_NORMAL;
	    /* 7-bit ST == ESC '\' too, but that isn't handled... */
	    if(b == 7 || b == 0x9c) { // BELL or 8-bit ST.
		handle_OCS_sequence();
	    } else {
		trace("Unknown OCS-seq:" + this.receivedEsc.toString() + "  and " + b);
	    }
	} else {
	    this.receivedEsc.addChar(b);
	}
    }

    private function newByteHandleParameterAfterEscape(b : Int)
    {
	if((b >= 48 && b <= 57) ||
	   (b == 59) ||
	   (b == 62) ||
	   (b == 63)) {
	    this.receivedEsc.addChar(b);
	} else {
	    inputState = VIS_NORMAL;
	    maybeRemovePrompt();
	    switch(b) {
		case 64: // @
		    handle_ICH(this.receivedEsc.toString());
		case 65: // A
		    handle_CUU(this.receivedEsc.toString());
		case 66: // B
		    handle_CUD(this.receivedEsc.toString());
		case 67: // C
		    handle_CUF(this.receivedEsc.toString());
		case 68: // D
		    handle_CUB(this.receivedEsc.toString());
		case 69: // E
		    handle_CNL(this.receivedEsc.toString());
		case 70: // F
		    handle_CPL(this.receivedEsc.toString());
		case 71: // G
		    handle_CHA(this.receivedEsc.toString());
		case 72: // H
		    handle_CUP(this.receivedEsc.toString());
		case 74: // J
		    handle_ED(this.receivedEsc.toString());
		case 75: // K
		    handle_EL(this.receivedEsc.toString());
		case 76: // L
		    handle_IL(this.receivedEsc.toString());
		case 77: // M
		    handle_DL(this.receivedEsc.toString());
		case 80: // P
		    handle_DCH(this.receivedEsc.toString());
		case 98: // b
		    handle_REP(this.receivedEsc.toString());
		case 99: // c
		    handle_DA(this.receivedEsc.toString());
		case 103: // g
		    handle_TBC(this.receivedEsc.toString());
		case 104: // h
		    handle_SM(this.receivedEsc.toString());
		case 108: // l
		    handle_RM(this.receivedEsc.toString());
		case 109: // m
		    handle_SGR();
		case 114: // r
		    handle_DECSTBM(this.receivedEsc.toString());
		default:
		    trace("ESC-seq:" + b + " : " + this.receivedEsc.toString());
	    }
	}
    }

    private function newByte(b : Int)
    {
	try {
	    if(utfEnabled) {
		if(utfState != 0) {
		    if((b & 0xc0) != 0x80) {
			utfState = 0;
			trace("unsequential UTF " + b);
			newByte(UTF_ERROR);
			newByte(b);
			return;
		    }
		    utfChar = (utfChar << 6) | (b & 0x3f);
		    if(--utfState > 0) return; // There's more to process.
		    b = utfChar;
		    if(b < 0x80 ||
			    (b < 0x800 && utfLength == 2) ||
			    (b < 0x10000 && utfLength == 3) ||
			    (b < 0x200000 && utfLength == 4) ||
			    (b < 0x4000000 && utfLength == 5)) {
			trace("wrongly encoded UTF " + b );
			b = UTF_ERROR;
			// Process below.
		    } else {
			if(b == 0x2028) b = 10; // LF
			else if(b == 0x2029) b = 13; // CR
			else if(b >= 0xD800 && b < 0xE000) b = UTF_ERROR; // Surrogates.
			else if(b > 0x10FFFF) b = UTF_ERROR; // Non Unicode.
			else if(b == 0xFFFE || b == 0xFFFF) b = UTF_ERROR;
			else if(b == 0xFEFF) b = 0;

			if(b >= 0x10000) {
			    // Recode as surrogates as action script strings are
			    // in UTF-16...
			    /*
			       b -= 0x10000;
			       newByte(0xD800 | (b >> 10));
			       b = 0xD900 | (b & 0x3FFFF);
			     */
			    // We don't handle multiple codes per character
			    // position yet...
			    b = UTF_ERROR;
			}
		    }
		} else {
		    if(b > 0xff) {
			// an injected unicode character,
			// process it below.
		    } else if(b < 0x80) {
			// Normal char, processed below.
		    } else if((b & 0xe0) == 0xc0) {
			utfState = 1; utfLength = 1;
			utfChar = b & 0x1f;
			return;
		    } else if((b & 0xf0) == 0xe0) {
			utfState = 2; utfLength = 2;
			utfChar = b & 0x0f;
			return;
		    } else if((b & 0xf8) == 0xf0) {
			utfState = 3; utfLength = 3;
			utfChar = b & 0x07;
			return;
		    } else if((b & 0xfc) == 0xf8) {
			utfState = 4; utfLength = 4;
			utfChar = b & 0x03;
			return;
		    } else if((b & 0xfe) == 0xfc) {
			utfState = 5; utfLength = 5;
			utfChar = b & 0x01;
			return;
		    } else {
			b = UTF_ERROR;
		    }
		}
	    }
	    switch(this.inputState) {
		case VIS_NORMAL:
		    newByteHandleNormal(b);
		case VIS_ESC:
		    newByteHandleEscape(b);
		case VIS_ESC_TWO_CHAR:
		    newByteHandleCharAfterEscape(b);
		case VIS_PARAM:
		    newByteHandleParameterAfterEscape(b);
		case VIS_PARAM2:
		    newByteHandleParameter2AfterEscape(b);
	    }
	} catch ( ex : Dynamic ) {
	    trace(ex);
	}
    }

    // First newByte is called until all currently available
    // bytes have been sent over, then flush() is called
    // to make it appear on the screen.
    public function flush()
    {
	cb.endUpdate();
	if(gotPreviousInput) {
	    gotPreviousInput = false;
	    if(outputAfterPrompt > 0) {
		promptTimer.reset();
		promptTimer.start();
		promptWaiting = true;
		// trace("Waiting for prompt");
	    }
	}
    }

    public function gotPrompt_(isTimeout : Bool)
    {
	// trace("gotPrompt");
	promptTimer.stop();
	promptTimer.reset();
	promptWaiting = false;
	if(outputAfterPrompt == 0) return;
	outputAfterPrompt = 0;
	var newPrompt = newPromptString.toString();
	if(newPrompt.length > 0) {
	    if(!isTimeout || localEcho) {
		oldPromptString = newPrompt;
		oldPromptAttribute = newPromptAttribute;
	    }
	    if(!isTimeout) {
		// If this is just a timeout prompt, don't start on a new prompt
		// in case there is more comming due to lag.
		newPromptString = new StringBuf();
		newPromptAttribute = new Array<Int>();
	    }
	    // This prompt should not be cleared if it is created due to a timeout.
	    // In that case it can just as well be normal text and lag.
	    promptHasBeenDrawn = ! isTimeout;
	    cb.setExtraCurs(cb.getCursX(), cb.getCursY());
	    clh.drawInputString();
	} else {
	    // Draw the old prompt.
	    drawPrompt();
	}
	cb.endUpdate();
    }

    private function promptTimeout(o : Dynamic)
    {
	// trace("promptTimeout");
	if(promptWaiting) gotPrompt_(true);
    }

    /* From TelnetEventListener */
    public function onReceiveByte(b : Int)
    {
	newByte(b);
    }

    // Called when everything from the start of the line to the
    // current position should be considered a prompt.
    // There should also be some timer that calls this method if
    // the mud doesn't support EOR handling...
    public function onPromptReception()
    {
	gotPrompt_(false);
    }

    /* From TelnetEventListener */
    public function changeServerEcho(remoteEcho : Bool)
    {
	this.localEcho = ! remoteEcho;
	clh.setCharByChar(remoteEcho);
    }

    /* From TelnetEventListener */
    public function getColumns()
    {
	return cb.getWidth();
    }

    /* From TelnetEventListener */
    public function getRows()
    {
	return cb.getHeight();
    }

    private function setColoursDefault()
    {
	cb.setDefaultAttributes();
	cb.setBgColour(0);
	cb.setFgColour(2);
    }

    private function drawPrompt()
    {
	promptHasBeenDrawn = true;
	var fromChar = 0;
	while(fromChar < oldPromptString.length) {
	    cb.printCharWithAttribute(
		    oldPromptString.charCodeAt(fromChar),
		    oldPromptAttribute[fromChar]);
	    fromChar++;
	}
	cb.setExtraCurs(cb.getCursX(), cb.getCursY());
	clh.drawInputString();
    }

    private function removePrompt()
    {
	clh.removeInputString();
	if(promptHasBeenDrawn) {
	    var chars = oldPromptString.length;
	    if(chars > 0) {
		cb.setCurs(0, cb.getCursY());
		while(chars-- > 0) {
		    cb.printChar(32);
		}
		cb.setCurs(0, cb.getCursY());
	    }
	    promptHasBeenDrawn = false;
	}
    }

    public function handleKey(e : KeyboardEvent)
    {
	clh.handleKey(e);
    }

    public function doPaste(s : String)
    {
	clh.doPaste(s);
    }

    private inline function isCharByCharMode() : Bool
    {
	return !localEcho;
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

    private function callExternal(method : String, argument : Dynamic)
    {
	if(ExternalInterface.available) {
	    ExternalInterface.call(method, argument);
	}
    }
}
