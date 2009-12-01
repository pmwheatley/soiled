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

import flash.net.Socket;

enum EnuTelnetInputState {
    TIS_NORMAL;
    TIS_GOT_IAC;
    TIS_GOT_WILL;
    TIS_GOT_WONT;
    TIS_GOT_DO;
    TIS_GOT_DONT;
    TIS_GOT_SB;
    TIS_GOT_SB_IAC;
}

enum EnuTelnetOptionState {
    TOS_NO;
    TOS_YES;
    TOS_WANTYES_EMPTY;
    TOS_WANTNO_EMPTY;
    TOS_WANTYES_OPPOSITE;
    TOS_WANTNO_OPPOSITE;
}

/* An implementation of the Telnet protocol using the Q-method
   of option negotiation.
   The class supports a few of the extra protocols;
   NAWS
   TERMINAL TYPE (TT)
   ECHO
   SUPRESSGOAHEAD
   END OF RECORD (EOR)
   Very basic support of CHARSET.
 */
class Telnet extends flash.events.EventDispatcher {

    private static var terminals : Array<String> = [
    	"xterm-color",
	"Soiled-pre-0.45",
	"Soiled",
    	"xterm",
    	"vt102",
    	"vt100",
    	"ansi",
    	"UNKNOWN",
    	"UNKNOWN" // Must be twice...
	];

    private static inline var ENDOFRECORD : Int = -17;
    private static inline var SE : Int = -16;
    private static inline var GA : Int = -7;
    private static inline var SB : Int = -6;
    private static inline var WILL : Int = -5;
    private static inline var WONT : Int = -4;
    private static inline var DO : Int = -3;
    private static inline var DONT : Int = -2;
    private static inline var IAC : Int = -1;

    private static inline var TO_ECHO : Int = 1;
    private static inline var TO_SUPRESSGOAHEAD = 3;
    private static inline var TO_TT : Int = 24;
    private static inline var TO_EOR : Int = 25;
    private static inline var TO_NAWS : Int = 31;
    private static inline var TO_CHARSET : Int = 42;

    private static inline var TO_CHARSET_REQUEST : Int = 1;
    private static inline var TO_CHARSET_ACCEPTED : Int = 2;
    private static inline var TO_CHARSET_REJECTED : Int = 3;
    private static inline var TO_CHARSET_TTABLE_IS : Int = 4;
    private static inline var TO_CHARSET_TTABLE_REJECTED : Int = 5;
    private static inline var TO_CHARSET_TTABLE_ACK : Int = 6;
    private static inline var TO_CHARSET_TTABLE_NAK : Int = 7;

    private var naws : Bool;

    private var s : Socket;
    private var eventListener : ITelnetEventListener;
    private var inputState : EnuTelnetInputState;

    private var sbOption : StringBuf;

    private var ttIndex : Int;

    private var optionsUs : Array<EnuTelnetOptionState>;
    private var optionsHim : Array<EnuTelnetOptionState>;

    private var config : Config;

    public function new(eventListener : ITelnetEventListener,
	                server : String,
			port : Int,
			config : Config)
    {
	super();

	this.config = config;

	this.ttIndex = -1;

	this.eventListener = eventListener;

	this.inputState = TIS_NORMAL;

	optionsUs = new Array();
	optionsHim = new Array();
	for(i in 0...256) {
	    optionsUs.push(TOS_NO);
	    optionsHim.push(TOS_NO);
	}

	s = new Socket();
	s.addEventListener("socketData", onSocketData);
	s.addEventListener("close", gotClose);
	s.addEventListener("connect", gotConnect);
	s.addEventListener("securityError", gotSecError);
	s.addEventListener("ioError", gotIoError);
	s.connect(server, port);
    }

