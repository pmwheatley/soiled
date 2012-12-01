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

import flash.ui.Keyboard;
import flash.external.ExternalInterface;
import flash.events.KeyboardEvent;

/*
   VT100 handles input from the server and sends draw requests to
   a CharBuffer. Input from the user is sent to a ICommandLineHandling
   object.

   Despite its name, it is not a VT100 emulator, but it understands
   enough of it to be usable for common MUDs and most curses programs.
   It also understands some of the xterm extensions and some VT102 and VT220
   commands.
*/
class VT100 implements ITelnetEventListener,
            implements IVtParserListener
{
    private inline static var UTF_ERROR = 0xFFFD;
    private var charset48 : Array<Int>;
    private var charset_cp437 : Array<Int>;

    private var cb : ICharBuffer;

    private var clh : ICommandLineHandling;

    private var config : Config;

    private var sendByte : Int -> Void;

    private var localEcho : Bool;

    /* If != 0, in tiledata output mode:
     * 1: MESSAGE
     * 2: STATUS
     * 3: MAP
     * 4: MENU
     * 5: TEXT
     */
    private var tiledataWindow : Int;

    /* If in tiledata mode don't output anything else. */
    private var tiledataMode : Bool;

    /* If the received charset is UTF-8 */
    private var utfEnabled : Bool;

    /* If 0xA0 to 0xFF should be treated as in CP437 */
    private var ibmGraphics : Bool;

    /* utfState says how many more bytes that are expected to be received. */
    private var utfState : Int;
    /* utfChar is the Unicode being built up from the received bytes. */
    private var utfChar : Int;
    /* utfLength is used to verify the received utfChar once fully received. */
    private var utfLength : Int;

    private var charset : Int; // 0 or 1 for G0 and G1.
    private var charsets : Array<Int>; // Current designation for G0 .. G3
    private var nextCharacterCharset : Int;

    var savedAttribs : CharAttributes;
    var savedCursX : Int;
    var savedCursY : Int;
    var savedDecomMode : Bool;
    var savedAutoWrapMode : Bool;

    var decomMode : Bool; // Origin Mode. false = absolute.

    var lnmMode : Bool; // Line feed/New Line Mode. True = New Line Mode.

    var irmMode : Bool; // Insert/replace mode. true = insert.

    private var promptTimer : flash.utils.Timer;
    private var promptWaiting : Bool;

    private var outputAfterPrompt : Int;

    private var oldPromptString : String;
    private var oldPromptAttribute : Array<CharAttributes>;
    private var newPromptString : StringBuf;
    private var newPromptAttribute : Array<CharAttributes>;

    // Have a prompt been drawn be us, so we must remove it?
    private var promptHasBeenDrawn : Bool;

    private var gotPreviousInput : Bool;

    private var vtParser : VtParser;

    private var oscString : String;

    // Used to store the latest printable character, so it may be repeated by REP.
    var latestPrintableChar : Int;

    private var receivedCr : Bool;

    private var tabStops : Array<Bool>;

    public function new(sendByte : Int -> Void,
	                charBuffer : ICharBuffer,
                        clh : ICommandLineHandling,
			config : Config)
    {
	try {
	    charset48 = [ // Thanks Putty! :-)
		0x2666, 0x2592, 0x2409, 0x240c, 0x240d, 0x240a, 0x00b0, 0x00b1,
		0x2424, 0x240b, 0x2518, 0x2510, 0x250c, 0x2514, 0x253c, 0x23ba,
		0x23bb, 0x2500, 0x23bc, 0x23bd, 0x251c, 0x2524, 0x2534, 0x252c,
		0x2502, 0x2264, 0x2265, 0x03c0, 0x2260, 0x00a3, 0x00b7, 0x0020
	    ];
	    charset_cp437 = [
		0x00E1, 0x00Ed, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
		0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
		0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
		0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
		0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
		0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
		0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
		0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
		0x03B1, 0x00Df, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
		0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
		0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
		0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0
	    ];

	    ibmGraphics = config.getUseIbmGraphics();

	    vtParser = new VtParser(this);
	    cb = charBuffer;
	    newPromptString = new StringBuf();
	    oldPromptAttribute = new Array<CharAttributes>();
	    newPromptAttribute = new Array<CharAttributes>();

	    this.config = config;
	    this.clh = clh;

	    promptTimer = new flash.utils.Timer(250, 1);
	    promptTimer.addEventListener("timer", promptTimeout);

	    this.sendByte = sendByte;

	    reset();
	} catch ( ex : Dynamic ) {
	    trace(ex);
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

    public function onResize()
    {
	var hadDrawnPrompt = promptHasBeenDrawn;
	if(hadDrawnPrompt) removePrompt();
	else clh.removeInputString();
	var result = cb.resize();
	if(hadDrawnPrompt) drawPrompt();
	else clh.drawInputString();
	cb.endUpdate();
	return result;
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

    public function onDisconnect()
    {
	setColoursDefault();
	oldPromptString = "";
	cb.setCursorVisibility(true);
    }

    public function reset()
    {
	localEcho = true;
	vtParser.reset();

	cb.setCursorVisibility(true);
	clh.reset();

	decomMode = false;
	lnmMode = false;
	irmMode = false;

	setUtfEnabled(config.getUtf8());
	utfState = 0;

	handle_RIS();
    }

    /**********************************************************************/
    /* From ITelnetEventListener                                           */
    /**********************************************************************/

    public function shouldReceiveData() : Bool
    {
	return !clh.isCommandInputMode();
    }

    // Appends local text.
    public function appendText(s : String)
    {
	cb.printWordWrap(s);
	cb.setExtraCurs(cb.getCursX(), cb.getCursY());
    }

    public function onReceiveByte(b : Int)
    {
	newByte(b);
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

    // Called when everything from the start of the line to the
    // current position should be considered a prompt.
    // There should also be some timer that calls this method if
    // the mud doesn't support EOR handling...
    public function onPromptReception()
    {
	gotPrompt_(false);
    }

    public function setUtfEnabled(on : Bool)
    {
	utfEnabled = on;
	clh.setUtfCharSet(on);
    }


    public function changeServerEcho(remoteEcho : Bool)
    {
	this.localEcho = ! remoteEcho;
	clh.setCharByChar(remoteEcho);
    }

    public function getColumns()
    {
	return cb.getWidth();
    }

    public function getRows()
    {
	return cb.getHeight();
    }

    /******************************************************************/
    /* Private functions below here (and Listener implementations...) */
    /******************************************************************/

    private function translateCharset(b : Int) : Int
    {
	var cc = nextCharacterCharset;
	nextCharacterCharset = charset;
	switch(charsets[cc]) {
	    case 48:
		if(b >= 0x60 && b <= 0x7F) {
		    return charset48[b - 0x60];
		}
		return b;
	    case 65, 66:
		if(ibmGraphics) {
		    if(b >= 0xa0 && b <= 0xff) {
			return charset_cp437[b - 0xa0];
		    }
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
	    newPromptAttribute = new Array<CharAttributes>();
	    receivedCr = false;
	}
    }


    /********************************************/
    /* Character sequence implementations below */
    /********************************************/

    private function handle_CHA(params : Array<Int>)
    {
	var col = params[0];
	if(col < 1) col = 1;
	col -= 1;
	if(col >= cb.getWidth()) col = cb.getWidth()-1;
	cb.setCurs(col, cb.getCursY());
    }

    private function handle_CNL(params : Array<Int>)
    {
	cb.setCurs(0, cb.getCursY());
	handle_CUD(params);
    }

    private function handle_CPL(params : Array<Int>)
    {
	cb.setCurs(0, cb.getCursY());
	handle_CUU(params);
    }

    private function handle_CUP(params : Array<Int>)
    {
	var row = params[0];
	if(row < 1) row = 1;
	var col = params[1];
	if(col < 1) col = 1;
	if(decomMode) {
	    // row starts at the scroll region.
	    row += cb.getTopMargin();
	    var bottom = cb.getBottomMargin();
	    if(row > bottom) row = bottom;
	}
	cb.setCurs(col-1, row-1);
    }

    private function handle_CUD(params : Array<Int>)
    {
	var param = params[0];
	if(param < 1) param = 1;
	var row = cb.getCursY() + param;
	if(row > cb.getHeight()) row = cb.getHeight();
	cb.setCurs(cb.getCursX(), row);
	// trace("CUD pos: " + (cb.getCursX()+1) + "," + (cb.getCursY()+1));
	// TODO handle margins.
    }

    private function handle_CUB(params : Array<Int>)
    {
	var param = params[0];
	if(param < 1) param = 1;
	var col = cb.getCursX() - param;
	if(col < 0) col = 0;
	cb.setCurs(col, cb.getCursY());
    }

    private function handle_CUF(params : Array<Int>)
    {
	var param = params[0];
	if(param < 1) param = 1;
	var col = cb.getCursX() + param;
	if(col > cb.getWidth()) col = cb.getWidth();
	cb.setCurs(col, cb.getCursY());
	// trace("CUF pos: " + (cb.getCursX()+1) + "," + (cb.getCursY()+1));
    }

    private function handle_CUU(params : Array<Int>)
    {
	var param = params[0];
	if(param < 1) param = 1;
	var row = cb.getCursY() - param;
	if(row < 0) row = 0;
	cb.setCurs(cb.getCursX(), row);
	// TODO handle margins.
    }

    private function handle_DCH(params : Array<Int>)
    {
	var charsToMove = params[0];
	if(charsToMove < 1) charsToMove = 1;

	var x = cb.getCursX();
	var y = cb.getCursY();
	var columns = cb.getWidth();

	if(x + charsToMove >= columns) {
	    // Just erase.
	    params[0] = 0;
	    handle_EL(params);
	} else {
	    for(i in x ... columns-charsToMove) {
		cb.copyChar(i+charsToMove, y, i, y);
	    }
	    // TODO: Incorrect attributes are used here:
	    for(x in (columns-charsToMove) ... columns)
		cb.printCharAt(32, x, y);
	}
    }

    // DEC Screen Alignment Test
    private function handle_DECALN()
    {
	var savedAttribs = cb.getAttributes().clone();
	cb.getAttributes().setDefaultAttributes();
	cb.getAttributes().setFgColour(2);
	for(y in 0...cb.getHeight())
	    for(x in 0...cb.getWidth())
		cb.printCharAt(69, x, y);
	cb.setAttributes(savedAttribs);
    }

    private function handle_DECRC()
    {
	cb.setAttributes(savedAttribs);
	cb.setCurs(savedCursX, savedCursY);
	cb.setAutoWrapMode(savedAutoWrapMode);
	decomMode = savedDecomMode;
    }

    private function handle_DECSC()
    {
	savedAttribs = cb.getAttributes().clone();
	savedCursX = cb.getCursX();
	savedCursY = cb.getCursY();
	savedAutoWrapMode = cb.getAutoWrapMode();
	savedDecomMode = decomMode;
    }

    private function handle_DECSTBM(params : Array<Int>)
    {
	var from = params[0];
	var to = params[1];
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

    private function handle_DA(inter : String)
    {
	if(inter.length>0) {
	    if(inter.charAt(0) == ">") {
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

    private function handle_DL(params : Array<Int>)
    {
	var linesToMove = params[0];
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

    private function handle_ED(params : Array<Int>)
    {
	var param = params[0];
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

    private function handle_EL(params : Array<Int>)
    {
	var param = params[0];
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
		trace("EL Mode not implemented yet: " + param);
	}
    }

    private function handle_HTS()
    {
	tabStops[cb.getCursX()] = true;
    }

    private function handle_HVP(params : Array<Int>)
    {
	handle_CUP(params);
    }

    private function handle_ICH(params : Array<Int>)
    {
	var charsToMove = params[0];
	if(charsToMove < 1) charsToMove = 1;
	var columns = cb.getWidth();
	var x = cb.getCursX();

	if(x + charsToMove >= columns) {
	    // Just erase.
	    params[0] = 0;
	    handle_EL(params);
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
    private function handle_IL(params : Array<Int>)
    {
	var linesToMove = params[0];
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

    private function handle_REP(params : Array<Int>)
    {
	var charsToRep = params[0];
	if(charsToRep < 1) charsToRep = 1;

	for(i in 0...charsToRep) {
	    vtpPrint(latestPrintableChar);
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
	    var params = new Array<Int>();
	    params.push(1);
	    handle_IL(params);
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
	nextCharacterCharset = charset;
	cb.setMargins(0, 10000);
	cb.clear();
	cb.setCurs(0, 0);
	clh.setApplicationCursorKeys(false);
	oldPromptString = "";
    }

    private function handle_SGR(nParams : Int, params : Array<Int>)
    {
	if(nParams == 0) {
	    setColoursDefault();
	} else {
	    var i = 0;
	    while(i < nParams) {
		if(i + 3 <= nParams &&
			params[i] == 38 && 
			params[i+1] == 5) {
		    i += 2;
		    cb.getAttributes().setFgColour(params[i]);
		} else if(i + 3 <= nParams &&
			params[i] == 48 && 
			params[i+1] == 5) {
		    i += 2;
		    cb.getAttributes().setBgColour(params[i]);
		} else {
		    var b = params[i];
		    if(b >= 30 && b <= 37) {
			cb.getAttributes().setFgColour(b-30);
		    } else if(b == 39) {
			cb.getAttributes().setFgColour(
					config.getDefaultFgColour());
		    } else if(b >= 40 && b <= 47) {
			cb.getAttributes().setBgColour(b-40);
		    } else if(b == 49) {
			cb.getAttributes().setBgColour(
					config.getDefaultBgColour());
		    } else if(b >= 90 && b <= 97) {
			cb.getAttributes().setFgColour(b-82);
		    } else if(b >= 100 && b <= 107) {
			cb.getAttributes().setBgColour(b-92);
		    } else if(b == 0) {
			setColoursDefault();
		    } else if(b == 1) {
			cb.getAttributes().setBright();
		    } else if(b == 4) {
			cb.getAttributes().setUnderline();
		    } else if(b == 5) {
			cb.getAttributes().setBold();
		    } else if(b == 7) {
			cb.getAttributes().setInverted();
		    } else if(b == 22) {
			cb.getAttributes().resetBright();
		    } else if(b == 24) {
			cb.getAttributes().resetUnderline();
		    } else if(b == 25) {
			cb.getAttributes().resetBold();
		    } else if(b == 27) {
			cb.getAttributes().resetInverted();
		    } // else trace("PARAM: "+b);
		}
		i++;
	    }
	}
    }

    private function handle_RM(inter : String, nParams : Int, params : Array<Int>)
    {
	if(inter == "?") {
	    // DEC Private Mode Reset.
	    for(i in 0 ... nParams) {
		switch(params[i]) {
		    case 1:
			clh.setApplicationCursorKeys(false);
		    case 3: // DECCOLM - selects 80 columns per line.
			trace("80 columns selected, not supported");
		    case 4:
			// SET jump-scroll mode.
		    // case 5: // DECSCNM - screen
			// trace("DECSCNM");
		    case 6: // DECOM - Origin
			decomMode = false;
		    case 7: // DECAWM - auto wrap mode.
			cb.setAutoWrapMode(false);
		    // case 8: // DECARM - auto repeat
			// trace("DECARM");
		    case 25:
			cb.setCursorVisibility(false);
		    // case 40: // Allow 80 -> 132 Mode
		    // case 45: // Reverse-wraparound Mode
		    case 47:
			// trace("Use normal screen.");
		    case 1049:
			// trace("Use normal screen.");
		    default:
			trace("Unknown DECRST-setting: " + params[i]);
		}
	    }
	} else {
	    // Reset Mode.
	    for(i in 0 ... nParams) {
		switch(params[i]) {
		    case 4: // IRM - Insert/replace
			irmMode = false;
		    case 20: // LNM - Line Feed/New Line Mode.
			lnmMode = false;
		    default:
			trace("Unknown RM-setting: " + params[i]);
		}
	    }
	}
    }

    private function handle_SM(inter : String, nParams : Int, params : Array<Int>)
    {
	if(inter == "?") {
	    // DEC Private Mode Set.
	    for(i in 0 ... nParams) {
		switch(params[i]) {
		    case 1:
			clh.setApplicationCursorKeys(true);
		    case 3: // DECCOLM - selects 132 columns per line.
			trace("132 columns selected, not supported");
		    case 4:
			// SET smooth scroll mode.
		    // case 5: // DECSCNM - screen
			// trace("DECSCNM");
		    case 6: // DECOM - Origin
			decomMode = true;
		    case 7: // set DECAWM - auto wrap mode.
			cb.setAutoWrapMode(true);
		    case 25:
			cb.setCursorVisibility(true);
		    case 47:
			// trace("Use alt screen");
		    case 1049:
			// trace("Use alt screen");
		    default:
			trace("Unknown DECSET-setting: " + params[i]);
		}
	    }
	} else {
	    // Set Mode.
	    for(i in 0 ... nParams) {
		switch(params[i]) {
		    case 4: // IRM - Insert/replace
			irmMode = true;
		    case 20: // LNM - Line Feed/New Line Mode.
			lnmMode = false;
		    default:
			trace("Unknown SM-setting: " + params[i]);
		}
	    }
	}
    }

    private function handle_TBC(params : Array<Int>)
    {
	var p = params[0];
	if(p == 3) {
	    for(i in 0...tabStops.length)
		tabStops[i] = false;
	} else if(p == 0) {
	    tabStops[cb.getCursX()] = false;
	}
    }

    private function handle_vt_tiledata(params : Array<Int>)
    {
	var subcmd = params[0];
	switch(subcmd) {
	    case 2: // win#; Select a window to output to.
		tiledataWindow = params[0];
	    case 0: // tile; Start a glyph
	        if(cb.isTilesAvailable()) {
	    	// if(tiledataWindow == 3) // MAP.
		    tiledataMode = true;
		    cb.printTile(params[1]);
		}
	    case 1: // End a glyph
		tiledataMode = false;
	    case 3: // End of data.
		tiledataWindow = 0;
	    default:
		trace("Unknown vt-tiledata sequence: params=" + params);
	}
    }

    private function send_DA()
    {
	sendByte(27); // ESC
	sendByte(91);  // [
	sendByte(63);  // ?
	sendByte(48+6);  // 6 = VT102...
	sendByte(99);  // c
    }


    /**********************************************************/
    /* VtParserListener funcions                              */
    /**********************************************************/

    private function getEmptyParams()
    {
	var ret = new Array();
	for(i in 0...16) {
	    ret.push(0);
	}
	return ret;
    }

    private function unknownCmd(prefix : String, cmd : Int, intermediateChars : String)
    {
	trace("Unknown " + prefix + "command: " + intermediateChars + " " + cmd);
    }

    public function vtpEscDispatch(cmd : Int, intermediateChars : String) : Void
    {
	if(intermediateChars == "%") {
	    if(cmd == 64) { // @ -- Change to latin-1
		if(utfEnabled) {
		    setUtfEnabled(false);
		}
	    } else if(cmd == 71) { // G -- Change to UTF-8
		if(!utfEnabled) {
		    setUtfEnabled(true);
		    utfState = 0;
		}
	    } else unknownCmd("ESC ", cmd, intermediateChars);
	} else if(intermediateChars == "(") {
	    // Designate G0 character set.
	    charsets[0] = cmd;
	} else if(intermediateChars == ")") {
	    // Designate G1 character set.
	    charsets[1] = cmd;
	} else if(intermediateChars == "*") {
	    // Designate G2 character set.
	    charsets[2] = cmd;
	} else if(intermediateChars == "+") {
	    // Designate G3 character set.
	    charsets[3] = cmd;
	} else if(intermediateChars == "#") {
	    if(cmd == 0x38) handle_DECALN();
	    else unknownCmd("ESC ", cmd, intermediateChars);
	} else if(intermediateChars == "") {
	    switch(cmd) {
		case 55: // 7
		    handle_DECSC();
		case 56: // 8
		    handle_DECRC();
		case 61: // =
		    handle_DECPAM();
		case 62: // >
		    handle_DECPNM();
		case 65: // A
		    handle_CUU(getEmptyParams());
		case 66: // B
		    handle_CUD(getEmptyParams());
		case 67: // C
		    handle_CUF(getEmptyParams());
		case 68: // D
		    vtpExecute(0x84);
		case 69: // E
		    vtpExecute(0x85);
		case 70: // F
		    handle_CPL(getEmptyParams());
		case 71: // G
		    handle_CHA(getEmptyParams());
		case 72: // H
		    vtpExecute(0x88);
		case 77: // M
		    handle_RI();
		case 78: // N
		    vtpExecute(0x8E);
		case 79: // O
		    vtpExecute(0x8F);
		case 80: // P
		    vtpExecute(0x90);
		case 86: // V
		    vtpExecute(0x96);
		case 87: // W
		    vtpExecute(0x97);
		case 88: // X
		    vtpExecute(0x98);
		case 90: // Z
		    send_DA();
		case 99: // c
		    handle_RIS();
		default:
		    unknownCmd("ESC ", cmd, intermediateChars);
	    }
	} else unknownCmd("ESC ", cmd, intermediateChars);
    }

    public function vtpCsiDispatch(cmd : Int,
				   intermediateChars : String,
				   nParams : Int,
				   params : Array<Int>) : Void
    {
	maybeRemovePrompt();
	switch(cmd) {
	    case 64: // @
		handle_ICH(params);
	    case 65: // A
		handle_CUU(params);
	    case 66: // B
		handle_CUD(params);
	    case 67: // C
		handle_CUF(params);
	    case 68: // D
		handle_CUB(params);
	    case 69: // E
		handle_CNL(params);
	    case 70: // F
		handle_CPL(params);
	    case 71: // G
		handle_CHA(params);
	    case 72: // H
		handle_CUP(params);
	    case 74: // J
		handle_ED(params);
	    case 75: // K
		handle_EL(params);
	    case 76: // L
		handle_IL(params);
	    case 77: // M
		handle_DL(params);
	    case 80: // P
		handle_DCH(params);
	    case 98: // b
		handle_REP(params);
	    case 99: // c
		handle_DA(intermediateChars);
	    case 102:
		handle_HVP(params);
	    case 103: // g
		handle_TBC(params);
	    case 104: // h
		handle_SM(intermediateChars, nParams, params);
	    case 108: // l
		handle_RM(intermediateChars, nParams, params);
	    case 109: // m
		handle_SGR(nParams, params);
	    case 114: // r
		handle_DECSTBM(params);
	    case 122: // z
		handle_vt_tiledata(params);
	    default:
		trace("Unknown ESC-seq:" + intermediateChars + " " + cmd + " nParams=" + nParams + " params=" + params);
	}
    }

    public function vtpDcsHook(cmd : Int, intermediateChars : String, nParams : Int, params : Array<Int>) : Void
    {
	// TODO
    }

    public function vtpDcsPut(c : Int) : Void
    {
	// TODO
    }

    public function vtpDcsUnhook() : Void
    {
	// TODO
    }

    public function vtpOscStart() : Void
    {
	oscString = "";
    }

    public function vtpOscPut(c : Int) : Bool
    {
	if(c == 7) return true;
	oscString = oscString + String.fromCharCode(c);
	return false;
    }

    public function vtpOscEnd() : Void
    {
	var params = oscString;
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

    public function vtpExecute(b : Int)
    {
	switch(b) {
	    case 0: // NUL
		// Ignore.
	    case 7: // Bell.
		cb.bell();
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
		var newX = 0;
		var newY = cb.getCursY();
		if(lnmMode) {
		    cb.setCurs(0, newY);
		} else {
		    newX = cb.getCursX();
		}
		cb.setExtraCurs(newX, newY);
	    case 11: // VT - Vertical tabulation.
		vtpExecute(10); // Process it just like LF.
	    case 12: // FF - Form feed.
		vtpExecute(10); // Process it just like LF.
	    case 13: // CR
		if(cb.getCursX() != 0) {
		    receivedCr = true;
		}
	    case 14: // CTRL-N, Shift Out -> Switch to G1 character set.
		charset = 1;
		nextCharacterCharset = charset;
	    case 15: // CTRL-O, Shift In -> Switch to G0 character set.
		charset = 0;
		nextCharacterCharset = charset;
	    case 0x84:
		handle_CUB(getEmptyParams());
	    case 0x85:
		    vtpExecute(13);
		    vtpExecute(10);
	    case 0x88:
		    handle_HTS();
	    case 0x8D: // RI
		maybeRemovePrompt();
		handle_RI();
	    case 0x8E: // SS2
		nextCharacterCharset = 2;
	    case 0x8F: // SS3
		nextCharacterCharset = 3;
	    case 0x90: // DCS
		// TODO
	    case 0x96: // SPA
		// TODO
	    case 0x97: // EPA
		// TODO
	    case 0x98: // SOS
		// TODO
	    case 0x9A: // DECID
		// TODO
	    default:
		unknownCmd("", b, "");
	}
    }
    
    public function vtpPrint(b : Int)
    {
    	if(tiledataMode) return; // No output in tile data mode.
	maybeRemovePrompt();
	b = translateCharset(b);
	newPromptString.addChar(b);
	newPromptAttribute.push(cb.getAttributes().clone());
	latestPrintableChar = b;
	if(irmMode) cb.insertChar(b);
	else cb.printChar(b);
    }

    /** Draws the prompt on the CharBuffer **/
    public function drawPrompt()
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

    /******************************************************/
    /* End of IVtParserListener implementation            */
    /******************************************************/

    /*
       Decode UTF-8 encoding, then call the VtParser.
     */
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
	    vtParser.handleReceivedByte(b);
	} catch ( ex : Dynamic ) {
	    trace(ex);
	}
    }

    private function gotPrompt_(isTimeout : Bool)
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
		newPromptAttribute = new Array<CharAttributes>();
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

    private function setColoursDefault()
    {
	var attr = cb.getAttributes();
	attr.setDefaultAttributes();
	attr.setFgColour(config.getDefaultFgColour());
	attr.setBgColour(config.getDefaultBgColour());
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
