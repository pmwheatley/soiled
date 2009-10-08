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

   The project's page is located here: http://code.google.com/p/soiled/
*/

enum EnuVtInputState
{
    VIS_GROUND; // The initial state.
    VIS_ESC;
    VIS_ESC_INTER;
    VIS_CSI_ENTRY;
    VIS_CSI_IGNORE;
    VIS_CSI_INTER; // intermediate.
    VIS_CSI_PARAM;
    VIS_DCS_ENTRY;
    VIS_DCS_IGNORE;
    VIS_DCS_INTER;
    VIS_DCS_PARAM;
    VIS_DCS_PASS; // passthrough
    VIS_OSC_STRING; 
    VIS_SOS_PM_APC_STRING;
}


/* A parser for the VT500-series.

   This is the low level parse, layered above UTF-8 decoding.

   This one is an implementation of the state diagram defined here:
   http://vt100.net/emu/ by Paul Williams.

   Changes from that state-diagram:
   - All characters above 0x9F are handled like 20-7F characters.
   - OSC_STRING can end with BEL (to be xterm combatible).
   - The transitions to DCS_PASSTHROUGH will keep the character, for
     use by the hook action.

   All commands are handled by some class implementing IVtParserListener.
 */
class VtParser
{
    private inline static var UCS_ERROR = 0xFFFD;
    private inline static var MAX_PARAMS = 16;

    private var inputState : EnuVtInputState;

    private var listener : IVtParserListener;

    private var intermediateChars : String;

    private var nParams : Int;

    private var params : Array<Int>;

    public function new(listener : IVtParserListener)
    {
	this.listener = listener;
	params = new Array();
	params[MAX_PARAMS-1] = 0;
    }

    public function reset()
    {
	this.inputState = VIS_GROUND;
	clear();
    }

    public function handleReceivedByte(b : Int)
    {
	// if(inputState != VIS_GROUND) {
	    // trace("Processing char: " + b);
	// }
	try {
	    switch(b) {
		case 0x18,
		     0x1A,
		     0x80,0x81,0x82,0x83,0x84,0x85,0x86,0x87,
		     0x88,0x89,0x8A,0x8B,0x8C,0x8D,0x8E,0x8F,
		     0x91,0x92,0x93,0x94,0x95,0x96,0x97,0x99,
		     0x9A:
		    enterState(VIS_GROUND);
		    listener.vtpExecute(b);
		case 0x1B: enterState(VIS_ESC);
		case 0x90: enterState(VIS_DCS_ENTRY);
		case 0x98, 0x9E, 0x9F:
		    enterState(VIS_SOS_PM_APC_STRING);
		case 0x9B: enterState(VIS_CSI_ENTRY);
		case 0x9C: enterState(VIS_GROUND);
		case 0x9D: enterState(VIS_OSC_STRING);
		default:
		    switch(inputState)
		    {
			case VIS_GROUND: handleGroundState(b);
			case VIS_ESC_INTER: handleEscInter(b);
			case VIS_SOS_PM_APC_STRING: handleSosPmApcString(b);
			case VIS_ESC: handleEsc(b);
			case VIS_DCS_ENTRY: handleDcsEntry(b);
			case VIS_DCS_INTER: handleDcsInter(b);
			case VIS_CSI_PARAM: handleCsiParam(b);
			case VIS_DCS_IGNORE: handleDcsIgnore(b);
			case VIS_CSI_IGNORE: handleCsiIgnore(b);
			case VIS_OSC_STRING: handleOscString(b);
			case VIS_DCS_PARAM: handleDcsParam(b);
			case VIS_CSI_INTER: handleCsiInter(b);
			case VIS_CSI_ENTRY: handleCsiEntry(b);
			case VIS_DCS_PASS: handleDcsPass(b);
		    }
	    }
	} catch(ex : Dynamic) {
	    trace(ex);
	}
    }

    /* Private functions below here */