    public function sendNawsInfo()
    {
	if(naws) {
	    var w = eventListener.getColumns();
	    var h = eventListener.getRows();

	    // trace("Sending NAWS: " + w + "," + h);

	    // Some sane defaults...
	    if(w < 20) w = 20;
	    if(h < 10) h = 10;

	    s.writeByte(IAC);
	    s.writeByte(SB);
	    s.writeByte(TO_NAWS);

	    var w1 = 255 & (w >> 8);
	    var w2 = w & 255;

	    s.writeByte(w1);
	    s.writeByte(w2);
	    if(w2 == 255) s.writeByte(w2);

	    var h1 = 255 & (h >> 8);
	    var h2 = h & 255;

	    s.writeByte(h1);
	    s.writeByte(h2);
	    if(h2 == 255) s.writeByte(h2);

	    s.writeByte(IAC);
	    s.writeByte(SE);
	}
    }

    public function close()
    {
	s.close();
    }
    
    // XXX Optimize this...
    public function writeByte(b : Int)
    {
	if(b == IAC || b == 255) s.writeByte(IAC); // Escape IAC.
	s.writeByte(b);
    }

    public function flush()
    {
	s.flush();
    }

    /* Call this to enable peer's option b */
    private function askHimToTurnOn(b : Int)
    {
	var himQ = optionsHim[b & 255];
	switch(himQ) {
	    case TOS_NO:
	        optionsHim[b & 255] = TOS_WANTYES_EMPTY;
		sendDo(b);
	    case TOS_YES:
		trace("Error, trying to ask peer to turn on enabled option: " + b);
	    case TOS_WANTNO_EMPTY:
	        optionsHim[b & 255] = TOS_WANTNO_OPPOSITE;
	    case TOS_WANTNO_OPPOSITE:
		trace("Error: already queued an peer-enable request for " + b);
	    case TOS_WANTYES_EMPTY:
		trace("Error: already negotiating for enable of peer's " + b);
	    case TOS_WANTYES_OPPOSITE:
	        optionsHim[b & 255] = TOS_WANTYES_EMPTY;
	}
    }

    /* Call this to disable peer's option b */
    private function askHimToTurnOff(b : Int)
    {
	var himQ = optionsHim[b & 255];
	switch(himQ) {
	    case TOS_NO:
		trace("Error, trying to ask peer to turn off disabled option: " + b);
	    case TOS_YES:
	        optionsHim[b & 255] = TOS_WANTNO_EMPTY;
		sendDont(b);
	    case TOS_WANTNO_EMPTY:
		trace("Error: already negotiating for disable of peer's " + b);
	    case TOS_WANTNO_OPPOSITE:
	        optionsHim[b & 255] = TOS_WANTNO_EMPTY;
	    case TOS_WANTYES_EMPTY:
	        optionsHim[b & 255] = TOS_WANTYES_OPPOSITE;
	    case TOS_WANTYES_OPPOSITE:
		trace("Error: already queued a disable request for peer's " + b);
	}
    }

    /* Call this to enable our option b */
    private function askUsToTurnOn(b : Int)
    {
	var usQ = optionsUs[b & 255];
	switch(usQ) {
	    case TOS_NO:
	        optionsUs[b & 255] = TOS_WANTYES_EMPTY;
		sendWill(b);
	    case TOS_YES:
		trace("Error, trying to ask peer to turn on our enabled option: " + b);
	    case TOS_WANTNO_EMPTY:
	        optionsUs[b & 255] = TOS_WANTNO_OPPOSITE;
	    case TOS_WANTNO_OPPOSITE:
		trace("Error: already queued an enable request for our " + b);
	    case TOS_WANTYES_EMPTY:
		trace("Error: already negotiating for enable of our " + b);
	    case TOS_WANTYES_OPPOSITE:
	        optionsUs[b & 255] = TOS_WANTYES_EMPTY;
	}
    }

