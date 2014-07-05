/* Soiled - The flash mud client.
   Copyright 2007-2014 Sebastian Andersson

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

import flash.display.Loader;
import flash.display.Bitmap;
import flash.events.ContextMenuEvent;
import flash.events.Event;
import flash.events.IOErrorEvent;
import flash.events.TextEvent;
import flash.net.URLLoader;
import flash.net.URLRequest;
import flash.text.TextField;
import flash.text.TextFormat;
import flash.text.TextFieldType;
import flash.text.TextFieldAutoSize;
import flash.system.Security;
import flash.ui.ContextMenu;
import flash.ui.ContextMenuItem;

/* The main class, it sets up the other classes,
   routes the I/O and GUI events to the other classes.
*/
class Client {

    private static var config : Config;
    private static var charBuffer : CharBuffer;
    private static var vt100 : VT100;
    private static var telnet : Telnet;

    private static var textField : TextField;

    static var mouseDown : Bool;
    static var lastX : Int;
    static var lastY : Int;

    /* Convert an integer to its character value (as a string) */
    private static function asc(b : Int) {
	if(b == 10) return "\n";
	if(b == 9) return "\t";
	if(b < 32) return "";
	return String.fromCharCode(b);
    }

    /* The "Copy" action has been performed by the user */
    private static function onCopy(o : Dynamic)
    {
	if(charBuffer.doCopy())
	    flash.system.System.setClipboard(charBuffer.getSelectedText());
    }

    /* The "Copy As HTML" action has been performed by the user */
    private static function onCopyHtml(o : Dynamic)
    {
	if(charBuffer.doCopyAsHtml())
	    flash.system.System.setClipboard(charBuffer.getSelectedText());
    }

    /* The "Paste" action has been performed by the user */
    private static function onPaste(o : Dynamic)
    {
	vt100.doPaste(charBuffer.getSelectedText());
    }

    /* The "Copy & Paste" action has been performed by the user */
    private static function onCopyPaste(o : Dynamic)
    {
	onCopy(o);
	onPaste(o);
    }

