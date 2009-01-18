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

import flash.ui.ContextMenu;
import flash.ui.ContextMenuItem;
import flash.events.ContextMenuEvent;

import flash.text.TextField;
import flash.text.TextFormat;
import flash.text.TextFieldType;
import flash.text.TextFieldAutoSize;
import flash.events.TextEvent;

class Client {
    private static var charBuffer : CharBuffer;
    private static var vt100 : VT100;
    private static var telnet : Telnet;

    private static function asc(b : Int) {
	if(b == 10) return "\n";
	if(b == 9) return "\t";
	if(b < 32) return "";
	return String.fromCharCode(b);
    }

    private static function onCopy(o : Dynamic)
    {
	// trace("Copy" + o);
	if(charBuffer.doCopy())
	    flash.system.System.setClipboard(charBuffer.getSelectedText());
    }

    private static function onPaste(o : Dynamic)
    {
	// trace("Paste" + o);
	vt100.doPaste(charBuffer.getSelectedText());
    }

    /*
    private static function onPasteFromTextField(o : Dynamic)
    {
	trace(o);
    }
    */

    private static function onCopyPaste(o : Dynamic)
    {
	onCopy(o);
	onPaste(o);
    }

    private static var textField : TextField;

    private static function onText(o : Dynamic)
    {
	try {
	    var e : TextEvent = o;
	    e.stopPropagation();
	    e.preventDefault();
	    // trace(e);
	    if(e.text.length > 1) {
		vt100.doPaste(e.text);
	    } else {
		var c = e.text.charCodeAt(0);
		var newEvent = new flash.events.KeyboardEvent("textInput", false, false, c);
		vt100.handleKey(newEvent);
	    }
	} catch(ex : Dynamic) {
	    trace(ex);
	}
    }

    private static function onKeyDown(o : Dynamic)
    {
	// trace(o);
	try {
	    var e : flash.events.KeyboardEvent = o;
	    // trace("KC=" + StringTools.hex(e.keyCode) + " CC=" + StringTools.hex(e.charCode));

	    vt100.handleKey(e);

	} catch ( ex : Dynamic ) {
	    trace(ex);
	}
    }
    
    static function onResize(o : Dynamic)
    {
	textField.width = charBuffer.width = flash.Lib.current.stage.stageWidth;
	textField.height = charBuffer.height = flash.Lib.current.stage.stageHeight;
	if(vt100.onResize() && (telnet != null)) {
	    telnet.sendNawsInfo();
	}
    }

    private static function onClose(o : Dynamic)
    {
	telnet.removeEventListener("close", onClose);
	telnet = null;
	vt100.onDisconnect();
	charBuffer.appendText("% Connection to server was closed by foreign host.\n");
    }

    static var mouseDown : Bool;
    static var lastX : Int;
    static var lastY : Int;

    static function onMouseDown(o : Dynamic)
    {
	mouseDown = true;
	if(telnet == null) connect();
	else {
	    var x = charBuffer.getColumn(o.localX);
	    var y = charBuffer.getRow(o.localY);
	    if(o.ctrlKey) {
		mouseDown = false;
		var s = charBuffer.getWordAt(x, y);
		flash.Lib.getURL(new flash.net.URLRequest(s), "_blank");
	    } else {
		lastX = x;
		lastY = y;
		vt100.onMouseDown(x+1, y+1, 0);
		charBuffer.beginSelect(o.localX, o.localY);
	    }
	}
    }

    static function onMouseMove(o : Dynamic)
    {
	if(telnet != null && mouseDown) {
	    var x = charBuffer.getColumn(o.localX);
	    var y = charBuffer.getRow(o.localY);
	    if(lastX == x && lastY == y) return;
	    lastX = x;
	    lastY = y;
	    vt100.onMouseMove(x+1, y+1, 0);
	    charBuffer.updateSelect(o.localX, o.localY);
	}
    }

    static function onMouseUp(o : Dynamic)
    {
	// trace(o);
	if(!mouseDown) return;
	mouseDown = false;
	if(telnet != null) {
	    var x = charBuffer.getColumn(o.localX);
	    var y = charBuffer.getRow(o.localY);
	    vt100.onMouseUp(x+1, y+1, 0);
	    charBuffer.endSelect(o.localX, o.localY);
	}
    }

    static function onDoubleClick(o : Dynamic)
    {
	// trace(o);
	if(telnet != null) {
	    var x = charBuffer.getColumn(o.localX);
	    var y = charBuffer.getRow(o.localY);
	    vt100.onMouseDouble(x+1, y+1, 0);
	    charBuffer.doubleClickSelect(o.localX, o.localY);
	}
    }