    /* Call this to disable our option b */
    private function askUsToTurnOff(b : Int)
    {
	var usQ = optionsUs[b & 255];
	switch(usQ) {
	    case TOS_NO:
		trace("Error, trying to disabled our disabled option: " + b);
	    case TOS_YES:
	        optionsUs[b & 255] = TOS_WANTNO_EMPTY;
		sendWont(b);
	    case TOS_WANTNO_EMPTY:
		trace("Error: already negotiating for disable of our " + b);
	    case TOS_WANTNO_OPPOSITE:
	        optionsUs[b & 255] = TOS_WANTNO_EMPTY;
	    case TOS_WANTYES_EMPTY:
	        optionsUs[b & 255] = TOS_WANTYES_OPPOSITE;
	    case TOS_WANTYES_OPPOSITE:
		trace("Error: already queued a disable request for our " + b);
	}
    }

    /* The peer has asked us to turn on this option, should we ? */
    private function turnOnUsOption(b : Int) : Bool
    {
	if(b == TO_NAWS) {
	    return true;
	} else if(b == TO_TT) {
	    return true;
	} else if(b == TO_CHARSET) {
	    return true;
	}
	return false;
    }

    /* Our b option was turned on, now deal with it. */
    private function turnedOnUsOption(b : Int)
    {
	if(b == TO_NAWS) {
	    naws = true;
	    sendNawsInfo();
	} else if(b == TO_CHARSET) {
	    handleCharsetInit();
	}
    }

    /* Our b option has been turned off. Now deal with it. */
    private function turnedOffUsOption(b : Int)
    {
	if(b == TO_NAWS) {
	    naws = false;
	}
    }

    /* The peer wants to turn on the b option, should he? */
    private function turnOnHimOption(b : Int) : Bool
    {
	if(b == TO_ECHO) {
	    return true;
	} else if(b == TO_EOR) {
	    return true;
	} else if(b == TO_SUPRESSGOAHEAD) {
	    return true;
	} else if(b == TO_CHARSET) {
	    return true;
	} else return false;
    }

    /* The peer has turned on the b option, deal with it. */
    private function turnedOnHimOption(b : Int)
    {
	if(b == TO_ECHO) {
	    eventListener.changeServerEcho(true);
	} else if(b == TO_CHARSET) {
	    handleCharsetInit();
	}
    }

    /* The peer has turned off the b option, deal with it. */
    private function turnedOffHimOption(b : Int)
    {
	if(b == TO_ECHO) {
	    eventListener.changeServerEcho(false);
	}
    }

    /* We've received a SB option, handle it */
    private function handleSbOption()
    {
	var str = sbOption.toString();
	if(str.length == 0) return;
	switch(str.charCodeAt(0)) {
	    case TO_CHARSET:
		handleCharsetOption(str);
	    case TO_TT: 
		if(str.length != 2) return;
		if(str.charCodeAt(1) != 1) return; // SEND
		if(++ttIndex >= terminals.length) ttIndex = 0;
		s.writeByte(IAC);
		s.writeByte(SB);
		s.writeByte(TO_TT);
		s.writeByte(0); // IS
		writeString(terminals[ttIndex]);
		s.writeByte(IAC);
		s.writeByte(SE);
	}
    }

    private function handleCharsetInit()
    {
	s.writeByte(IAC);
	s.writeByte(SB);
	s.writeByte(TO_CHARSET);
	s.writeByte(TO_CHARSET_REQUEST);
	s.writeByte(33);
	writeString("UTF-8");
	s.writeByte(33);
	writeString("ISO_8859-1");
	s.writeByte(33);
	writeString("US-ASCII");
	s.writeByte(IAC);
	s.writeByte(SE);
    }

    private function handleCharsetOption(str : String)
    {
	switch(str.charCodeAt(1)) {
	    case TO_CHARSET_REQUEST:
		// XXX Decode request.
	    case TO_CHARSET_ACCEPTED:
		var chrSet = str.substr(2);
		if(chrSet == "UTF-8") {
		    eventListener.setUtfEnabled(true);
		}
	    case TO_CHARSET_REJECTED:
		// No common ground was found.
	    case TO_CHARSET_TTABLE_IS:
		s.writeByte(IAC);
		s.writeByte(SB);
		s.writeByte(TO_CHARSET);
		s.writeByte(TO_CHARSET_TTABLE_REJECTED);
		s.writeByte(IAC);
		s.writeByte(SE);
	    case TO_CHARSET_TTABLE_REJECTED:
	    case TO_CHARSET_TTABLE_ACK:
	    case TO_CHARSET_TTABLE_NAK:
	}
    }