    private function enterState(state : EnuVtInputState)
    {
	// trace("Leaving state : " + inputState + " entering: " + state);
	// Leave old state action
	if(inputState == VIS_DCS_PASS) {
	    listener.vtpDcsUnhook();
	} else if(inputState == VIS_OSC_STRING) {
	    listener.vtpOscEnd();
	}

	inputState = state;

	// Enter new state action
	if(state == VIS_ESC ||
	   state == VIS_DCS_ENTRY ||
	   state == VIS_CSI_ENTRY) {
	    clear();
	} else if(state == VIS_OSC_STRING) {
	    listener.vtpOscStart();
	}
    }

    private function clear()
    {
	intermediateChars = "";
	nParams = 0;
    }

    private function collect(b)
    {
	// Store the private marker and intermediate character(s).
	intermediateChars += String.fromCharCode(b);
    }

    private function param(b)
    {
	// Store the parameters.

	if(nParams > MAX_PARAMS) return;

	if(nParams == 0) {
	    nParams += 1;
	    params[0] = 0;
	}
	if(b == 0x3B) { // ;
	    nParams++;
	    if(nParams <= MAX_PARAMS) params[nParams-1] = 0;
	} else {
	    var i = nParams-1;
	    params[i] *= 10;
	    params[i] += b - 0x30;
	    // The maximum size of a parameter is 10^5-1
	    if(params[i] > 99999) params[i] = 99999;
	}
    }

    private function escDispatch(b)
    {
	listener.vtpEscDispatch(b, intermediateChars);
    }

    private function csiDispatch(b : Int)
    {
	for(i in nParams...MAX_PARAMS) {
	    params[i] = 0;
	}
	// trace("CsiDispatching: " + intermediateChars + " " + b + " nP=" + nParams + " P=" + params);
	listener.vtpCsiDispatch(b, intermediateChars, nParams, params);
	// trace("CsiDispatched");
    }

    private function handleGroundState(b : Int)
    {
	if((b >= 0x00 && b <= 0x1F)) { // 18, 1A and 1B are handled elsewhere.
	    listener.vtpExecute(b);
	} else {
	    listener.vtpPrint(b);
	}
    }

    private function handleEscInter(b : Int)
    {
	if(b >= 0x00 && b <= 0x1F) {
	    listener.vtpExecute(b);
	} else if(b >= 0x20 && b <= 0x2F) {
	    collect(b);
	} else if(b == 0x7F) {
	    // Ignore.
	} else {
	    enterState(VIS_GROUND);
	    escDispatch(b);
	}
    }

    private function handleSosPmApcString(b : Int)
    {
	// Ignore.
	// 9C terminates this state, but it is already handled.
    }

    private function handleEsc(b : Int)
    {
	if(b == 0x58 ||
           b == 0x5E ||
	   b == 0x5F) {
	    enterState(VIS_SOS_PM_APC_STRING);
	} else if(b >= 0x20 && b <= 0x2F) {
	    enterState(VIS_ESC_INTER);
	    handleEscInter(b);
	} else if(b == 0x50) {
	    enterState(VIS_DCS_ENTRY);
	} else if(b == 0x5D) {
	    enterState(VIS_OSC_STRING);
	} else if(b == 0x5B) {
	    enterState(VIS_CSI_ENTRY);
	} else if(b == 0x7F) {
	    // Ignore
	} else if(b >= 0x00 && b <= 0x1F) {
	    listener.vtpExecute(b);
	} else {
	    enterState(VIS_GROUND);
	    escDispatch(b);
	}
    }

    private function handleDcsEntry(b : Int)
    {
	if(b >= 0x20 && b <= 0x2F) {
	    collect(b);
	    enterState(VIS_DCS_INTER);
	} else if((b >= 0x00 && b <= 0x1F) || // 18, 1A, 1B are handled already.
		  b == 0x7F) {
	    // ignore.
	} else if(b == 0x3A) {
	    enterState(VIS_DCS_IGNORE);
	} else if((b >= 0x30 && b <= 0x3B)) { // 3A handled above.
	    param(b);
	    enterState(VIS_DCS_PARAM);
	} else if (b >= 0x3C && b <= 0x3F) {
	    collect(b);
	    enterState(VIS_DCS_PARAM);
	} else {
	    listener.vtpDcsHook(b, intermediateChars, nParams, params);
	    enterState(VIS_DCS_PASS);
	}
    }