    /* Text has been written/pasted by the user */
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
		var newEvent = new MyKeyboardEvent();
		newEvent.charCode = c;
		newEvent.isTextInput = true;
		vt100.handleKey(newEvent);
	    }
	} catch(ex : Dynamic) {
	    trace(ex);
	}
    }

    /* The user has pressed a key */
    private static function onKeyDown(o : Dynamic)
    {
	try {
	    var e : flash.events.KeyboardEvent = o;

	    var m = new MyKeyboardEvent();
	    m.altKey = e.altKey;
	    m.shiftKey = e.shiftKey;
	    m.ctrlKey = e.ctrlKey;

	    m.keyCode = e.keyCode;
	    m.charCode = e.charCode;

	    m.isNumpad = e.keyLocation == flash.ui.KeyLocation.NUM_PAD;

	    vt100.handleKey(m);
	} catch ( ex : Dynamic ) {
	    trace(ex);
	}
    }
    
    /* The user has resized the client */
    static function onResize(o : Dynamic)
    {
	textField.width = charBuffer.width = flash.Lib.current.stage.stageWidth;
	textField.height = charBuffer.height = flash.Lib.current.stage.stageHeight;
	if(vt100.onResize() && (telnet != null)) {
	    telnet.sendNawsInfo();
	}
    }

    /* The socket has been closed to the server */
    private static function onClose(o : Dynamic)
    {
	telnet.removeEventListener("close", onClose);
	telnet = null;
	vt100.onDisconnect();
	charBuffer.appendText("% Connection to server was closed by foreign host.\n");
    }

    /* The CharBuffer has a new font */
    private static function onNewFont()
    {
	if(telnet != null) {
	    telnet.sendNawsInfo();
	}
    }

    /* The user has pressed the mouse button */
    static function onMouseDown(o : Dynamic)
    {
	mouseDown = true;
	if(telnet == null) connect();
	else {
	    var x = charBuffer.getColumnFromLocalX(o.localX);
	    var y = charBuffer.getRowFromLocalY(o.localY);
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

    /* The user has moved the mouse */
    static function onMouseMove(o : Dynamic)
    {
	if(telnet != null && mouseDown) {
	    var x = charBuffer.getColumnFromLocalX(o.localX);
	    var y = charBuffer.getRowFromLocalY(o.localY);
	    if(lastX == x && lastY == y) return;
	    lastX = x;
	    lastY = y;
	    vt100.onMouseMove(x+1, y+1, 0);
	    charBuffer.updateSelect(o.localX, o.localY);
	}
    }

    /* The user has released the mouse button */
    static function onMouseUp(o : Dynamic)
    {
	if(!mouseDown) return;
	mouseDown = false;
	if(telnet != null) {
	    var x = charBuffer.getColumnFromLocalX(o.localX);
	    var y = charBuffer.getRowFromLocalY(o.localY);
	    vt100.onMouseUp(x+1, y+1, 0);
	    charBuffer.endSelect(o.localX, o.localY);
	}
    }

    /* The user has double clicked */
    static function onDoubleClick(o : Dynamic)
    {
	if(telnet != null) {
	    var x = charBuffer.getColumnFromLocalX(o.localX);
	    var y = charBuffer.getRowFromLocalY(o.localY);
	    vt100.onMouseDouble(x+1, y+1, 0);
	    charBuffer.doubleClickSelect(o.localX, o.localY);
	}
    }

    /* Connect to the configured server address and port */
    static function connect()
    {
	if(Security.sandboxType != Security.REMOTE &&
	   Security.sandboxType != Security.LOCAL_WITH_NETWORK) {
	    charBuffer.appendText("\n\nThis client was not loaded from a HTTP server, so it can not connect to the network.\nThe sandbox type is: " + Security.sandboxType);
	} else {
	    var params : Dynamic<String> = flash.Lib.current.loaderInfo.parameters;
	    vt100.reset();
	    charBuffer.appendText("\n\nConnecting to " +
		    params.s + ":" + params.p + "... ");
	    telnet = new Telnet(vt100,
		                params.s,
				Std.parseInt(params.p),
				params.ssl != null,
				config);
	    telnet.addEventListener("close", onClose);
	}
    }

    /* Send a byte to the server */
    static function sendByte(b : Int) {
	if(telnet != null) {
	    // TODO: Optimize. No need to flush after each byte...
	    telnet.writeByte(b);
	    telnet.flush();
	} else if(b == 10) {
	    connect();
	}
    }

    /* The first method called */
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

            config = new Config();
            charBuffer = new CharBuffer(onNewFont, config);
	    var clh = new CommandLineHandler(sendByte,
                                             charBuffer,
                                             config,
					     new FontRepository());
            vt100 = new VT100(sendByte, charBuffer, clh, config);
            clh.setDrawPrompt(vt100.drawPrompt);

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

	    charBuffer.appendText("Soiled, version pre-0.47 (" + CompileTime.time + ")\n" +
		    "  (C)2007-2014 Sebastian Andersson.");

	    var loader = new URLLoader();
	    loader.addEventListener(Event.COMPLETE, onMotdLoaded);
	    loader.addEventListener(IOErrorEvent.IO_ERROR, onMotdError);
	    loader.load(new URLRequest("soiled.txt"));

	    loader = new URLLoader();
	    loader.addEventListener(Event.COMPLETE, onTileDescriptionLoaded);
	    loader.addEventListener(IOErrorEvent.IO_ERROR, onTilesetError);
	    loader.load(new URLRequest("tilesets.txt"));

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

	    customMenu = new ContextMenuItem("Paste Copied Text");
	    contextMenu.customItems.push(customMenu);
	    customMenu.addEventListener(ContextMenuEvent.MENU_ITEM_SELECT, onPaste);

	    customMenu = new ContextMenuItem("Copy and Paste");
	    contextMenu.customItems.push(customMenu);
	    customMenu.addEventListener(ContextMenuEvent.MENU_ITEM_SELECT, onCopyPaste);

	    customMenu = new ContextMenuItem("Copy Selected Text As HTML");
	    contextMenu.customItems.push(customMenu);
	    customMenu.addEventListener(ContextMenuEvent.MENU_ITEM_SELECT, onCopyHtml);

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
	} catch(ex : Dynamic) {
	    trace(ex);
	}
    }

    private static function onMotdLoaded(o : Dynamic)
    {
	charBuffer.appendText(o.target.data);
    }

    private static var tileDescriptions : List<String>;
    private static var currTileWidth : Int;
    private static var currTileHeight : Int;

    private static function onTileDescriptionLoaded(o : Dynamic)
    {
	tileDescriptions = new List<String>();
	var res : String = o.target.data;
	for(row in res.split("\n")) {
	    row = StringTools.trim(row);
	    if(row.length > 0 && row.charAt(0) != '#') {
		tileDescriptions.add(row);
	    }
	}
	if(!tileDescriptions.isEmpty()) {
	    var firstRow = tileDescriptions.first().split(";");
	    var filename = firstRow[0];
	    currTileWidth = Std.parseInt(firstRow[1]);
	    currTileHeight = Std.parseInt(firstRow[2]);
	    var imgLoader = new Loader();
	    var li = imgLoader.contentLoaderInfo;
	    li.addEventListener(Event.INIT, onTileImageComplete);
	    imgLoader.load(new URLRequest(filename));
	} else {
	    trace("No tileset defined");
	}
    }

    private static function onTileImageComplete(o : Dynamic)
    {
        var bitmap = cast(o.target.loader.content, Bitmap);
        charBuffer.changeTileset(bitmap.bitmapData, currTileWidth, currTileHeight);
    }

    private static function onMotdError(o : Dynamic)
    {
	trace("Failed to load soiled.txt: " + o);
	charBuffer.appendText("\n\nClick on this window to connect.\nWrite /help to read the documentation.\n");
    }

    private static function onTilesetError(o : Dynamic)
    {
	trace("Failed to load tilesets.txt or the first tileset:" + o);
    }

    // A null-trace method to disable tracing.
    private static function noTrace( v : Dynamic, ?inf : haxe.PosInfos) {
	// Nothing
    }
}