    /* Process received data. */
    private function onSocketData(o : Dynamic)
    {
	if(!eventListener.shouldReceiveData()) return;
	try {
	    while(s.bytesAvailable > 0) {
		var b = s.readByte();

		switch(inputState) {
		    case TIS_NORMAL:
			if(b == IAC) inputState = TIS_GOT_IAC;
			else eventListener.onReceiveByte(b & 255);
		    case TIS_GOT_IAC:
			switch(b) {
			    case GA:
				eventListener.onPromptReception();
				inputState = TIS_NORMAL;
			    case ENDOFRECORD:
				eventListener.onPromptReception();
				inputState = TIS_NORMAL;
			    case WILL:
				inputState = TIS_GOT_WILL;
			    case WONT:
				inputState = TIS_GOT_WONT;
			    case DO:
				inputState = TIS_GOT_DO;
			    case DONT:
				inputState = TIS_GOT_DONT;
			    case SB:
				inputState = TIS_GOT_SB;
				sbOption = new StringBuf();
			    case IAC:
				inputState = TIS_NORMAL;
				eventListener.onReceiveByte(b & 255);
			    default:
				trace("Unknown IAC code: " + b);
				inputState = TIS_NORMAL;
				// eventListener.onReceiveByte(b);
			}
		    case TIS_GOT_SB:
			if(b == IAC) inputState = TIS_GOT_SB_IAC;
			else sbOption.addChar(b);
		    case TIS_GOT_SB_IAC:
			if(b == IAC) {
			    inputState = TIS_GOT_SB;
			    sbOption.addChar(b);
			} else if(b == SE) {
			    inputState = TIS_NORMAL;
			    handleSbOption();
			} else {
			    trace("Incorrect IAC SB sequence");
			    inputState = TIS_NORMAL;
			}
		    case TIS_GOT_WILL:
			inputState = TIS_NORMAL;
			processWillOption(b);
		    case TIS_GOT_WONT:
			inputState = TIS_NORMAL;
			processWontOption(b);
		    case TIS_GOT_DO:
			inputState = TIS_NORMAL;
			processDoOption(b);
		    case TIS_GOT_DONT:
			inputState = TIS_NORMAL;
			processDontOption(b);
		}
	    }
	    eventListener.flush();
	    flush();
	} catch ( ex : Dynamic ) {
	    trace(ex);
	}
    }

    private function processDoOption(b : Int)
    {
	var usQ = optionsUs[b & 255];

	switch(usQ) {
	    case TOS_NO:
		if(turnOnUsOption(b)) {
		    optionsUs[b & 255] = TOS_YES;
		    sendWill(b);
		    turnedOnUsOption(b);
		} else sendWont(b);
	    case TOS_YES:
		// Ignore.
	    case TOS_WANTNO_EMPTY:
		// Error: WONT answered by DO.
		optionsUs[b & 255] = TOS_NO;
	    case TOS_WANTNO_OPPOSITE:
		// Error: WONT answered by DO.
		optionsUs[b & 255] = TOS_YES;
	    case TOS_WANTYES_EMPTY:
		optionsUs[b & 255] = TOS_YES;
		turnedOnUsOption(b);
	    case TOS_WANTYES_OPPOSITE:
		optionsUs[b & 255] = TOS_WANTNO_EMPTY;
		sendWont(b);
	}
    }

