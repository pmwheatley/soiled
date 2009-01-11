interface TelnetEventListener {

    /* Tells the client if the server is supposed to echo entered text or not. */
    function changeServerEcho(remoteEcho : Bool) : Void;

    /* If on is true, tells the client that it should use UTF-8 should be used
       to/from the server. */
    function setUtfEnabled(on : Bool) : Void;

    /* The cursor has been received from the server */
    function onPromptReception() : Void;

    /* Handle a received byte from the server, after telnet processing */
    function onReceiveByte(b : Int) : Void;

    /* No more bytes are received, draw everything */
    function flush() : Void;

    /* Writes some text to the screen */
    function appendText(s : String) : Void;

    /* Gets the size of the screen */
    function getColumns() : Int;
    function getRows() : Int;
}