    static function connect()
    {
	var params : Dynamic<String> = flash.Lib.current.loaderInfo.parameters;
	vt100.reset();
	charBuffer.appendText("\n\nConnecting to " +
	                 params.s + ":" + params.p + "... ");
	telnet = new Telnet(vt100, params.s, Std.parseInt(params.p));
	telnet.addEventListener("close", onClose);
    }

    static function sendByte(b : Int) {
        // trace("Sending: " + b);
	if(telnet != null) {
	    // TODO: Optimize. No need to flush after each byte...
	    telnet.writeByte(b);
	    telnet.flush();
	} else if(b == 10) {
	    connect();
	}
    }

    static function main() {
        try {
            flash.Lib.current.stage.scaleMode = flash.display.StageScaleMode.NO_SCALE;
            flash.Lib.current.stage.align = flash.display.StageAlign.TOP_LEFT;

	    var params : Dynamic<String> = flash.Lib.current.loaderInfo.parameters;

	    if(params.debug == null) {
		haxe.Log.trace = noTrace;
	    }

	    if(params.policyFile != null) {
		trace("Loading policy file from: " + params.policyFile);
		flash.system.Security.loadPolicyFile(params.policyFile);
	    }

            charBuffer = new CharBuffer();
            vt100 = new VT100(sendByte, charBuffer);

	    textField = new TextField();
	    textField.type = TextFieldType.INPUT;
	    textField.autoSize = TextFieldAutoSize.NONE;
	    textField.background = false;
	    textField.multiline = true;
	    textField.alpha = 0.0;
	    textField.addEventListener(TextEvent.TEXT_INPUT, onText);
	    textField.width = flash.Lib.current.width;
	    textField.height = flash.Lib.current.height;

	    flash.Lib.current.addChild(textField);
            flash.Lib.current.addChild(charBuffer);

            onResize(null);


            charBuffer.appendText("\n\n Soiled, version 0.43 (" + CompileTime.time + ")\n" +
		    "  (C)2007-2009 Sebastian Andersson.");

	    var contextMenu = new ContextMenu();
	    contextMenu.hideBuiltInItems();


/* #if flash10

   This doesn't work on textfields... One has got to low the exceptions they
   make all of the time...

	    contextMenu.clipboardMenu = true;
	    contextMenu.clipboardItems.copy = false;
	    contextMenu.clipboardItems.cut = false;
	    contextMenu.clipboardItems.paste = true;
	    contextMenu.clipboardItems.clear = false;
	    contextMenu.clipboardItems.selectAll = false;
  #end */

	    var customMenu = new ContextMenuItem("Copy Selected Text");
	    contextMenu.customItems.push(customMenu);
	    customMenu.addEventListener(ContextMenuEvent.MENU_ITEM_SELECT, onCopy);
	    var customMenu = new ContextMenuItem("Paste Copied Text");
	    contextMenu.customItems.push(customMenu);
	    customMenu.addEventListener(ContextMenuEvent.MENU_ITEM_SELECT, onPaste);
	    var customMenu = new ContextMenuItem("Copy and Paste");
	    contextMenu.customItems.push(customMenu);
	    customMenu.addEventListener(ContextMenuEvent.MENU_ITEM_SELECT, onCopyPaste);
	    charBuffer.parent.contextMenu = contextMenu;

	    textField.contextMenu = contextMenu;


            flash.Lib.current.stage.addEventListener(flash.events.KeyboardEvent.KEY_DOWN, onKeyDown);
            flash.Lib.current.stage.addEventListener(flash.events.MouseEvent.MOUSE_DOWN, onMouseDown);
            flash.Lib.current.stage.addEventListener(flash.events.MouseEvent.MOUSE_UP, onMouseUp);
            flash.Lib.current.stage.addEventListener(flash.events.MouseEvent.MOUSE_MOVE, onMouseMove);
            flash.Lib.current.stage.addEventListener(flash.events.MouseEvent.DOUBLE_CLICK, onDoubleClick);
	    flash.Lib.current.stage.doubleClickEnabled = true;

#if flash10
	    // This doesn't work due to a bug in the player as of 10.0.0.0...
	    // flash.Lib.current.stage.addEventListener(flash.events.Event.PASTE, onPasteFromTextField);
#end

            // flash.Lib.current.stage.focus = vt100;
            flash.Lib.current.stage.addEventListener("resize", onResize);
	    charBuffer.appendText("\n\nClick on this window to connect.\nWrite /help to read the documentation.\n");

        } catch(ex : Dynamic) {
            trace(ex);
        }
    }

    // A null-trace method to disable tracing.
    private static function noTrace( v : Dynamic, ?inf : haxe.PosInfos) {
	// Nothing
    }
}