    private function handleDcsInter(b : Int)
    {
	if(b >= 0x30 && b <= 0x3F) {
	    enterState(VIS_DCS_IGNORE);
	} else if((b >= 0x00 && b <= 0x1F) ||
		  b == 0x7F) {
	    // Ignore.
	} else if(b >= 0x20 && b <= 0x2F) {
	    collect(b);
	} else {
	    listener.vtpDcsHook(b, intermediateChars, nParams, params);
	    enterState(VIS_DCS_PASS);
	}
    }

    private function handleCsiParam(b : Int)
    {
	if(b == 0x3A ||
	   (b >= 0x3C && b <= 0x3F)) {
	    enterState(VIS_CSI_IGNORE);
	} else if(b >= 0x20 && b <= 0x2F) {
	    collect(b);
	    enterState(VIS_CSI_INTER);
	} else if(b >= 0x00 && b <= 0x1F) {
	    listener.vtpExecute(b);
	} else if(b >= 0x30 && b <= 0x3B) { // 3A handled above
	    param(b);
	} else if(b == 0x7F) {
	    // Ignore
	} else {
	    enterState(VIS_GROUND);
	    csiDispatch(b);
	}
    }

    private function handleDcsIgnore(b : Int)
    {
	// Ignore.
    }

    private function handleCsiIgnore(b : Int)
    {
	if((b >= 0x40 && b <= 0x7E) ||
           b >= 0xA0) {
	    enterState(VIS_GROUND);
	} else {
	    // Ignore
	}
    }

    private function handleOscString(b : Int)
    {
	if(b == 0x07) {
	    /* This is a deviation from Paul Williams' parser, needed for
	       xterm emulation */
	    if(listener.vtpOscPut(b)) {
		enterState(VIS_GROUND);
	    }
	} else if(b >= 0x00 && b <= 0x1F) {
	    // Ignore
	} else {
	    if(listener.vtpOscPut(b)) {
		enterState(VIS_GROUND);
	    }
	}
    }

    private function handleDcsParam(b : Int)
    {
	if((b >= 0x00 && b <= 0x1F) ||
	   b == 0x7F) {
	    // Ignore.
	} else if(b == 0x3A ||
		  (b >= 0x3C && b <= 0x3F)) {
	    enterState(VIS_DCS_IGNORE);
	} else if(b >= 0x30 && b <= 0x3B) {
	    param(b);
	} else if(b >= 0x20 && b <= 0x2F) {
	    collect(b);
	    enterState(VIS_DCS_INTER);
	} else {
	    listener.vtpDcsHook(b, intermediateChars, nParams, params);
	    enterState(VIS_DCS_PASS);
	}
    }

    private function handleCsiInter(b : Int)
    {
	if(b >= 0x00 && b <= 0x1F) {
	    listener.vtpExecute(b);
	} else if(b == 0x7F) {
	    // Ignore
	} else if(b >= 0x30 && b <= 0x3F) {
	    enterState(VIS_CSI_IGNORE);
	} else if(b >= 0x20 && b <= 0x2F) {
	    collect(b);
	} else {
	    enterState(VIS_GROUND);
	    csiDispatch(b);
	}
    }

    private function handleCsiEntry(b : Int)
    {
	if(b == 0x3A) {
	    enterState(VIS_CSI_IGNORE);
	} else if(b >= 0x00 && b <= 0x1F) {
	    listener.vtpExecute(b);
	} else if(b == 0x7F) {
	    // Ignore.
	} else if(b >= 0x20 && b <= 0x2F) {
	    collect(b);
	    enterState(VIS_CSI_INTER);
	} else if(b >= 0x30 && b <= 0x3B) {
	    param(b);
	    enterState(VIS_CSI_PARAM);
	} else if(b >= 0x3C && b <= 0x3F) {
	    collect(b);
	    enterState(VIS_CSI_PARAM);
	} else {
	    enterState(VIS_GROUND);
	    csiDispatch(b);
	}
    }

    private function handleDcsPass(b : Int)
    {
	if(b == 0x7F) {
	    // Ignore
	} else {
	    listener.vtpDcsPut(b);
	}
    }
}