    private function processDontOption(b : Int)
    {
	var usQ = optionsUs[b & 255];

	switch(usQ) {
	    case TOS_NO:
		// Ignore.
	    case TOS_YES:
	        optionsUs[b & 255] = TOS_NO;
		sendWont(b);
		turnedOffUsOption(b);
	    case TOS_WANTNO_EMPTY:
	        optionsUs[b & 255] = TOS_NO;
		turnedOffUsOption(b);
	    case TOS_WANTNO_OPPOSITE:
	        optionsUs[b & 255] = TOS_WANTYES_EMPTY;
		sendWill(b);
		turnedOffUsOption(b);
	    case TOS_WANTYES_EMPTY:
	        optionsUs[b & 255] = TOS_NO;
	    case TOS_WANTYES_OPPOSITE:
	        optionsUs[b & 255] = TOS_NO;
	}
    }

    private function processWillOption(b : Int)
    {
	var himQ : EnuTelnetOptionState = optionsHim[b & 255];

	switch(himQ) {
	    case TOS_NO:
		if(turnOnHimOption(b)) {
		    optionsHim[b & 255] = TOS_YES;
		    sendDo(b);
		    turnedOnHimOption(b);
		} else sendDont(b);
	    case TOS_YES:
		// Ignore.
	    case TOS_WANTNO_EMPTY:
		// Error: WONT answered by DO.
		optionsHim[b & 255] = TOS_NO;
	    case TOS_WANTNO_OPPOSITE:
		// Error: WONT answered by DO.
		optionsHim[b & 255] = TOS_YES;
	    case TOS_WANTYES_EMPTY:
		optionsHim[b & 255] = TOS_YES;
		turnedOnHimOption(b);
	    case TOS_WANTYES_OPPOSITE:
		optionsHim[b & 255] = TOS_WANTNO_EMPTY;
		sendDont(b);
	}
    }

    private function processWontOption(b : Int)
    {
	var himQ = optionsHim[b & 255];

	switch(himQ) {
	    case TOS_NO:
		// Ignore.
	    case TOS_YES:
	        optionsHim[b & 255] = TOS_NO;
		sendDont(b);
		turnedOffHimOption(b);
	    case TOS_WANTNO_EMPTY:
	        optionsHim[b & 255] = TOS_NO;
		turnedOffHimOption(b);
	    case TOS_WANTNO_OPPOSITE:
	        optionsHim[b & 255] = TOS_WANTYES_EMPTY;
		sendDo(b);
		turnedOffHimOption(b);
	    case TOS_WANTYES_EMPTY:
	        optionsHim[b & 255] = TOS_NO;
	    case TOS_WANTYES_OPPOSITE:
	        optionsHim[b & 255] = TOS_NO;
	}
    }

    private function sendDo(b : Int)
    {
	s.writeByte(IAC);
	s.writeByte(DO);
	s.writeByte(b);
    }

    private function sendDont(b : Int)
    {
	s.writeByte(IAC);
	s.writeByte(DONT);
	s.writeByte(b);
    }

    private function sendWill(b : Int)
    {
	s.writeByte(IAC);
	s.writeByte(WILL);
	s.writeByte(b);
    }

    private function sendWont(b : Int)
    {
	s.writeByte(IAC);
	s.writeByte(WONT);
	s.writeByte(b);
    }

    private function writeString(str : String)
    {
	for(i in 0...str.length) {
	    s.writeByte(str.charCodeAt(i));
	}
    }

    private function gotSecError(o : Dynamic)
    {
	trace(o);
	eventListener.appendText("Got a security error!\n");
	s.close();
	gotClose(o);
    }

    private function gotClose(o : Dynamic)
    {
	var v = new flash.events.Event("close");
	this.dispatchEvent(v);
	s.close();
    }

    private function gotConnect(o : Dynamic)
    {
	eventListener.appendText("Connected!\n\n");
	var str = config.getAutologin();
	if(str != null) writeString(str);
    }

    private function gotIoError(o : Dynamic)
    {
	var e : flash.events.IOErrorEvent = o;
	eventListener.appendText("Got IO Error:" + e.text + "\n");
	s.close();
	gotClose(o);
    }
}
