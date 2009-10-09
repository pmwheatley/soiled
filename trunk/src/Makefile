.SILENT:

CP=cp

all: install

install: soiled.swf
	$(CP) soiled.swf ../html/soiled.swf

CompileTime.hx:
	date '+class CompileTime { public static var time = "%Y-%m-%d %H:%M:%S";}'> CompileTime.hx

soiled.swf: CharBuffer.hx Client.hx CommandLineHandler.hx CompileTime.hx Config.hx IVtParserListener.hx Telnet.hx ITelnetEventListener.hx VT100.hx VtParser.hx compile.hxml
	@echo Compiling soiled.swf
	haxe compile.hxml
	rm CompileTime.hx
